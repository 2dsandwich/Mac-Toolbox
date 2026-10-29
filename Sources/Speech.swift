import AVFoundation
import NaturalLanguage
import CoreAudio
import Foundation
import Observation
import Speech

/// One on-device transcriber (Apple SpeechAnalyzer) for one language, fed audio buffers as they arrive.
final class LiveTranscriber: @unchecked Sendable {
    let locale: Locale
    private let transcriber: SpeechTranscriber
    private var analyzer: SpeechAnalyzer?
    private var converter: AnalyzerInputConverter?
    private var analyzerFormat: AVAudioFormat?
    private var inputFormat: AVAudioFormat?
    private let input: AsyncStream<AnalyzerInput>
    private let feed: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private let lock = NSLock()
    private var finals: [String] = []
    private var volatile = ""
    private var confidence: (sum: Double, count: Int) = (0, 0)
    /// Final words with when they were said, for merging languages phrase by phrase.
    private var timed: [TimedWord] = []
    /// Called (on any thread) with a finalised segment, or with the current volatile text.
    var onFinal: ((String) -> Void)?
    var onVolatile: ((String) -> Void)?

    init(locale: Locale) {
        self.locale = locale
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults, .fastResults],
                                        attributeOptions: [.transcriptionConfidence, .audioTimeRange])
        (input, feed) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Fast: makes `append` usable, so the mic can start before the model has loaded (audio queues up).
    func prepare() async throws {
        converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    func start(context words: [String]) async throws {
        if converter == nil { try await prepare() }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        self.analyzer = analyzer
        if !words.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = words
            try? await analyzer.setContext(ctx)
        }
        let transcriber = self.transcriber
        resultsTask = Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    guard let self else { return }
                    let text = String(r.text.characters)
                    if r.isFinal {
                        var sum = 0.0, n = 0
                        var words: [TimedWord] = []
                        for run in r.text.runs {
                            if let c = run.transcriptionConfidence { sum += c; n += 1 }
                            if let range = run.audioTimeRange {
                                words.append(TimedWord(text: String(r.text[run.range].characters), start: range.start.seconds,
                                                       end: range.end.seconds, confidence: run.transcriptionConfidence ?? 0.5))
                            }
                        }
                        self.lock.withLock {
                            self.timed += words
                            self.finals.append(text)
                            self.volatile = ""
                            self.confidence.sum += sum
                            self.confidence.count += n
                        }
                        self.onFinal?(text)
                        self.onVolatile?("")
                    } else {
                        self.lock.withLock { self.volatile = text }
                        self.onVolatile?(text)
                    }
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: input)
    }

    /// Audio thread: convert to the model's format and queue it.
    func append(_ buffer: AVAudioPCMBuffer) {
        // A headset switching profile mid-recording changes the format: start a fresh converter for it.
        if let last = inputFormat, last != buffer.format, let fmt = analyzerFormat {
            if let rest = try? converter?.flush() { rest.forEach { feed.yield($0) } }
            converter = AnalyzerInputConverter(analyzerFormat: fmt)
        }
        inputFormat = buffer.format
        guard let converter, let inputs = try? converter.convert(buffer, at: nil) else { return }
        inputs.forEach { feed.yield($0) }
    }

    /// Ends the audio and waits for the last words.
    /// Waits for the last words, but never more than a few seconds (with no audio it could wait forever).
    func finish() async -> String {
        if let rest = try? converter?.flush() { rest.forEach { feed.yield($0) } }
        feed.finish()
        let analyzer = self.analyzer, results = self.resultsTask
        let done = await withTaskGroup(of: Bool.self) { g in
            g.addTask {
                try? await analyzer?.finalizeAndFinishThroughEndOfInput()
                await results?.value
                return true
            }
            g.addTask {
                try? await Task.sleep(for: .seconds(4))
                // A task group waits for all its children, so the stuck one has to be ended here, not after.
                await analyzer?.cancelAndFinishNow()
                results?.cancel()
                return false
            }
            let first = await g.next() ?? false
            g.cancelAll()
            return first
        }
        if !done { Log.write("speech recognizer didn't finish in time") }
        return text
    }

    func cancel() async {
        feed.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
    }

    var text: String { lock.withLock { joinSegments(finals + (volatile.isEmpty ? [] : [volatile])) } }
    var averageConfidence: Double { lock.withLock { confidence.count == 0 ? 0 : confidence.sum / Double(confidence.count) } }
    var words: [TimedWord] { lock.withLock { timed } }
    var volatileText: String { lock.withLock { volatile } }
}

struct TimedWord: Sendable {
    var text: String
    var start: Double
    var end: Double
    var confidence: Double
    var mid: Double { (start + end) / 2 }
}

/// Speech in more than one language, from one recognizer per language on the same audio. Each recognizer is only good
/// at its own language, so the recording is cut at natural pauses into phrases, and each phrase is taken from the
/// recognizer that heard it best: how sure it was, whether its text really is in its language, and in its script.
/// Instant, so even a small local model gets one clean, already-mixed transcript to polish.
enum SpeechMerge {
    static func merge(_ takes: [(locale: String, words: [TimedWord])]) -> String? {
        guard takes.count > 1, takes.contains(where: { !$0.words.isEmpty }) else { return nil }
        let languages = takes.map { language($0.locale) }
        struct Phrase { var take: Int; var start: Double; var end: Double; var text: String; var score: Double }
        // Each language's words, grouped into phrases at its own pauses. A token said over seconds (a recognizer
        // stretching one character across speech it couldn't read) is pinned to when it ended.
        var phrases: [Phrase] = []
        for (i, take) in takes.enumerated() {
            var cur: [TimedWord] = []
            func close() {
                guard !cur.isEmpty else { return }
                let text = cur.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    let chars = Double(max(1, cur.reduce(0) { $0 + $1.text.count }))
                    let sure = cur.reduce(0) { $0 + $1.confidence * Double($1.text.count) } / chars
                    let score = sure + 0.35 * likelihood(text, languages[i], among: languages) + 0.25 * scriptFit(text, take.locale)
                    phrases.append(Phrase(take: i, start: cur[0].start, end: cur.last!.end, text: text, score: score))
                }
                cur = []
            }
            for var w in take.words.sorted(by: { $0.start < $1.start }) {
                if w.end - w.start > 0.6 { w.start = w.end - 0.25 }
                if let last = cur.last, w.start > last.end + 0.25 { close() }
                cur.append(w)
            }
            close()
        }
        // A recognizer hearing speech in another language writes scraps: a lone "パ", katakana spelling out English.
        // Those go when another language heard something right there.
        phrases.removeAll { p in
            let letters = p.text.unicodeScalars.filter { $0.properties.isAlphabetic }
            let kana = Double(letters.filter { (0x30A0...0x30FF).contains($0.value) }.count) / Double(max(1, letters.count))
            let nearby = takes.enumerated().contains { i, t in
                i != p.take && t.words.contains { $0.mid > p.start - 0.4 && $0.mid < p.end + 0.4 }
            }
            return nearby && (kana >= 0.6 || (p.text.count <= 2 && p.score < 1.1))
        }
        // Where two languages heard the same stretch, the one that heard it best keeps it.
        var kept: [Phrase] = []
        for p in phrases.sorted(by: { $0.score > $1.score }) {
            let clash = kept.contains { k in
                guard k.take != p.take else { return false }
                let overlap = min(k.end, p.end) - max(k.start, p.start)
                return overlap > 0.4 * min(k.end - k.start, p.end - p.start)
            }
            if !clash { kept.append(p) }
        }
        return joinSegments(kept.sorted { $0.start < $1.start }.map(\.text))
    }

    private static func language(_ locale: String) -> NLLanguage {
        NLLanguage(rawValue: Locale(identifier: locale).language.languageCode?.identifier ?? "en")
    }

    /// How sure Apple's language identifier is that `text` is in `lang`, choosing only among the languages being listened for.
    private static func likelihood(_ text: String, _ lang: NLLanguage, among: [NLLanguage]) -> Double {
        let r = NLLanguageRecognizer()
        r.languageConstraints = among
        r.processString(text)
        return r.languageHypotheses(withMaximum: among.count)[lang] ?? 0
    }

    /// Share of the letters written in the locale's own script. A Japanese recognizer hearing English writes it in katakana,
    /// so katakana counts for half.
    static func scriptFit(_ text: String, _ locale: String) -> Double {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return 0 }
        func share(_ test: (Unicode.Scalar) -> Bool) -> Double { Double(letters.filter(test).count) / Double(letters.count) }
        let han: (Unicode.Scalar) -> Bool = { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        let hira: (Unicode.Scalar) -> Bool = { (0x3040...0x309F).contains($0.value) }
        let kata: (Unicode.Scalar) -> Bool = { (0x30A0...0x30FF).contains($0.value) }
        let hangul: (Unicode.Scalar) -> Bool = { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
        switch String(locale.prefix(2)) {
        case "ja": return share { han($0) || hira($0) } + share(kata) * 0.5
        case "zh", "yu": return share(han)
        case "ko": return share(hangul)
        default: return share { !han($0) && !hira($0) && !kata($0) && !hangul($0) }
        }
    }
}

/// Joins recognizer segments: a space between Latin words, nothing between Japanese.
func joinSegments(_ parts: [String]) -> String {
    var out = ""
    for p in parts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !p.isEmpty {
        if let last = out.last, let first = p.first, !isCJK(last), !isCJK(first), !last.isWhitespace {
            out += " "
        }
        out += p
    }
    return out
}

func isCJK(_ c: Character) -> Bool {
    c.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
}

/// Microphone → buffers + a smoothed level for the waveform.
final class MicCapture: @unchecked Sendable {
    private var queue: AudioQueueRef?
    private let callbackQueue = DispatchQueue(label: "money.mic", qos: .userInteractive)
    private let preferBuiltIn: Bool
    private let deviceUID: String?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    private(set) var buffers = 0
    private(set) var peak: Float = 0

    /// `preferBuiltIn`: when the default microphone is Bluetooth (AirPods…), use the Mac's own instead.
    /// Bluetooth headsets drop to call quality and go silent for a moment while switching, which loses words.
    /// `deviceUID`: a specific microphone (overrides `preferBuiltIn`); nil follows the system's choice.
    init(preferBuiltIn: Bool = false, deviceUID: String? = nil) {
        self.preferBuiltIn = preferBuiltIn
        self.deviceUID = deviceUID?.isEmpty == true ? nil : deviceUID
    }

    /// Microphones on this Mac, by name.
    static func inputDevices() -> [(uid: String, name: String)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).compactMap { id in
            guard let uid = uid(id) else { return nil }
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var nsize = UInt32(MemoryLayout<CFString?>.size)
            var cf: Unmanaged<CFString>?
            let name = AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nsize, &cf) == noErr ? (cf?.takeRetainedValue() as String?) : nil
            return (uid, name ?? uid)
        }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Records with an input-only audio queue. Unlike AVAudioEngine it never touches the speakers, so switching
    /// to the built-in mic doesn't rebuild the output (which made all sound on the Mac stutter).
    func start() throws {
        var fmt = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        guard let format = AVAudioFormat(streamDescription: &fmt) else { throw NSError(domain: "MONEY", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio format"]) }
        var q: AudioQueueRef?
        var status = AudioQueueNewInputWithDispatchQueue(&q, &fmt, 0, callbackQueue) { [weak self] aq, buffer, _, _, _ in
            guard let self else { return }
            let bytes = Int(buffer.pointee.mAudioDataByteSize)
            let frames = AVAudioFrameCount(bytes / 4)
            if frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let ch = pcm.floatChannelData?[0] {
                pcm.frameLength = frames
                memcpy(ch, buffer.pointee.mAudioData, bytes)
                self.onBuffer?(pcm)
                self.buffers += 1
                var sum: Float = 0
                for i in 0..<Int(frames) { sum += ch[i] * ch[i] }
                let rms = sqrt(sum / Float(max(Int(frames), 1)))
                self.peak = max(self.peak, rms)
                self.onLevel?(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 55) / 45)))
            }
            AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
        }
        guard status == noErr, let q else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        queue = q
        if let chosen = deviceUID {
            var cf: CFString? = chosen as CFString
            AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &cf, UInt32(MemoryLayout<CFString?>.size))
            Log.write("using microphone \(chosen)")
        } else if preferBuiltIn, Self.defaultInputIsBluetooth(), let builtIn = Self.builtInInput(), let uid = Self.uid(builtIn) {
            var cf: CFString? = uid as CFString
            AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &cf, UInt32(MemoryLayout<CFString?>.size))
            Log.write("using the built-in microphone (default input is Bluetooth)")
        }
        for _ in 0..<4 {
            var b: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(q, 4096, &b) == noErr, let b { AudioQueueEnqueueBuffer(q, b, 0, nil) }
        }
        status = AudioQueueStart(q, nil)
        guard status == noErr else {
            AudioQueueDispose(q, true)
            queue = nil
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        Log.write("mic format: \(format)")
    }

    func stop() {
        if let q = queue {
            AudioQueueStop(q, true)
            AudioQueueDispose(q, true)
        }
        queue = nil
        Log.write("mic stopped after \(buffers) buffers, peak level \(String(format: "%.3f", peak))")
    }

    // MARK: Core Audio devices

    private static func defaultInputIsBluetooth() -> Bool {
        guard let id = defaultInput() else { return false }
        let t = transport(id)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
    }

    private static func builtInInput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    private static func uid(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return t
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }
}

/// Which on-device speech models are installed, and downloading the missing ones (only when asked).
@MainActor @Observable final class SpeechModels {
    static let shared = SpeechModels()
    var status: [String: AssetInventory.Status] = [:]
    var progress: [String: Double] = [:]
    var errors: [String: String] = [:]
    /// Every language Apple's on-device speech recognition can do.
    var supported: [String] = []

    func refresh() {
        Task {
            var out: [String: AssetInventory.Status] = [:]
            let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
            if supported.isEmpty { supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted { Self.name($0) < Self.name($1) } }
            for id in Store.shared.settings.listenLocales {
                let t = SpeechTranscriber(locale: Locale(identifier: id), preset: .progressiveTranscription)
                let st = await AssetInventory.status(forModules: [t])
                out[id] = installed.contains(id) ? .installed : st
            }
            status = out
        }
    }

    func isInstalled(_ id: String) -> Bool { status[id] == .installed }

    func download(_ id: String) {
        Task {
            errors[id] = nil
            let t = SpeechTranscriber(locale: Locale(identifier: id), preset: .progressiveTranscription)
            do {
                guard let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) else { refresh(); return }
                progress[id] = 0
                let watch = Task {
                    while !Task.isCancelled {
                        progress[id] = req.progress.fractionCompleted
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
                try await req.downloadAndInstall()
                watch.cancel()
                progress[id] = nil
            } catch {
                progress[id] = nil
                errors[id] = error.localizedDescription
            }
            refresh()
        }
    }

    nonisolated static func name(_ id: String) -> String {
        let mine = Locale.current.localizedString(forIdentifier: id) ?? id
        let own = Locale(identifier: id).localizedString(forIdentifier: id) ?? id
        return own == mine ? mine : "\(own) (\(mine))"
    }
}

/// `--merge-file <audio> <locale> <locale> …`: every language over one file, then the phrase-by-phrase merge.
func mergeFileForTest(_ path: String, locales: [String]) async -> String {
    var out = ""
    var takes: [(locale: String, words: [TimedWord])] = []
    for id in locales {
        let t = LiveTranscriber(locale: Locale(identifier: id))
        do {
            try await t.start(context: [])
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            while true {
                let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
                guard (try? file.read(into: buf)) != nil, buf.frameLength > 0 else { break }
                t.append(buf)
            }
            out += "\(id): \(await t.finish())  [\(t.words.count) timed words]\n"
            out += t.words.map { String(format: "  %.2f-%.2f %.2f %@", $0.start, $0.end, $0.confidence, $0.text) }.joined(separator: "\n") + "\n"
            takes.append((id, t.words))
        } catch {
            out += "\(id): error \(error)\n"
        }
    }
    return out + "merged: " + (SpeechMerge.merge(takes) ?? "(nothing)")
}

/// `--transcribe-file <audio> <locale>`: runs a file through the same pipeline, for testing without a mic.
func transcribeFileForTest(_ path: String, locale: String) async -> String {
    let t = LiveTranscriber(locale: Locale(identifier: locale))
    do {
        try await t.start(context: [])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        while true {
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            guard (try? file.read(into: buf)) != nil, buf.frameLength > 0 else { break }
            t.append(buf)
        }
        return await t.finish() + "  [confidence \(String(format: "%.2f", t.averageConfidence))]"
    } catch {
        return "error: \(error)"
    }
}

extension AVAudioPCMBuffer {
    func copied() -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        out.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            if let sp = s.mData, let dp = d.mData { memcpy(dp, sp, Int(min(s.mDataByteSize, d.mDataByteSize))) }
        }
        return out
    }
}
