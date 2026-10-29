import Foundation
import Observation

/// What you've done with MONEY!, day by day: words dictated, apps opened, copies, focus time and so on.
/// Kept on this Mac only (`~/Library/Application Support/MONEY/stats.json`).
@MainActor @Observable final class Stats {
    static let shared = Stats()

    enum Metric: String, CaseIterable, Codable {
        case dictations, words, speakingSeconds, appsOpened, answers, copies, textScans, meetings, meetingMinutes,
             focusSessions, focusMinutes, timers, alarms, notes, calculations, translations
    }

    private struct Saved: Codable {
        var since: Date
        var days: [String: [String: Double]]
    }

    /// Day ("2026-10-29") → metric → amount.
    private(set) var days: [String: [String: Double]] = [:] { didSet { scheduleSave() } }
    private(set) var since = Date()
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MONEY", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stats.json")
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ date: Date) -> String { dayFormat.string(from: date) }

    private init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            days = saved.days
            since = saved.since
        }
    }

    /// First run: fill in what's already on this Mac (dictations kept in clipboard history, saved copies), dated
    /// when they happened.
    func importHistory(_ clips: [Clip]) {
        guard days.isEmpty, persists, !FileManager.default.fileExists(atPath: Self.url.path) else { return }
        var out: [String: [String: Double]] = [:]
        for c in clips {
            let day = Self.key(c.date)
            if ["Dictation", "Voice Edit"].contains(c.sourceName), let t = c.text {
                out[day, default: [:]][Metric.dictations.rawValue, default: 0] += 1
                out[day, default: [:]][Metric.words.rawValue, default: 0] += Double(DictationController.wordCount(t))
            } else {
                out[day, default: [:]][Metric.copies.rawValue, default: 0] += 1
            }
        }
        if let first = clips.map(\.date).min() { since = first }
        days = out
    }

    private var persists: Bool { !CommandLine.arguments.contains { $0.hasSuffix("-snapshot") || $0.hasSuffix("-test") } }

    func add(_ m: Metric, _ amount: Double = 1) {
        guard amount > 0, persists else { return }
        days[Self.key(Date()), default: [:]][m.rawValue, default: 0] += amount
    }

    func total(_ m: Metric) -> Double { days.values.reduce(0) { $0 + ($1[m.rawValue] ?? 0) } }
    func on(_ date: Date, _ m: Metric) -> Double { days[Self.key(date)]?[m.rawValue] ?? 0 }
    func today(_ m: Metric) -> Double { on(Date(), m) }

    /// The last `n` days, oldest first.
    func daily(_ m: Metric, last n: Int) -> [(day: Date, value: Double)] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        return (0..<n).reversed().compactMap { back in
            cal.date(byAdding: .day, value: -back, to: start).map { ($0, on($0, m)) }
        }
    }

    /// Days in a row, up to today (or yesterday, if nothing yet today), with anything done.
    var streak: Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        if days[Self.key(day)]?.isEmpty ?? true { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while !(days[Self.key(day)]?.isEmpty ?? true) {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }

    /// Typing at 40 words a minute versus speaking them.
    func minutesSaved(_ words: Double, speaking seconds: Double) -> Double { max(0, words / 40 - seconds / 60) }

    func reset() {
        days = [:]
        since = Date()
    }

    private func scheduleSave() {
        guard persists else { return }
        saveWork?.cancel()
        let snapshot = Saved(since: since, days: days)
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
