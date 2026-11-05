import AppKit
import AVFoundation
import Observation
import ScreenCaptureKit

/// Meeting dictation: your microphone ("Me") and the Mac's sound ("Others", e.g. the people on a call)
/// are transcribed separately on device, saved as you go, and summarized by Claude at the end.
@MainActor @Observable final class MeetingRecorder {
    enum Phase: Equatable { case idle, recording, paused, summarizing, done, failed(String) }

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let me: Bool
        var text: String
        let at: TimeInterval
        var updated: Date
        /// Who said it, when told apart from the others on the same channel (nil: the channel's name).
        var speaker: String?
    }

    var phase = Phase.idle
    /// The meeting being recorded, or the one that just ended (its notes, your notes, the transcript).
    var doc: MeetingDoc
    var volatileMe = ""
    var volatileOthers = ""
    var elapsed: TimeInterval = 0
    var note: String?
    var language = DictationLanguage.both
    var lines: [Line] {
        get { doc.lines }
        set { doc.lines = newValue }
    }
    /// The meeting's name (editable in the meeting window); it names the saved file too.
    var name: String {
        get { doc.title }
        set { doc.title = newValue }
    }

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var mic: MicCapture?
    @ObservationIgnored private var system: SystemAudioCapture?
    @ObservationIgnored private let meRoute = AudioRoute()
    @ObservationIgnored private let othersRoute = AudioRoute()
    @ObservationIgnored private var meT: MixedTranscriber? { didSet { meRoute.target = meT } }
    @ObservationIgnored private var othersT: MixedTranscriber? { didSet { othersRoute.target = othersT } }
    @ObservationIgnored private var ticker: Timer?
    /// Which recording the audio being started belongs to (a stop or a new start makes late starts stand down).
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var savedSlot = -1
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var paused = false
    /// How many lines there were when the speakers were last named (nil: not yet), and whether that's under way.
    @ObservationIgnored private var namedAt: Int?
    @ObservationIgnored private var naming = false
    @ObservationIgnored var onChange: (() -> Void)?

    init(store: Store) {
        self.store = store
        language = store.settings.meetingLanguage
        doc = MeetingDoc(url: MeetingDoc.folder.appendingPathComponent("Meeting.md"))
    }

    var isRunning: Bool { phase == .recording || phase == .paused }

    var clock: String { MeetingDoc.clock(elapsed) }

    // MARK: Control

    /// Starts recording. Named after `event`, or the calendar event on now (its title and attendees).
    func start(event: CalendarEvent? = nil) {
        guard !isRunning, phase != .summarizing else { return }
        micOn = true
        volatileMe = ""
        volatileOthers = ""
        note = nil
        elapsed = 0
        paused = false
        meRoute.paused = false
        othersRoute.paused = false
        startedAt = Date()
        doc = MeetingDoc(url: MeetingDoc.newFile(startedAt), date: startedAt)
        if let e = event ?? CalendarEvents.shared.current() {
            doc.title = e.title
            doc.attendees = e.attendees
            doc.othersName = SpeakerNames.oneOnOne(e.attendees)
        }
        namedAt = nil
        phase = .recording
        changed()
        session = UUID()
        savedSlot = -1
        let id = session
        Task { await startSources(id) }
        ticker?.invalidate()
        lastTick = Date()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func togglePause() {
        guard isRunning else { return }
        paused.toggle()
        meRoute.paused = paused
        othersRoute.paused = paused
        phase = paused ? .paused : .recording
        changed()
    }

    /// Switches the recognition language mid-meeting (lines so far are kept).
    func setLanguage(_ l: DictationLanguage) {
        guard l != language else { return }
        language = l
        guard isRunning else { return }
        Task {
            await stopTranscribers()
            await startTranscribers()
        }
    }

    func stop() {
        guard isRunning else { return }
        session = UUID()
        Stats.shared.add(.meetings)
        Stats.shared.add(.meetingMinutes, Date().timeIntervalSince(startedAt) / 60)
        ticker?.invalidate()
        ticker = nil
        mic?.stop()
        mic = nil
        let sys = system
        system = nil
        phase = .summarizing
        changed()
        Task {
            await sys?.stop()
            await stopTranscribers()
            self.save()
            while self.naming { try? await Task.sleep(for: .milliseconds(200)) }
            if let from = self.speakersToName(final: true) { await self.nameSpeakers(from: from) }
            await self.summarize()
        }
    }

    func reset() {
        guard !isRunning, phase != .summarizing else { return }
        phase = .idle
        doc = MeetingDoc(url: MeetingDoc.folder.appendingPathComponent("Meeting.md"))
        changed()
    }

    // MARK: Audio

    /// Mic, transcribers and the Mac's sound for recording `id`. Each step waits (permission, models), so after each one it
    /// checks the meeting is still that one, and stops what it started if not.
    private func startSources(_ id: UUID) async {
        guard await MicCapture.requestAccess() else {
            guard id == session else { return }
            ticker?.invalidate()
            ticker = nil
            phase = .failed("Allow the microphone for MONEY! in System Settings › Privacy & Security.")
            return changed()
        }
        guard id == session, isRunning else { return }
        await startTranscribers()
        guard id == session, isRunning else { return await stopTranscribers() }
        startMic()
        computerOn = store.settings.meetingSystemAudio
        guard computerOn else { return }
        await startComputerAudio()
        if id != session || !isRunning {
            let sys = system
            system = nil
            await sys?.stop()
        }
    }

    /// Me: the microphone (the one picked in the window or Settings, else the system's).
    var micOn = true { didSet { meRoute.muted = !micOn; changed() } }
    /// Others: everything the Mac plays.
    var computerOn = true { didSet { othersRoute.muted = !computerOn; changed() } }
    var micLevel: Float = 0

    private func startMic() {
        mic?.stop()
        let mic = MicCapture(deviceUID: store.settings.meetingMicUID)
        let meRoute = self.meRoute
        mic.onBuffer = { buf in meRoute.send(buf) }
        mic.onLevel = { [weak self] l in
            Task { @MainActor in
                guard let self, abs(self.micLevel - l) > 0.04 else { return }
                self.micLevel = l
            }
        }
        do {
            try mic.start()
            self.mic = mic
        } catch {
            note = "Microphone couldn't start: \(error.localizedDescription)"
        }
    }

    /// Picks another microphone (also mid-meeting).
    func useMic(_ uid: String) {
        store.settings.meetingMicUID = uid
        if isRunning { startMic() }
        changed()
    }

    /// Turns transcribing the Mac's sound on or off (starting the capture if it wasn't running).
    func setComputerAudio(_ on: Bool) {
        computerOn = on
        if on, isRunning, system == nil { Task { await startComputerAudio() } }
    }

    private func startComputerAudio() async {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            note = "Only your microphone is transcribed. To include the other people, allow Screen & System Audio Recording for MONEY!, then start a new meeting."
            return
        }
        let sys = SystemAudioCapture()
        let othersRoute = self.othersRoute
        sys.onBuffer = { buf in othersRoute.send(buf) }
        do {
            try await sys.start()
            system = sys
        } catch {
            note = "Couldn't capture the Mac's audio: \(error.localizedDescription)"
        }
    }

    /// The languages listened for: one, or (mixed) your dictation languages, each with its own recognizer.
    private var locales: [String] {
        switch language {
        case .english, .japanese: language.locales
        case .both:
            store.settings.listenLocales.count > 1 ? store.settings.listenLocales : DictationLanguage.both.locales
        }
    }

    private func startTranscribers() async {
        let wanted = locales
        let ready = wanted.filter { SpeechModels.shared.isInstalled($0) }
        if let missing = wanted.first(where: { !ready.contains($0) }) {
            note = "Download the \(SpeechModels.name(missing)) speech model in Settings › Dictation."
        }
        guard !ready.isEmpty else { return }
        let me = MixedTranscriber(locales: ready)
        let others = MixedTranscriber(locales: ready)
        for (t, isMe) in [(me, true), (others, false)] {
            t.onFinal = { [weak self] text in Task { @MainActor in self?.add(text, me: isMe) } }
            t.onVolatile = { [weak self] text in
                Task { @MainActor in
                    if isMe { self?.volatileMe = text } else { self?.volatileOthers = text }
                }
            }
            try? await t.prepare()
        }
        meT = me
        othersT = others
        let words = store.settings.dictionary
        me.start(context: words)
        others.start(context: words)
    }

    private func stopTranscribers() async {
        let ts = [meT, othersT].compactMap { $0 }
        meT = nil
        othersT = nil
        for t in ts { await t.finish() }
        volatileMe = ""
        volatileOthers = ""
    }

    private func add(_ text: String, me: Bool) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if var last = lines.last, last.me == me, Date().timeIntervalSince(last.updated) < 6 {
            last.text = joinSegments([last.text, t])
            last.updated = Date()
            lines[lines.count - 1] = last
        } else {
            lines.append(Line(me: me, text: t, at: elapsed, updated: Date()))
        }
        if let from = speakersToName(final: false) { Task { await nameSpeakers(from: from) } }
    }

    /// When to name the speakers: once the others have said enough (or at the end, if they never did), and at the end
    /// again for lines said since, if several people were told apart. Returns the first line to look at.
    private func speakersToName(final: Bool) -> Int? {
        guard !naming, !doc.namedByYou else { return nil }
        let others = lines.filter { !$0.me }
        guard let at = namedAt else {
            let heard = others.reduce(0) { $0 + $1.text.count }
            return heard >= (final ? 80 : 500) || (!final && others.count >= 8) ? 0 : nil
        }
        guard final, doc.othersName == nil, lines.contains(where: { $0.speaker != nil }), lines[min(at, lines.count)...].filter({ !$0.me }).count >= 3 else { return nil }
        return at
    }

    private func nameSpeakers(from: Int) async {
        naming = true
        let d = doc
        if let g = await SpeakerNames.detect(d, from: from) { SpeakerNames.apply(g, to: d, from: from) }
        if d === doc { namedAt = d.lines.count }
        naming = false
    }

    private func tick() {
        let now = Date()
        if phase == .recording { elapsed += now.timeIntervalSince(lastTick) }
        lastTick = now
        // Saved every 30 seconds of recording.
        if phase == .recording, Int(elapsed) / 30 != savedSlot {
            savedSlot = Int(elapsed) / 30
            save()
        }
        changed()
    }

    // MARK: Notes

    var transcript: String { doc.transcript }

    private func save() {
        doc.duration = elapsed
        doc.save()
    }

    private func summarize() async {
        if store.settings.meetingSummary { await doc.enhance() } else { save() }
        phase = .done
        changed()
    }

    /// Sample content for the off-screen layout checks (made up).
    func demo() {
        phase = .recording
        elapsed = 754
        doc = MeetingDoc(url: MeetingDoc.folder.appendingPathComponent("demo.md"), date: Date().addingTimeInterval(-754))
        doc.title = "Sponsor sync"
        doc.attendees = ["Aiko Tanaka", "Ben Ito"]
        doc.myNotes = "venue confirmed 12th\nsponsor deck by friday\nartist contracts?"
        lines = [Line(me: false, text: "Okay, so the venue confirmed the 12th. We still need the sponsor deck by Friday.", at: 610, updated: Date()),
                 Line(me: true, text: "I can finish the deck tomorrow. 来週の月曜日にもう一回確認しましょう。", at: 642, updated: Date()),
                 Line(me: false, text: "Sounds good. Who's handling the artist contracts?", at: 701, updated: Date())]
        volatileMe = "I think Gaito wanted to"
    }

    struct Past: Identifiable, Hashable {
        let url: URL
        let date: Date
        let title: String
        let snippet: String
        let text: String
        var attendees: [String] = []
        var duration: TimeInterval = 0
        var id: URL { url }
    }

    /// Saved meetings, newest first (the Markdown files in the meetings folder).
    func pastMeetings() -> [Past] {
        let files = (try? FileManager.default.contentsOfDirectory(at: MeetingDoc.folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { url -> Past? in
            guard let d = MeetingDoc.load(url), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let snippet = (d.notes + "\n" + d.myNotes).components(separatedBy: "\n").first { $0.hasPrefix("- ") }
                .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "- [ ] ", with: "").replacingOccurrences(of: "- ", with: "") }
                ?? d.lines.first?.text ?? ""
            return Past(url: url, date: d.date, title: d.title.isEmpty ? url.deletingPathExtension().lastPathComponent : d.title,
                        snippet: snippet, text: text, attendees: d.attendees, duration: d.duration)
        }
        .sorted { $0.date > $1.date }
    }

    func showInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private func changed() { onChange?() }
}

/// The Mac's audio output via ScreenCaptureKit (needs Screen & System Audio Recording permission).
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "flick.system-audio")
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { return }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        cfg.width = 2 // audio only: keep the (required) video stream tiny
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buf = Self.pcm(sb) else { return }
        onBuffer?(buf)
    }

    private static func pcm(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sb.formatDescription, var asbd = desc.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return status == noErr ? buf : nil
    }
}

/// Hands audio from a capture thread to the current transcriber (which can change mid-meeting).
final class AudioRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var _target: MixedTranscriber?
    private var _paused = false
    private var _muted = false
    /// Switched off in the meeting window (that side isn't transcribed).
    var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }
    var target: MixedTranscriber? {
        get { lock.withLock { _target } }
        set { lock.withLock { _target = newValue } }
    }
    var paused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }

    func send(_ buf: AVAudioPCMBuffer) {
        let t: MixedTranscriber? = lock.withLock { _paused || _muted ? nil : _target }
        t?.append(buf)
    }
}
