import AppKit
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
    var artwork: NSImage?
    var position: Double = 0
    var duration: Double = 0
    var updated = Date()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored private var artKey = ""

    var available: Bool { !title.isEmpty }

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
        return min(duration, position + Date().timeIntervalSince(updated))
    }

    func start() {
        guard poller == nil else { return }
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        poller = t
    }

    private static func running(_ id: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
    }

    /// Off the main thread, so a busy Music (an iCloud sync, a beachball) can't freeze the launcher, the hotkeys or the
    /// notch; each question gives up after two seconds.
    private static let queue = DispatchQueue(label: "money.nowplaying", qos: .utility)
    @ObservationIgnored private var asking = false

    func refresh() {
        // Only ask apps that are already open (asking would launch them).
        let spotify = Self.running("com.spotify.client"), music = Self.running("com.apple.Music")
        guard spotify || music else { return apply(nil, source: nil) }
        guard !asking else { return }
        asking = true
        Self.queue.async { [weak self] in
            let (info, source) = Self.read(spotify: spotify, music: music)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.asking = false
                    self?.apply(info, source: source)
                }
            }
        }
    }

    nonisolated private static func read(spotify: Bool, music: Bool) -> ([String]?, String?) {
        var info: [String]?
        var source: String?
        if spotify {
            info = ask("""
            with timeout of 2 seconds
              tell application "Spotify"
                if player state is stopped then return ""
                set t to current track
                return (player state as string) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & (artwork url of t) & "||" & (player position as string) & "||" & ((duration of t) / 1000 as string)
              end tell
            end timeout
            """)
            source = "com.spotify.client"
        }
        if (info == nil || info?.first != "playing"), music {
            if let m = ask("""
            with timeout of 2 seconds
              tell application "Music"
                if player state is stopped then return ""
                set t to current track
                return (player state as string) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & "" & "||" & (player position as string) & "||" & (duration of t as string)
              end tell
            end timeout
            """), m.first == "playing" || info == nil {
                info = m
                source = "com.apple.Music"
            }
        }
        return (info, source)
    }

    private func apply(_ info: [String]?, source: String?) {
        let wasPlaying = playing, wasTitle = title
        let started = info.map { $0.first == "playing" } ?? false
        let change = { [self] in
            if let f = info, f.count >= 7 {
                playing = f[0] == "playing"
                title = f[1]
                artist = f[2]
                album = f[3]
                position = Double(f[5].replacingOccurrences(of: ",", with: ".")) ?? 0
                duration = Double(f[6].replacingOccurrences(of: ",", with: ".")) ?? 0
                updated = Date()
                appID = source
                loadArtwork(url: f[4], source: source)
                lookUpCredits()
            } else {
                playing = false
                title = ""
                artist = ""
                artwork = nil
                appID = nil
            }
        }
        // Starting or stopping changes what the notch shows: animate that; ordinary updates just apply.
        if started != wasPlaying { clockChange(change) } else { change() }
        if wasPlaying != playing || wasTitle != title { clockChange { onChange?() } }
    }

    nonisolated private static func ask(_ script: String) -> [String]? {
        var err: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue, err == nil, !out.isEmpty else { return nil }
        return out.components(separatedBy: "||")
    }

    private func loadArtwork(url: String, source: String?) {
        let key = "\(source ?? "")|\(title)|\(album)"
        guard key != artKey else { return }
        artKey = key
        artwork = nil
        if let u = URL(string: url), !url.isEmpty {
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: u), let img = NSImage(data: data), self.artKey == key { self.artwork = img }
            }
        } else if source == "com.apple.Music" {
            var err: NSDictionary?
            let d = NSAppleScript(source: "tell application \"Music\" to get raw data of artwork 1 of current track")?.executeAndReturnError(&err)
            if err == nil, let data = d?.data, let img = NSImage(data: data) { artwork = img }
        }
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

    func playPause() { control("playpause", key: 16) }
    func next() { control("next track", key: 17) }
    func previous() { control("previous track", key: 18) }

    private func control(_ command: String, key: Int32) {
        if let id = appID, Self.running(id) {
            var err: NSDictionary?
            NSAppleScript(source: "tell application id \"\(id)\" to \(command)")?.executeAndReturnError(&err)
            if err == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
                return
            }
        }
        Self.mediaKey(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
    }

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
