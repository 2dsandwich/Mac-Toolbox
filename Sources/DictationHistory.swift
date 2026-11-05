import AVFoundation
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// One dictation (or transcribed file): the words as heard and as written, where they went, how long it took.
struct DictationEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case dictation, voiceEdit, file }
    struct Line: Codable, Equatable { var start: Double; var end: Double; var text: String }

    var id = UUID()
    var date = Date()
    var kind = Kind.dictation
    /// What the recognizers heard, merged: the raw words.
    var raw: String
    /// Each recognizer's own text by locale, for polishing again.
    var heard: [String: String] = [:]
    /// What was typed (the polished words, or the raw ones).
    var text: String
    /// The app it went into (a file's name for a file).
    var app = ""
    var bundleID = ""
    /// The `Prompts.WritingContext` it was polished for.
    var context = ""
    var seconds: Double = 0
    /// A file's words with their times, for subtitles.
    var lines: [Line]? = nil

    var polished: Bool { text != raw && !raw.isEmpty }
    var words: Int { DictationController.wordCount(text) }
}

/// Every dictation, kept on this Mac (`~/Library/Application Support/MONEY/dictations.json`), newest first.
@MainActor @Observable final class DictationHistory {
    static let shared = DictationHistory()
    static let limit = 1000

    private(set) var entries: [DictationEntry] = []
    /// A file being transcribed: its name and how far along (0…1).
    var job: (name: String, progress: Double)?
    /// The entry the view shows; the newest when nil.
    var selected: UUID?
    var showRaw = false
    /// Polishing an entry again.
    var retrying: UUID?
    @ObservationIgnored var persist = !CommandLine.arguments.contains { $0.hasSuffix("-snapshot") || $0.hasSuffix("-test") }
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    nonisolated private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MONEY", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictations.json")
    }

    private init() {
        guard persist, let data = try? Data(contentsOf: Self.url) else { return }
        entries = (try? JSONDecoder().decode([DictationEntry].self, from: data)) ?? []
    }

    var last: DictationEntry? { entries.first { $0.kind != .file } }
    func current(in list: [DictationEntry]) -> DictationEntry? { list.first { $0.id == selected } ?? list.first }

    /// Words this week, speaking speed, and days in a row with a dictation (from the history, so it matches the list).
    var summary: (words: Int, wpm: Int, streak: Int) {
        let spoken = entries.filter { $0.kind == .dictation && $0.seconds > 0 }
        let week = spoken.filter { Date().timeIntervalSince($0.date) < 7 * 86400 }
        let words = week.reduce(0) { $0 + $1.words }
        let minutes = week.reduce(0) { $0 + $1.seconds } / 60
        let cal = Calendar.current
        let days = Set(spoken.map { cal.startOfDay(for: $0.date) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while days.contains(day) {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return (words, minutes > 0 ? Int((Double(words) / minutes).rounded()) : 0, streak)
    }

    /// An audio or video file to text, in every dictation language; it lands at the top of the history.
    func transcribe(_ url: URL) {
        guard job == nil else { return }
        let s = Store.shared.settings
        let locales = s.listenLocales.filter { SpeechModels.shared.isInstalled($0) }
        let name = url.lastPathComponent
        guard !locales.isEmpty else { return note("Download a speech model in Settings › Dictation") }
        job = (name, 0)
        Task {
            do {
                let r = try await FileTranscriber.transcribe(url, locales: locales, context: s.dictionary) { p in
                    Task { @MainActor in if DictationHistory.shared.job != nil { DictationHistory.shared.job?.progress = p } }
                }
                let e = DictationEntry(kind: .file, raw: r.text, text: r.text, app: name, seconds: r.seconds, lines: r.lines)
                entries.insert(e, at: 0)
                selected = e.id
                showRaw = false
                save()
                note("Transcribed \(name)")
            } catch {
                Log.write("file transcription failed: \(error.localizedDescription)")
                note(error.localizedDescription)
            }
            job = nil
        }
    }

    /// Subtitles (.srt) or plain text, saved where you choose.
    func export(_ e: DictationEntry, subtitles: Bool) {
        let panel = NSSavePanel()
        let base = (e.app as NSString).deletingPathExtension
        panel.nameFieldStringValue = (base.isEmpty ? "Dictation" : base) + (subtitles ? ".srt" : ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = subtitles ? FileTranscriber.srt(e.lines ?? [.init(start: 0, end: max(1, e.seconds), text: e.text)]) : e.text
        do { try body.write(to: url, atomically: true, encoding: .utf8) } catch { note(error.localizedDescription) }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribe(url)
    }

    private func note(_ text: String) {
        (NSApp.delegate as? AppDelegate)?.island.flash(text, symbol: "waveform", color: .white, seconds: 2.4, note: true)
    }

    func add(_ e: DictationEntry) {
        guard Store.shared.settings.keepDictationHistory else { return }
        entries.insert(e, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func update(_ id: UUID, _ change: (inout DictationEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if selected == id { selected = nil }
        save()
    }

    func clear() {
        entries = []
        selected = nil
        save()
    }

    func search(_ q: String) -> [DictationEntry] {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.raw.localizedCaseInsensitiveContains(q) || $0.app.localizedCaseInsensitiveContains(q) }
    }

    /// Made-up dictations for snapshots (never the real history).
    func useDemo() {
        persist = false
        let now = Date()
        func e(_ mins: Double, _ raw: String, _ text: String, _ app: String, _ id: String, _ ctx: String, _ secs: Double, kind: DictationEntry.Kind = .dictation) -> DictationEntry {
            DictationEntry(date: now.addingTimeInterval(-mins * 60), kind: kind, raw: raw, text: text, app: app, bundleID: id, context: ctx, seconds: secs)
        }
        entries = [
            e(2, "um so can you uh move the standup to ten thirty tomorrow no wait eleven and send the notes to Aiko after",
              "Can you move the standup to 11 tomorrow and send the notes to Aiko after?", "Slack", "com.tinyspeck.slackmacgap", "chat", 9),
            e(18, "hey Ben just wanted to say the venue is confirmed for the twelfth thanks Sam",
              "Hey Ben,\n\nJust wanted to say the venue is confirmed for the 12th.\n\nThanks,\nSam", "Mail", "com.apple.mail", "email", 7),
            e(41, "えーと明日の会議はあの三時からに変更になりましたよろしくお願いします", "明日の会議は3時からに変更になりました。よろしくお願いします。",
              "Messages", "com.apple.MobileSMS", "chat", 6),
            e(65, "fix the bug in app dot swift where the button doesn't uh show up", "Fix the bug in `app.swift` where the button doesn't show up.",
              "Terminal", "com.apple.Terminal", "prompt", 5),
            e(180, "sponsor sync recording", "Thanks everyone for joining. The venue is confirmed for the twelfth, and the sponsor deck is due Friday.",
              "Sponsor sync.m4a", "", "", 312, kind: .file),
            e(1500, "number one book the venue number two order the food", "1. Book the venue\n2. Order the food", "Notes", "com.apple.Notes", "document", 6),
        ]
        entries[4].raw = entries[4].text
        entries[4].lines = [.init(start: 0, end: 2.4, text: "Thanks everyone for joining."),
                            .init(start: 2.6, end: 7.9, text: "The venue is confirmed for the twelfth, and the sponsor deck is due Friday.")]
    }

    private func save() {
        guard persist else { return }
        saveWork?.cancel()
        let snapshot = entries
        let work = DispatchWorkItem {
            DispatchQueue.global(qos: .utility).async {
                if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.url, options: .atomic) }
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

// MARK: - Files

/// An audio or video file through the same on-device recognizers as dictation (every language at once, merged
/// phrase by phrase), faster than real time. Gives the text and its lines with their times.
enum FileTranscriber {
    static let types = ["mp3", "m4a", "wav", "aiff", "aif", "caf", "aac", "flac", "mp4", "mov", "m4v"]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func transcribe(_ url: URL, locales: [String], context: [String] = [], progress: @escaping @Sendable (Double) -> Void) async throws -> (text: String, lines: [DictationEntry.Line], seconds: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure(message: "No sound in this file") }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let rate = 16_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading(), let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            throw Failure(message: "This file can't be read")
        }
        let takes = locales.map { LiveTranscriber(locale: Locale(identifier: $0)) }
        for t in takes { try await t.prepare() }
        for t in takes { Task { try? await t.start(context: context) } }
        while let sample = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            pcm.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { continue }
            takes.forEach { $0.append(pcm) }
            if duration > 0 { progress(min(0.95, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration * 0.95)) }
            await Task.yield()
        }
        guard reader.status != .failed else { throw Failure(message: reader.error?.localizedDescription ?? "This file can't be read") }
        for t in takes { _ = await t.finish() }
        progress(1)
        let phrases = SpeechMerge.phrases(takes.map { ($0.locale.identifier, $0.words) })
        let lines = captions(phrases)
        let text = joinSegments(phrases.map(\.text))
        guard !text.isEmpty else { throw Failure(message: "No speech in this file") }
        return (text, lines, duration)
    }

    /// Phrases joined into subtitle lines: up to about 7 seconds and 84 characters, split at pauses and sentence ends.
    static func captions(_ phrases: [DictationEntry.Line]) -> [DictationEntry.Line] {
        // A phrase with several sentences in it (said without a pause) splits at their ends, its time shared by length.
        let sentences = phrases.flatMap { p -> [DictationEntry.Line] in
            let parts = p.text.replacingOccurrences(of: #"([.!?])\s+|([。！？])"#, with: "$1$2\n", options: .regularExpression)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let total = Double(max(1, parts.reduce(0) { $0 + $1.count }))
            var t = p.start
            return parts.map { s in
                let end = t + (p.end - p.start) * Double(s.count) / total
                defer { t = end }
                return DictationEntry.Line(start: t, end: end, text: s)
            }
        }
        var out: [DictationEntry.Line] = []
        for p in sentences {
            // A sentence that's ended starts a new line once the line has some length.
            let ended = out.last.map { $0.text.count >= 24 && ".!?。！？".contains($0.text.last ?? " ") } ?? false
            if var last = out.last, !ended, p.start - last.end < 1.0, p.end - last.start <= 7, last.text.count + p.text.count <= 84 {
                last.text = joinSegments([last.text, p.text])
                last.end = p.end
                out[out.count - 1] = last
            } else {
                out.append(p)
            }
        }
        return out
    }

    static func srt(_ lines: [DictationEntry.Line]) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return lines.enumerated().map { i, l in "\(i + 1)\n\(stamp(l.start)) --> \(stamp(l.end))\n\(l.text)\n" }.joined(separator: "\n")
    }
}

// MARK: - Learning words

/// After a paste, keeps an eye on that one field for a minute: a word fixed by hand inside what was just dictated
/// (a name it misheard) goes into the dictionary, like Wispr Flow's auto-add. Reads only that field, through
/// Accessibility, and keeps nothing but the word. Stops when the field loses focus or the next dictation starts.
@MainActor final class CorrectionWatcher {
    var onLearn: ((String) -> Void)?
    private var timer: Timer?
    private var element: AXUIElement?
    private var start = ""
    private var span = NSRange()
    private var candidate: String?
    private var until = Date.distantPast

    func watch(pasted: String, pid: pid_t?, field: AXUIElement? = nil) {
        finish()
        guard let el = field ?? Paster.focusedElement(pid).0, let (text, cursor) = Paster.textAndCursor(el) else { return }
        let len = (pasted as NSString).length
        guard cursor >= len, (text as NSString).substring(with: NSRange(location: cursor - len, length: len)) == pasted else { return }
        element = el
        start = text
        span = NSRange(location: cursor - len, length: len)
        until = Date().addingTimeInterval(60)
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Looks at the field now (the timer does this; `--paste-test` calls it directly).
    func poll(focusCheck: Bool = true) {
        guard let el = element, Date() < until else { return finish() }
        if focusCheck, let now = Paster.focusedElement(nil).0, !CFEqual(now, el) { return finish() }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success, let text = value as? String else { return finish() }
        let s = Store.shared.settings
        if let w = Self.learned(before: start, after: text, span: span, known: s.dictionary + s.dictionaryIgnored) { candidate = w }
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        element = nil
        if let w = candidate { onLearn?(w) }
        candidate = nil
    }

    /// The word typed in place of a dictated one, when it looks like a name or term worth keeping: one to three words
    /// replacing up to four inside `span`, not a common word, not a link, code or a number, not one already known.
    static func learned(before: String, after: String, span: NSRange, known: [String]) -> String? {
        let a = before as NSString, b = after as NSString
        var p = 0
        while p < a.length, p < b.length, a.character(at: p) == b.character(at: p) { p += 1 }
        var q = 0
        while q < a.length - p, q < b.length - p, a.character(at: a.length - 1 - q) == b.character(at: b.length - 1 - q) { q += 1 }
        guard p >= span.location, a.length - q <= NSMaxRange(span), a.length - q > p || b.length - q > p else { return nil }
        // Out to whole words (the text around the change is the same in both).
        func wordy(_ c: unichar) -> Bool {
            guard let u = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(u) || c == 0x27 || c == 0x2D || c == 0x2E
        }
        var lo = p
        while lo > 0, wordy(a.character(at: lo - 1)) { lo -= 1 }
        var endA = a.length - q, endB = b.length - q
        while endA < a.length, wordy(a.character(at: endA)) { endA += 1; endB += 1 }
        let old = a.substring(with: NSRange(location: lo, length: endA - lo)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let new = b.substring(with: NSRange(location: lo, length: endB - lo)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let newWords = new.split(separator: " "), oldWords = old.split(separator: " ")
        guard !old.isEmpty, (1...3).contains(newWords.count), oldWords.count <= 4, (2...40).contains(new.count), new != old,
              new.contains(where: \.isLetter), !new.contains(where: isCJK),
              new.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\@`=_{}()<>[]#$%^*|~:;\"\n")) == nil,
              !known.contains(where: { $0.caseInsensitiveCompare(new) == .orderedSame }) else { return nil }
        // Only the first capital changed at the start of a sentence ("so" → "So"): not a name.
        let lead = a.substring(to: lo).trimmingCharacters(in: .whitespacesAndNewlines).last
        if new.lowercased() == old.lowercased(), new.dropFirst() == old.dropFirst(), lead == nil || ".!?:".contains(lead!) { return nil }
        return newWords.contains(where: { unusual(String($0)) }) ? new : nil
    }

    /// Not an ordinary English word: the spelling dictionary doesn't know it, or it's written like a name (TestFlight, AWS).
    static func unusual(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .punctuationCharacters)
        guard w.count > 1, !w.allSatisfy(\.isNumber) else { return false }
        if w.dropFirst().contains(where: \.isUppercase) { return true }
        let miss = NSSpellChecker.shared.checkSpelling(of: w.lowercased(), startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return miss.location != NSNotFound
    }
}
