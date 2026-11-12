import AppKit
import CryptoKit
import NaturalLanguage
import Observation
import SwiftUI

// Synced lyrics for the song in Music or Spotify, from LRCLIB (lrclib.net): looked up when the song changes, for
// display only, and kept on disk so each song is asked for once. Nothing is bundled, and nothing is fetched while
// Settings › Notch › Lyrics is off. Shown by the open notch's player when you turn its lyrics on, and (if you like) as
// one line under the closed notch.

@MainActor @Observable final class Lyrics {
    static let shared = Lyrics()

    /// One timed line. No text is an instrumental break of 5 s or more (shown as dots filling up over it).
    struct Cue: Equatable {
        var time: Double
        var text: String?
        /// When the singing (or the break) ends.
        var end: Double = .infinity
        /// Each word (Japanese: each token) and when it's sung, from the file's own word stamps or spread over the line.
        var words: [Word] = []
    }

    /// A word with the spaces after it, so the words put back together are the line.
    struct Word: Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    /// A song as LRCLIB knows it. `name` is the title without "(feat. …)", for the search fallback.
    struct Song: Equatable {
        var title: String
        var name: String
        var artist: String
        var album: String
        var duration: Double
        var key: String { [title, artist, album, String(Int(duration.rounded()))].joined(separator: "|").lowercased() }
    }

    /// What LRCLIB had for a song, as cached. All empty means it had nothing.
    struct Entry: Codable {
        var synced: String?
        var plain: String?
        var instrumental = false
        var fetched = Date()
        /// Timed lyrics are kept for good; anything less is asked for again after a week (LRCLIB keeps growing).
        var fresh: Bool { synced != nil || Date().timeIntervalSince(fetched) < 7 * 86400 }
    }

    /// The current song's timed lines. Empty when it has none: plain lyrics have no timing, so they aren't shown.
    private(set) var cues: [Cue] = []
    /// A new song's lines are on their way (the player shows meanwhile; the face comes up only once there are lines).
    private(set) var loading = false
    /// Changes with each song's lines, so a view starts afresh rather than scrolling from the last song's place.
    private(set) var version = 0
    /// Lines to show. Never just the hope of some: a song without lyrics never flashes the face up and away.
    var hasLines: Bool { !cues.isEmpty }
    /// When the lines last changed (a new song): the reel spins in only when the face opens, not as songs change.
    @ObservationIgnored private(set) var changed = Date.distantPast
    /// Scrolled through the lyrics face: the line (fractional) in its middle. Nil follows the song; back by itself 5 s after.
    private(set) var browse: Double?
    @ObservationIgnored private var browseEnd: Task<Void, Never>?
    /// `--island-snapshot --lyrics`: made-up lines, with the line under the closed notch on.
    @ObservationIgnored private(set) var demo = false
    @ObservationIgnored private var current: Song?
    @ObservationIgnored private var pending: Song?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var blockedUntil = Date.distantPast

    /// Breaks shorter than this keep the line before on screen.
    static let gapMin: Double = 5
    /// The poll's reply lands a moment after the player read its position, so lines go up a touch early.
    static let lead: Double = 0.15
    private static let agent = "MONEY! (https://github.com/2dsandwich/Mac-Toolbox)"

    var closedLine: Bool { !cues.isEmpty && (demo || Store.shared.settings.notchLyricLine) }

    func start() { follow() }

    /// Looks again whenever the song or the settings change.
    private func follow() {
        withObservationTracking { sync() } onChange: { Task { @MainActor in Lyrics.shared.follow() } }
    }

    private func sync() {
        let m = NowPlaying.shared, s = Store.shared.settings
        let song = Song(title: m.title, name: m.songTitle, artist: m.artist, album: m.album, duration: m.duration)
        guard s.notchLyrics, s.notchEnabled, s.mediaInNotch, !song.title.isEmpty, !song.artist.isEmpty else {
            current = nil
            pending = nil
            if !cues.isEmpty { cues = [] }
            loading = false
            return
        }
        guard song.key != current?.key else { return }
        current = song
        if let e = Self.cached(song) { return show(e, song) }
        cues = []
        newLines()
        loading = true
        pending = song
        pump()
    }

    /// One request at a time; skipping through songs only asks for the last one.
    private func pump() {
        guard !busy, let song = pending else { return }
        pending = nil
        busy = true
        Task {
            let (entry, _) = await fetch(song)
            busy = false
            if let entry { Self.save(entry, song) }
            if song.key == current?.key { show(entry ?? Entry(), song) }
            pump()
        }
    }

    private func show(_ e: Entry, _ song: Song) {
        let lines = e.instrumental ? [] : e.synced.map { Self.parse($0, duration: song.duration) } ?? []
        // Lines found after the song started: the face opens onto them as one move.
        withAnimation(!lines.isEmpty && loading ? islandSpring : nil) {
            loading = false
            cues = lines
            newLines()
        }
    }

    /// Cache first, then LRCLIB; says where it came from (for `--lyrics-test`). Nil means the network failed.
    func lookUp(_ song: Song) async -> (Entry?, String) {
        if let e = Self.cached(song) { return (e, "cache") }
        let (e, via) = await fetch(song)
        if let e { Self.save(e, song) }
        return (e, via)
    }

    // MARK: LRCLIB

    private struct Record: Decodable {
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
        var entry: Entry {
            Entry(synced: syncedLyrics.flatMap { $0.isEmpty ? nil : $0 }, plain: plainLyrics.flatMap { $0.isEmpty ? nil : $0 },
                  instrumental: instrumental ?? false)
        }
    }

    /// By exact name and length first; not found, a search by name, taking the closest length.
    private func fetch(_ song: Song) async -> (Entry?, String) {
        var query = [("track_name", song.title), ("artist_name", song.artist)]
        if song.duration > 0 {
            if !song.album.isEmpty { query.append(("album_name", song.album)) }
            query.append(("duration", String(Int(song.duration.rounded()))))
            guard let (data, status) = await request("get", query) else { return (nil, "get") }
            if status == 200, let r = try? JSONDecoder().decode(Record.self, from: data) { return (r.entry, "get") }
            guard status == 404 else { return (nil, "get") }
        }
        guard let (data, status) = await request("search", [("track_name", song.name), ("artist_name", song.artist)]), status == 200,
              let list = try? JSONDecoder().decode([Record].self, from: data) else { return (nil, "search") }
        // Within 2 s counts as the same recording (timed lyrics preferred); further off, the closest, up to 10 s.
        func off(_ r: Record) -> Double { song.duration > 0 ? abs((r.duration ?? 0) - song.duration) : 0 }
        let best = list.filter { off($0) <= 10 }.min { a, b in
            (off(a) > 2 ? off(a) : 0, a.syncedLyrics == nil ? 1 : 0, off(a)) < (off(b) > 2 ? off(b) : 0, b.syncedLyrics == nil ? 1 : 0, off(b))
        }
        return (best?.entry ?? Entry(), "search")
    }

    /// One GET. A 429 waits as long as Retry-After says (a minute if it gives a date), then tries once more.
    private func request(_ path: String, _ query: [(String, String)]) async -> (Data, Int)? {
        let q = query.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .queryValue) ?? "")" }.joined(separator: "&")
        guard let url = URL(string: "https://lrclib.net/api/\(path)?\(q)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        for _ in 0..<2 {
            let wait = blockedUntil.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(min(wait, 600))) }
            guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
            guard http.statusCode == 429 else { return (data, http.statusCode) }
            let after = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 60
            blockedUntil = Date().addingTimeInterval(after)
        }
        return nil
    }

    // MARK: Cache (~/Library/Application Support/MONEY/Lyrics)

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MONEY", isDirectory: true).appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(_ song: Song) -> URL {
        let hash = SHA256.hash(data: Data(song.key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash + ".json")
    }

    private static func cached(_ song: Song) -> Entry? {
        guard let data = try? Data(contentsOf: file(song)), let e = try? JSONDecoder().decode(Entry.self, from: data), e.fresh else { return nil }
        return e
    }

    private static func save(_ e: Entry, _ song: Song) {
        if let data = try? JSONEncoder().encode(e) { try? data.write(to: file(song), options: .atomic) }
    }


    // MARK: Timing

    /// "[mm:ss.xx] words" lines in time order (a line with several stamps is sung at each). Tags such as [ar:…] are
    /// skipped. A blank line is a break: dots when it's 5 s or more (as is a long intro), else the line before stays.
    /// Word stamps ("<mm:ss.xx>word", enhanced LRC) time each word; without them the line's words share its time.
    static func parse(_ lrc: String, duration: Double) -> [Cue] {
        var lines: [(time: Double, text: String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                guard let t = stamp(rest[rest.index(after: rest.startIndex)..<close]) else { break }
                times.append(t)
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            lines += times.map { ($0, text) }
        }
        lines.sort { $0.time < $1.time }
        let songEnd = duration > 0 ? duration : (lines.last?.time ?? 0) + 8
        guard lines.contains(where: { !wordless($0.text) }) else { return [] }
        let sung = sungLengths(lines, songEnd: songEnd)
        var out: [Cue] = []
        if let first = lines.first(where: { !wordless($0.text) }), first.time >= gapMin { out.append(Cue(time: 0, text: nil, end: first.time)) }
        for (k, l) in lines.enumerated() {
            let next = k + 1 < lines.count ? lines[k + 1].time : songEnd
            if wordless(l.text) {
                guard next - l.time >= gapMin, !out.isEmpty, out.last?.text != nil else { continue }
                out.append(Cue(time: l.time, text: nil, end: next))
            } else {
                let cue = timed(l.text, at: l.time, until: next, sung: sung[k])
                out.append(cue)
                // Sung well before the next line (and no blank line says so): dots for the rest.
                if k + 1 < lines.count, next - cue.end > 9 { out.append(Cue(time: cue.end + 1.5, text: nil, end: next)) }
            }
        }
        return out
    }

    /// "mm:ss.xx" (or "mm:ss:xx") in seconds.
    private static func stamp(_ s: Substring) -> Double? {
        let p = s.split(separator: ":", maxSplits: 1)
        guard p.count == 2, let m = Double(p[0]), let sec = Double(p[1].replacingOccurrences(of: ":", with: ".")) else { return nil }
        return m * 60 + sec
    }

    /// A line with nothing to sing (blank, or only word stamps).
    private static func wordless(_ text: String) -> Bool {
        text.replacingOccurrences(of: #"<\d+:\d+(?:[.:]\d+)?>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// About how long each line is sung. Lines follow the music's bars more than their syllables: over 163 songs (6,198
    /// lines) a line's time hardly grows with its syllables (half the syllables still take about 80% of the time; relative
    /// time ≈ 0.69 + 0.26 × relative syllables), and the lines around it tell its length better than the song's pace.
    /// So a line the next one follows at once is sung across its time, less a breath; one before a rest (a gap well past
    /// its neighbours') takes about what they take, a little more or less with its syllables. No syllable is drawn out
    /// much past a second.
    static func sungLengths(_ lines: [(time: Double, text: String)], songEnd: Double) -> [Double] {
        func median(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.sorted()[v.count / 2] }
        let gaps = lines.indices.map { k in (k + 1 < lines.count ? lines[k + 1].time : songEnd) - lines[k].time }
        let syl = lines.map { wordless($0.text) ? 0 : syllables($0.text.replacingOccurrences(of: #"<\d+:\d+(?:[.:]\d+)?>"#, with: "", options: .regularExpression)) }
        let sung = lines.indices.filter { syl[$0] > 0 && gaps[$0] > 0.5 }
        let typical = median(sung.map { gaps[$0] }) ?? 3
        let ordinary = sung.filter { gaps[$0] <= typical * 1.6 }
        return lines.indices.map { k in
            guard syl[k] > 0 else { return 0 }
            // The lines around it (four each way): the tempo of this part of the song.
            let near = ordinary.filter { $0 != k && abs($0 - k) <= 4 }
            let usual = median(near.map { gaps[$0] }) ?? typical
            let usualSyl = median(near.map { syl[$0] }) ?? syl[k]
            let own = gaps[k]
            let likely = own <= usual * 1.6 ? own : usual * min(1.6, max(0.5, 0.69 + 0.26 * syl[k] / max(1, usualSyl)))
            let breath = min(0.6, max(0.25, own * 0.1))
            return max(min(0.5, own * 0.9), min(likely, syl[k] + 0.8, own - breath))
        }
    }

    /// About how many syllables a bit of a line takes to sing: vowel groups in a word written in letters (a final silent
    /// "e" left out, at least one a word), each kana or Hangul syllable (small kana join the one before), a kanji as
    /// nearly two, a digit as one.
    static func syllables(_ s: String) -> Double {
        var n = 0.0, word: [Unicode.Scalar] = []
        let vowels = "aeiouyàáâãäåèéêëìíîïòóôõöùúûüýÿæœ".unicodeScalars
        func endWord() {
            guard !word.isEmpty else { return }
            var groups = 0, was = false
            for u in word {
                let v = vowels.contains(u)
                if v && !was { groups += 1 }
                was = v
            }
            if groups > 1, word.last == "e", word.count > 2, !vowels.contains(word[word.count - 2]), word[word.count - 2] != "l" { groups -= 1 }
            n += Double(max(1, groups))
            word = []
        }
        for u in s.lowercased().unicodeScalars {
            let v = u.value
            if CharacterSet.letters.contains(u) && v < 0x3000 {
                word.append(u)
                continue
            }
            endWord()
            if (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) {
                if !"ぁぃぅぇぉゃゅょゎァィゥェォャュョヮ・".unicodeScalars.contains(u) { n += 1 }
            } else if (0x3400...0x9FFF).contains(v) {
                n += 1.7
            } else if CharacterSet.decimalDigits.contains(u) {
                n += 1
            }
        }
        endWord()
        return n
    }

    /// One line with each word's time: from its own stamps, else spread over the time it's likely sung (`sungLengths`):
    /// each word's share by its syllables, the last word held, and a word before a comma (or 、, or a space between
    /// Japanese phrases) drawn out a little before the next comes in. After that it stays lit.
    static func timed(_ raw: String, at time: Double, until next: Double, sung: Double) -> Cue {
        let marks = raw.matches(of: #/<(\d+:\d+(?:[.:]\d+)?)>/#)
        if !marks.isEmpty {
            var words: [Word] = []
            for (k, m) in marks.enumerated() {
                let to = k + 1 < marks.count ? marks[k + 1].range.lowerBound : raw.endIndex
                let text = String(raw[m.range.upperBound..<to])
                guard let t = stamp(m.output.1), !text.isEmpty else { continue }
                if let last = words.indices.last { words[last].end = t }
                words.append(Word(start: t, end: t, text: text))
            }
            if let last = words.indices.last { words[last].end = min(next, words[last].start + max(0.4, Double(words[last].text.count) * 0.09)) }
            let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            if let first = words.first, !text.isEmpty {
                return Cue(time: time, text: text, end: words.last?.end ?? next, words: words.map { var w = $0; w.start = max(w.start, first.start); return w })
            }
        }
        let text = raw.trimmingCharacters(in: .whitespaces)
        let parts = tokens(text)
        let weights = parts.map { 0.25 + syllables($0) }
        let total = weights.reduce(0, +)
        let japanese = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
        // Time not spread by syllables: the last word's hold, and a short hold at each comma inside the line.
        var extra = parts.indices.map { k -> Double in
            guard k < parts.count - 1 else { return min(1.2, max(0.2, sung * 0.18)) }
            let pause = parts[k].range(of: #"[,、，;；:：…—!?！？]|　"#, options: .regularExpression) != nil || (japanese && parts[k].hasSuffix(" "))
            return pause ? min(0.35, max(0.12, sung * 0.06)) : 0
        }
        let held = extra.reduce(0, +)
        if held > sung * 0.4 { extra = extra.map { $0 * sung * 0.4 / held } }
        let spread = sung - extra.reduce(0, +)
        var words: [Word] = []
        var t = time
        for (k, p) in parts.enumerated() {
            let d = spread * weights[k] / total + extra[k]
            words.append(Word(start: t, end: t + d, text: p))
            t += d
        }
        return Cue(time: time, text: text, end: time + sung, words: words)
    }

    /// The line cut into words, each keeping what follows it (spaces, punctuation): NLTokenizer finds the words in
    /// languages written without spaces too.
    static func tokens(_ text: String) -> [String] {
        let tok = NLTokenizer(unit: .word)
        tok.string = text
        var starts: [String.Index] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in starts.append(r.lowerBound); return true }
        guard !starts.isEmpty else { return [text] }
        starts[0] = text.startIndex
        return zip(starts, Array(starts.dropFirst()) + [text.endIndex]).map { String(text[$0..<$1]) }
    }

    /// The cue being sung at a time (-1 before the first).
    func index(at t: Double) -> Int { cues.lastIndex { $0.time <= t } ?? -1 }

    /// Where the song is at a moment, moving on from the last poll while it plays. A poll that finds the song a little
    /// off (under a second) eases there over half a second rather than jumping the words; a seek jumps.
    func playhead(_ date: Date) -> Double {
        let m = NowPlaying.shared
        func at(_ r: Reading) -> Double { r.playing ? r.position + date.timeIntervalSince(r.updated) + Self.lead - Store.shared.settings.lyricsOffset : r.position }
        let now = Reading(position: m.position, updated: m.updated, playing: m.playing)
        if now != reading {
            let off = reading.map(at).map { $0 - at(now) } ?? 0
            slip = abs(off) < 1 && m.playing ? (off, date) : (0, date)
            reading = now
        }
        let fade = max(0, 1 - date.timeIntervalSince(slip.at) / 0.5)
        let p = at(now) + slip.by * fade * fade
        return m.duration > 0 ? min(m.duration, p) : p
    }
    private struct Reading: Equatable {
        var position: Double
        var updated: Date
        var playing: Bool
    }
    @ObservationIgnored private var reading: Reading?
    @ObservationIgnored private var slip: (by: Double, at: Date) = (0, .distantPast)

    /// Keeps a view on the cue being sung: woken at each cue's time while playing. The views start it again at every
    /// poll, so a seek or a pause shows up there.
    func track(_ update: @MainActor (Int) -> Void) async {
        while !Task.isCancelled {
            let t = playhead(Date())
            let i = index(at: t)
            update(i)
            guard NowPlaying.shared.playing, i + 1 < cues.count else { return }
            try? await Task.sleep(for: .seconds(max(0.05, cues[i + 1].time - t)))
        }
    }

    /// Made-up lines for the snapshot (never real lyrics), with a break after the fourth; `second` is another song's,
    /// one line with its own word stamps and one in Japanese (`none`: the next song has no lines).
    func showDemo(second: Bool = false, none: Bool = false) {
        demo = true
        let lrc = second
            ? "[01:00.00]<01:00.00>Second <01:00.40>song <01:00.90>starts <01:01.60>here\n[01:05.00]A line long enough that it has to wrap onto a second row in the notch\n[01:12.00]これは二番目の歌の行です\n[01:18.00]Short one"
            : "[01:02.00]Line one of the song\n[01:10.00]Line two, a little longer than the first one so it wraps\n[01:18.50]Line three of the song\n[01:24.00]Line four comes next\n[01:30.00]\n[01:40.00]Line five after the break"
        withAnimation(loading ? islandSpring : nil) {
            loading = false
            cues = none ? [] : Self.parse(lrc, duration: 200)
            newLines()
        }
    }

    /// `--song-frames`: a song change with the lines still on their way.
    func demoLoading() {
        demo = true
        loading = true
        cues = []
        newLines()
    }

    private func newLines() {
        version += 1
        changed = Date()
        stopBrowsing()
    }

    /// The lyrics face scrolled by some lines (down the song is positive); it eases back to the line being sung 5 s later.
    func scroll(by lines: Double) {
        guard !cues.isEmpty else { return }
        let from = browse ?? Double(max(0, index(at: playhead(Date()))))
        browse = min(Double(cues.count - 1), max(0, from + lines))
        // A click on the trackpad for each line that rolls past the middle, like a reel's ratchet.
        if let to = browse, to.rounded() != from.rounded() {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        browseEnd?.cancel()
        browseEnd = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(islandSettle) { browse = nil }
        }
    }

    func stopBrowsing() {
        browseEnd?.cancel()
        if browse != nil { browse = nil }
    }
}

/// What restarts a lyric view's clock: each poll, play/pause, new lines.
private struct LyricClock: Hashable {
    var updated: Date
    var playing: Bool
    var version: Int
}

@MainActor private func lyricClock(_ lyrics: Lyrics) -> LyricClock {
    LyricClock(updated: NowPlaying.shared.updated, playing: NowPlaying.shared.playing, version: lyrics.version)
}

private let lyricMove = Animation.spring(response: 0.5, dampingFraction: 0.82)

/// The closed notch's lyric line, or dots for a break.
@MainActor @ViewBuilder private func lyricText(_ cue: Lyrics.Cue, size: CGFloat = 12.5) -> some View {
    if let text = cue.text {
        Text(text).font(.app(.lyrics, size, weight: size > 13 ? .semibold : .medium)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
    } else {
        Image(systemName: "ellipsis").font(.system(size: size - 1.5, weight: .bold)).foregroundStyle(.white.opacity(0.6))
    }
}

/// The open player's lyrics face, after Apple Music: every line of the song in a column, the one being sung in the
/// middle, big and bright, its words filling in as they're sung with a soft glow in the cover's colour; the others
/// smaller and dimmer the further they are. Scrolling moves through the song (back to the line being sung 5 s later);
/// clicking a line plays the song from there. Long lines wrap. Breaks are dots that fill up over the break.
struct LyricLines: View {
    let lyrics: Lyrics
    var tint: Color
    /// On screen (the notch open and showing): only then does the line being sung redraw as it goes.
    var live = true
    @State private var index: Int?
    /// Extra lines of turn, wound up as the face opens and let go so the reel spins down onto the line being sung.
    @State private var spin: Double = 0
    @State private var height: CGFloat = 200
    @State private var width: CGFloat = 0

    /// The line being sung, and the rest.
    static let size: CGFloat = 21
    static let small: CGFloat = 14

    var body: some View {
        let cues = lyrics.cues
        let i = min(index ?? lyrics.index(at: lyrics.playhead(Date())), cues.count - 1)
        let focus = (lyrics.browse ?? Double(max(0, i))) + spin
        LyricStack(focus: focus) {
            ForEach(cues.indices, id: \.self) { k in line(cues[k], k: k, i: i, focus: focus) }
        }
        // Lines fade out at the top (under the header, never over it) and at the bottom.
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.35), location: 0.14),
                                   .init(color: .black, location: 0.34), .init(color: .black, location: 0.66),
                                   .init(color: .black.opacity(0.35), location: 0.86), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        // Blurred while the reel spins in, sharpening as it slows.
        .blur(radius: min(2.5, spin * 0.2))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { height = $0.height; width = $0.width }
        .task(id: lyricClock(lyrics)) {
            await lyrics.track { i in
                if index == nil { index = i } else if i != index { withAnimation(reelStop) { index = i } }
            }
        }
        // A fresh position from the player as the face opens, so the first line starts on time; the reel spins in.
        .onAppear {
            NowPlaying.shared.refresh()
            guard Date().timeIntervalSince(lyrics.changed) > 1 else { return }
            spin = 14
            DispatchQueue.main.async { withAnimation(reelSpin) { spin = 0 } }
        }
        .onDisappear { lyrics.stopBrowsing() }
    }

    private func line(_ cue: Lyrics.Cue, k: Int, i: Int, focus: Double) -> some View {
        let cue = Self.rows(cue, width: width)
        let now = k == i, far = abs(Double(k) - focus)
        return Group {
            if cue.text == nil { GapDots(cue: cue, active: now && live).scaleEffect(now ? 1 : 0.7, anchor: .leading) }
            else { KaraokeLine(cue: cue, active: now, live: live, tint: tint) }
        }
        .modifier(LyricFont(size: now ? Self.size : Self.small))
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(now ? 1 : max(0.2, 0.6 - 0.18 * far))
        // Turned with the drum: lines flatten as they go over the top and under the bottom.
        .scaleEffect(x: 1, y: cos(LyricStack.turn(Double(k) - focus, height: height)))
        .contentShape(Rectangle())
        .onTapGesture {
            // Plays from this line; the column follows at once.
            NowPlaying.shared.seek(to: cue.time)
            lyrics.stopBrowsing()
            withAnimation(reelStop) { index = k }
        }
    }
}

extension LyricLines {
    /// Where each line breaks when it's the one being sung (full size, full width), by line text and width.
    nonisolated(unsafe) private static var breaks: [String: [Int]] = [:]

    /// The line with those breaks written into it, so it keeps the same rows big or small (smaller, every row still
    /// fits): becoming the line being sung never re-wraps it.
    static func rows(_ cue: Lyrics.Cue, width: CGFloat) -> Lyrics.Cue {
        guard let text = cue.text, width > 0 else { return cue }
        var parts = cue.words.isEmpty ? [text] : cue.words.map(\.text)
        let joined = parts.joined()
        let font = Fonts.ns(.lyrics, size, weight: .bold)
        let key = "\(Int(width))|\(font.fontName)|\(font.pointSize)|\(joined)"
        let found = breaks[key] ?? {
            let s = NSAttributedString(string: joined, attributes: [.font: font])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(s), CFRange(location: 0, length: 0),
                                                 CGPath(rect: CGRect(x: 0, y: 0, width: width - 2, height: 10_000), transform: nil), nil)
            let starts = (CTFrameGetLines(frame) as? [CTLine] ?? []).dropFirst().map { CTLineGetStringRange($0).location }
            breaks[key] = starts
            return starts
        }()
        guard !found.isEmpty else { return cue }
        var starts: [Int] = [], at = 0
        for p in parts { starts.append(at); at += (p as NSString).length }
        // Last break first, so the earlier offsets still hold. A space before a break becomes the line break; else one goes in.
        for b in found.sorted(by: >) where b > 0 {
            let t = b - 1
            guard let k = starts.lastIndex(where: { $0 <= t }) else { continue }
            let m = NSMutableString(string: parts[k]), o = t - starts[k]
            guard o < m.length else { continue }
            let ch = m.character(at: o)
            if ch == 0x20 || ch == 0x3000 { m.replaceCharacters(in: NSRange(location: o, length: 1), with: "\n") } else { m.insert("\n", at: o + 1) }
            parts[k] = m as String
        }
        var out = cue
        if cue.words.isEmpty { out.text = parts[0] } else {
            for k in parts.indices { out.words[k].text = parts[k] }
            out.text = parts.joined().trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}

/// A new line: the reel turns over in one smooth move, no overshoot (a bounce wobbled every line on the drum).
private let reelStop = Animation.spring(response: 0.45, dampingFraction: 1)
/// Opening the face: a long spin that slows onto the line being sung, overshooting a touch.
private let reelSpin = Animation.spring(response: 1.1, dampingFraction: 0.7)

/// The lines on a drum, like a slot machine reel: the line at `focus` (fractional while scrolling) faces you in the
/// middle; the others wrap round it, bunching up as they go over the top and under the bottom.
private struct LyricStack: Layout {
    /// About one line's travel, for the lean of each line (the drum's own positions use the real heights).
    static let pitch = 27.0
    static func radius(_ height: CGFloat) -> Double { max(80, Double(height)) }
    /// How far round the drum a line is, `lines` from the front: a quarter turn at most (edge on, out of sight).
    static func turn(_ lines: Double, height: CGFloat) -> Double { min(.pi / 2, max(-.pi / 2, lines * pitch / radius(height))) }

    var focus: Double
    var spacing: CGFloat = 8
    var animatableData: Double {
        get { focus }
        set { focus = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { proposal.replacingUnspecifiedDimensions() }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = ProposedViewSize(width: bounds.width, height: nil)
        let heights = subviews.map { $0.sizeThatFits(width).height }
        guard !heights.isEmpty else { return }
        var tops: [CGFloat] = [], y: CGFloat = 0
        for h in heights { tops.append(y); y += h + spacing }
        func middle(_ k: Int) -> CGFloat { tops[k] + heights[k] / 2 }
        let k = min(heights.count - 1, max(0, Int(focus.rounded(.down)))), f = CGFloat(focus) - CGFloat(k)
        let at = k + 1 < heights.count ? middle(k) + (middle(k + 1) - middle(k)) * f : middle(k)
        let r = Self.radius(bounds.height)
        for (n, v) in subviews.enumerated() {
            let angle = min(.pi / 2, max(-.pi / 2, Double(middle(n) - at) / r))
            v.place(at: CGPoint(x: bounds.minX, y: bounds.midY + CGFloat(r * sin(angle))), anchor: .leading, proposal: width)
        }
    }
}

/// The lines' font: its size springs (and the line rewraps) as a line becomes the one being sung.
private struct LyricFont: ViewModifier, Animatable {
    var size: CGFloat
    var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }

    func body(content: Content) -> some View { content.font(.app(.lyrics, size, weight: .bold)).environment(\.lyricSize, size) }
}

extension EnvironmentValues {
    /// The lyrics face's font size for a line, for the parts drawn in a hosting view of their own.
    @Entry var lyricSize: CGFloat = LyricLines.small
}

/// Drawn in a hosting view of its own: its redraws (30 a second) lay out and commit only itself, never the notch
/// around it. Clicks go through to the line under it.
private struct Isolated<Content: View>: NSViewRepresentable {
    let content: Content

    final class Host: NSHostingView<Content> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Host {
        let h = Host(rootView: content)
        h.sizingOptions = []
        return h
    }

    func updateNSView(_ h: Host, context: Context) { h.rootView = content }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Host, context: Context) -> CGSize? { proposal.replacingUnspecifiedDimensions() }
}

/// `--cpu-test`: how many times a karaoke line was drawn.
nonisolated(unsafe) var karaokeDraws = 0

/// The lyrics face's moving parts: 30 frames a second while on and seen, else none.
private struct Frames: TimelineSchedule {
    var on: Bool

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = start, first = true
        return AnyIterator {
            guard on, mode == .normal else {
                defer { first = false }
                return first ? start : nil
            }
            defer { next += 1.0 / 30 }
            return next
        }
    }
}

/// When a word is sung, carried on its piece of the line.
private struct Sung: TextAttribute {
    var start: Double
    var end: Double
}

/// A line drawn word by word: sung words bright, the one being sung filling left to right with a soft glow and a
/// slight lift, the rest dim. Off, the line is drawn plain.
private struct Karaoke: TextRenderer {
    var t: Double
    var tint: Color
    var on: Bool

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        karaokeDraws += 1
        for line in layout {
            for run in line {
                guard on, let w = run[Sung.self] else { ctx.draw(run); continue }
                let p = min(1, max(0, (t - w.start) / max(0.05, w.end - w.start)))
                var c = ctx
                c.translateBy(x: 0, y: -1.5 * p)
                var dim = c
                dim.opacity = 0.35
                dim.draw(run)
                guard p > 0 else { continue }
                let r = run.typographicBounds.rect
                let edge = r.minX - 6 + (r.width + 12) * p
                var lit = c
                lit.clipToLayer { m in
                    m.fill(Path(r.insetBy(dx: -6, dy: -10)),
                           with: .linearGradient(Gradient(colors: [.black, .clear]), startPoint: CGPoint(x: edge - 6, y: 0), endPoint: CGPoint(x: edge + 6, y: 0)))
                }
                if p < 1 { lit.addFilter(.shadow(color: tint.opacity(0.95), radius: 6)) }
                lit.draw(run)
            }
        }
    }
}

/// One line of the lyrics face. While it's the one being sung, a copy of it laid over it (in a hosting view of its
/// own) carries each word's time and redraws 30 times a second while the song plays and the face is on screen.
private struct KaraokeLine: View {
    let cue: Lyrics.Cue
    let active: Bool
    let live: Bool
    var tint: Color
    @Environment(\.lyricSize) private var size
    private var fill: Bool { Store.shared.settings.notchLyricsFill }

    var body: some View {
        Text(verbatim: cue.text ?? "")
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            // Swapped with the copy at once, never cross-faded (that showed the line twice as it moved).
            .animation(nil) { $0.opacity(active && fill ? 0 : 1) }
            .overlay {
                if active && fill {
                    let words = sung, on = live && NowPlaying.shared.playing, tint = tint, size = size
                    Isolated(content: TimelineView(Frames(on: on)) { ctx in
                        words.font(.app(.lyrics, size, weight: .bold))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .textRenderer(Karaoke(t: Lyrics.shared.playhead(ctx.date), tint: tint, on: true))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    })
                    .transition(.identity)
                }
            }
    }

    /// The line with each word's time on it, in one flat interpolation (nesting a Text per word made every redraw
    /// resolve the line once per word).
    private var sung: Text {
        var s = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: cue.words.count)
        for w in cue.words { s.appendInterpolation(Text(verbatim: w.text).customAttribute(Sung(start: w.start, end: w.end))) }
        return cue.words.isEmpty ? Text(verbatim: cue.text ?? "") : Text(LocalizedStringKey(stringInterpolation: s))
    }
}

/// A break: three dots that light up one by one as it goes on, breathing, and shrinking away just before the singing
/// comes back.
private struct GapDots: View {
    let cue: Lyrics.Cue
    let active: Bool

    var body: some View {
        if active {
            let cue = cue
            Color.clear.frame(height: 22).overlay {
                Isolated(content: TimelineView(Frames(on: NowPlaying.shared.playing)) { ctx in Self.dots(cue, at: ctx.date, active: true) })
            }
            .transition(.identity)
        } else {
            Self.dots(cue, at: .now, active: false).transition(.identity)
        }
    }

    private static func dots(_ cue: Lyrics.Cue, at date: Date, active: Bool) -> some View {
        let t = Lyrics.shared.playhead(date)
        let p = active ? min(1, max(0, (t - cue.time) / max(1, cue.end - cue.time))) : 0
        let breathe = active ? 1 + 0.1 * sin(date.timeIntervalSinceReferenceDate * 2.6) : 1
        let away = p > 0.94 ? max(0, (1 - p) / 0.06) : 1
        return HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { k in
                let lit = min(1, max(0, p * 3 - Double(k)))
                Circle().fill(Color.white.opacity(0.28 + 0.72 * lit)).frame(width: 9, height: 9)
                    .scaleEffect(0.8 + 0.2 * lit)
            }
        }
        .scaleEffect(breathe * away, anchor: .leading)
        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: .infinity, alignment: .leading)
    }
}

/// Closed notch (Settings › Notch): the line being sung, just under the notch while the song plays. It hangs in its
/// own black pill so the notch keeps its width.
struct ClosedLyricLine: View {
    let model: IslandModel
    @State private var index: Int?

    var body: some View {
        let lyrics = Lyrics.shared
        let shown = model.stage == .compact && model.contentVisible && lyrics.closedLine && NowPlaying.shared.playing
            && model.compactShown.contains(.media)
        let i = index ?? lyrics.index(at: lyrics.playhead(Date()))
        ZStack {
            if shown, lyrics.cues.indices.contains(i) {
                ZStack {
                    lyricText(lyrics.cues[i])
                        .id(i)
                        .transition(.push(from: .bottom))
                }
                // As wide as the line (up to a limit), growing and shrinking as the lines change.
                .frame(width: Self.width(lyrics.cues[i]), height: 16)
                .clipped()
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black))
                .clipShape(Capsule())
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: shown)
        // Runs while it's wanted, even before the first line (to wake for it); starts afresh each time it shows.
        .task(id: shown ? lyricClock(lyrics) : nil) {
            guard shown else { index = nil; return }
            await lyrics.track { i in
                if index == nil { index = i } else if i != index { withAnimation(lyricMove) { index = i } }
            }
        }
        .padding(.top, model.geometry.topInset + model.geometry.compactSize.height + 5)
        .allowsHitTesting(false)
    }

    private static func width(_ cue: Lyrics.Cue) -> CGFloat {
        guard let text = cue.text else { return 16 }
        return min(340, ceil((text as NSString).size(withAttributes: [.font: Fonts.ns(.lyrics, 12.5, weight: .medium)]).width))
    }
}
