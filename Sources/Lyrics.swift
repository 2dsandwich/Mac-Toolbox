import AppKit
import CryptoKit
import Observation
import SwiftUI

// Synced lyrics for the song in Music or Spotify, from LRCLIB (lrclib.net): looked up when the song changes, for
// display only, and kept on disk so each song is asked for once. Nothing is bundled, and nothing is fetched while
// Settings › Notch › Lyrics is off. Shown under the song in the open notch, and (if you like) as one line under the
// closed notch.

@MainActor @Observable final class Lyrics {
    static let shared = Lyrics()

    /// One timed line. No text is an instrumental break of 5 s or more (shown as a music note).
    struct Cue: Equatable {
        var time: Double
        var text: String?
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
    /// Extra height the lyrics take in the open notch's music player.
    var openHeight: CGFloat { cues.isEmpty ? 0 : LyricLines.height + 10 }

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
            return
        }
        guard song.key != current?.key else { return }
        current = song
        cues = []
        if let e = Self.cached(song) { return show(e, song) }
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
            if let entry {
                Self.save(entry, song)
                if song.key == current?.key { show(entry, song) }
            }
            pump()
        }
    }

    private func show(_ e: Entry, _ song: Song) {
        cues = e.instrumental ? [] : e.synced.map { Self.parse($0, duration: song.duration) } ?? []
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
    /// skipped. A blank line is a break: a music note when it's 5 s or more (as is a long intro), else the line
    /// before stays.
    static func parse(_ lrc: String, duration: Double) -> [Cue] {
        var lines: [(time: Double, text: String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let stamp = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":", maxSplits: 1)
                guard stamp.count == 2, let m = Double(stamp[0]), let s = Double(stamp[1].replacingOccurrences(of: ":", with: ".")) else { break }
                times.append(m * 60 + s)
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            lines += times.map { ($0, text) }
        }
        lines.sort { $0.time < $1.time }
        guard lines.contains(where: { !$0.text.isEmpty }) else { return [] }
        var out: [Cue] = []
        if let first = lines.first(where: { !$0.text.isEmpty }), first.time >= gapMin { out.append(Cue(time: 0, text: nil)) }
        for (k, l) in lines.enumerated() {
            if l.text.isEmpty {
                let end = k + 1 < lines.count ? lines[k + 1].time : (duration > 0 ? duration : .infinity)
                guard end - l.time >= gapMin, !out.isEmpty, out.last?.text != nil else { continue }
                out.append(Cue(time: l.time, text: nil))
            } else {
                out.append(Cue(time: l.time, text: l.text))
            }
        }
        return out
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

    /// Made-up lines for the snapshot (never real lyrics), with a break after the fourth.
    func showDemo() {
        demo = true
        cues = [Cue(time: 62, text: "Line one of the song"), Cue(time: 70, text: "Line two, a little longer than the first one"),
                Cue(time: 78.5, text: "Line three of the song"), Cue(time: 84, text: "Line four comes next"),
                Cue(time: 90, text: nil), Cue(time: 100, text: "Line five after the break")]
    }
}

/// What restarts a lyric view's clock: each poll, play/pause, new lines.
private struct LyricClock: Hashable {
    var updated: Date
    var playing: Bool
    var count: Int
}

@MainActor private func lyricClock(_ lyrics: Lyrics) -> LyricClock {
    LyricClock(updated: NowPlaying.shared.updated, playing: NowPlaying.shared.playing, count: lyrics.cues.count)
}

private let lyricMove = Animation.spring(response: 0.45, dampingFraction: 0.9)

/// A lyric line, or the quiet note for a break.
@ViewBuilder private func lyricText(_ cue: Lyrics.Cue) -> some View {
    if let text = cue.text {
        Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
    } else {
        Image(systemName: "music.note").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
    }
}

/// Open notch, under the song: the line being sung, the next one dimmer; they move up as the song goes on.
struct LyricLines: View {
    let lyrics: Lyrics
    @State private var index: Int?

    static let lineHeight: CGFloat = 18
    static let height: CGFloat = lineHeight * 2

    var body: some View {
        let cues = lyrics.cues
        let i = min(index ?? lyrics.index(at: lyrics.playhead(Date())), cues.count - 1)
        ZStack(alignment: .topLeading) {
            if !cues.isEmpty {
                ForEach(max(0, i - 1)...min(cues.count - 1, max(0, i + 2)), id: \.self) { k in
                    lyricText(cues[k])
                        .frame(height: Self.lineHeight)
                        .opacity(k == i ? 1 : k == i + 1 ? 0.45 : 0)
                        .offset(y: CGFloat(k - i) * Self.lineHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
        .clipped()
        .task(id: lyricClock(lyrics)) {
            await lyrics.track { i in
                if index == nil { index = i } else if i != index { withAnimation(lyricMove) { index = i } }
            }
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
        guard let text = cue.text else { return 12 }
        return min(340, ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium)]).width))
    }
}
