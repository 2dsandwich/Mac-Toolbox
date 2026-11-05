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
    /// A new song's lines are on their way: the lyrics face stays up (empty) instead of flipping to the player and back.
    private(set) var loading = false
    /// Changes with each song's lines, so a view starts afresh rather than scrolling from the last song's place.
    private(set) var version = 0
    /// Lines to show, or about to be.
    var hasLines: Bool { !cues.isEmpty || loading }
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
        version += 1
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
        // None after all: the face folds back into the player as one move.
        withAnimation(lines.isEmpty && loading ? islandSpring : nil) {
            loading = false
            cues = lines
            version += 1
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
        var out: [Cue] = []
        if let first = lines.first(where: { !wordless($0.text) }), first.time >= gapMin { out.append(Cue(time: 0, text: nil, end: first.time)) }
        for (k, l) in lines.enumerated() {
            let next = k + 1 < lines.count ? lines[k + 1].time : songEnd
            if wordless(l.text) {
                guard next - l.time >= gapMin, !out.isEmpty, out.last?.text != nil else { continue }
                out.append(Cue(time: l.time, text: nil, end: next))
            } else {
                let cue = timed(l.text, at: l.time, until: next)
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

    /// One line with each word's time: from its own stamps, else spread over the time it likely takes to sing (each
    /// word's share by its length; kana and kanji take longer than letters), never past the next line.
    static func timed(_ raw: String, at time: Double, until next: Double) -> Cue {
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
        let weights = parts.map { p in 1 + p.unicodeScalars.reduce(0.0) { $0 + (wide($1) ? 2.2 : $1.properties.isWhitespace ? 0.3 : 1) } }
        let total = weights.reduce(0, +)
        let sung = min(max(0.8, total * 0.07), max(0.6, (next - time) * 0.92))
        var words: [Word] = []
        var t = time
        for (p, w) in zip(parts, weights) {
            let d = sung * w / total
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

    private static func wide(_ u: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(u.value) || (0x3400...0x9FFF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value)
    }

    /// The cue being sung at a time (-1 before the first).
    func index(at t: Double) -> Int { cues.lastIndex { $0.time <= t } ?? -1 }

    /// Where the song is at a moment, moving on from the last poll while it plays.
    func playhead(_ date: Date) -> Double {
        let m = NowPlaying.shared
        guard m.playing else { return m.position }
        let p = m.position + date.timeIntervalSince(m.updated) + Self.lead
        return m.duration > 0 ? min(m.duration, p) : p
    }

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
            version += 1
        }
    }

    /// `--song-frames`: a song change with the lines still on their way.
    func demoLoading() {
        demo = true
        loading = true
        cues = []
        version += 1
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
@ViewBuilder private func lyricText(_ cue: Lyrics.Cue, size: CGFloat = 12.5) -> some View {
    if let text = cue.text {
        Text(text).font(.system(size: size, weight: size > 13 ? .semibold : .medium)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
    } else {
        Image(systemName: "ellipsis").font(.system(size: size - 1.5, weight: .bold)).foregroundStyle(.white.opacity(0.6))
    }
}

/// The open player's lyrics face, after Apple Music: the line being sung big and bright, its words filling in as
/// they're sung with a soft glow in the cover's colour; the next lines dimmer and smaller under it; past lines drift up
/// and fade. Long lines wrap. Breaks are dots that fill up over the break.
struct LyricLines: View {
    let lyrics: Lyrics
    var tint: Color
    @State private var index: Int?
    @State private var heights: [Int: CGFloat] = [:]

    static let size: CGFloat = 17
    private static let spacing: CGFloat = 9

    var body: some View {
        let cues = lyrics.cues
        let i = min(index ?? lyrics.index(at: lyrics.playhead(Date())), cues.count - 1)
        let lo = max(0, i - 1), hi = min(cues.count - 1, max(0, i) + 3)
        // Up by the lines above the one being sung, so it sits at the top.
        let top = (lo..<max(lo, i)).reduce(CGFloat(0)) { $0 + (heights[$1] ?? 22) + Self.spacing }
        VStack(alignment: .leading, spacing: Self.spacing) {
            if lo <= hi {
                ForEach(lo...hi, id: \.self) { k in
                    line(cues[k], k: k, i: i)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[k] = $0 }
                }
            }
        }
        .padding(.top, 6)
        .offset(y: -top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Lines leaving at the top fade out under the header, never over it; the last ones fade at the bottom.
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                                   .init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .task(id: lyricClock(lyrics)) {
            await lyrics.track { i in
                if index == nil { index = i } else if i != index { withAnimation(lyricMove) { index = i } }
            }
        }
    }

    private func line(_ cue: Lyrics.Cue, k: Int, i: Int) -> some View {
        let now = k == i
        return Group {
            if cue.text == nil { GapDots(cue: cue, active: now) } else { KaraokeLine(cue: cue, active: now, tint: tint) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(now ? 1 : 0.9, anchor: .leading)
        .opacity(k < i ? 0 : now ? 1 : k == i + 1 ? 0.42 : 0.2)
        .blur(radius: k > i + 1 ? 0.6 : 0)
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

/// One line of the lyrics face; while it's the one being sung (and the song plays) it redraws every frame.
private struct KaraokeLine: View {
    let cue: Lyrics.Cue
    let active: Bool
    var tint: Color

    var body: some View {
        let text = cue.words.isEmpty ? Text(cue.text ?? "")
            : cue.words.reduce(Text("")) { Text("\($0)\(Text($1.text).customAttribute(Sung(start: $1.start, end: $1.end)))") }
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || !NowPlaying.shared.playing)) { ctx in
            text.font(.system(size: LyricLines.size, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .textRenderer(Karaoke(t: Lyrics.shared.playhead(ctx.date), tint: tint, on: active))
        }
    }
}

/// A break: three dots that light up one by one as it goes on, breathing, and shrinking away just before the singing
/// comes back.
private struct GapDots: View {
    let cue: Lyrics.Cue
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || !NowPlaying.shared.playing)) { ctx in
            let t = Lyrics.shared.playhead(ctx.date)
            let p = active ? min(1, max(0, (t - cue.time) / max(1, cue.end - cue.time))) : 0
            let breathe = active ? 1 + 0.1 * sin(ctx.date.timeIntervalSinceReferenceDate * 2.6) : 1
            let away = p > 0.94 ? max(0, (1 - p) / 0.06) : 1
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { k in
                    let lit = min(1, max(0, p * 3 - Double(k)))
                    Circle().fill(Color.white.opacity(0.28 + 0.72 * lit)).frame(width: 9, height: 9)
                        .scaleEffect(0.8 + 0.2 * lit)
                }
            }
            .scaleEffect(breathe * away, anchor: .leading)
            .frame(height: 22, alignment: .leading)
        }
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
        return min(340, ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium)]).width))
    }
}
