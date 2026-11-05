import AppKit
import ImageIO
import Observation
import SwiftUI

/// Clock changes happen inside an animation, so the notch (and the popup) glide instead of jumping.
@MainActor func clockChange(_ change: () -> Void) {
    withAnimation(islandSettle) { change() }
}

/// ⌘5 Clock: Focus (Pomodoro), Timers, Stopwatches and Alarms.
enum ClockMode: String, CaseIterable, Identifiable {
    case focus, timer, stopwatch, alarms
    var id: String { rawValue }
    var title: String {
        switch self {
        case .focus: "Focus"
        case .timer: "Timer"
        case .stopwatch: "Stopwatch"
        case .alarms: "Alarms"
        }
    }
    var symbol: String {
        switch self {
        case .focus: "brain.head.profile"
        case .timer: "timer"
        case .stopwatch: "stopwatch"
        case .alarms: "alarm"
        }
    }
}

/// Chimes and the notch messages for the clocks.
@MainActor enum ClockSound {
    static var announce: (String, String, String) -> Void = { _, _, _ in }

    static func play(_ name: String = "Glass", volume: Float = 0.8) {
        let s = NSSound(named: name)
        s?.volume = volume
        s?.play()
    }

    /// Alert sounds available to alarms (the system's).
    static let names: [String] = {
        let dirs = ["/System/Library/Sounds", NSHomeDirectory() + "/Library/Sounds"]
        let found = dirs.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
            .filter { $0.hasSuffix(".aiff") || $0.hasSuffix(".caf") || $0.hasSuffix(".wav") }
            .map { ($0 as NSString).deletingPathExtension }
        return Array(Set(found)).sorted()
    }()
}

// MARK: Timers (as many as you like)

@MainActor @Observable final class CountdownTimer: Identifiable {
    let id = UUID()
    var label: String
    var length: TimeInterval
    var endsAt: Date
    var pausedLeft: TimeInterval?
    var finished = false

    init(seconds: TimeInterval, label: String) {
        self.label = label
        length = seconds
        endsAt = Date().addingTimeInterval(seconds)
    }

    var paused: Bool { pausedLeft != nil }
    var running: Bool { !finished && !paused }
    func remaining(_ now: Date) -> TimeInterval { finished ? 0 : pausedLeft ?? max(0, endsAt.timeIntervalSince(now)) }
    func progress(_ now: Date) -> Double { length > 0 ? min(1, max(0, 1 - remaining(now) / length)) : 0 }
    var name: String { label.isEmpty ? SystemTools.span(length / 60) + " timer" : label }
}

@MainActor @Observable final class Timers {
    static let shared = Timers()

    var list: [CountdownTimer] = []
    var now = Date()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var ticker: Timer?

    var running: [CountdownTimer] { list.filter(\.running) }
    /// The one that rings soonest.
    var next: CountdownTimer? { running.min { $0.remaining(now) < $1.remaining(now) } }

    @discardableResult func add(minutes: Double, label: String = "") -> CountdownTimer {
        Stats.shared.add(.timers)
        let t = CountdownTimer(seconds: max(1, minutes * 60), label: label)
        clockChange {
            list.insert(t, at: 0)
            tick()
            changed()
        }
        return t
    }

    func toggle(_ t: CountdownTimer) {
        now = Date()
        if t.finished { return restart(t) }
        clockChange {
            if let left = t.pausedLeft {
                t.endsAt = now.addingTimeInterval(left)
                t.pausedLeft = nil
            } else {
                t.pausedLeft = t.remaining(now)
            }
            changed()
        }
    }

    func extend(_ t: CountdownTimer, _ seconds: TimeInterval) {
        if t.finished {
            t.finished = false
            t.endsAt = Date().addingTimeInterval(seconds)
            t.length = seconds
        } else if let left = t.pausedLeft {
            t.pausedLeft = left + seconds
            t.length += seconds
        } else {
            t.endsAt = t.endsAt.addingTimeInterval(seconds)
            t.length += seconds
        }
        changed()
    }

    func restart(_ t: CountdownTimer) {
        clockChange {
            t.finished = false
            t.pausedLeft = nil
            t.endsAt = Date().addingTimeInterval(t.length)
            changed()
        }
    }

    func remove(_ t: CountdownTimer) {
        clockChange {
            list.removeAll { $0.id == t.id }
            changed()
        }
    }

    private func changed() {
        tick()
        if ticker == nil, !running.isEmpty {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
        onChange?()
    }

    private func tick() {
        now = Date()
        for t in running where t.remaining(now) <= 0 {
            clockChange { t.finished = true }
            ClockSound.play(Store.shared.settings.timerSound)
            ClockSound.announce("Time’s up", t.name, "timer")
            onChange?()
        }
        if running.isEmpty {
            ticker?.invalidate()
            ticker = nil
        }
    }
}

// MARK: Stopwatches

@MainActor @Observable final class Stopwatch: Identifiable {
    let id = UUID()
    var startedAt: Date?
    var banked: TimeInterval = 0
    /// Elapsed time at each lap, newest first.
    var laps: [TimeInterval] = []

    var running: Bool { startedAt != nil }
    var active: Bool { running || banked > 0 }
    func elapsed(_ now: Date) -> TimeInterval { banked + (startedAt.map { now.timeIntervalSince($0) } ?? 0) }

    /// 1:02:03.45, 02:03.45, or without hundredths for the notch.
    static func format(_ t: TimeInterval, hundredths: Bool = true) -> String {
        let total = Int(t)
        let h = total / 3600, m = total % 3600 / 60, s = total % 60, cs = Int((t - Double(total)) * 100)
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
        return hundredths ? base + String(format: ".%02d", cs) : base
    }
}

@MainActor @Observable final class Stopwatches {
    static let shared = Stopwatches()

    var list: [Stopwatch] = [Stopwatch()]
    var now = Date()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var ticker: Timer?

    var running: [Stopwatch] { list.filter(\.running) }

    func add() {
        let w = Stopwatch()
        clockChange { list.insert(w, at: 0) }
        toggle(w)
    }

    func toggle(_ w: Stopwatch) {
        now = Date()
        clockChange {
            if let s = w.startedAt {
                w.banked += now.timeIntervalSince(s)
                w.startedAt = nil
            } else {
                w.startedAt = now
            }
            changed()
        }
    }

    func lap(_ w: Stopwatch) {
        guard w.running else { return }
        now = Date()
        w.laps.insert(w.elapsed(now), at: 0)
    }

    func reset(_ w: Stopwatch) {
        clockChange {
            w.startedAt = nil
            w.banked = 0
            w.laps = []
            changed()
        }
    }

    func remove(_ w: Stopwatch) {
        clockChange {
            list.removeAll { $0.id == w.id }
            if list.isEmpty { list = [Stopwatch()] }
            changed()
        }
    }

    private func changed() {
        if running.isEmpty {
            ticker?.invalidate()
            ticker = nil
        } else if ticker == nil {
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.now = Date() } }
            t.tolerance = 0.02
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        }
        onChange?()
    }
}

// MARK: Alarms

struct Alarm: Codable, Identifiable, Equatable {
    var id = UUID()
    var hour: Int
    var minute: Int
    var label = ""
    var enabled = true
    /// 1 = Sunday … 7 = Saturday. Empty = rings once.
    var weekdays: Set<Int> = []
    var sound = "Glass"
    var snooze = true
    var snoozeMinutes = 9
    var lastRang: Date?

    init(hour: Int, minute: Int, label: String = "", weekdays: Set<Int> = [], sound: String = "Glass", snooze: Bool = true, snoozeMinutes: Int = 9) {
        self.hour = hour
        self.minute = minute
        self.label = label
        self.weekdays = weekdays
        self.sound = sound
        self.snooze = snooze
        self.snoozeMinutes = snoozeMinutes
    }

    // Older saved alarms had a "daily" flag instead of days.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        hour = try c.decode(Int.self, forKey: .hour)
        minute = try c.decode(Int.self, forKey: .minute)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        weekdays = try c.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? ((try? c.decodeIfPresent(Bool.self, forKey: .daily)) == true ? Set(1...7) : [])
        sound = try c.decodeIfPresent(String.self, forKey: .sound) ?? "Glass"
        snooze = try c.decodeIfPresent(Bool.self, forKey: .snooze) ?? true
        snoozeMinutes = try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? 9
        lastRang = try c.decodeIfPresent(Date.self, forKey: .lastRang)
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(hour, forKey: .hour)
        try c.encode(minute, forKey: .minute)
        try c.encode(label, forKey: .label)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(weekdays, forKey: .weekdays)
        try c.encode(sound, forKey: .sound)
        try c.encode(snooze, forKey: .snooze)
        try c.encode(snoozeMinutes, forKey: .snoozeMinutes)
        try c.encodeIfPresent(lastRang, forKey: .lastRang)
    }

    private enum CodingKeys: String, CodingKey { case id, hour, minute, label, enabled, weekdays, sound, snooze, snoozeMinutes, lastRang, daily }

    var time: String { Self.time(hour, minute) }

    static func time(_ hour: Int, _ minute: Int) -> String {
        var c = DateComponents()
        c.hour = hour
        c.minute = minute
        let df = DateFormatter()
        df.timeStyle = .short
        return Calendar.current.date(from: c).map(df.string) ?? String(format: "%d:%02d", hour, minute)
    }

    /// "Every day", "Weekdays", "Mon, Wed" or "Once".
    var repeatText: String {
        switch weekdays {
        case []: return "Once"
        case Set(1...7): return "Every day"
        case Set(2...6): return "Weekdays"
        case [1, 7]: return "Weekends"
        default:
            let names = Calendar.current.shortWeekdaySymbols
            return weekdays.sorted().map { names[$0 - 1] }.joined(separator: ", ")
        }
    }

    /// When it rings next.
    var next: Date {
        let cal = Calendar.current
        if weekdays.isEmpty {
            return cal.nextDate(after: Date(), matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime) ?? Date()
        }
        return weekdays.compactMap { cal.nextDate(after: Date(), matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: $0), matchingPolicy: .nextTime) }.min() ?? Date()
    }
}

/// The alarm being added or edited.
struct AlarmDraft: Equatable {
    var editing: UUID?
    var hour: Int
    var minute: Int
    var weekdays: Set<Int> = []
    var label = ""
    var sound = "Glass"
    var snooze = true
    var snoozeMinutes = 9

    @MainActor static func new() -> AlarmDraft {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        var d = AlarmDraft(hour: c.hour ?? 7, minute: c.minute ?? 0)
        d.sound = Store.shared.settings.alarmSound
        d.snoozeMinutes = Store.shared.settings.alarmSnoozeMinutes
        return d
    }

    init(editing: UUID? = nil, hour: Int, minute: Int) {
        self.editing = editing
        self.hour = hour
        self.minute = minute
    }

    init(_ a: Alarm) {
        editing = a.id
        hour = a.hour
        minute = a.minute
        weekdays = a.weekdays
        label = a.label
        sound = a.sound
        snooze = a.snooze
        snoozeMinutes = a.snoozeMinutes
    }
}

@MainActor @Observable final class Alarms {
    static let shared = Alarms()
    private static let key = "alarms"

    var list: [Alarm] = [] { didSet { save() } }
    var ringing: Alarm?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var checker: Timer?
    @ObservationIgnored private var bell: Timer?

    var upcoming: [Alarm] { list.filter(\.enabled).sorted { $0.next < $1.next } }
    /// Alarms that already rang (and one-offs that are off), newest first.
    var past: [Alarm] { list.filter { !$0.enabled }.sorted { ($0.lastRang ?? .distantPast) > ($1.lastRang ?? .distantPast) } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Alarm].self, from: data) { list = saved }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        checker = t
    }

    private func save() {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    @discardableResult func add(hour: Int, minute: Int, label: String = "", weekdays: Set<Int> = []) -> Alarm {
        let a = Alarm(hour: hour, minute: minute, label: label, weekdays: weekdays)
        list.append(a)
        onChange?()
        return a
    }

    @discardableResult func save(_ d: AlarmDraft) -> Alarm {
        var a = Alarm(hour: d.hour, minute: d.minute, label: d.label, weekdays: d.weekdays, sound: d.sound, snooze: d.snooze, snoozeMinutes: d.snoozeMinutes)
        if let id = d.editing, let i = list.firstIndex(where: { $0.id == id }) {
            a.id = id
            a.lastRang = list[i].lastRang
            list[i] = a
        } else {
            list.append(a)
        }
        onChange?()
        return a
    }

    func remove(_ id: UUID) {
        list.removeAll { $0.id == id }
        onChange?()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].enabled = on
        onChange?()
    }

    func clearPast() {
        list.removeAll { !$0.enabled }
        onChange?()
    }

    private func check() {
        let now = Date()
        let c = Calendar.current.dateComponents([.hour, .minute, .weekday], from: now)
        for a in list where a.enabled && a.hour == c.hour && a.minute == c.minute && (a.weekdays.isEmpty || a.weekdays.contains(c.weekday ?? 0)) {
            if let last = a.lastRang, now.timeIntervalSince(last) < 90 { continue }
            guard let i = list.firstIndex(where: { $0.id == a.id }) else { continue }
            list[i].lastRang = now
            if a.weekdays.isEmpty { list[i].enabled = false }
            ring(list[i])
        }
    }

    private func ring(_ a: Alarm) {
        Stats.shared.add(.alarms)
        clockChange { ringing = a }
        bell?.invalidate()
        var count = 0
        ClockSound.play(a.sound)
        // Rings every 2 s for a minute, or until stopped.
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                count += 1
                if count > 30 { self?.dismiss() } else { ClockSound.play(a.sound) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        bell = t
        onChange?()
    }

    func dismiss() {
        bell?.invalidate()
        bell = nil
        clockChange {
            ringing = nil
            onChange?()
        }
    }

    func snooze() {
        guard let a = ringing else { return }
        let at = Date().addingTimeInterval(Double(a.snoozeMinutes) * 60)
        let c = Calendar.current.dateComponents([.hour, .minute], from: at)
        var s = Alarm(hour: c.hour ?? 0, minute: c.minute ?? 0, label: a.label.isEmpty ? "Snoozed" : a.label, sound: a.sound, snooze: a.snooze, snoozeMinutes: a.snoozeMinutes)
        s.weekdays = []
        list.append(s)
        dismiss()
    }

    /// "7:30", "7am", "7:30pm wake up", "19:00", "7時30分", "in 20 min" → hour, minute and a label.
    static func parse(_ raw: String) -> (hour: Int, minute: Int, label: String)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let m = Tools.rx(#"^in\s+(.+)$"#, s), let mins = SystemTools.minutes(m[1]).value {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(mins * 60))
            return (c.hour ?? 0, c.minute ?? 0, SystemTools.minutes(m[1]).label)
        }
        if let m = Tools.rx(#"^(午前|午後)?\s*(\d{1,2})\s*(?:[:：.]\s*(\d{2})|時\s*(?:(\d{1,2})\s*分|半)?)?\s*(am|pm|a\.m\.|p\.m\.)?\s*(.*)$"#, s), var h = Int(m[2]) {
            var minute = Int(m[3]) ?? Int(m[4]) ?? 0
            if s.contains("時半") { minute = 30 }
            let ampm = m[5].lowercased().replacingOccurrences(of: ".", with: "")
            if ampm == "pm" || m[1] == "午後", h < 12 { h += 12 }
            if ampm == "am" || m[1] == "午前", h == 12 { h = 0 }
            // A bare number needs am/pm, a colon or 時 to count as a time.
            guard !m[3].isEmpty || !m[4].isEmpty || !ampm.isEmpty || s.contains("時") else { return nil }
            guard h < 24, minute < 60 else { return nil }
            return (h, minute, m[6].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

// MARK: Night Shift (CoreBrightness, the same switch as Control Center)

@MainActor enum NightShift {
    private static let client: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    static var available: Bool { client != nil }

    static var isOn: Bool {
        guard let c = client else { return false }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard let m = class_getInstanceMethod(type(of: c), sel) else { return false }
        typealias F = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        var status = [UInt8](repeating: 0, count: 64)
        let ok = status.withUnsafeMutableBytes { unsafeBitCast(method_getImplementation(m), to: F.self)(c, sel, $0.baseAddress!) }
        return ok && status[1] != 0 // { active, enabled, … }
    }

    static func set(_ on: Bool) {
        guard let c = client else { return }
        let sel = NSSelectorFromString("setEnabled:")
        guard let m = class_getInstanceMethod(type(of: c), sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(method_getImplementation(m), to: F.self)(c, sel, on)
    }

    /// Warmth 0…1.
    static var strength: Double {
        guard let c = client else { return 0.5 }
        let sel = NSSelectorFromString("getStrength:")
        guard let m = class_getInstanceMethod(type(of: c), sel) else { return 0.5 }
        typealias F = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
        var v: Float = 0.5
        _ = unsafeBitCast(method_getImplementation(m), to: F.self)(c, sel, &v)
        return Double(v)
    }

    static func setStrength(_ v: Double) {
        guard let c = client else { return }
        let sel = NSSelectorFromString("setStrength:commit:")
        guard let m = class_getInstanceMethod(type(of: c), sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool
        _ = unsafeBitCast(method_getImplementation(m), to: F.self)(c, sel, Float(min(1, max(0, v))), true)
        if !isOn { set(true) }
    }
}

// MARK: Now playing

/// What's playing in Music or Spotify, with controls. Play/pause, next and previous also work for any other
/// player (browsers too) through the media keys.
@MainActor @Observable final class NowPlaying {
    static let shared = NowPlaying()

    var title = ""
    var artist = ""
    var album = ""
    var appID: String?
    var playing = false
    /// The cover showing. A new song keeps the last one up until its own is decoded, so there's never a blank between.
    var artwork: NSImage?
    /// This song has no cover to be had (a local file, a stream, nothing in the catalogue): the note shows instead.
    var artMissing = false
    var position: Double = 0
    var duration: Double = 0
    var updated = Date()
    /// Spotify's track URI or Music's persistent ID: what tells one song from the next (two can share a name).
    @ObservationIgnored private(set) var trackID = ""
    /// A radio station or stream in Music (the song comes from its stream title, the cover from the catalogue).
    @ObservationIgnored private var stream = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var poller: Timer?
    /// Snapshots and tests: keep the demo song (the player's answers are ignored).
    @ObservationIgnored var frozen = false
    /// Dev snapshots: the same as `frozen` (the notch's hooks set this one).
    @ObservationIgnored var demo: Bool {
        get { frozen }
        set { frozen = newValue }
    }
    /// Tests: a stand-in player that gets each command instead of Music or Spotify (and no media keys are sent).
    @ObservationIgnored var fakePlayer: (@Sendable (String) -> Bool)?
    /// Until then, answers from the player don't undo a seek or a play/pause it hasn't caught up with yet.
    @ObservationIgnored private var hold = Date.distantPast

    var available: Bool { !title.isEmpty }

    /// The song from before the player stopped, while Music or Spotify is still open (the idle notch offers it again).
    struct Last { var title: String, artist: String, artwork: NSImage?, appID: String }
    var last: Last?

    /// Plays again in the app it came from.
    func play(_ s: Last) { send("tell application id \"\(s.appID)\" to play", key: nil) }

    /// The song name without "(feat. …)" (those names go in `collaborators`).
    var songTitle: String {
        title.replacingOccurrences(of: #"\s*[\(\[](?:feat\.?|ft\.?|featuring|with)\s+[^\)\]]+[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(?:feat\.?|ft\.?|featuring)\s+.+$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Everyone on the song: the artist field (split on "," "&" "x" "×" "feat.") plus anyone featured in the title.
    var collaborators: [String] {
        var names: [String] = []
        func add(_ s: String) {
            for part in s.components(separatedBy: CharacterSet(charactersIn: ",&×、")).flatMap({ $0.components(separatedBy: " feat. ") })
                .flatMap({ $0.components(separatedBy: " ft. ") }).flatMap({ $0.components(separatedBy: " x ") }).flatMap({ $0.components(separatedBy: " with ") }) {
                let n = part.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { names.append(n) }
            }
        }
        add(fullArtist ?? artist)
        if let m = Tools.rx(#"(?:feat\.?|ft\.?|featuring|with)\s+([^\)\]]+)"#, title) { add(m[1]) }
        return names
    }

    var artistLine: String { collaborators.joined(separator: ", ") }

    /// Every credited artist from Apple's public song catalog (Music and Spotify often report only the main one).
    var fullArtist: String?
    @ObservationIgnored private var creditKey = ""
    @ObservationIgnored private var credits: [String: String] = [:]

    private func lookUpCredits() {
        let key = "\(songTitle)|\(artist)"
        guard key != creditKey, !songTitle.isEmpty, !artist.isEmpty else { return }
        creditKey = key
        if let hit = credits[key] { fullArtist = hit; return }
        fullArtist = nil
        let term = "\(songTitle) \(artist)".addingPercentEncoding(withAllowedCharacters: .queryValue) ?? ""
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(term)&entity=song&limit=5") else { return }
        let title = songTitle.lowercased(), main = artist.lowercased()
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let results = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]] else { return }
            // The first result with the same song name whose artists include the one playing.
            let match = results.first { r in
                let name = (r["trackName"] as? String ?? "").lowercased()
                let who = (r["artistName"] as? String ?? "").lowercased()
                return who.contains(main) && (name.hasPrefix(title) || title.hasPrefix(name.components(separatedBy: " (").first ?? name))
            }
            guard let who = match?["artistName"] as? String, self.creditKey == key else { return }
            self.credits[key] = who
            if who.lowercased() != main { self.fullArtist = who }
        }
    }
    var appName: String { appID == "com.spotify.client" ? "Spotify" : "Music" }
    var appIcon: NSImage? { appID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { NSWorkspace.shared.icon(forFile: $0.path) } }

    /// Where the song is now (moves on between polls).
    var livePosition: Double {
        guard playing else { return position }
        let p = position + Date().timeIntervalSince(updated)
        return duration > 0 ? min(duration, p) : p
    }

    /// Spotify and Music announce every play, pause and new song, and the workspace announces them opening and
    /// quitting: those drive the updates. The poll is only a safety net (a seek, a missed notice), and stops when
    /// neither app is open.
    func start() {
        guard !started else { return }
        started = true
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard id == Self.spotifyID || id == Self.musicID else { return }
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    @ObservationIgnored private var started = false
    nonisolated private static let spotifyID = "com.spotify.client", musicID = "com.apple.Music"

    /// Every 3 s while playing (keeps lyrics right after a seek), every 15 s while paused, none with both apps closed.
    private func schedulePoll(open: Bool) {
        let every: TimeInterval? = !open ? nil : playing ? 3 : 15
        guard every != poller?.timeInterval || (every == nil) != (poller == nil) else { return }
        poller?.invalidate()
        poller = nil
        guard let every else { return }
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        t.tolerance = every / 4
        RunLoop.main.add(t, forMode: .common)
        poller = t
    }

    nonisolated private static func running(_ id: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    /// Off the main thread, so a busy Music (an iCloud sync, a beachball) can't freeze the launcher, the hotkeys or the
    /// notch; each question gives up after two seconds.
    private static let queue = DispatchQueue(label: "money.nowplaying", qos: .utility)
    @ObservationIgnored private var asking = false
    /// Asked for while a question was out: asked again once it's back (dropping it left a skip unseen until the next poll).
    @ObservationIgnored private var again = false

    func refresh() {
        guard !demo else { return }
        // Only ask apps that are already open (asking would launch them).
        let spotify = Self.running(Self.spotifyID), music = Self.running(Self.musicID)
        defer { schedulePoll(open: spotify || music) }
        guard spotify || music else { return apply(nil, source: nil) }
        guard !asking else { again = true; return }
        asking = true
        Self.queue.async { [weak self] in
            let (info, source) = Self.read(spotify: spotify, music: music)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.asking = false
                    self.apply(info, source: source)
                    self.schedulePoll(open: true) // playing or paused now decides the next poll
                    if self.again { self.again = false; self.refresh() }
                }
            }
        }
    }

    private func refresh(after delays: [Double]) {
        for d in delays { DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in MainActor.assumeIsolated { self?.refresh() } } }
    }

    /// Each field on its own `try` (as 2dle reads them), so one the player can't give (a stream's length, a local
    /// file's cover) doesn't lose the rest. state || name || artist || album || cover URL || position || length || id || stream title
    nonisolated private static func read(spotify: Bool, music: Bool) -> ([String]?, String?) {
        var info: [String]?
        var source: String?
        if spotify {
            info = ask("""
            with timeout of 2 seconds
              tell application "Spotify"
                if player state is stopped then return ""
                set t to current track
                set {n, ar, al, u, i, d} to {"", "", "", "", "", 0}
                try
                  set n to name of t
                end try
                try
                  set ar to artist of t
                end try
                try
                  set al to album of t
                end try
                try
                  set u to artwork url of t
                end try
                if u is missing value then set u to ""
                try
                  set i to id of t
                end try
                try
                  set d to (duration of t) / 1000
                end try
                return (player state as string) & "||" & n & "||" & ar & "||" & al & "||" & u & "||" & (player position as string) & "||" & (d as string) & "||" & i & "||"
              end tell
            end timeout
            """)
            source = spotifyID
        }
        if (info == nil || info?.first != "playing"), music {
            if let m = ask("""
            with timeout of 2 seconds
              tell application "Music"
                if player state is stopped then return ""
                set t to current track
                set {n, ar, al, i, d, p, s} to {"", "", "", "", 0, 0, ""}
                try
                  set n to name of t
                end try
                try
                  set ar to artist of t
                end try
                try
                  set al to album of t
                end try
                try
                  set i to persistent ID of t
                end try
                try
                  set d to duration of t
                end try
                if d is missing value then set d to 0
                try
                  set p to player position
                end try
                if p is missing value then set p to 0
                try
                  set s to current stream title
                end try
                if s is missing value then set s to ""
                return (player state as string) & "||" & n & "||" & ar & "||" & al & "||" & "" & "||" & (p as string) & "||" & (d as string) & "||" & i & "||" & s
              end tell
            end timeout
            """), m.first == "playing" || info == nil {
                info = m
                source = musicID
            }
        }
        return (info, source)
    }

    private func apply(_ info: [String]?, source: String?) {
        guard !frozen else { return }
        let wasPlaying = playing, wasTitle = title
        let started = info.map { $0.first == "playing" } ?? false
        func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        // Only what changed is written: every write redraws whatever shows the song, and most polls change nothing.
        // The position moves on by itself between polls (`livePosition`), so it's only corrected when it drifted.
        let change = { [self] in
            if let f = info, f.count >= 9 {
                var (name, who, from) = (f[1], f[2], f[3])
                // A radio station or stream: Music names the station; the song is its stream title ("Artist - Song").
                stream = !f[8].isEmpty
                if stream {
                    let parts = f[8].components(separatedBy: " - ")
                    if parts.count > 1 { who = parts[0]; name = parts.dropFirst().joined(separator: " - ") } else { name = f[8] }
                    from = ""
                }
                let nowPlaying = f[0] == "playing"
                let pos = number(f[5]), dur = number(f[6])
                let id = f[7].isEmpty || stream ? "\(name)|\(who)|\(from)" : f[7]
                let newSong = id != trackID
                // Just seeked or tapped play/pause: an answer from before the player caught up doesn't undo it.
                let held = !newSong && Date() < hold
                if newSong || (!held && (nowPlaying != playing || abs(pos - livePosition) > 1)) {
                    position = pos
                    updated = Date()
                }
                if !held, playing != nowPlaying { playing = nowPlaying }
                trackID = id
                if title != name { title = name }
                if artist != who { artist = who }
                if album != from { album = from }
                if duration != dur { duration = dur }
                if appID != source { appID = source }
                loadArtwork(url: f[4], source: source)
                lookUpCredits()
                // Spotify can announce a song while its cover is still the last one's: asked again shortly (2dle does too).
                if newSong { refresh(after: [0.7, 2.2]) }
            } else if !title.isEmpty || playing || appID != nil || last != nil {
                // Stopped with its app still open: kept to offer again; quit, forgotten.
                if let id = appID, !title.isEmpty, Self.running(id) {
                    last = Last(title: songTitle, artist: artistLine, artwork: artwork, appID: id)
                } else if let l = last, !Self.running(l.appID) {
                    last = nil
                }
                playing = false
                title = ""
                artist = ""
                artwork = nil
                artMissing = false
                artKey = "" // the same song coming back shows its (kept) cover again
                trackID = ""
                appID = nil
            }
        }
        // Starting or stopping changes what the notch shows: animate that; ordinary updates just apply.
        if started != wasPlaying { clockChange(change) } else { change() }
        if wasPlaying != playing || wasTitle != title { clockChange { onChange?() } }
    }

    /// Compiled once per script and kept (only ever run on `queue`).
    nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:]

    nonisolated private static func ask(_ script: String) -> [String]? {
        var err: NSDictionary?
        let s = compiled[script] ?? NSAppleScript(source: script)
        compiled[script] = s
        guard let out = s?.executeAndReturnError(&err).stringValue, err == nil, !out.isEmpty else { return nil }
        return out.components(separatedBy: "||")
    }

    // MARK: Artwork (after 2dle: the player's own cover first, then exactly this album from Apple's catalogue, else none)

    /// The cover wanted (the song playing) and the one showing.
    @ObservationIgnored private var artKey = ""
    @ObservationIgnored private var shownKey = ""
    /// Decoded covers by key (the last 40), and keys known to have none.
    @ObservationIgnored private var covers: [String: NSImage] = [:]
    @ObservationIgnored private var coverOrder: [String] = []
    @ObservationIgnored private var coverless: Set<String> = []

    /// Spotify: its cover URL (one per album, so an album's songs share it), or the track when it gave none. Music: the
    /// album, or the song when it has no album name.
    private func coverKey(_ url: String, _ source: String?) -> String {
        if !url.isEmpty { return url }
        if source == Self.spotifyID { return "spotify|" + trackID }
        return "music|\(artist)|\(album.isEmpty ? "song:" + title : album)".lowercased()
    }

    private func loadArtwork(url: String, source: String?) {
        let key = coverKey(url, source)
        guard key != artKey else { return }
        artKey = key
        if let img = covers[key] { return show(img, key) }
        if coverless.contains(key) { return showNone(key) }
        // The last cover stays up while this one comes; with nothing by then, the note.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated { if let self, self.artKey == key, self.shownKey != key { self.showNone(key, remember: false) } }
        }
        if let u = URL(string: url), !url.isEmpty { return fetch(u, key) }
        if source == Self.musicID, !stream { return musicArtwork(key, song: title, tries: 2) }
        if trackID.hasPrefix("spotify:track:") || trackID.hasPrefix("spotify:episode:") { return oEmbed(key) }
        if source == Self.musicID { return catalogue(key) }
        showNone(key) // a local file in Spotify
    }

    private func show(_ img: NSImage, _ key: String) {
        covers[key] = img
        coverOrder.removeAll { $0 == key }
        coverOrder.append(key)
        if coverOrder.count > 40 { covers[coverOrder.removeFirst()] = nil }
        guard key == artKey else { return }
        shownKey = key
        if artMissing { artMissing = false }
        if artwork !== img { artwork = img }
    }

    private func showNone(_ key: String, remember: Bool = true) {
        if remember { coverless.insert(key) }
        guard key == artKey else { return }
        shownKey = key
        artwork = nil
        artMissing = true
    }

    /// Downloaded and decoded off the main thread (the first draw of an undecoded picture hitched the cross-fade).
    private func fetch(_ url: URL, _ key: String) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let img = data.flatMap(Self.decode)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if let img { self?.show(img, key) } else { self?.showNone(key, remember: false) } }
            }
        }.resume()
    }

    nonisolated static func decode(_ data: Data) -> NSImage? {
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400,
                    kCGImageSourceShouldCacheImmediately: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard data.count > 64, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Music's own copy of the cover (`raw data`, else `data`), checked to be of this very song: a song just begun can
    /// be ahead of its artwork, or Music still on the last one, so it's asked again shortly; none, the catalogue.
    private func musicArtwork(_ key: String, song: String, tries: Int) {
        Self.queue.async { [weak self] in
            let (name, data) = Self.musicCover()
            let img = data.flatMap(Self.decode)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.artKey == key else { return }
                    if let img, name == song { return self.show(img, key) }
                    guard tries > 0 else { return self.catalogue(key) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        MainActor.assumeIsolated { if self.artKey == key { self.musicArtwork(key, song: song, tries: tries - 1) } }
                    }
                }
            }
        }
    }

    nonisolated private static func musicCover() -> (String, Data?) {
        let script = """
        with timeout of 3 seconds
          tell application "Music"
            set t to current track
            set img to missing value
            try
              set img to raw data of artwork 1 of t
            end try
            if img is missing value then
              try
                set img to data of artwork 1 of t
              end try
            end if
            return {name of t, img}
          end tell
        end timeout
        """
        var err: NSDictionary?
        let s = compiled[script] ?? NSAppleScript(source: script)
        compiled[script] = s
        guard running(musicID), let r = s?.executeAndReturnError(&err), err == nil, r.numberOfItems >= 2 else { return ("", nil) }
        let pic = r.atIndex(2).flatMap { $0.descriptorType == typeNull || $0.descriptorType == typeType ? nil : $0.data }
        return (r.atIndex(1)?.stringValue ?? "", pic)
    }

    /// Exactly this album (or, with no album, this song) by this artist from Apple's public catalogue, or none: a cover
    /// that's only close (another edition, a namesake) is worse than the note.
    private func catalogue(_ key: String) {
        let song = songTitle, who = artist.lowercased(), record = album
        var c = URLComponents(string: "https://itunes.apple.com/search")
        c?.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(record.isEmpty ? song : record)"),
                         URLQueryItem(name: "entity", value: record.isEmpty ? "song" : "album"), URLQueryItem(name: "limit", value: "10")]
        guard !who.isEmpty, !song.isEmpty, let url = c?.url else { return showNone(key) }
        let wanted = Self.norm(record.isEmpty ? song : record), field = record.isEmpty ? "trackName" : "collectionName"
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let rows = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["results"] as? [[String: Any]] ?? []
            let hit = rows.first { r in
                let name = (r["artistName"] as? String ?? "").lowercased()
                return Self.norm(r[field] as? String ?? "") == wanted && (name.contains(who) || who.contains(name))
            }
            let art = (hit?["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let art, let u = URL(string: art) { self?.fetch(u, key) } else { self?.showNone(key, remember: data != nil) }
                }
            }
        }.resume()
    }

    /// A name without "(Deluxe)" or " - Single", lowercased, to compare with the catalogue's.
    nonisolated private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]|\s+-\s+(single|ep)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Spotify gave no cover URL: its public oEmbed page has the track's (or episode's) thumbnail.
    private func oEmbed(_ key: String) {
        var c = URLComponents(string: "https://open.spotify.com/oembed")
        c?.queryItems = [URLQueryItem(name: "url", value: trackID)]
        guard let url = c?.url else { return showNone(key) }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let thumb = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["thumbnail_url"] as? String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let thumb, let u = URL(string: thumb) { self?.fetch(u, key) } else { self?.showNone(key, remember: data != nil) }
                }
            }
        }.resume()
    }

    // MARK: Controls

    /// Brings the app that's playing to the front.
    func openPlayer() {
        guard let id = appID, let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id }) else { return }
        if app.isHidden { app.unhide() }
        if let url = app.bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        } else {
            app.activate()
        }
    }

    func playPause() {
        // Shown at once; the player's own answer a moment later confirms it.
        if available {
            position = livePosition
            updated = Date()
            playing.toggle()
            hold = Date().addingTimeInterval(1.5)
        }
        control("playpause", key: 16)
    }
    func next() { control("next track", key: 17) }
    func previous() { control("previous track", key: 18) }

    /// Moves the song to a time: the bar goes there at once and the player follows (`set player position`, which
    /// Spotify and Music both take).
    func seek(to t: Double) {
        guard let id = appID, duration > 0 else { return }
        let to = min(max(0, t), max(0, duration - 0.5))
        position = to
        updated = Date()
        hold = Date().addingTimeInterval(1.5)
        send("tell application id \"\(id)\" to set player position to " + String(format: "%.2f", to), key: nil)
    }

    private func control(_ command: String, key: Int32) {
        guard let id = appID, fakePlayer != nil || Self.running(id) else {
            Self.mediaKey(key)
            return refresh(after: [0.4])
        }
        send("tell application id \"\(id)\" to \(command)", key: key)
    }

    /// Off the main thread (a busy player can take a while to answer), then the player is asked what it's doing now.
    /// A command it refused goes out as the media key instead.
    private func send(_ script: String, key: Int32?) {
        let fake = fakePlayer
        Self.controls.async {
            let ok: Bool
            if let fake { ok = fake(script) } else {
                var err: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&err)
                ok = err == nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !ok, fake == nil, let key { Self.mediaKey(key) }
                    NowPlaying.shared.refresh(after: [0.3, 1.6])
                }
            }
        }
    }

    private static let controls = DispatchQueue(label: "money.nowplaying.controls", qos: .userInitiated)

    /// The keyboard's play/pause, next and previous keys (work with whatever is playing, browsers included).
    static func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
