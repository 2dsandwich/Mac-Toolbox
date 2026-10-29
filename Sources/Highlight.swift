import AppKit

/// Colors the words MONEY! understood in what you type inside a mode (Clock, Calculator), like the Moneybag search bar:
/// times and amounts in coral, keywords in purple, small joining words in grey. The normal search bar stays plain.
@MainActor enum Highlighter {
    static let when = NSColor(srgbRed: 1, green: 0x6A / 255, blue: 0x55 / 255, alpha: 1)       // #FF6A55
    static let place = NSColor(srgbRed: 0x5A / 255, green: 0xC8 / 255, blue: 0xFA / 255, alpha: 1) // #5AC8FA
    static let note = NSColor(srgbRed: 0xA8 / 255, green: 0xA8 / 255, blue: 0xAE / 255, alpha: 1)  // #A8A8AE
    static let command = NSColor(srgbRed: 0xBF / 255, green: 0x8C / 255, blue: 1, alpha: 1)       // #BF8CFF
    static let op = NSColor.systemOrange

    private typealias Rule = (pattern: String, color: NSColor, group: Int)

    private static let times = #"\b\d{1,2}(?::\d{2})?\s*(?:am|pm|a\.m\.|p\.m\.)(?![a-z])|\b\d{1,2}:\d{2}\b|(?:午前|午後)?\d{1,2}時(?:\d{1,2}分|半)?"#
    private static let durations = #"\b\d+(?:\.\d+)?\s*(?:hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s|days?|weeks?|wks?|months?|years?|yrs?)(?![a-z])|\d+(?:\.\d+)?\s*(?:時間|分|秒|日|週間|週|ヶ月|か月|カ月|年)(?:後|前)?"#
    private static let dates = #"\b(?:today|tomorrow|yesterday|tonight|now|christmas(?: eve)?|xmas|new year'?s?(?: eve)?|halloween|valentine'?s?(?: day)?|(?:next )?(?:mon|tues?|wed(?:nes)?|thu(?:rs)?|fri|sat(?:ur)?|sun)(?:day)?|jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?|weekdays?|weekends?|every day|daily)\b|今日|明日|昨日|明後日|クリスマス|お?正月|元日|大晦日|(?:令和|平成|昭和|大正|明治)\s*(?:\d{1,2}|元)\s*年?|\d{1,2}月\d{1,2}日|\d{4}年|\d{4}-\d{1,2}-\d{1,2}|[月火水木金土日]曜日?"#
    private static let joins = #"\b(?:to|in|into|as|at|for|from|of|until|till|then|with|and|every)\b|→|->|=|/|;|×|\bx\b|まで|から|後|前|は|を|の|に"#
    private static let numbers = #"-?\d[\d,]*(?:\.\d+)?%?"#

    static func spans(_ raw: String, _ m: LauncherModel) -> [(NSRange, NSColor)] {
        let q = raw
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        switch m.scope {
        case .pomodoro:
            switch m.clockMode {
            case .focus:
                return run(q, [(times, when, 0), (durations, when, 0), (#"\b(?:breaks?|focus|rounds?|sessions?|pomodoros?|no breaks?|long|short)\b|休憩|集中|回|なし"#, command, 0),
                               (joins, note, 0), (numbers, when, 0)])
            case .timer: return run(q, [(durations, when, 0), (#"[,、，]"#, note, 0), (numbers, when, 0)])
            case .alarms: return run(q, [(times, when, 0), (dates, when, 0), (#"\bin\b"#, note, 0), (durations, when, 0)])
            case .stopwatch: return []
            }
        case .calculator:
            return run(q, [(#"\b(?:sqrt|cbrt|abs|ln|log2|log10|log|exp|sin|cos|tan|asin|acos|atan|round|floor|ceil|min|max|pow|hypot|pi|tau|mod)\b|√|π"#, command, 0),
                           (#"[+\-*/^%×÷−!]"#, op, 0), (#"[()\[\]]"#, note, 0)])
        case .apps:
            // The normal search bar stays plain; colors are for the modes.
            return []
        default:
            return []
        }
    }

    private static var cache: [String: NSRegularExpression] = [:]

    /// Applies the rules in order; a character keeps the first color it gets.
    private static func run(_ q: String, _ rules: [Rule]) -> [(NSRange, NSColor)] {
        let ns = q as NSString
        var taken = IndexSet()
        var out: [(NSRange, NSColor)] = []
        for rule in rules {
            let re: NSRegularExpression
            if let c = cache[rule.pattern] {
                re = c
            } else {
                guard let made = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
                cache[rule.pattern] = made
                re = made
            }
            for m in re.matches(in: q, range: NSRange(location: 0, length: ns.length)) {
                guard rule.group < m.numberOfRanges else { continue }
                var r = m.range(at: rule.group)
                guard r.location != NSNotFound, r.length > 0 else { continue }
                // Trim spaces off the ends.
                while r.length > 0, ns.substring(with: NSRange(location: r.location, length: 1)) == " " { r = NSRange(location: r.location + 1, length: r.length - 1) }
                while r.length > 0, ns.substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1)) == " " { r.length -= 1 }
                guard r.length > 0, !taken.intersects(integersIn: r.location..<NSMaxRange(r)) else { continue }
                taken.insert(integersIn: r.location..<NSMaxRange(r))
                out.append((r, rule.color))
            }
        }
        return out
    }
}
