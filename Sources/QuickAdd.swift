import Foundation

/// Moneybag's quick-add reading of a one-line task: "call Ben tomorrow 3pm // bring the contract in Work" → the title
/// "Call Ben", due tomorrow, a note, and the list it names. Local rules first; Claude only for date words the rules
/// couldn't place (as in Moneybag).
struct QuickAdd: Equatable {
    enum Kind { case when, note, group }
    struct Span: Equatable {
        var range: NSRange
        var kind: Kind
    }

    var title = ""
    var spans: [Span] = []
    var day: Date?
    /// Read so it leaves the title; Google Tasks keeps dates only.
    var hour: Int?
    var minute = 0
    var note: String?
    var group: String?

    private static let months = ["jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6,
                                 "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10,
                                 "nov": 11, "november": 11, "dec": 12, "december": 12]
    private static let weekdays = ["sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3, "wed": 4, "weds": 4, "wednesday": 4,
                                   "thu": 5, "thur": 5, "thurs": 5, "thursday": 5, "fri": 6, "friday": 6, "sat": 7, "saturday": 7]
    private static let fullWeekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let fullMonths = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    private static let dateWords = ["today", "tonight", "tomorrow", "yesterday", "next", "week", "month", "noon", "midnight", "morning", "evening", "afternoon"]
        + fullWeekdays + fullMonths
    private static let monthNames = months.keys.sorted { $0.count > $1.count }.joined(separator: "|")
    private static let weekdayNames = weekdays.keys.sorted { $0.count > $1.count }.joined(separator: "|")
    private static let connector = #"^(at|on|from|to|by|due|for|in|@|ー|に|の)$"#

    static func parse(_ text: String, now: Date = Date(), groups: [String] = []) -> QuickAdd {
        let ns = text as NSString
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: now)
        var out = QuickAdd()
        var evening = false
        let plus = { (n: Int) in cal.date(byAdding: .day, value: n, to: today)! }

        func scan(_ pattern: String, _ kind: Kind = .when, _ handle: ([String?], NSRange) -> Bool) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                guard !out.spans.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) else { continue }
                let parts = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
                guard handle(parts, m.range) else { continue }
                // Without the spaces at either end.
                var r = m.range
                while r.length > 0, ns.substring(with: NSRange(location: r.location, length: 1)).trimmingCharacters(in: .whitespaces).isEmpty { r.location += 1; r.length -= 1 }
                while r.length > 0, ns.substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1)).trimmingCharacters(in: .whitespaces).isEmpty { r.length -= 1 }
                out.spans.append(Span(range: r, kind: kind))
            }
        }
        func dated(_ month: Int, _ day: Int, year: Int? = nil) -> Bool {
            guard (1...12).contains(month), (1...31).contains(day),
                  var d = cal.date(from: DateComponents(year: year ?? cal.component(.year, from: now), month: month, day: day)) else { return false }
            if year == nil, d < today { d = cal.date(byAdding: .year, value: 1, to: d)! }
            out.day = d
            return true
        }
        func clock(_ hour: String?, _ minute: String?, _ meridiem: String?, bare: Bool) -> Bool {
            guard var h = hour.flatMap({ Int($0) }) else { return false }
            let m = minute.flatMap { Int($0) } ?? 0
            guard h <= 24, m <= 59 else { return false }
            let mer = meridiem?.lowercased()
            if mer == "pm", h < 12 { h += 12 }
            if mer == "am", h == 12 { h = 0 }
            if mer == nil, bare, (1...7).contains(h) { h += 12 }
            out.hour = h % 24
            out.minute = m
            return true
        }

        scan(#"//\s*([\s\S]*)$"#, .note) { p, _ in
            let n = p[1]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            out.note = n.isEmpty ? nil : n
            return true
        }
        // A list named after "in" / "to" ("in Shopping", "to the work list"), or "<name> list".
        for name in groups.sorted(by: { $0.count > $1.count }) where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            let n = NSRegularExpression.escapedPattern(for: name)
            scan(#"(?:\b(?:in|to|into)\s+(?:the\s+)?"# + n + #"(?:\s+list)?|"# + n + #"\s+list)(?![\p{L}\p{N}])"#, .group) { _, _ in
                guard out.group == nil else { return false }
                out.group = name
                return true
            }
        }
        // Misspelt "tomorrow", "today", "tonight" and weekdays.
        scan(#"\b[a-z]{4,}\b"#) { p, _ in
            let w = p[0]!.lowercased()
            if fuzzy(w, "tomorrow") { out.day = plus(1); return true }
            if fuzzy(w, "today") { out.day = today; return true }
            if fuzzy(w, "tonight") { out.day = today; evening = true; return true }
            if let i = fullWeekdays.firstIndex(where: { fuzzy(w, $0) }) {
                let n = ((i + 1) - weekday + 7) % 7
                out.day = plus(n == 0 ? 7 : n)
                return true
            }
            return false
        }
        scan(#"\b([a-z]{4,})\.? (\d{1,2})(?:st|nd|rd|th)?\b"#) { p, _ in
            guard let i = fullMonths.firstIndex(where: { fuzzy(p[1]!.lowercased(), $0) }) else { return false }
            return dated(i + 1, Int(p[2]!)!)
        }
        scan(#"\bday after tomorrow\b|明後日"#) { _, _ in out.day = plus(2); return true }
        scan(#"\b(tomorrow|tmrw|tmr)\b|明日"#) { _, _ in out.day = plus(1); return true }
        scan(#"\b(today|tonight)\b|今日|今夜"#) { p, _ in
            out.day = today
            evening = p[0]!.range(of: "tonight|今夜", options: [.regularExpression, .caseInsensitive]) != nil
            return true
        }
        scan(#"\bnext week\b|来週"#) { _, _ in out.day = plus(7); return true }
        scan(#"\bin (\d{1,3}) (day|days|week|weeks)\b"#) { p, _ in
            out.day = plus(Int(p[1]!)! * (p[2]!.lowercased().hasPrefix("week") ? 7 : 1))
            return true
        }
        scan(#"\b(?:on )?(?:(next|this) )?("# + weekdayNames + #")\b"#) { p, _ in
            let target = weekdays[p[2]!.lowercased()]!
            var offset = (target - weekday + 7) % 7
            if p[1]?.lowercased() == "next" {
                if offset == 0 { offset = 7 } else if weekday <= target { offset += 7 }
            }
            out.day = plus(offset)
            return true
        }
        scan(#"\b(?:on )?("# + monthNames + #")\.? (\d{1,2})(?:st|nd|rd|th)?\b"#) { p, _ in dated(months[p[1]!.lowercased()]!, Int(p[2]!)!) }
        scan(#"\b(?:on )?(\d{1,2})(?:st|nd|rd|th)? ("# + monthNames + #")\b"#) { p, _ in dated(months[p[2]!.lowercased()]!, Int(p[1]!)!) }
        scan(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#) { p, _ in dated(Int(p[2]!)!, Int(p[3]!)!, year: Int(p[1]!)!) }
        scan(#"\b(?:on )?(\d{1,2})/(\d{1,2})\b"#) { p, _ in dated(Int(p[1]!)!, Int(p[2]!)!) }
        scan(#"(\d{1,2})月(\d{1,2})日"#) { p, _ in dated(Int(p[1]!)!, Int(p[2]!)!) }

        scan(#"\b(?:from |at )?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:-|–|to|until|till)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#) { p, _ in
            clock(p[1], p[2], p[3] ?? p[6], bare: p[2] == nil && p[3] == nil)
        }
        scan(#"(\d{1,2})時(半|(\d{1,2})分)?"#) { p, _ in clock(p[1], p[2] == "半" ? "30" : p[3], nil, bare: false) }
        scan(#"\b(?:at )?(\d{1,2}):(\d{2})\s*(am|pm)?\b"#) { p, _ in clock(p[1], p[2], p[3], bare: false) }
        scan(#"\b(?:at )?(\d{1,2})\s*(am|pm)\b"#) { p, _ in clock(p[1], nil, p[2], bare: false) }
        scan(#"\bat (\d{1,2})\b(?![/:])"#) { p, _ in clock(p[1], nil, nil, bare: true) }
        scan(#"\b(noon|midday)\b"#) { _, _ in out.hour = 12; return true }
        scan(#"\bmidnight\b"#) { _, _ in out.hour = 0; return true }
        scan(#"\bfor (\d+(?:\.\d+)?)\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes)\b"#) { _, _ in true }
        if out.hour == nil {
            // A bare hour right after a date ("tomorrow 3").
            scan(#"\b(\d{1,2})\b(?![/:.\d]|\s*(?:st|nd|rd|th|月|日|days?|weeks?)\b)"#) { p, r in
                let before = ns.substring(to: r.location).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression).utf16.count
                guard out.spans.contains(where: { $0.kind == .when && NSMaxRange($0.range) == before }) else { return false }
                return clock(p[1], nil, nil, bare: true)
            }
        }
        if evening, out.hour == nil { out.hour = 19 }

        // The title is what's left, without joining words at the ends.
        out.spans.sort { $0.range.location < $1.range.location }
        var rest = ""
        var at = 0
        for s in out.spans {
            rest += ns.substring(with: NSRange(location: at, length: max(0, s.range.location - at))) + " "
            at = NSMaxRange(s.range)
        }
        rest += ns.substring(from: min(at, ns.length))
        var words = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        let isConnector = { (w: String) in w.range(of: connector, options: [.regularExpression, .caseInsensitive]) != nil }
        while let last = words.last, isConnector(last) { words.removeLast() }
        while let first = words.first, isConnector(first) { words.removeFirst() }
        out.title = words.enumerated().filter { i, w in !(isConnector(w) && (i == words.count - 1 || isConnector(words[i + 1]))) }.map(\.element)
            .joined(separator: " ")
        return out
    }

    /// Date words the rules left in the title ("next tuesday at 3" written oddly, "来月"): worth asking Claude.
    var needsModel: Bool {
        let words = title.lowercased().split(separator: " ").map(String.init)
        if words.contains(where: { w in w.contains(where: \.isNumber) && w.range(of: #"[/:.\-]|\d(st|nd|rd|th|am|pm|h)$"#, options: .regularExpression) != nil }) { return true }
        if words.contains(where: { w in Self.dateWords.contains { $0 == w || Self.fuzzy(w, $0) } }) { return true }
        return title.range(of: "[時分曜週午朝夜昼昨今明来再月日]", options: .regularExpression) != nil
    }

    /// One or two letters off (Damerau), same first letter, at least four long.
    static func fuzzy(_ word: String, _ target: String) -> Bool {
        guard word != target, word.count >= 4, word.first == target.first else { return false }
        let a = Array(word), b = Array(target)
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count] <= (b.count >= 7 ? 2 : 1)
    }

    /// Moneybag's tidy title: single spaces, no "!!!", a capital first letter ("call Ben" → "Call Ben", "iPhone" kept).
    static func formatTitle(_ t: String) -> String {
        var s = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*([!?.,])\1+$"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let f = s.first, f.isLowercase, f.isASCII, s.range(of: #"^[a-z]+[A-Z]"#, options: .regularExpression) == nil {
            s = f.uppercased() + s.dropFirst()
        }
        return s
    }

    /// The final reading for adding: the rules, then Claude (2.5 s at most) when date words are left over.
    static func final(_ text: String, groups: [String]) async -> QuickAdd {
        var p = parse(text, groups: groups)
        if p.needsModel, Claude.hasKey, let ai = await ask(text, groups: groups) { p = ai }
        p.title = formatTitle(p.title.isEmpty ? text : p.title)
        return p
    }

    private static func ask(_ text: String, groups: [String]) async -> QuickAdd? {
        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE yyyy-MM-dd, HH:mm"
        let system = """
        Today is \(f.string(from: now)).
        You parse a one-line to-do task the user is typing, in any language (often English or Japanese).
        Return the title without the date, time and note words (keep the user's wording otherwise; drop connector words like "due", "at", "on", "by", "まで", "に" that only introduced the date).
        Resolve relative and numeric dates (10/8 means month/day) to the nearest sensible absolute date. Leave fields empty when not given; never invent them.
        Text after "//" is the note.
        \(groups.isEmpty ? "group: always empty." : "group: the task list the input names, from: \(groups.map { "\"\($0)\"" }.joined(separator: ", ")); empty unless some words name that list.")
        Reply with JSON only: {"title": "", "date": "YYYY-MM-DD or empty", "notes": "", "group": ""}
        """
        let call = Task { try await Claude.complete(system: system, user: text, model: "claude-haiku-5-5", effort: "low", maxTokens: 200, timeout: 2.5, fallback: false) }
        guard let reply = try? await call.value, let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let json = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any],
              let title = json["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var p = parse(text, groups: groups)
        p.title = title
        let date = (json["date"] as? String ?? "").split(separator: "-").compactMap { Int($0) }
        p.day = date.count == 3 ? Calendar.current.date(from: DateComponents(year: date[0], month: date[1], day: date[2])) : nil
        if let n = json["notes"] as? String, !n.isEmpty { p.note = n }
        if let g = json["group"] as? String, groups.contains(g) { p.group = g }
        return p
    }

    /// A due date as typed back into the bar when editing: "today", "tomorrow", "Nov 12", or "2026-11-01" when past.
    static func dueText(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        if days == 0 { return "today" }
        if days == 1 { return "tomorrow" }
        let c = cal.dateComponents([.year, .month, .day], from: d)
        if days > 0, days < 300 { return "\(fullMonths[c.month! - 1].prefix(3).capitalized) \(c.day!)" }
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
