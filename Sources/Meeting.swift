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
    }

    var phase = Phase.idle
    var lines: [Line] = []
    var volatileMe = ""
    var volatileOthers = ""
    var elapsed: TimeInterval = 0
    var summary = ""
    var note: String?
    var language = DictationLanguage.english
    /// The meeting's name (editable in the meeting window); it names the saved file too.
    var name = ""
    private(set) var fileURL: URL?
    @ObservationIgnored private var stamp = ""

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var mic: MicCapture?
    @ObservationIgnored private var system: SystemAudioCapture?
    @ObservationIgnored private let meRoute = AudioRoute()
    @ObservationIgnored private let othersRoute = AudioRoute()
    @ObservationIgnored private var meT: LiveTranscriber? { didSet { meRoute.target = meT } }
    @ObservationIgnored private var othersT: LiveTranscriber? { didSet { othersRoute.target = othersT } }
    @ObservationIgnored private var ticker: Timer?
    /// Which recording the audio being started belongs to (a stop or a new start makes late starts stand down).
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var savedSlot = -1
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var paused = false
    @ObservationIgnored var onChange: (() -> Void)?

    init(store: Store) {
        self.store = store
        language = store.settings.meetingLanguage == .japanese ? .japanese : .english
    }

    var isRunning: Bool { phase == .recording || phase == .paused }

    var clock: String {
        let t = Int(elapsed)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }

    // MARK: Control

    func start() {
        guard !isRunning, phase != .summarizing else { return }
        micOn = true
        lines = []
        volatileMe = ""
        volatileOthers = ""
        summary = ""
        note = nil
        elapsed = 0
        paused = false
        meRoute.paused = false
        othersRoute.paused = false
        startedAt = Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        stamp = f.string(from: startedAt)
        name = ""
        let folder = URL(fileURLWithPath: (store.settings.meetingFolder as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Two meetings in the same minute get their own files.
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.contains(where: { $0.hasPrefix(stamp + " ") }) == true {
            f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            stamp = f.string(from: startedAt)
        }
        fileURL = folder.appendingPathComponent("\(stamp) Meeting.md")
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
            save()
            await summarize()
        }
    }

    func reset() {
        guard !isRunning else { return }
        phase = .idle
        lines = []
        summary = ""
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

    private func startTranscribers() async {
        let id = language == .japanese ? "ja_JP" : "en_US"
        guard SpeechModels.shared.isInstalled(id) else {
            note = "Download the \(SpeechModels.name(id)) speech model in Settings › Dictation."
            return
        }
        let me = LiveTranscriber(locale: Locale(identifier: id))
        let others = LiveTranscriber(locale: Locale(identifier: id))
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
        Task { try? await me.start(context: words) }
        Task { try? await others.start(context: words) }
    }

    private func stopTranscribers() async {
        let ts = [meT, othersT].compactMap { $0 }
        meT = nil
        othersT = nil
        for t in ts { _ = await t.finish() }
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

    var transcript: String {
        lines.map { l in
            let t = Int(l.at)
            return "**\(l.me ? "Me" : "Others")** (\(String(format: "%02d:%02d", t / 60, t % 60))): \(l.text)"
        }.joined(separator: "\n\n")
    }

    private func save() {
        guard var url = fileURL else { return }
        let title = name.trimmingCharacters(in: .whitespaces)
        // A name you typed wins over the title Claude wrote; the file follows the name.
        let wanted = url.deletingLastPathComponent().appendingPathComponent("\(stamp) \(title.isEmpty ? "Meeting" : Self.safe(title)).md")
        if wanted != url {
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.moveItem(at: url, to: wanted) }
            url = wanted
            fileURL = wanted
        }
        var notes = summary
        if !title.isEmpty {
            var lines = notes.components(separatedBy: "\n")
            if let i = lines.firstIndex(where: { $0.hasPrefix("# ") }) { lines[i] = "# \(title)" } else { lines.insert("# \(title)\n", at: 0) }
            notes = lines.joined(separator: "\n")
        }
        var doc = notes.isEmpty ? "# \(title.isEmpty ? "Meeting" : title)\n\n" : notes + "\n\n---\n\n"
        doc += "## Transcript\n\n" + transcript + "\n"
        try? doc.write(to: url, atomically: true, encoding: .utf8)
    }

    static func safe(_ name: String) -> String {
        String(name.map { "/:\\".contains($0) ? "-" : $0 }.prefix(80))
    }

    /// Renames a saved meeting: its title line and its file.
    func rename(_ past: Past, to newName: String) -> Past? {
        let title = newName.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, var text = try? String(contentsOf: past.url, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("# ") }) { lines[i] = "# \(title)" } else { lines.insert("# \(title)\n", at: 0) }
        text = lines.joined(separator: "\n")
        let file = past.url.deletingPathExtension().lastPathComponent
        let prefix = file.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}"#, options: .regularExpression).map { String(file[$0]) + " " } ?? ""
        let url = past.url.deletingLastPathComponent().appendingPathComponent(prefix + Self.safe(title) + ".md")
        try? text.write(to: past.url, atomically: true, encoding: .utf8)
        if url != past.url { try? FileManager.default.moveItem(at: past.url, to: url) }
        return Past(url: url, date: past.date, title: title, snippet: past.snippet, text: text)
    }

    private func summarize() async {
        guard !lines.isEmpty else {
            phase = .done
            summary = "# Meeting\n\nNothing was transcribed."
            return changed()
        }
        let problem = AI.problem(.meetingNotes, store.settings)
        guard store.settings.meetingSummary, problem == nil else {
            phase = .done
            summary = store.settings.meetingSummary ? "\(problem ?? ""). The transcript is saved." : ""
            save()
            return changed()
        }
        let system = """
        You write meeting notes from a raw speech-to-text transcript. "Me" is the person who recorded; "Others" is everyone else on the call, \
        mixed into one voice. The transcript has recognition errors: infer the intended words from context, but never invent facts. \
        Write in the meeting's main language (Japanese meeting, Japanese notes). Use Markdown: a title line "# …", then "## Summary" \
        (3–6 bullets), "## Decisions", "## Action items" (as "- [ ] who — what (when)" where known) and "## Open questions". Leave out empty sections.
        """
        do {
            summary = try await AI.completeLong(.meetingNotes, system: system, prefix: "Transcript:\n\n", text: transcript)
        } catch {
            summary = "Couldn't write notes: \(error.localizedDescription). The transcript is saved."
        }
        save()
        phase = .done
        changed()
    }

    /// Sample content for the off-screen layout check (`--snapshot --scope meeting`).
    func demo() {
        phase = .recording
        elapsed = 754
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
        var id: URL { url }
    }

    /// Saved meetings, newest first (the Markdown files in the meetings folder).
    func pastMeetings() -> [Past] {
        let folder = URL(fileURLWithPath: (store.settings.meetingFolder as NSString).expandingTildeInPath)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { url -> Past? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let lines = text.components(separatedBy: "\n")
            let heading = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            let title = heading.flatMap { $0 == "Meeting" ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
            let snippet = lines.first { $0.hasPrefix("- ") || $0.hasPrefix("**Me**") || $0.hasPrefix("**Others**") }
                .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "- [ ] ", with: "").replacingOccurrences(of: "- ", with: "") } ?? ""
            return Past(url: url, date: date, title: title, snippet: snippet, text: text)
        }
        .sorted { $0.date > $1.date }
    }

    func showInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func showInFinder() {
        if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    }

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
    private var _target: LiveTranscriber?
    private var _paused = false
    private var _muted = false
    /// Switched off in the meeting window (that side isn't transcribed).
    var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }
    var target: LiveTranscriber? {
        get { lock.withLock { _target } }
        set { lock.withLock { _target = newValue } }
    }
    var paused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }

    func send(_ buf: AVAudioPCMBuffer) {
        let t: LiveTranscriber? = lock.withLock { _paused || _muted ? nil : _target }
        t?.append(buf)
    }
}
