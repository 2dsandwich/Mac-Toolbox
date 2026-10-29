import AppKit
import Observation

/// The Pomodoro timer (moved here from the Moneybag browser). Focus → short break, every 4th a long break.
@MainActor @Observable final class Pomodoro {
    enum Phase: String { case focus, rest }

    struct Plan: Equatable {
        var focus: Double = 25
        var short: Double = 5
        var long: Double = 15
        var rounds: Int?
        /// "timer 10m tea": a single countdown with no breaks.
        var label: String?
        var isTimer: Bool { rounds == 1 && short == 0 }
    }

    static let presets = [Plan(focus: 25, short: 5, long: 15), Plan(focus: 50, short: 10, long: 20), Plan(focus: 90, short: 15, long: 30)]
    private static let roundsBeforeLong = 4
    private static let maxMinutes = 240.0

    var phase: Phase?
    var endsAt = Date()
    var pausedLeft: TimeInterval?
    var length: TimeInterval = 0
    var round = 0
    var plan = Plan()
    var now = Date()

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored var onChange: (() -> Void)?
    /// Tells the notch to say something ("Focus done", "Break over").
    @ObservationIgnored var announce: ((String, String) -> Void)?

    var active: Bool { phase != nil }
    var paused: Bool { pausedLeft != nil }
    var remaining: TimeInterval { pausedLeft ?? max(0, endsAt.timeIntervalSince(now)) }
    var progress: Double { length > 0 ? min(1, max(0, 1 - remaining / length)) : 0 }

    var clock: String { Self.clock(remaining) }

    static func clock(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.up))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    var status: String {
        guard let phase else { return "Ready" }
        if paused { return "Paused" }
        if plan.isTimer { return plan.label ?? "Timer" }
        if phase == .rest { return "Break" }
        return "Focus · round \(round)" + (plan.rounds.map { " of \($0)" } ?? "")
    }

    // MARK: Control

    func start(_ p: Plan) {
        plan = p
        begin(.focus, minutes: p.focus, round: 1)
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        phase = nil
        pausedLeft = nil
        round = 0
        changed()
    }

    func toggle() {
        guard phase != nil else { return start(plan) }
        now = Date()
        if let left = pausedLeft {
            endsAt = now.addingTimeInterval(left)
            pausedLeft = nil
        } else {
            pausedLeft = remaining
        }
        changed()
    }

    /// Adds time to the running countdown (+1 min on the timer).
    func extend(_ seconds: TimeInterval) {
        guard phase != nil else { return }
        if let left = pausedLeft { pausedLeft = left + seconds } else { endsAt = endsAt.addingTimeInterval(seconds) }
        length += seconds
        changed()
    }

    func skip() {
        guard phase != nil else { return }
        advance()
    }

    private func begin(_ p: Phase, minutes: Double, round r: Int) {
        length = minutes * 60
        now = Date()
        endsAt = now.addingTimeInterval(length)
        pausedLeft = nil
        phase = p
        round = r
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        changed()
    }

    private func tick() {
        now = Date()
        guard phase != nil, pausedLeft == nil, now >= endsAt else { return }
        advance()
    }

    private func advance() {
        guard let phase else { return }
        if phase == .focus {
            if !plan.isTimer {
                Stats.shared.add(.focusSessions)
                Stats.shared.add(.focusMinutes, plan.focus)
            }
            if plan.isTimer {
                announce?("Time’s up", plan.label ?? Self.describeTimer(plan.focus))
                chime()
                return stop()
            }
            if let rounds = plan.rounds, round >= rounds {
                announce?("Pomodoro complete", "\(round) round\(round == 1 ? "" : "s") done")
                chime()
                return stop()
            }
            let minutes = round % Self.roundsBeforeLong == 0 ? plan.long : plan.short
            if minutes <= 0 { return begin(.focus, minutes: plan.focus, round: round + 1) }
            announce?("Focus done", "\(Int(minutes)) min break")
            chime()
            begin(.rest, minutes: minutes, round: round)
        } else {
            announce?("Break over", "Round \(round + 1)")
            chime()
            begin(.focus, minutes: plan.focus, round: round + 1)
        }
    }

    private func chime() {
        let s = NSSound(named: "Glass")
        s?.volume = 0.5
        s?.play()
    }

    private func changed() { onChange?() }

    // MARK: Plans from plain words ("30/5", "1h", "until 3pm", "45分 休憩10分", "4 rounds", "no breaks")

    static func describeTimer(_ minutes: Double) -> String {
        minutes < 1 ? "\(Int((minutes * 60).rounded())) sec timer" : "\(fmt(minutes)) min timer"
    }

    static func describe(_ p: Plan) -> String {
        var parts = ["Focus \(fmt(p.focus)) min", p.short > 0 ? "break \(fmt(p.short))" : "no breaks"]
        if p.short > 0, p.long != p.short, p.rounds == nil || p.rounds! >= roundsBeforeLong { parts.append("long \(fmt(p.long))") }
        parts.append(p.rounds.map { "\($0) round\($0 == 1 ? "" : "s")" } ?? "repeats")
        return parts.joined(separator: " · ")
    }

    private static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    static func parse(_ input: String, now: Date = Date()) -> Plan? {
        var text = String(input.unicodeScalars.map { (0xFF10...0xFF19).contains($0.value) ? Character(UnicodeScalar($0.value - 0xFF10 + 0x30)!) : Character($0) })
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var plan = Plan()
        var touched = false
        var rest = text
        func clamp(_ v: Double) -> Double { min(maxMinutes, max(0, (v * 10).rounded() / 10)) }
        func match(_ pattern: String, _ s: String) -> [String?]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
        }
        if let r = match(#"(?:x\s*(\d+)\b|(\d+)\s*(?:rounds?|cycles?|sessions?|times|pomodoros?|poms?|回|セット|ラウンド))"#, rest) {
            plan.rounds = max(1, Int(r[1] ?? r[2] ?? "1") ?? 1)
            rest = rest.replacingOccurrences(of: r[0]!, with: " ")
            touched = true
        }
        let unit = #"\s*(?:m|min|mins|分)?"#
        // "30/5", also typed by accident as "30;5" (or with full-width ／ ；), and plain "30 5".
        let sep = #"\s*[/;；／]\s*"#
        if let pair = match(#"^\s*(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s*$"#, rest) {
            plan.focus = clamp(Double(pair[1]!) ?? 25)
            plan.short = clamp(Double(pair[2]!) ?? 5)
            plan.long = max(plan.short, 15)
            return plan.focus > 0 ? plan : nil
        }
        if let s = match(#"(\d+(?:\.\d+)?)"# + unit + sep + #"(\d+(?:\.\d+)?)"# + unit + "(?:" + sep + #"(\d+(?:\.\d+)?)"# + unit + ")?", rest) {
            plan.focus = clamp(Double(s[1]!) ?? 25)
            plan.short = clamp(Double(s[2]!) ?? 5)
            plan.long = s[3].flatMap(Double.init).map(clamp) ?? max(plan.short, 15)
            return plan.focus > 0 ? plan : nil
        }
        if let u = match(#"(?:until|till|til|to|by)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?|(\d{1,2})(?:[:時](\d{1,2})?分?)?\s*(?:まで)"#, rest) {
            var hour = Int(u[1] ?? u[4] ?? "") ?? 0
            let minute = Int(u[2] ?? u[5] ?? "0") ?? 0
            let mer = u[3]?.lowercased()
            if mer == "pm", hour < 12 { hour += 12 }
            if mer == "am", hour == 12 { hour = 0 }
            let cal = Calendar.current
            var target = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            if mer == nil, target <= now, hour < 12 { target = target.addingTimeInterval(12 * 3600) }
            if target <= now { target = target.addingTimeInterval(24 * 3600) }
            let minutes = target.timeIntervalSince(now) / 60
            if minutes > 0, minutes <= maxMinutes { return Plan(focus: clamp(minutes), short: plan.short, long: plan.long, rounds: 1) }
        }
        let noBreak = #"no\s+breaks?|without\s+breaks?|休憩なし|休憩無し"#
        if match(noBreak, rest) != nil {
            plan.short = 0
            plan.long = 0
            rest = rest.replacingOccurrences(of: noBreak, with: " ", options: [.regularExpression, .caseInsensitive])
            touched = true
        }
        // Durations, each labelled by the word next to it (before it in Japanese, after it in English).
        let durationRe = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*h(?:ours?|rs?)?\s*(\d+)\s*(?:m|min|mins|minutes?|分)?(?![a-z])|(\d+(?:\.\d+)?)\s*(h|hr|hrs|hours?|時間|m|min|mins|minutes?|分)(?![a-z])|half\s+an?\s+hour|quarter\s+(?:of\s+)?an?\s+hour|\b(?:an|one)\s+hour\b"#, options: [.caseInsensitive])
        let ns = rest as NSString
        var found: [(minutes: Double, range: NSRange)] = []
        for m in durationRe.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            let word = ns.substring(with: m.range).lowercased()
            var minutes = 60.0
            if let h = g(1), let mm = g(2) { minutes = (Double(h) ?? 0) * 60 + (Double(mm) ?? 0) }
            else if let v = g(3), let u = g(4) { minutes = (Double(v) ?? 0) * (["h", "hr", "hrs", "hour", "hours", "時間"].contains(u.lowercased()) ? 60 : 1) }
            else if word.hasPrefix("half") { minutes = 30 }
            else if word.hasPrefix("quarter") { minutes = 15 }
            found.append((minutes, m.range))
        }
        if found.isEmpty, let re = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) {
            for m in re.matches(in: rest, range: NSRange(location: 0, length: ns.length)) { found.append((Double(ns.substring(with: m.range)) ?? 0, m.range)) }
        }
        let japanese = rest.contains(where: isCJK)
        func label(_ piece: String) -> String? {
            let l = piece.lowercased()
            if l.range(of: "break|rest|pause|休憩|休み|きゅうけい", options: .regularExpression) != nil {
                return l.range(of: "long|長い|ロング", options: .regularExpression) != nil ? "long" : "break"
            }
            return l.range(of: "focus|work|study|deep|集中|作業|勉強", options: .regularExpression) != nil ? "focus" : nil
        }
        func clip(_ piece: String, fromEnd: Bool) -> String {
            let parts = piece.components(separatedBy: CharacterSet(charactersIn: ",、，;+")).flatMap { $0.components(separatedBy: " and ") }
            return (fromEnd ? parts.last : parts.first) ?? ""
        }
        for (i, d) in found.enumerated() {
            let beforeStart = i > 0 ? NSMaxRange(found[i - 1].range) : 0
            let before = clip(ns.substring(with: NSRange(location: beforeStart, length: d.range.location - beforeStart)), fromEnd: true)
            let afterEnd = i < found.count - 1 ? found[i + 1].range.location : ns.length
            let after = clip(ns.substring(with: NSRange(location: NSMaxRange(d.range), length: afterEnd - NSMaxRange(d.range))), fromEnd: false)
            // Japanese puts the word first (休憩10分), so a word after a number belongs to the next one.
            let kind = (japanese ? (label(before) ?? (i == found.count - 1 ? label(after) : nil)) : (label(after) ?? label(before))) ?? "focus"
            touched = true
            switch kind {
            case "long": plan.long = clamp(d.minutes)
            case "break": plan.short = clamp(d.minutes)
            default: plan.focus = clamp(d.minutes)
            }
        }
        return touched && plan.focus > 0 ? plan : nil
    }
}
