import AppKit
import CoreImage.CIFilterBuiltins
import CoreServices
import CryptoKit

/// One instant answer shown above the apps while you type ("12*8", "weather", "10 km to mi").
struct Answer {
    enum Action {
        case copy(String)
        /// Copied without going into the clipboard history (passwords).
        case copySecret(String)
        case paste(String)
        /// Puts this text in the bar (the tools list).
        case fill(String)
        case open(URL)
        case copyImage(NSImage)
        case run(keepOpen: Bool, @MainActor () -> Void)
        case none
    }

    var title: String
    var subtitle: String?
    var symbol = "sparkles"
    var color = NSColor.systemGray
    var emoji: String?
    var image: NSImage?
    var action: Action = .none
    var hint: String?
    /// A bigger layout for answers that need one (weather, currency, clocks, switches…).
    var card: ToolCard?

    var hintText: String {
        if let hint { return hint }
        switch action {
        case .copy, .copySecret, .copyImage: return "Copy ↩"
        case .paste: return "Paste ↩"
        case .fill: return "Try ↩"
        case .open: return "Open ↩"
        case .run: return "Run ↩"
        case .none: return ""
        }
    }
}

struct ToolInfo {
    let name: String
    let example: String
    let symbol: String
    let color: NSColor
}

@MainActor enum Tools {
    /// Set by the launcher.
    static var flash: (String, String, String) -> Void = { _, _, _ in }
    static var startTimer: (Double, String) -> Void = { minutes, label in Timers.shared.add(minutes: minutes, label: label) }
    static var openSettings: () -> Void = {}
    /// Opens a full view (keypad calculator, timer, mixer) with this text in the bar.
    static var enterScope: (Scope, String) -> Void = { _, _ in }
    /// Opens the Translate mode with this text (and target language, or Auto).
    static var translate: (String, String?) -> Void = { _, _ in }

    /// Random results (passwords, dice) stay put while the popup is open.
    private static var stable: [String: [Answer]] = [:]
    static func reset() { stable = [:] }

    /// What's playing, with controls (also the top of the empty popup).
    static func mediaAnswer() -> Answer {
        let m = NowPlaying.shared
        return Answer(title: m.available ? m.title : "Media", subtitle: m.artist, symbol: "music.note", color: .systemPink,
                      action: .run(keepOpen: true) { m.playPause() }, hint: m.playing ? "Pause ↩" : "Play ↩", card: .media)
    }

    /// ↻ on a card: forget the stored roll and draw again.
    static func again(_ key: String) -> Answer.Action {
        .run(keepOpen: true) {
            stable[key] = nil
            LiveData.shared.onUpdate?()
        }
    }

    static func answers(_ raw: String, _ s: Settings) -> [Answer] {
        let q = normalize(raw)
        guard !q.isEmpty, q.count <= 4000 else { return [] }
        let l = q.lowercased()
        if let hit = stable[l] { return hit }
        let off = Set(s.disabledTools)
        for (group, h) in handlers {
            if let group, off.contains(group) { continue }
            if group == .text, let g = textGroup(l), off.contains(g) { continue }
            let r = h(q, l, s)
            if !r.isEmpty { return r }
        }
        return []
    }

    private static let handlers: [(ToolGroup?, (String, String, Settings) -> [Answer])] = [
        (nil, help), (nil, alarm), (.text, textTools), (.weather, weather), (.system, system), (.generators, generators), (.colors, colors),
        (.colors, bases), (.dates, timestamps), (.dates, dates), (.time, timeZones), (.currency, currency), (.units, units),
        (.calculator, calculator), (.dates, moon), (.dates, holidays),
    ]

    /// Text commands that belong to their own group (translate, dictionary, emoji, QR codes).
    private static func textGroup(_ l: String) -> ToolGroup? {
        let first = l.split(separator: " ").first.map(String.init) ?? l
        if ["tr", "translate", "翻訳"].contains(first) { return .translate }
        if ["define", "def", "meaning", "dict", "意味"].contains(first) || l.hasSuffix("とは") || l.hasSuffix("意味") { return .define }
        if ["emoji", "絵文字"].contains(first) || l.hasPrefix(":") { return .emoji }
        if first == "qr" { return .colors }
        return nil
    }

    static let catalog: [ToolInfo] = [
        ToolInfo(name: "Weather", example: "weather", symbol: "cloud.sun.fill", color: .systemBlue),
        ToolInfo(name: "Weather somewhere else", example: "weather osaka", symbol: "cloud.sun.fill", color: .systemBlue),
        ToolInfo(name: "Umbrella check", example: "umbrella", symbol: "umbrella.fill", color: .systemBlue),
        ToolInfo(name: "Sunrise and sunset", example: "sunset", symbol: "sunset.fill", color: .systemOrange),
        ToolInfo(name: "Calculator", example: "(1200 + 380) * 1.1", symbol: "plus.forwardslash.minus", color: .systemOrange),
        ToolInfo(name: "Percentages", example: "15% of 4800", symbol: "percent", color: .systemOrange),
        ToolInfo(name: "Units", example: "10 km to mi", symbol: "ruler", color: .systemTeal),
        ToolInfo(name: "Temperature", example: "72f", symbol: "thermometer.medium", color: .systemTeal),
        ToolInfo(name: "Currency", example: "100 usd to jpy", symbol: "yensign.circle.fill", color: .systemGreen),
        ToolInfo(name: "Currency (Japanese)", example: "1万円", symbol: "yensign.circle.fill", color: .systemGreen),
        ToolInfo(name: "Crypto prices", example: "btc", symbol: "bitcoinsign.circle.fill", color: .systemYellow),
        ToolInfo(name: "Time here and abroad", example: "time", symbol: "clock.fill", color: .systemIndigo),
        ToolInfo(name: "Time in a city", example: "time in london", symbol: "globe", color: .systemIndigo),
        ToolInfo(name: "Convert a time", example: "3pm pst to jst", symbol: "clock.arrow.2.circlepath", color: .systemIndigo),
        ToolInfo(name: "Today’s date", example: "today", symbol: "calendar", color: .systemRed),
        ToolInfo(name: "Countdown", example: "days until christmas", symbol: "calendar.badge.clock", color: .systemRed),
        ToolInfo(name: "Date math", example: "in 90 days", symbol: "calendar.badge.plus", color: .systemRed),
        ToolInfo(name: "Japanese era", example: "令和8年", symbol: "calendar", color: .systemRed),
        ToolInfo(name: "Japanese holidays", example: "祝日", symbol: "flag.fill", color: .systemRed),
        ToolInfo(name: "Timer", example: "timer 10m", symbol: "timer", color: .systemOrange),
        ToolInfo(name: "Stopwatch", example: "stopwatch", symbol: "stopwatch", color: .systemOrange),
        ToolInfo(name: "Alarm", example: "alarm 7:30 gym", symbol: "alarm.fill", color: .systemOrange),
        ToolInfo(name: "Keypad calculator", example: "calc", symbol: "plus.forwardslash.minus", color: .systemOrange),
        ToolInfo(name: "Volume mixer", example: "mixer", symbol: "slider.vertical.3", color: .systemBlue),
        ToolInfo(name: "Unix time", example: "1700000000", symbol: "number", color: .systemGray),
        ToolInfo(name: "Number bases", example: "255 to hex", symbol: "number.square", color: .systemGray),
        ToolInfo(name: "Roman numerals", example: "roman 2026", symbol: "textformat.123", color: .systemGray),
        ToolInfo(name: "Colors", example: "#ff8800", symbol: "paintpalette.fill", color: .systemPink),
        ToolInfo(name: "Translate", example: "tr おはようございます", symbol: "character.bubble.fill", color: .systemPurple),
        ToolInfo(name: "Dictionary", example: "define serendipity", symbol: "character.book.closed.fill", color: .systemBrown),
        ToolInfo(name: "Emoji", example: "emoji fire", symbol: "face.smiling", color: .systemYellow),
        ToolInfo(name: "Word count", example: "count (copied text)", symbol: "textformat.size", color: .systemPurple),
        ToolInfo(name: "Change case", example: "upper hello world", symbol: "textformat", color: .systemPurple),
        ToolInfo(name: "Kana and romaji", example: "kana 東京タワー", symbol: "character.ja", color: .systemPurple),
        ToolInfo(name: "Base64 / URL", example: "base64 hello", symbol: "chevron.left.forwardslash.chevron.right", color: .systemPurple),
        ToolInfo(name: "Hashes", example: "sha256 hello", symbol: "number.circle", color: .systemPurple),
        ToolInfo(name: "Pretty JSON", example: "json (copied text)", symbol: "curlybraces", color: .systemPurple),
        ToolInfo(name: "Character info", example: "char あ", symbol: "character", color: .systemPurple),
        ToolInfo(name: "QR code", example: "qr https://apple.com", symbol: "qrcode", color: .systemGray),
        ToolInfo(name: "Password", example: "password 24", symbol: "key.fill", color: .systemGray),
        ToolInfo(name: "UUID", example: "uuid", symbol: "barcode", color: .systemGray),
        ToolInfo(name: "Random number", example: "random 1-100", symbol: "dice.fill", color: .systemGray),
        ToolInfo(name: "Dice", example: "roll 2d6", symbol: "dice.fill", color: .systemGray),
        ToolInfo(name: "Coin flip", example: "coin", symbol: "circle.lefthalf.filled", color: .systemGray),
        ToolInfo(name: "Pick one", example: "pick ramen, sushi, curry", symbol: "hand.point.up.left.fill", color: .systemGray),
        ToolInfo(name: "Lorem ipsum", example: "lorem 40", symbol: "text.alignleft", color: .systemGray),
        ToolInfo(name: "Moon phase", example: "moon", symbol: "moon.fill", color: .systemIndigo),
        ToolInfo(name: "Battery", example: "battery", symbol: "battery.75percent", color: .systemGreen),
        ToolInfo(name: "IP address", example: "ip", symbol: "network", color: .systemBlue),
        ToolInfo(name: "Disk space", example: "disk", symbol: "internaldrive.fill", color: .systemGray),
        ToolInfo(name: "Memory", example: "memory", symbol: "memorychip.fill", color: .systemGray),
        ToolInfo(name: "Uptime", example: "uptime", symbol: "clock.arrow.circlepath", color: .systemGray),
        ToolInfo(name: "This Mac", example: "about this mac", symbol: "laptopcomputer", color: .systemGray),
        ToolInfo(name: "Keep awake", example: "awake 1h", symbol: "cup.and.saucer.fill", color: .systemBrown),
        ToolInfo(name: "Volume", example: "volume 30", symbol: "speaker.wave.2.fill", color: .systemBlue),
        ToolInfo(name: "Mute", example: "mute", symbol: "speaker.slash.fill", color: .systemBlue),
        ToolInfo(name: "Dark mode", example: "dark mode", symbol: "circle.lefthalf.filled", color: .systemIndigo),
        ToolInfo(name: "Night Shift", example: "night shift", symbol: "moon.haze.fill", color: .systemOrange),
        ToolInfo(name: "Hide the Dock", example: "dock", symbol: "dock.rectangle", color: .systemGray),
        ToolInfo(name: "Hidden files", example: "hidden files", symbol: "eye.fill", color: .systemGray),
        ToolInfo(name: "Desktop icons", example: "desktop icons", symbol: "menubar.dock.rectangle", color: .systemGray),
        ToolInfo(name: "Lock screen", example: "lock", symbol: "lock.fill", color: .systemGray),
        ToolInfo(name: "Sleep", example: "sleep", symbol: "moon.zzz.fill", color: .systemIndigo),
        ToolInfo(name: "Screen off", example: "display off", symbol: "display", color: .systemGray),
        ToolInfo(name: "Screen saver", example: "screensaver", symbol: "sparkles.tv", color: .systemGray),
        ToolInfo(name: "Empty Trash", example: "empty trash", symbol: "trash.fill", color: .systemGray),
        ToolInfo(name: "Eject disks", example: "eject", symbol: "eject.fill", color: .systemGray),
        ToolInfo(name: "Hide other apps", example: "hide others", symbol: "eye.slash.fill", color: .systemGray),
        ToolInfo(name: "Restart / Shut down / Log out", example: "restart", symbol: "power", color: .systemRed),
    ]

    // MARK: Helpers

    private static var regexCache: [String: NSRegularExpression] = [:]

    /// Capture groups of the first match ("" for groups that didn't take part), or nil.
    static func rx(_ pattern: String, _ s: String) -> [String]? {
        let re: NSRegularExpression
        if let cached = regexCache[pattern] {
            re = cached
        } else {
            guard let made = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            regexCache[pattern] = made
            re = made
        }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    /// Full-width letters, digits and signs (typed with the Japanese keyboard) → ASCII; kana stay as they are.
    static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if (0xFF01...0xFF5E).contains(u.value), let a = Unicode.Scalar(u.value - 0xFEE0) {
                out.append(a)
            } else if u.value == 0x3000 {
                out.append(" ")
            } else {
                out.append(u)
            }
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "_", with: ""))
    }

    private static var formatters: [String: NumberFormatter] = [:]

    /// 1,234.5678 (for showing).
    static func fmt(_ v: Double, digits: Int = 6) -> String { format(v, digits: digits, grouping: true) }
    /// 1234.5678 (for copying).
    static func plain(_ v: Double, digits: Int = 10) -> String { format(v, digits: digits, grouping: false) }

    private static func format(_ v: Double, digits: Int, grouping: Bool) -> String {
        if v != 0, abs(v) >= 1e15 || abs(v) < 1e-7 { return String(format: "%.8g", v) }
        let key = "\(digits)-\(grouping)"
        let f: NumberFormatter
        if let cached = formatters[key] {
            f = cached
        } else {
            f = NumberFormatter()
            f.numberStyle = .decimal
            f.locale = Locale(identifier: "en_US")
            f.maximumFractionDigits = digits
            f.usesGroupingSeparator = grouping
            formatters[key] = f
        }
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func oneLine(_ s: String, _ limit: Int = 300) -> String {
        let flat = s.replacingOccurrences(of: "\r\n", with: " ⏎ ").replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { r in
            c.setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            return true
        }
    }

    // MARK: Media and alarms

    private static func media(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        let m = NowPlaying.shared
        switch l {
        case "music", "now playing", "playing", "media", "song", "what's playing", "再生中", "音楽", "曲":
            m.refresh()
            return [mediaAnswer()]
        case "play", "pause", "play pause", "再生", "一時停止":
            m.refresh()
            return [mediaAnswer()]
        case "next", "next song", "next track", "skip", "次", "次の曲":
            var a = mediaAnswer()
            a.action = .run(keepOpen: true) { m.next() }
            a.hint = "Next ↩"
            return [a]
        case "previous", "prev", "previous song", "back", "前", "前の曲":
            var a = mediaAnswer()
            a.action = .run(keepOpen: true) { m.previous() }
            a.hint = "Previous ↩"
            return [a]
        default: return []
        }
    }

    private static func alarm(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        guard let m = rx(#"^(?:alarm|set alarm|set an alarm|wake me(?: up)?(?: at)?|アラーム|目覚まし)\s+(?:for\s+|at\s+)?(.+)$"#, q), let t = Alarms.parse(m[1]) else { return [] }
        var c = DateComponents()
        c.hour = t.hour
        c.minute = t.minute
        let df = DateFormatter()
        df.timeStyle = .short
        let time = Calendar.current.date(from: c).map(df.string) ?? "\(t.hour):\(t.minute)"
        return [Answer(title: "Set an alarm for \(time)" + (t.label.isEmpty ? "" : " · \(t.label)"), subtitle: "Alarm",
                       symbol: "alarm.fill", color: .systemOrange, action: .run(keepOpen: false) {
                           let a = Alarms.shared.add(hour: t.hour, minute: t.minute, label: t.label)
                           flash("Alarm set for \(a.time)", RelativeDateTimeFormatter().localizedString(for: a.next, relativeTo: Date()), "alarm.fill")
                       }, hint: "Set ↩")]
    }

    // MARK: Tools list ("?")

    private static func help(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        guard ["?", "tools", "help", "commands", "ツール", "ヘルプ"].contains(l) else { return [] }
        return catalog.map { t in
            Answer(title: t.name, subtitle: t.example, symbol: t.symbol, color: t.color, action: .fill(t.example), hint: "Try ↩")
        }
    }

    // MARK: Text tools ("upper hello", "count" with the clipboard)

    private static let clipboardCommands: Set<String> = [
        "upper", "uppercase", "lower", "lowercase", "camel", "camelcase", "snake", "kebab", "slug", "trim", "count", "wc",
        "base64", "b64", "base64d", "b64d", "unbase64", "urlencode", "urldecode", "sha256", "sha1", "sha512", "md5", "hash",
        "json", "kana", "hiragana", "katakana", "romaji", "zen", "zenkaku", "han", "hankaku", "qr", "tr", "translate", "翻訳",
        "文字数", "かな", "カタカナ", "ローマ字",
    ]
    private static let argCommands: Set<String> = [
        "title", "capitalize", "reverse", "url", "define", "def", "meaning", "dict", "意味", "emoji", "絵文字", "char", "unicode",
    ]

    private static func textTools(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        if let m = rx(#"^:([a-z0-9_ ]{2,})$"#, l) { return emoji(m[1]) }
        if let m = rx(#"^(?:what does|meaning of|what is the meaning of)\s+(.+?)(?:\s+mean)?\??$"#, q) { return define(m[1]) }
        if let m = rx(#"^(.+?)(?:\s*とは|\s+意味|の意味)$"#, q) { return define(m[1]) }

        let parts = q.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return [] }
        let cmd = first.lowercased()
        var arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        var fromClipboard = false
        if arg.isEmpty {
            guard clipboardCommands.contains(cmd) else { return [] }
            guard let clip = NSPasteboard.general.string(forType: .string), !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return []
            }
            arg = clip
            fromClipboard = true
        } else if !clipboardCommands.contains(cmd), !argCommands.contains(cmd) {
            return []
        }
        let src = fromClipboard ? " · from the clipboard" : ""

        func row(_ result: String, _ label: String, _ symbol: String = "textformat") -> Answer {
            Answer(title: oneLine(result), subtitle: label + src, symbol: symbol, color: .systemPurple, action: .copy(result))
        }

        switch cmd {
        case "upper", "uppercase": return [row(arg.uppercased(), "Uppercase")]
        case "lower", "lowercase": return [row(arg.lowercased(), "Lowercase")]
        case "title", "capitalize": return [row(arg.capitalized, "Title Case")]
        case "camel", "camelcase":
            let w = words(arg)
            return [row((w.first?.lowercased() ?? "") + w.dropFirst().map { $0.capitalized }.joined(), "camelCase")]
        case "snake": return [row(words(arg).map { $0.lowercased() }.joined(separator: "_"), "snake_case")]
        case "kebab", "slug": return [row(words(arg).map { $0.lowercased() }.joined(separator: "-"), "kebab-case")]
        case "reverse": return [row(String(arg.reversed()), "Reversed")]
        case "trim": return [row(arg.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"), "Trimmed")]
        case "count", "wc", "文字数": return count(arg, src)
        case "base64", "b64": return [row(Data(arg.utf8).base64EncodedString(), "Base64", "chevron.left.forwardslash.chevron.right")]
        case "base64d", "b64d", "unbase64":
            let cleaned = arg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let d = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters), let t = String(data: d, encoding: .utf8) else {
                return [Answer(title: "Not Base64 text", subtitle: "Base64 decode" + src, symbol: "exclamationmark.triangle", color: .systemPurple)]
            }
            return [row(t, "Base64 decoded", "chevron.left.forwardslash.chevron.right")]
        case "url", "urlencode":
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+?#/:")
            return [row(arg.addingPercentEncoding(withAllowedCharacters: allowed) ?? arg, "URL encoded", "link")]
        case "urldecode": return [row(arg.removingPercentEncoding ?? arg, "URL decoded", "link")]
        case "sha256", "hash": return [row(hex(SHA256.hash(data: Data(arg.utf8))), "SHA-256", "number.circle")]
        case "sha1": return [row(hex(Insecure.SHA1.hash(data: Data(arg.utf8))), "SHA-1", "number.circle")]
        case "sha512": return [row(hex(SHA512.hash(data: Data(arg.utf8))), "SHA-512", "number.circle")]
        case "md5": return [row(hex(Insecure.MD5.hash(data: Data(arg.utf8))), "MD5", "number.circle")]
        case "json": return json(arg, src)
        case "kana", "hiragana", "かな":
            return [row(hiragana(arg), "Hiragana", "character.ja"), row(romaji(arg), "Romaji", "character.ja")]
        case "katakana", "カタカナ":
            let k = String(String.UnicodeScalarView(hiragana(arg).unicodeScalars.map { u in
                (0x3041...0x3096).contains(u.value) ? Unicode.Scalar(u.value + 0x60) ?? u : u
            }))
            return [row(k, "Katakana", "character.ja")]
        case "romaji", "ローマ字":
            let r = romaji(arg)
            let plainR = r.folding(options: .diacriticInsensitive, locale: nil)
            return plainR == r ? [row(r, "Romaji", "character.ja")] : [row(r, "Romaji", "character.ja"), row(plainR, "Romaji without long marks", "character.ja")]
        case "zen", "zenkaku": return [row(arg.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? arg, "Full-width (全角)", "character.ja")]
        case "han", "hankaku": return [row(arg.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? arg, "Half-width (半角)", "character.ja")]
        case "char", "unicode": return charInfo(arg)
        case "qr":
            guard let img = qr(arg) else { return [] }
            return [Answer(title: "QR code for “\(oneLine(arg, 60))”", subtitle: "QR code" + src, symbol: "qrcode", image: img, action: .copyImage(img),
                           card: .qr(img, text: oneLine(arg, 400)))]
        case "define", "def", "meaning", "dict", "意味": return define(arg)
        case "emoji", "絵文字": return emoji(arg)
        case "tr", "translate", "翻訳":
            var text = arg
            var target: String?
            if !fromClipboard, let m = rx(#"^(.+?)\s+(?:to|into|in)\s+([a-z]+|[\p{Han}\p{Katakana}]+語?)$"#, arg) {
                text = m[1]
                target = m[2]
            }
            return [LiveData.shared.translation(text, target: target, s, fromClipboard: fromClipboard)]
        default: return []
        }
    }

    private static func words(_ s: String) -> [String] {
        // Splits on spaces and punctuation, and between camelCase humps.
        let spaced = s.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        return spaced.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private static func count(_ text: String, _ src: String) -> [Answer] {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        let chars = text.count
        let noSpaces = text.filter { !$0.isWhitespace }.count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        let minutes = max(1, Int((Double(words) / 230).rounded()))
        let summary = "\(fmt(Double(words))) words · \(fmt(Double(chars))) characters"
        let detail = "\(lines) lines · \(fmt(Double(text.utf8.count))) bytes · about \(minutes) min to read"
        return [
            Answer(title: summary, subtitle: detail + src, symbol: "textformat.size", color: .systemPurple, action: .copy(summary),
                   card: .big(.init(title: "Word count" + src, symbol: "textformat.size", color: .systemPurple, value: fmt(Double(words)), unit: words == 1 ? "word" : "words",
                                    detail: detail, chips: [.init(label: "Characters", value: fmt(Double(chars)), action: .copy("\(chars)")),
                                                            .init(label: "Without spaces", value: fmt(Double(noSpaces)), action: .copy("\(noSpaces)"))]))),
        ]
    }

    private static func json(_ text: String, _ src: String) -> [Answer] {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let compact = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else {
            return [Answer(title: "Not valid JSON", subtitle: "JSON" + src, symbol: "curlybraces", color: .systemPurple)]
        }
        let p = String(decoding: pretty, as: UTF8.self)
        let c = String(decoding: compact, as: UTF8.self)
        return [
            Answer(title: oneLine(p, 200), subtitle: "Pretty JSON · \(p.components(separatedBy: "\n").count) lines" + src, symbol: "curlybraces", color: .systemPurple, action: .copy(p)),
            Answer(title: oneLine(c, 200), subtitle: "Minified JSON" + src, symbol: "curlybraces", color: .systemPurple, action: .copy(c)),
        ]
    }

    /// The reading of Japanese text in Latin letters ("東京" → "tōkyō").
    static func romaji(_ s: String) -> String {
        let cf = s as CFString
        let len = CFStringGetLength(cf)
        guard let tok = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: len), kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        while !CFStringTokenizerAdvanceToNextToken(tok).isEmpty {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            if r.location > last { out += ns.substring(with: NSRange(location: last, length: r.location - last)) }
            let piece = ns.substring(with: NSRange(location: r.location, length: r.length))
            if let attr = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription), let latin = attr as? String {
                out += (out.isEmpty || out.hasSuffix(" ") ? "" : " ") + latin
            } else {
                out += piece
            }
            last = r.location + r.length
        }
        if last < len { out += ns.substring(from: last) }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Kanji become their reading, katakana turn into hiragana ("東京タワー" → "とうきょうたわー").
    static func hiragana(_ s: String) -> String {
        // Katakana runs convert directly (the reading of a whole word would lose "ー").
        var out = "", run = "", runIsKana = false
        func flush() {
            out += runIsKana ? kataToHira(run) : readingInHiragana(run)
            run = ""
        }
        for ch in s {
            let kana = ch.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) }
            if kana != runIsKana, !run.isEmpty { flush() }
            runIsKana = kana
            run.append(ch)
        }
        if !run.isEmpty { flush() }
        return out
    }

    /// ア → あ, keeping ー (the system transform turns it into a vowel).
    private static func kataToHira(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            (0x30A1...0x30F6).contains(u.value) ? Unicode.Scalar(u.value - 0x60) ?? u : u
        }))
    }

    private static func readingInHiragana(_ s: String) -> String {
        let cf = s as CFString
        let len = CFStringGetLength(cf)
        guard let tok = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: len), kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        while !CFStringTokenizerAdvanceToNextToken(tok).isEmpty {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            if r.location > last { out += ns.substring(with: NSRange(location: last, length: r.location - last)) }
            let piece = ns.substring(with: NSRange(location: r.location, length: r.length))
            if piece.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }),
               let attr = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription), let latin = attr as? String {
                out += latin.applyingTransform(.latinToHiragana, reverse: false) ?? piece
            } else {
                out += kataToHira(piece)
            }
            last = r.location + r.length
        }
        if last < len { out += ns.substring(from: last) }
        return out
    }

    private static func charInfo(_ s: String) -> [Answer] {
        Array(s.unicodeScalars.prefix(8)).map { u in
            let code = String(format: "U+%04X", u.value)
            return Answer(title: "\(String(u))   \(code)", subtitle: (u.properties.name ?? u.properties.nameAlias ?? "Unnamed").capitalized + " · UTF-8 " + String(u).utf8.map { String(format: "%02X", $0) }.joined(separator: " "),
                          symbol: "character", color: .systemPurple, action: .copy(code))
        }
    }

    static func qr(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width / 2, height: out.extent.height / 2))
    }

    private static func define(_ raw: String) -> [Answer] {
        let word = raw.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return [] }
        let cf = word as CFString
        let url = URL(string: "dict://" + (word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word))
        guard let cfDef = DCSCopyTextDefinition(nil, cf, CFRange(location: 0, length: CFStringGetLength(cf)))?.takeRetainedValue() else {
            return [Answer(title: "No definition for “\(word)”", subtitle: "Dictionary", symbol: "character.book.closed.fill", color: .systemBrown,
                           action: url.map { .open($0) } ?? .none, hint: "Dictionary ↩")]
        }
        let def = cfDef as String
        let flat = def.components(separatedBy: .newlines).joined(separator: " ")
        let parts = flat.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        let title: String
        var subtitle = "Dictionary"
        var head = word
        if parts.count >= 3 {
            title = parts[2...].joined(separator: " ")
            subtitle = "\(parts[0]) · \(parts[1])"
            head = parts[0]
        } else {
            title = flat
        }
        return [Answer(title: oneLine(title, 240), subtitle: subtitle, symbol: "character.book.closed.fill", color: .systemBrown,
                       action: url.map { .open($0) } ?? .copy(def), hint: "Dictionary ↩",
                       card: .define(word: head, detail: parts.count >= 3 ? parts[1] : "", text: oneLine(title, 600)))]
    }

    // MARK: Emoji (":fire", "emoji cat")

    private static var emojiList: [(String, String)] = {
        var out: [(String, String)] = []
        let ranges: [ClosedRange<UInt32>] = [0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF,
                                             0x1FA70...0x1FAFF, 0x2600...0x26FF, 0x2700...0x27BF]
        for r in ranges {
            for v in r {
                guard let u = Unicode.Scalar(v), u.properties.isEmoji, let name = u.properties.name else { continue }
                var ch = String(Character(u))
                if !u.properties.isEmojiPresentation { ch += "\u{FE0F}" }
                out.append((ch, name.lowercased()))
            }
        }
        return out
    }()

    private static let emojiWords: [String: String] = [
        "lol": "tears of joy", "laugh": "tears of joy", "cry": "crying", "sad": "crying", "love": "heart", "ok": "ok hand",
        "yes": "thumbs up", "no": "thumbs down", "clap": "clapping", "party": "party", "money": "money", "think": "thinking",
        "笑": "tears of joy", "泣": "crying", "ハート": "heart", "火": "fire", "猫": "cat", "ねこ": "cat", "犬": "dog", "いぬ": "dog",
        "お金": "money", "金": "money", "星": "star", "花": "flower", "怒": "angry", "拍手": "clapping", "桜": "cherry blossom",
        "寿司": "sushi", "ラーメン": "steaming bowl", "ビール": "beer", "コーヒー": "hot beverage", "雨": "umbrella", "晴れ": "sun",
    ]

    private static func emoji(_ term: String) -> [Answer] {
        var t = term.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: " ")
        if let alias = emojiWords[t] { t = alias }
        let words = t.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let hits = emojiList.filter { e in words.allSatisfy { w in e.1.split(separator: " ").contains { $0.hasPrefix(w) } } }
            .sorted { a, b in
                let ax = a.1 == t ? 0 : a.1.hasPrefix(t) ? 1 : 2
                let bx = b.1 == t ? 0 : b.1.hasPrefix(t) ? 1 : 2
                return ax != bx ? ax < bx : a.1.count < b.1.count
            }
        return hits.prefix(8).map { e in
            Answer(title: e.1.capitalized, subtitle: "Emoji", emoji: e.0, action: .paste(e.0), hint: "Paste ↩")
        }
    }

    // MARK: Weather

    private static func weather(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        let live = LiveData.shared
        if let m = rx(#"^(?:weather|forecast|wx|天気|天気予報|てんき)(?:\s+(?:in\s+|for\s+|at\s+)?(.+))?$"#, q) {
            return live.weather(place: m[1], kind: .full, s)
        }
        if let m = rx(#"^(.+?)\s*(?:の)?(?:天気|天気予報|weather|forecast)$"#, q) {
            return live.weather(place: m[1], kind: .full, s)
        }
        if ["umbrella", "rain", "傘", "かさ", "雨", "will it rain", "is it raining"].contains(l) { return live.weather(place: "", kind: .rain, s) }
        if ["sunrise", "sunset", "日の出", "日の入り", "日没", "daylight"].contains(l) { return live.weather(place: "", kind: .sun, s) }
        if ["temperature", "temp", "気温"].contains(l) { return live.weather(place: "", kind: .full, s) }
        return []
    }

    // MARK: Generators

    private static func generators(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        let r = makeGenerated(q, l)
        if !r.isEmpty { stable[l] = r }
        return r
    }

    private static func makeGenerated(_ q: String, _ l: String) -> [Answer] {
        func row(_ v: String, _ label: String, _ symbol: String, secret: Bool = false) -> Answer {
            Answer(title: v, subtitle: label, symbol: symbol, color: .systemGray, action: secret ? .copySecret(v) : .copy(v))
        }
        func big(_ title: String, _ symbol: String, _ value: String, caption: String? = nil, detail: String? = nil, chips: [ToolCard.Chip] = [], mono: Bool = false,
                 controls: [ToolCard.Control] = []) -> Answer {
            Answer(title: value, subtitle: title, symbol: symbol, color: .systemGray, action: .copy(value),
                   card: .big(.init(title: title, symbol: symbol, color: .systemGray, caption: caption, value: value, detail: detail, chips: chips, again: again(l), mono: mono,
                                    controls: controls)))
        }
        if ["uuid", "guid", "uuidgen"].contains(l) {
            let u = UUID().uuidString
            return [big("UUID", "barcode", u, chips: [.init(label: "lowercase", value: u.lowercased(), action: .copy(u.lowercased()))], mono: true)]
        }
        if let m = rx(#"^(?:password|passwd|pw|pass|パスワード)(?:\s+(\d{1,3}))?$"#, l) {
            let n = min(128, max(6, Int(m[1]) ?? 20))
            let strong = password(n, symbols: true), plainPw = password(n, symbols: false)
            let pin = String((0..<6).map { _ in "0123456789".randomElement()! })
            return [Answer(title: strong, subtitle: "Strong password · \(n) characters", symbol: "key.fill", color: .systemGray, action: .copySecret(strong),
                           card: .password(strong, length: n, chips: [.init(label: "Letters & numbers", value: plainPw, action: .copySecret(plainPw)),
                                                                       .init(label: "PIN", value: pin, action: .copySecret(pin))], again: again(l),
                                           controls: [.init(symbol: "minus", help: "Shorter", action: .fill("password \(max(6, n - 4))")),
                                                      .init(symbol: "plus", help: "Longer", action: .fill("password \(min(128, n + 4))"))]))]
        }
        if let m = rx(#"^(?:random|rand|rng|乱数)(?:\s+(-?\d+)\s*(?:-|to|〜|~|\.\.)\s*(-?\d+))?(?:\s+(\d+))?$"#, l) {
            var lo = Int(m[1]) ?? 1, hi = Int(m[2]) ?? 100
            if m[1].isEmpty, let single = Int(m[3]) { lo = 1; hi = single }
            if lo > hi { swap(&lo, &hi) }
            return [big("Random number", "dice.fill", "\(Int.random(in: lo...hi))", caption: "From \(lo) to \(hi)")]
        }
        if ["coin", "flip", "coin flip", "flip a coin", "heads or tails", "コイン", "コイントス"].contains(l) {
            return [big("Coin flip", "circle.lefthalf.filled", Bool.random() ? "Heads" : "Tails")]
        }
        if let m = rx(#"^(?:roll|dice|die|サイコロ)(?:\s+(\d{0,2})d(\d{1,3}))?$"#, l) {
            let n = min(20, max(1, Int(m[1]) ?? 1)), sides = max(2, Int(m[2]) ?? 6)
            let rolls = (0..<n).map { _ in Int.random(in: 1...sides) }
            return [big("Dice · \(n)d\(sides)", "dice.fill", "\(rolls.reduce(0, +))", detail: n > 1 ? rolls.map(String.init).joined(separator: " + ") : nil, controls: [
                .init(symbol: "minus", help: "One die fewer", action: .fill("roll \(max(1, n - 1))d\(sides)")),
                .init(symbol: "plus", help: "One more die", action: .fill("roll \(min(20, n + 1))d\(sides)")),
                .init(symbol: "dice", title: "d\(sides)", help: "Kind of die", menu: [4, 6, 8, 10, 12, 20, 100].map { ("d\($0)", .fill("roll \(n)d\($0)")) }),
            ])]
        }
        if let m = rx(#"^(?:pick|choose|either|どれ)\s+(.+)$"#, q) {
            let options = m[1].components(separatedBy: CharacterSet(charactersIn: ",、/|")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let list = options.count > 1 ? options : m[1].split(separator: " ").map(String.init)
            guard list.count > 1, let pick = list.randomElement() else { return [] }
            return [big("Pick one", "hand.point.up.left.fill", pick, caption: "From " + list.joined(separator: ", "))]
        }
        if let m = rx(#"^(?:lorem|lipsum|lorem ipsum)(?:\s+(\d{1,4}))?$"#, l) {
            let n = min(2000, max(1, Int(m[1]) ?? 50))
            let base = loremText.split(separator: " ")
            var w: [Substring] = []
            while w.count < n { w.append(contentsOf: base.prefix(n - w.count)) }
            var text = w.joined(separator: " ")
            if !text.hasSuffix(".") { text = text.trimmingCharacters(in: .punctuationCharacters) + "." }
            return [row(text, "Lorem ipsum · \(n) words", "text.alignleft")]
        }
        return []
    }

    private static let loremText = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."

    private static func password(_ n: Int, symbols: Bool) -> String {
        let lower = Array("abcdefghijkmnopqrstuvwxyz"), upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), digits = Array("23456789"), sym = Array("!@#$%^&*-_=+?")
        let all = lower + upper + digits + (symbols ? sym : [])
        while true {
            let p = (0..<n).map { _ in all.randomElement()! }
            let ok = p.contains { lower.contains($0) } && p.contains { upper.contains($0) } && p.contains { digits.contains($0) } && (!symbols || p.contains { sym.contains($0) })
            if ok || n < 6 { return String(p) }
        }
    }

    // MARK: Colors

    private static func colors(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        var color: NSColor?
        if let m = rx(#"^(?:colou?r\s+)?#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$"#, l) ?? rx(#"^colou?r\s+([0-9a-f]{6})$"#, l) {
            var h = m[1]
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            color = NSColor(hex: h)
        } else if let m = rx(#"^rgba?\(\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*(?:[,/]\s*([\d.]+))?\s*\)$"#, l) {
            let c = [m[1], m[2], m[3]].map { min(255, Double($0) ?? 0) / 255 }
            color = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: min(1, Double(m[4]) ?? 1))
        } else if let m = rx(#"^hsla?\(\s*([\d.]+)(?:deg)?\s*[, ]\s*([\d.]+)%\s*[, ]\s*([\d.]+)%\s*(?:[,/]\s*([\d.]+))?\s*\)$"#, l) {
            let h = (Double(m[1]) ?? 0).truncatingRemainder(dividingBy: 360) / 360, sat = min(1, (Double(m[2]) ?? 0) / 100), light = min(1, (Double(m[3]) ?? 0) / 100)
            let v = light + sat * min(light, 1 - light)
            color = NSColor(hue: h, saturation: v == 0 ? 0 : 2 * (1 - light / v), brightness: v, alpha: min(1, Double(m[4]) ?? 1))
        }
        guard let c = color?.usingColorSpace(.sRGB) else { return [] }
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let mx = max(r, g, b), mn = min(r, g, b), light = (mx + mn) / 2
        var hue = 0.0, sat = 0.0
        if mx != mn {
            let d = mx - mn
            sat = light > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            switch mx {
            case r: hue = (g - b) / d + (g < b ? 6 : 0)
            case g: hue = (b - r) / d + 2
            default: hue = (r - g) / d + 4
            }
            hue *= 60
        }
        let img = swatch(c)
        let hexStr = c.hexString
        let rgb = "rgb(\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded())))"
        let hsl = "hsl(\(Int(hue.rounded())), \(Int((sat * 100).rounded()))%, \(Int((light * 100).rounded()))%)"
        let swift = String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", r, g, b)
        let chips = [("HEX", hexStr), ("RGB", rgb), ("HSL", hsl), ("SwiftUI", swift)].map { ToolCard.Chip(label: $0.0, value: $0.1, action: .copy($0.1)) }
        return [Answer(title: hexStr, subtitle: "\(rgb) · \(hsl)", image: img, action: .copy(hexStr), hint: "Copy HEX ↩", card: .color(c, chips))]
    }

    // MARK: Number bases and Roman numerals

    private static func bases(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        var value: UInt64?
        var from = ""
        if let m = rx(#"^0x([0-9a-f_]+)$"#, l) { value = UInt64(m[1].replacingOccurrences(of: "_", with: ""), radix: 16); from = "hex" }
        else if let m = rx(#"^0b([01_]+)$"#, l) { value = UInt64(m[1].replacingOccurrences(of: "_", with: ""), radix: 2); from = "bin" }
        else if let m = rx(#"^0o([0-7_]+)$"#, l) { value = UInt64(m[1].replacingOccurrences(of: "_", with: ""), radix: 8); from = "oct" }
        else if let m = rx(#"^(\d+)\s*(?:to|in|as)\s*(?:hex|hexadecimal|binary|bin|octal|oct|decimal|dec)$"#, l) { value = UInt64(m[1]) }
        else if let m = rx(#"^(?:hex|bin|binary|oct|octal)\s+(\d+)$"#, l) { value = UInt64(m[1]) }
        else if let m = rx(#"^(?:roman|ローマ数字)\s+(\d{1,4})$"#, l) ?? rx(#"^(\d{1,4})\s+(?:to|in)\s+roman$"#, l), let n = Int(m[1]), (1...3999).contains(n) {
            let r = roman(n)
            return [Answer(title: r, subtitle: "\(n) in Roman numerals", symbol: "textformat.123", color: .systemGray, action: .copy(r),
                           card: .big(.init(title: "Roman numerals", symbol: "textformat.123", color: .systemGray, caption: "\(n) =", value: r)))]
        } else if let m = rx(#"^roman\s+([ivxlcdm]+)$"#, l), let n = fromRoman(m[1].uppercased()) {
            return [Answer(title: "\(n)", subtitle: "\(m[1].uppercased()) from Roman numerals", symbol: "textformat.123", color: .systemGray, action: .copy("\(n)"))]
        }
        guard let v = value else { return [] }
        func group(_ s: String, _ n: Int) -> String {
            var out = ""
            for (i, ch) in s.reversed().enumerated() {
                if i > 0, i % n == 0 { out.append(" ") }
                out.append(ch)
            }
            return String(out.reversed())
        }
        let rows: [(String, String, String)] = [
            ("dec", fmt(Double(v), digits: 0), String(v)),
            ("hex", "0x" + String(v, radix: 16).uppercased(), "0x" + String(v, radix: 16).uppercased()),
            ("bin", "0b" + group(String(v, radix: 2), 4), "0b" + String(v, radix: 2)),
            ("oct", "0o" + String(v, radix: 8), "0o" + String(v, radix: 8)),
        ]
        let names = ["dec": "Decimal", "hex": "Hexadecimal", "bin": "Binary", "oct": "Octal"]
        let shown = rows.filter { $0.0 != from }
        guard let main = shown.first else { return [] }
        return [Answer(title: main.1, subtitle: names[main.0], symbol: "number.square", color: .systemGray, action: .copy(main.2),
                       card: .big(.init(title: "Number bases", symbol: "number.square", color: .systemGray, caption: "\(q) =", value: main.1, unit: names[main.0]?.lowercased(),
                                        chips: shown.dropFirst().map { .init(label: names[$0.0] ?? "", value: $0.1, action: .copy($0.2)) }, mono: true)))]
    }

    private static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, out = ""
        for (v, s) in table { while n >= v { out += s; n -= v } }
        return out
    }

    private static func fromRoman(_ s: String) -> Int? {
        let v: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        var total = 0, prev = 0
        for ch in s.reversed() {
            guard let x = v[ch] else { return nil }
            total += x < prev ? -x : x
            prev = max(prev, x)
        }
        return total > 0 && roman(total) == s ? total : nil
    }

    // MARK: Unix time

    private static func timestamps(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        let sym = "number", c = NSColor.systemGray
        if ["now", "epoch", "unix", "timestamp", "unix time", "unixtime", "unix timestamp"].contains(l) {
            let t = Date().timeIntervalSince1970
            let iso = ISO8601DateFormatter().string(from: Date())
            return [Answer(title: "\(Int(t))", subtitle: "Unix time, seconds", symbol: sym, color: c, action: .copy("\(Int(t))"),
                           card: .big(.init(title: "Unix time", symbol: sym, color: c, caption: "Now", value: "\(Int(t))",
                                            chips: [.init(label: "ms", value: "\(Int(t * 1000))", action: .copy("\(Int(t * 1000))")),
                                                    .init(label: "ISO", value: iso, action: .copy(iso))])))]
        }
        guard let m = rx(#"^(\d{10}|\d{13})$"#, l), let v = Double(m[1]) else { return [] }
        let secs = m[1].count == 13 ? v / 1000 : v
        let d = Date(timeIntervalSince1970: secs)
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .medium
        let local = df.string(from: d)
        let iso = ISO8601DateFormatter().string(from: d)
        let rel = RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
        return [Answer(title: local, subtitle: "From Unix time · \(rel)", symbol: sym, color: c, action: .copy(local),
                       card: .big(.init(title: "Unix time", symbol: sym, color: c, caption: m[1], value: local, detail: rel.prefix(1).uppercased() + rel.dropFirst(),
                                        chips: [.init(label: "ISO", value: iso, action: .copy(iso))])))]
    }

    // MARK: Dates

    private static func dates(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch l {
        case "today", "date", "今日", "きょう", "日付", "what day is it", "what's the date", "week", "week number", "週番号", "何日":
            return [dayRow(today)]
        case "tomorrow", "明日", "あした": return [dayRow(cal.date(byAdding: .day, value: 1, to: today)!)]
        case "yesterday", "昨日", "きのう": return [dayRow(cal.date(byAdding: .day, value: -1, to: today)!)]
        case "wareki", "和暦", "元号", "japanese era", "今年", "this year": return [eraRow(cal.component(.year, from: today), today)]
        default: break
        }
        let unit = #"(days?|d|weeks?|wks?|w|months?|mos?|years?|yrs?|y|日|週間|週|ヶ月|か月|カ月|ケ月|ヵ月|年)"#
        if let m = rx(#"^(?:in\s+)?(\d{1,5})\s*"# + unit + #"\s*(from now|later|後|ago|前|before|earlier)?$"#, l),
           l.hasPrefix("in ") || !m[3].isEmpty, let n = Int(m[1]) {
            let back = ["ago", "前", "before", "earlier"].contains(m[3])
            if let d = cal.date(byAdding: component(m[2]), value: back ? -n : n, to: today) { return [dayRow(d)] }
        }
        if let m = rx(#"^(?:today|now|今日)\s*([+-])\s*(\d{1,5})\s*"# + unit + "?$", l), let n = Int(m[2]) {
            let comp = m[3].isEmpty ? .day : component(m[3])
            if let d = cal.date(byAdding: comp, value: m[1] == "-" ? -n : n, to: today) { return [dayRow(d)] }
        }
        if let m = rx(#"^(?:how (?:long|many days) (?:until|till|to|before)|days? (?:until|till|to|left until|left till|before)|until|till|countdown(?: to)?)\s+(.+?)\??$"#, l)
            ?? rx(#"^(.+?)\s*まで(?:あと)?(?:何日)?$"#, q), let target = parseDay(m[1], future: true) {
            return [countRow(target, name: m[1])]
        }
        if let m = rx(#"^(?:days? since|since|how long since|how many days since)\s+(.+?)\??$"#, l) ?? rx(#"^(.+?)\s*から(?:何日)?$"#, q),
           let target = parseDay(m[1], future: false) {
            return [countRow(target, name: m[1])]
        }
        if let m = rx(#"^(令和|平成|昭和|大正|明治|reiwa|heisei|showa|shōwa|taisho|taishō|meiji)\s*(\d{1,2}|元)\s*年?$"#, l) {
            let starts: [String: Int] = ["令和": 2019, "reiwa": 2019, "平成": 1989, "heisei": 1989, "昭和": 1926, "showa": 1926, "shōwa": 1926,
                                         "大正": 1912, "taisho": 1912, "taishō": 1912, "明治": 1868, "meiji": 1868]
            let n = m[2] == "元" ? 1 : Int(m[2]) ?? 1
            let y = (starts[m[1].lowercased()] ?? 2019) + n - 1
            return [Answer(title: "\(y)", subtitle: "\(m[1])\(m[2])年 = \(y)年", symbol: "calendar", color: .systemRed, action: .copy("\(y)"),
                           card: .big(.init(title: "Japanese era", symbol: "calendar", color: .systemRed, caption: "\(m[1])\(m[2])年 =", value: "\(y)", unit: "年")))]
        }
        if let m = rx(#"^(\d{4})\s*(?:年\s*(?:は)?\s*(?:和暦)?|\s+(?:wareki|in japanese|和暦|japanese era))$"#, l), let y = Int(m[1]), (1868...2200).contains(y) {
            return [eraRow(y, nil)]
        }
        if l.rangeOfCharacter(from: .decimalDigits) != nil, let d = parseDay(q, future: nil, strict: true) {
            return [dayRow(d)]
        }
        return []
    }

    private static func component(_ u: String) -> Calendar.Component {
        switch u {
        case let x where x.hasPrefix("w") || x.hasPrefix("週"): .weekOfYear
        case let x where x.hasPrefix("mo") || x.hasSuffix("月"): .month
        case let x where x.hasPrefix("y") || x == "年": .year
        default: .day
        }
    }

    private static let weekdayNames: [String: Int] = [
        "sunday": 1, "sun": 1, "日曜": 1, "日曜日": 1, "monday": 2, "mon": 2, "月曜": 2, "月曜日": 2, "tuesday": 3, "tue": 3, "火曜": 3, "火曜日": 3,
        "wednesday": 4, "wed": 4, "水曜": 4, "水曜日": 4, "thursday": 5, "thu": 5, "木曜": 5, "木曜日": 5, "friday": 6, "fri": 6, "金曜": 6, "金曜日": 6,
        "saturday": 7, "sat": 7, "土曜": 7, "土曜日": 7, "weekend": 7, "週末": 7,
    ]

    /// "christmas", "friday", "dec 25", "2026-12-25", "12/25", "12月25日" → that day.
    static func parseDay(_ raw: String, future: Bool?, strict: Bool = false) -> Date? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "next ", with: "")
        let year = cal.component(.year, from: today)
        func upcoming(_ month: Int, _ day: Int) -> Date? {
            guard var d = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            if future != false, d < today { d = cal.date(byAdding: .year, value: 1, to: d) ?? d }
            if future == false, d > today { d = cal.date(byAdding: .year, value: -1, to: d) ?? d }
            return d
        }
        if !strict {
            let named: [String: (Int, Int)] = ["christmas": (12, 25), "xmas": (12, 25), "クリスマス": (12, 25), "christmas eve": (12, 24), "イブ": (12, 24),
                                               "new year": (1, 1), "new years": (1, 1), "new year's": (1, 1), "正月": (1, 1), "お正月": (1, 1), "元日": (1, 1),
                                               "halloween": (10, 31), "ハロウィン": (10, 31), "valentine": (2, 14), "valentines": (2, 14),
                                               "valentine's day": (2, 14), "バレンタイン": (2, 14), "white day": (3, 14), "ホワイトデー": (3, 14),
                                               "new year's eve": (12, 31), "大晦日": (12, 31), "tanabata": (7, 7), "七夕": (7, 7)]
            if let (m, d) = named[t] { return upcoming(m, d) }
            if let wd = weekdayNames[t] {
                return cal.nextDate(after: today, matching: DateComponents(weekday: wd), matchingPolicy: .nextTime,
                                    direction: future == false ? .backward : .forward)
            }
            if t == "tomorrow" || t == "明日" { return cal.date(byAdding: .day, value: 1, to: today) }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.isLenient = false
        let withYear = ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy/M/d", "yyyy.MM.dd", "yyyy-M-d", "MMM d yyyy", "MMM d, yyyy", "MMMM d yyyy", "MMMM d, yyyy",
                        "d MMM yyyy", "d MMMM yyyy", "yyyy年M月d日", "M/d/yyyy"]
        for f in withYear {
            df.dateFormat = f
            if let d = df.date(from: raw.trimmingCharacters(in: .whitespaces)) { return cal.startOfDay(for: d) }
        }
        var noYear = ["MMM d", "MMMM d", "d MMM", "d MMMM", "M月d日"]
        if !strict { noYear += ["M/d", "M-d"] }
        for f in noYear {
            df.dateFormat = f
            if let d = df.date(from: raw.trimmingCharacters(in: .whitespaces)) {
                let c = cal.dateComponents([.month, .day], from: d)
                return upcoming(c.month ?? 1, c.day ?? 1)
            }
        }
        if !strict, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let hit = det.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)), let d = hit.date {
            return cal.startOfDay(for: d)
        }
        return nil
    }

    private static func relative(_ d: Date) -> String {
        let cal = Calendar.current
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
        switch n {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case let x where x > 0: return "In \(fmt(Double(x))) days"
        default: return "\(fmt(Double(-n))) days ago"
        }
    }

    private static func era(_ d: Date) -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .japanese)
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "Gy年M月d日"
        return df.string(from: d).replacingOccurrences(of: #"(\D)1年"#, with: "$1元年", options: .regularExpression)
    }

    private static func dayRow(_ d: Date) -> Answer {
        let df = DateFormatter()
        df.dateStyle = .full
        let iso = Calendar(identifier: .iso8601)
        let week = iso.component(.weekOfYear, from: d)
        let cal = Calendar.current
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: d) ?? 0
        let daysInYear = cal.range(of: .day, in: .year, for: d)?.count ?? 365
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let main = DateFormatter()
        main.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        let iso8601 = f.string(from: d)
        return Answer(title: df.string(from: d), subtitle: "\(relative(d)) · Week \(week) · Day \(dayOfYear) of \(daysInYear) · \(era(d))",
                      symbol: "calendar", color: .systemRed, action: .copy(iso8601),
                      card: .big(.init(title: "Date", symbol: "calendar", color: .systemRed, caption: relative(d), value: main.string(from: d),
                                       unit: "\(cal.component(.year, from: d))", detail: "Week \(week) · Day \(dayOfYear) of \(daysInYear)",
                                       chips: [.init(label: "ISO", value: iso8601, action: .copy(iso8601)), .init(label: "和暦", value: era(d), action: .copy(era(d))),
                                               .init(label: "", value: df.string(from: d), action: .copy(df.string(from: d)))])))
    }

    private static func countRow(_ d: Date, name: String) -> Answer {
        let cal = Calendar.current
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: d).day ?? 0
        let df = DateFormatter()
        df.dateStyle = .full
        let weeks = abs(n) / 7, rest = abs(n) % 7
        let span = weeks > 0 ? " · \(weeks) week\(weeks == 1 ? "" : "s")" + (rest > 0 ? " \(rest) day\(rest == 1 ? "" : "s")" : "") : ""
        let title = n == 0 ? "Today" : n > 0 ? "\(fmt(Double(n))) day\(n == 1 ? "" : "s") until \(name.capitalized)" : "\(fmt(Double(-n))) day\(n == -1 ? "" : "s") since \(name.capitalized)"
        return Answer(title: title, subtitle: df.string(from: d) + span, symbol: "calendar.badge.clock", color: .systemRed, action: .copy("\(abs(n))"),
                      card: .big(.init(title: "Countdown", symbol: "calendar.badge.clock", color: .systemRed,
                                       caption: n == 0 ? nil : (n > 0 ? "Until " : "Since ") + name.capitalized, value: n == 0 ? "Today" : fmt(Double(abs(n))),
                                       unit: n == 0 ? nil : abs(n) == 1 ? "day" : "days", detail: df.string(from: d) + span)))
    }

    private static func eraRow(_ year: Int, _ day: Date?) -> Answer {
        let cal = Calendar.current
        let d = day ?? cal.date(from: DateComponents(year: year, month: 7, day: 1))!
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .japanese)
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "Gy年"
        let name = df.string(from: d).replacingOccurrences(of: #"(\D)1年"#, with: "$1元年", options: .regularExpression)
        // Years when the era changed have two names.
        let changes: [Int: String] = [2019: "平成31年 / 令和元年 (from May 1)", 1989: "昭和64年 / 平成元年 (from Jan 8)", 1926: "大正15年 / 昭和元年 (from Dec 25)", 1912: "明治45年 / 大正元年 (from Jul 30)"]
        let title = day.map { era($0) } ?? changes[year] ?? name
        return Answer(title: title, subtitle: "\(year) in the Japanese calendar", symbol: "calendar", color: .systemRed, action: .copy(title),
                      card: .big(.init(title: "Japanese era", symbol: "calendar", color: .systemRed, caption: "\(year) =", value: title)))
    }

    // MARK: Time zones

    private static let cities: [(String, String, String)] = [
        ("Tokyo", "Asia/Tokyo", "tokyo|東京|jst|japan|日本|とうきょう"), ("Osaka", "Asia/Tokyo", "osaka|大阪"), ("Seoul", "Asia/Seoul", "seoul|ソウル|kst|korea|韓国"),
        ("Beijing", "Asia/Shanghai", "beijing|北京|china|中国"), ("Shanghai", "Asia/Shanghai", "shanghai|上海"), ("Hong Kong", "Asia/Hong_Kong", "hong kong|hongkong|香港|hkt"),
        ("Taipei", "Asia/Taipei", "taipei|台北|taiwan|台湾"), ("Singapore", "Asia/Singapore", "singapore|シンガポール|sgt"), ("Bangkok", "Asia/Bangkok", "bangkok|バンコク|thailand|タイ"),
        ("Jakarta", "Asia/Jakarta", "jakarta|ジャカルタ|indonesia"), ("Bali", "Asia/Makassar", "bali|バリ"), ("Manila", "Asia/Manila", "manila|マニラ|philippines|フィリピン"),
        ("Ho Chi Minh City", "Asia/Ho_Chi_Minh", "ho chi minh|saigon|hanoi|vietnam|ベトナム|ハノイ"), ("Kuala Lumpur", "Asia/Kuala_Lumpur", "kuala lumpur|kl|malaysia|マレーシア"),
        ("Delhi", "Asia/Kolkata", "delhi|new delhi|mumbai|bangalore|india|インド|ist"), ("Dubai", "Asia/Dubai", "dubai|ドバイ|uae|gst|abu dhabi"),
        ("Moscow", "Europe/Moscow", "moscow|モスクワ|russia|msk"), ("Istanbul", "Europe/Istanbul", "istanbul|イスタンブール|turkey|トルコ"),
        ("London", "Europe/London", "london|ロンドン|uk|england|イギリス|gmt|bst|britain"), ("Dublin", "Europe/Dublin", "dublin|ireland"),
        ("Paris", "Europe/Paris", "paris|パリ|france|フランス|cet|cest"), ("Berlin", "Europe/Berlin", "berlin|ベルリン|germany|ドイツ|munich|frankfurt"),
        ("Madrid", "Europe/Madrid", "madrid|マドリード|spain|スペイン|barcelona"), ("Rome", "Europe/Rome", "rome|ローマ|italy|イタリア|milan"),
        ("Amsterdam", "Europe/Amsterdam", "amsterdam|netherlands|オランダ"), ("Zurich", "Europe/Zurich", "zurich|switzerland|スイス|geneva"),
        ("Stockholm", "Europe/Stockholm", "stockholm|sweden|スウェーデン"), ("Helsinki", "Europe/Helsinki", "helsinki|finland|フィンランド"),
        ("Athens", "Europe/Athens", "athens|greece|ギリシャ"), ("Cairo", "Africa/Cairo", "cairo|egypt|エジプト"), ("Nairobi", "Africa/Nairobi", "nairobi|kenya"),
        ("Johannesburg", "Africa/Johannesburg", "johannesburg|south africa|cape town"), ("Lagos", "Africa/Lagos", "lagos|nigeria"),
        ("New York", "America/New_York", "new york|nyc|ny|ニューヨーク|est|edt|eastern|boston|washington|dc|miami|atlanta|toronto|トロント"),
        ("Chicago", "America/Chicago", "chicago|シカゴ|cst|cdt|central|dallas|houston|texas"), ("Denver", "America/Denver", "denver|mst|mdt|mountain"),
        ("Phoenix", "America/Phoenix", "phoenix|arizona"),
        ("Los Angeles", "America/Los_Angeles", "los angeles|la|ロサンゼルス|ロス|pst|pdt|pacific|san francisco|sf|サンフランシスコ|seattle|シアトル|vancouver|silicon valley|california"),
        ("Honolulu", "Pacific/Honolulu", "honolulu|hawaii|ハワイ|hst"), ("Anchorage", "America/Anchorage", "anchorage|alaska"),
        ("Mexico City", "America/Mexico_City", "mexico city|mexico|メキシコ"), ("São Paulo", "America/Sao_Paulo", "sao paulo|são paulo|brazil|ブラジル|rio"),
        ("Buenos Aires", "America/Argentina/Buenos_Aires", "buenos aires|argentina"), ("Lima", "America/Lima", "lima|peru"),
        ("Sydney", "Australia/Sydney", "sydney|シドニー|aest|aedt|melbourne|メルボルン|australia|オーストラリア"), ("Brisbane", "Australia/Brisbane", "brisbane"),
        ("Perth", "Australia/Perth", "perth"), ("Auckland", "Pacific/Auckland", "auckland|new zealand|nz|ニュージーランド"), ("Guam", "Pacific/Guam", "guam|グアム"),
        ("UTC", "UTC", "utc|zulu|z"),
    ]

    private static let cityIndex: [String: (String, String)] = {
        var d: [String: (String, String)] = [:]
        for (name, id, aliases) in cities {
            for a in aliases.split(separator: "|") { d[String(a)] = (name, id) }
        }
        return d
    }()

    static func zone(_ raw: String) -> (name: String, tz: TimeZone)? {
        let k = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return nil }
        if ["local", "here", "me", "my time", "ここ"].contains(k) { return (localName, .current) }
        if let (n, id) = cityIndex[k], let tz = TimeZone(identifier: id) { return (n, tz) }
        if let m = rx(#"^(?:utc|gmt)\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?$"#, k), let h = Int(m[2]) {
            let secs = (h * 3600 + (Int(m[3]) ?? 0) * 60) * (m[1] == "-" ? -1 : 1)
            if let tz = TimeZone(secondsFromGMT: secs) { return (raw.uppercased(), tz) }
        }
        if k.count >= 3, let id = TimeZone.knownTimeZoneIdentifiers.first(where: { ($0.split(separator: "/").last ?? "").replacingOccurrences(of: "_", with: " ").lowercased() == k }),
           let tz = TimeZone(identifier: id) {
            return (String(id.split(separator: "/").last ?? "").replacingOccurrences(of: "_", with: " "), tz)
        }
        return nil
    }

    static var localName: String {
        let id = TimeZone.current.identifier
        return cities.first { $0.1 == id }?.0 ?? String(id.split(separator: "/").last ?? "").replacingOccurrences(of: "_", with: " ")
    }

    private static func timeZones(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        if ["time", "clock", "world clock", "what time is it", "時間", "時刻", "今何時", "いま何時", "何時", "世界時計"].contains(l) {
            var clocks = [ToolCard.Clock(name: localName, zone: .current, here: true)]
            for c in s.worldClocks {
                if let z = zone(c), z.tz.identifier != TimeZone.current.identifier { clocks.append(.init(name: z.name, zone: z.tz)) }
            }
            var row = clockRow(localName, .current)
            row.card = .clocks(Array(clocks.prefix(4)), convert: false)
            return [row]
        }
        if let m = rx(#"^(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.|時)?\s*(.*?)\s+(?:to|in|into|→|->)\s+(.+)$"#, l) {
            let hasMarker = !m[2].isEmpty || !m[3].isEmpty || !m[4].isEmpty
            let from: (name: String, tz: TimeZone)? = m[4].isEmpty ? (localName, .current) : zone(m[4])
            if hasMarker, let to = zone(m[5]), let from, var h = Int(m[1]) {
                let ampm = m[3].replacingOccurrences(of: ".", with: "")
                if ampm == "pm", h < 12 { h += 12 }
                if ampm == "am", h == 12 { h = 0 }
                guard h < 24 else { return [] }
                var fc = Calendar.current
                fc.timeZone = from.tz
                var comps = fc.dateComponents([.year, .month, .day], from: Date())
                comps.hour = h
                comps.minute = Int(m[2]) ?? 0
                guard let date = fc.date(from: comps) else { return [] }
                let out = clockString(date, to.tz, weekday: true)
                let here = TimeZone.current.identifier
                return [Answer(title: "\(out) in \(to.name)", subtitle: "\(clockString(date, from.tz, weekday: true)) in \(from.name)", symbol: "clock.arrow.2.circlepath", color: .systemIndigo, action: .copy(out),
                               card: .clocks([.init(name: from.name, zone: from.tz, at: date, here: from.tz.identifier == here),
                                              .init(name: to.name, zone: to.tz, at: date, here: to.tz.identifier == here)], convert: true))]
            }
        }
        var place: String?
        if let m = rx(#"^(?:time|clock|what time is it|current time)\s+(?:in\s+|at\s+)?(.+?)\??$"#, l) { place = m[1] }
        else if let m = rx(#"^(.+?)\s+(?:time|clock)$"#, l) { place = m[1] }
        else if let m = rx(#"^(.+?)\s*(?:の)?(?:時間|時刻|今何時|いま何時|何時)$"#, l) { place = m[1] }
        else if l.count >= 3, cityIndex[l] != nil { place = l }
        guard let p = place, let z = zone(p) else { return [] }
        var row = clockRow(z.name, z.tz)
        let same = z.tz.secondsFromGMT() == TimeZone.current.secondsFromGMT()
        row.card = .clocks([.init(name: z.name, zone: z.tz, here: same)] + (same ? [] : [.init(name: localName, zone: .current, here: true)]), convert: false)
        return [row]
    }

    private static func clockString(_ d: Date, _ tz: TimeZone, weekday: Bool) -> String {
        let df = DateFormatter()
        df.timeZone = tz
        df.timeStyle = .short
        df.dateStyle = .none
        var s = df.string(from: d)
        if weekday {
            let w = DateFormatter()
            w.timeZone = tz
            w.dateFormat = "EEE"
            s += " " + w.string(from: d)
        }
        return s
    }

    private static func clockRow(_ name: String, _ tz: TimeZone) -> Answer {
        let now = Date()
        let diff = Double(tz.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 3600
        let hours = diff == diff.rounded() ? "\(Int(abs(diff)))" : String(format: "%.1f", abs(diff))
        let rel = diff == 0 ? "Same time as here" : "\(hours) hour\(abs(diff) == 1 ? "" : "s") \(diff > 0 ? "ahead" : "behind")"
        let off = tz.secondsFromGMT(for: now)
        let gmt = String(format: "GMT%@%d", off >= 0 ? "+" : "-", abs(off) / 3600) + (off % 3600 != 0 ? ":\(String(format: "%02d", abs(off) % 3600 / 60))" : "")
        let df = DateFormatter()
        df.timeZone = tz
        df.dateFormat = "EEEE, MMM d"
        let time = clockString(now, tz, weekday: false)
        return Answer(title: "\(time)  \(name)", subtitle: "\(df.string(from: now)) · \(gmt) · \(rel)", symbol: "clock.fill", color: .systemIndigo, action: .copy(time))
    }

    // MARK: Currency

    static let currencyCodes: Set<String> = ["USD", "EUR", "JPY", "GBP", "AUD", "CAD", "CHF", "CNY", "HKD", "KRW", "SGD", "THB", "INR", "IDR", "MYR", "PHP",
                                             "NZD", "SEK", "NOK", "DKK", "PLN", "CZK", "HUF", "RON", "BGN", "TRY", "ILS", "MXN", "BRL", "ZAR", "ISK",
                                             "BTC", "ETH", "SOL", "XRP", "DOGE"]
    static let crypto: [String: String] = ["BTC": "bitcoin", "ETH": "ethereum", "SOL": "solana", "XRP": "ripple", "DOGE": "dogecoin"]
    private static let currencyAliases: [String: String] = [
        "$": "USD", "dollar": "USD", "dollars": "USD", "ドル": "USD", "米ドル": "USD", "bucks": "USD",
        "¥": "JPY", "yen": "JPY", "円": "JPY", "えん": "JPY", "€": "EUR", "euro": "EUR", "euros": "EUR", "ユーロ": "EUR",
        "£": "GBP", "pound": "GBP", "pounds": "GBP", "ポンド": "GBP", "₩": "KRW", "won": "KRW", "ウォン": "KRW",
        "元": "CNY", "yuan": "CNY", "rmb": "CNY", "人民元": "CNY", "baht": "THB", "バーツ": "THB", "rupee": "INR", "rupees": "INR", "ルピー": "INR",
        "₿": "BTC", "bitcoin": "BTC", "ビットコイン": "BTC", "ethereum": "ETH", "ether": "ETH", "イーサリアム": "ETH", "solana": "SOL", "ripple": "XRP", "dogecoin": "DOGE",
        "a$": "AUD", "c$": "CAD", "hk$": "HKD", "s$": "SGD", "franc": "CHF", "francs": "CHF", "peso": "MXN", "pesos": "MXN", "real": "BRL", "reais": "BRL",
    ]

    static func currencyCode(_ raw: String) -> String? {
        let k = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let a = currencyAliases[k] { return a }
        let up = k.uppercased()
        return currencyCodes.contains(up) ? up : nil
    }

    private static func currency(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        // "btc", "usd", "ドル" alone → the rate.
        if let code = currencyCode(l), !["real", "won", "try", "php", "franc", "peso", "pound", "pounds"].contains(l) {
            let to = code == s.homeCurrency ? (code == "USD" ? "EUR" : "USD") : s.homeCurrency
            return LiveData.shared.convert(1, from: code, to: [to] + (code != "USD" && to != "USD" ? ["USD"] : []))
        }
        let l = l.replacingOccurrences(of: "何円", with: "円").replacingOccurrences(of: "何ドル", with: "ドル").replacingOccurrences(of: "いくら", with: "")
        let cur = #"([$¥€£₩₿]|[a-z]{3,8}|a\$|c\$|hk\$|s\$|\p{Han}{1,4}|[\p{Katakana}ー]{1,6}|えん)"#
        guard let m = rx(#"^"# + cur + #"?\s*(\d[\d,]*\.?\d*|\.\d+)\s*(k|m|千|万|億|man)?\s*"# + cur + #"?\s*(?:(?:to|in|into|→|->|=|は|を)\s*"# + cur + #")?\s*(?:に|で|いくら|何円)*\??$"#, l),
              var amount = number(m[2]) else { return [] }
        let fromRaw = m[1].isEmpty ? m[4] : m[1]
        guard let from = currencyCode(fromRaw) else { return [] }
        switch m[3] {
        case "k", "千": amount *= 1_000
        case "m": amount *= 1_000_000
        case "万", "man": amount *= 10_000
        case "億": amount *= 100_000_000
        default: break
        }
        if !m[1].isEmpty, !m[4].isEmpty, currencyCode(m[4]) == nil { return [] }
        var targets: [String]
        if !m[5].isEmpty {
            guard let to = currencyCode(m[5]) else { return [] }
            targets = [to]
        } else {
            let home = s.homeCurrency
            targets = from == home ? (home == "USD" ? ["EUR", "JPY"] : ["USD", "EUR"]) : [home] + (from != "USD" && home != "USD" ? ["USD"] : [])
        }
        targets.removeAll { $0 == from }
        guard !targets.isEmpty else { return [] }
        return LiveData.shared.convert(amount, from: from, to: targets)
    }

    /// "¥15,796" (the code goes beside it).
    static func moneyValue(_ v: Double, _ code: String) -> String {
        let digits = code == "JPY" || code == "KRW" || code == "IDR" || code == "HUF" ? 0 : crypto[code] != nil ? 8 : 2
        let symbols: [String: String] = ["USD": "$", "EUR": "€", "JPY": "¥", "GBP": "£", "KRW": "₩", "CNY": "¥", "INR": "₹", "BTC": "₿"]
        let n = abs(v) < 1 && digits == 0 ? fmt(v, digits: 2) : fmt(v, digits: digits)
        return (symbols[code] ?? "") + n
    }

    static func money(_ v: Double, _ code: String) -> String {
        let digits = code == "JPY" || code == "KRW" || code == "IDR" || code == "HUF" ? 0 : crypto[code] != nil ? 8 : 2
        let symbols: [String: String] = ["USD": "$", "EUR": "€", "JPY": "¥", "GBP": "£", "KRW": "₩", "CNY": "¥", "INR": "₹", "BTC": "₿"]
        let n = abs(v) < 1 && digits == 0 ? fmt(v, digits: 2) : fmt(v, digits: digits)
        return (symbols[code].map { $0 + n } ?? n) + " " + code
    }

    // MARK: Units

    private static var unitIndex: [String: Dimension] = {
        var d: [String: Dimension] = [:]
        func add(_ u: Dimension, _ names: String) { for n in names.split(separator: "|") { d[String(n)] = u } }
        add(UnitLength.millimeters, "mm|millimeter|millimeters|millimetre|ミリ|ミリメートル")
        add(UnitLength.centimeters, "cm|centimeter|centimeters|centimetre|センチ|センチメートル")
        add(UnitLength.meters, "m|meter|meters|metre|metres|メートル")
        add(UnitLength.kilometers, "km|kilometer|kilometers|kilometre|kilometres|キロメートル|キロ")
        add(UnitLength.inches, "in|inch|inches|\"|インチ")
        add(UnitLength.feet, "ft|foot|feet|'|フィート")
        add(UnitLength.yards, "yd|yard|yards|ヤード")
        add(UnitLength.miles, "mi|mile|miles|マイル")
        add(UnitLength.nauticalMiles, "nmi|nautical mile|nautical miles")
        add(UnitLength(symbol: "尺", converter: UnitConverterLinear(coefficient: 0.30303)), "尺|shaku")
        add(UnitMass.milligrams, "mg|milligram|milligrams")
        add(UnitMass.grams, "g|gram|grams|gramme|グラム")
        add(UnitMass.kilograms, "kg|kgs|kilo|kilos|kilogram|kilograms|キログラム")
        add(UnitMass.metricTons, "t|ton|tons|tonne|tonnes|トン")
        add(UnitMass.ounces, "oz|ounce|ounces|オンス")
        add(UnitMass.pounds, "lb|lbs|pound|pounds|ポンド")
        add(UnitMass.stones, "st|stone|stones")
        add(UnitTemperature.celsius, "c|°c|celsius|centigrade|度|℃|摂氏")
        add(UnitTemperature.fahrenheit, "f|°f|fahrenheit|℉|華氏")
        add(UnitTemperature.kelvin, "k|kelvin")
        add(UnitVolume.milliliters, "ml|milliliter|milliliters|millilitre|cc|ミリリットル")
        add(UnitVolume.centiliters, "cl|centiliter|centiliters")
        add(UnitVolume.deciliters, "dl|deciliter|deciliters")
        add(UnitVolume.liters, "l|liter|liters|litre|litres|リットル")
        add(UnitVolume.teaspoons, "tsp|teaspoon|teaspoons|小さじ")
        add(UnitVolume.tablespoons, "tbsp|tablespoon|tablespoons|大さじ")
        add(UnitVolume.cups, "cup|cups|カップ")
        add(UnitVolume.fluidOunces, "floz|fl.oz|fluid ounce|fluid ounces")
        add(UnitVolume.pints, "pt|pint|pints")
        add(UnitVolume.quarts, "qt|quart|quarts")
        add(UnitVolume.gallons, "gal|gallon|gallons|ガロン")
        add(UnitVolume(symbol: "合", converter: UnitConverterLinear(coefficient: 0.180391)), "合|gou|go")
        add(UnitSpeed.kilometersPerHour, "km/h|kmh|kph|kmph|時速")
        add(UnitSpeed.milesPerHour, "mph|mi/h")
        add(UnitSpeed.metersPerSecond, "m/s|mps")
        add(UnitSpeed.knots, "kn|kt|knot|knots|ノット")
        add(UnitArea.squareMeters, "m2|m²|sqm|square meter|square meters|平米|平方メートル|㎡")
        add(UnitArea.squareKilometers, "km2|km²|square kilometer|square kilometers")
        add(UnitArea.squareFeet, "ft2|ft²|sqft|sq ft|square foot|square feet")
        add(UnitArea.hectares, "ha|hectare|hectares|ヘクタール")
        add(UnitArea.acres, "acre|acres|エーカー")
        add(UnitArea(symbol: "坪", converter: UnitConverterLinear(coefficient: 3.305785)), "坪|tsubo")
        add(UnitArea(symbol: "畳", converter: UnitConverterLinear(coefficient: 1.62)), "畳|jo|帖")
        add(UnitInformationStorage.bytes, "b|byte|bytes|バイト")
        add(UnitInformationStorage.kilobytes, "kb|kilobyte|kilobytes")
        add(UnitInformationStorage.megabytes, "mb|megabyte|megabytes|メガ")
        add(UnitInformationStorage.gigabytes, "gb|gigabyte|gigabytes|ギガ")
        add(UnitInformationStorage.terabytes, "tb|terabyte|terabytes|テラ")
        add(UnitInformationStorage.kibibytes, "kib|kibibyte|kibibytes")
        add(UnitInformationStorage.mebibytes, "mib|mebibyte|mebibytes")
        add(UnitInformationStorage.gibibytes, "gib|gibibyte|gibibytes")
        add(UnitInformationStorage.bits, "bit|bits")
        add(UnitInformationStorage.megabits, "mbit|mbps|megabit|megabits")
        add(UnitDuration.milliseconds, "ms|millisecond|milliseconds|ミリ秒")
        add(UnitDuration.seconds, "s|sec|secs|second|seconds|秒")
        add(UnitDuration.minutes, "min|mins|minute|minutes|分")
        add(UnitDuration.hours, "h|hr|hrs|hour|hours|時間")
        add(UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400)), "day|days|日")
        add(UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800)), "week|weeks|週間")
        add(UnitDuration(symbol: "yr", converter: UnitConverterLinear(coefficient: 31_557_600)), "year|years|年")
        add(UnitEnergy.kilocalories, "kcal|calorie|calories|cal|キロカロリー|カロリー")
        add(UnitEnergy.kilojoules, "kj|kilojoule|kilojoules")
        add(UnitEnergy.kilowattHours, "kwh|kilowatt hour|kilowatt hours")
        add(UnitPressure.hectopascals, "hpa|hectopascal|hectopascals|ヘクトパスカル")
        add(UnitPressure.kilopascals, "kpa|kilopascal|kilopascals")
        add(UnitPressure.poundsForcePerSquareInch, "psi")
        add(UnitPressure.bars, "bar|bars")
        add(UnitPressure.inchesOfMercury, "inhg")
        add(UnitAngle.degrees, "deg|degree|degrees|°")
        add(UnitAngle.radians, "rad|radian|radians")
        add(UnitFuelEfficiency.milesPerGallon, "mpg")
        add(UnitFuelEfficiency.litersPer100Kilometers, "l/100km")
        return d
    }()

    /// Where a unit converts to when you don't say ("10 km" → mi).
    private static let defaultTarget: [String: String] = [
        "mm": "in", "cm": "in", "m": "ft", "km": "mi", "in": "cm", "ft": "m", "yd": "m", "mi": "km", "NM": "km", "尺": "cm",
        "mg": "g", "g": "oz", "kg": "lb", "t": "lb", "oz": "g", "lb": "kg", "st": "kg",
        "°C": "f", "°F": "c", "K": "c",
        "mL": "floz", "cL": "floz", "dL": "cup", "L": "gal", "tsp": "ml", "tbsp": "ml", "cup": "ml", "fl oz": "ml", "pt": "ml", "qt": "l", "gal": "l", "合": "ml",
        "km/h": "mph", "mph": "km/h", "m/s": "km/h", "kn": "km/h",
        "m²": "sqft", "km²": "mi2", "ft²": "m2", "ha": "acre", "ac": "ha", "坪": "m2", "畳": "m2",
        "B": "kb", "kB": "mb", "MB": "gb", "GB": "mb", "TB": "gb", "KiB": "kb", "MiB": "mb", "GiB": "gb", "bit": "b", "Mb": "mb",
        "ms": "s", "s": "min", "min": "h", "hr": "min", "d": "h", "wk": "day", "yr": "day",
        "kCal": "kj", "kJ": "kcal", "kWh": "kj", "hPa": "inhg", "kPa": "psi", "psi": "bar", "bar": "psi", "inHg": "hpa",
        "°": "rad", "rad": "deg", "mpg": "l/100km", "L/100km": "mpg", "sec": "min",
    ]

    private static func unit(_ raw: String) -> Dimension? {
        var k = raw.trimmingCharacters(in: .whitespaces).lowercased()
        k = k.replacingOccurrences(of: "degrees ", with: "°").replacingOccurrences(of: "square ", with: "sq ")
        if k == "sq ft" || k == "sq feet" { k = "sqft" }
        if k == "sq m" || k == "sq meters" { k = "m2" }
        if k == "sq mi" || k == "sq miles" { return UnitArea.squareMiles }
        if k == "mi2" || k == "mi²" { return UnitArea.squareMiles }
        if k == "fl oz" { k = "floz" }
        return unitIndex[k] ?? unitIndex[k.replacingOccurrences(of: "°", with: "")]
    }

    /// The kind of quantity and the units worth showing next to an answer.
    private static func family(_ u: Dimension) -> (name: String, others: [String]) {
        switch u {
        case is UnitLength: ("Length", ["km", "m", "cm", "mi", "ft", "in"])
        case is UnitMass: ("Weight", ["kg", "g", "lb", "oz"])
        case is UnitTemperature: ("Temperature", ["c", "f", "kelvin"])
        case is UnitVolume: ("Volume", ["l", "ml", "cup", "floz", "gal"])
        case is UnitSpeed: ("Speed", ["km/h", "mph", "m/s", "kn"])
        case is UnitArea: ("Area", ["m2", "sqft", "坪", "畳", "ha"])
        case is UnitInformationStorage: ("Data", ["tb", "gb", "mb", "kb"])
        case is UnitDuration: ("Time", ["sec", "min", "h", "day", "week"])
        case is UnitEnergy: ("Energy", ["kcal", "kj", "kwh"])
        case is UnitPressure: ("Pressure", ["hpa", "kpa", "psi", "bar", "inhg"])
        case is UnitAngle: ("Angle", ["deg", "rad"])
        case is UnitFuelEfficiency: ("Fuel", ["l/100km", "mpg"])
        default: ("Units", [])
        }
    }

    private static func units(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        // 5'11" → cm
        if let m = rx(#"^(\d)'\s*(\d{1,2}(?:\.\d+)?)(?:"|”|'')?$"#, l), let ft = Double(m[1]), let inch = Double(m[2]) {
            let cm = (ft * 12 + inch) * 2.54
            return [Answer(title: "\(fmt(cm, digits: 1)) cm", subtitle: "\(m[1]) ft \(m[2]) in", symbol: "ruler", color: .systemTeal, action: .copy(plain(cm, digits: 1)))]
        }
        let numberPart = #"(-?\d[\d,]*\.?\d*|-?\.\d+)"#
        guard let m = rx(#"^"# + numberPart + #"\s*([^\d\s].*?)\s*(?:(?:\s(?:to|in|into|as|in to)\s|→|->|=|は|を)\s*(.+?))?\s*(?:に|で|何.*)?$"#, l),
              let v = number(m[1]) else { return [] }
        var fromText = m[2], toText = m[3]
        if toText.isEmpty, unit(fromText) == nil, let space = fromText.lastIndex(of: " ") {
            // "2 in cm", "10 km mi"
            toText = String(fromText[fromText.index(after: space)...])
            fromText = String(fromText[..<space])
        }
        guard let from = unit(fromText) else { return [] }
        var targets: [Dimension] = []
        if !toText.isEmpty {
            guard let t = unit(toText) else { return [] }
            targets = [t]
        } else if let key = defaultTarget[from.symbol], let t = unit(key) {
            targets = [t]
        }
        let fam = family(from)
        let rows: [Answer] = targets.compactMap { to -> Answer? in
            // Same kind of quantity (built-in units are private subclasses, so compare base units).
            guard type(of: to).baseUnit().symbol == type(of: from).baseUnit().symbol else { return nil }
            let base = from.converter.baseUnitValue(fromValue: v)
            let out = to.converter.value(fromBaseUnitValue: base)
            let digits = abs(out) >= 100 ? 2 : 4
            let title = "\(fmt(out, digits: digits)) \(to.symbol)"
            var detail: String?
            if to.symbol == "ft", from is UnitLength {
                let totalIn = base / 0.0254
                detail = "\(Int(totalIn / 12)) ft \(fmt(totalIn.truncatingRemainder(dividingBy: 12), digits: 1)) in"
            }
            let chips: [ToolCard.Chip] = fam.others.compactMap { alias in
                guard let u = unit(alias), u.symbol != from.symbol, u.symbol != to.symbol else { return nil }
                let x = u.converter.value(fromBaseUnitValue: base)
                return ToolCard.Chip(label: u.symbol, value: fmt(x, digits: abs(x) >= 100 ? 1 : 4), action: .copy(plain(x, digits: 4)))
            }
            let n = plain(v, digits: 6)
            let targetsMenu: [(String, Answer.Action)] = fam.others.compactMap { alias in
                guard let u = unit(alias), u.symbol != from.symbol else { return nil }
                return (u.symbol, .fill("\(n) \(from.symbol) to \(u.symbol)"))
            }
            let fromMenu: [(String, Answer.Action)] = fam.others.compactMap { alias in
                guard let u = unit(alias), u.symbol != to.symbol else { return nil }
                return (u.symbol, .fill("\(n) \(u.symbol) to \(to.symbol)"))
            }
            return Answer(title: title, subtitle: "\(fmt(v)) \(from.symbol) = \(fmt(out, digits: 6)) \(to.symbol)", symbol: "ruler", color: .systemTeal,
                          action: .copy(plain(out, digits: digits)),
                          card: .big(.init(title: "Units · \(fam.name)", symbol: "ruler", color: .systemTeal, caption: "\(fmt(v)) \(from.symbol) =",
                                           value: fmt(out, digits: digits), unit: to.symbol, detail: detail, chips: Array(chips.prefix(5)),
                                           controls: [.init(symbol: "arrow.right.circle", title: from.symbol, help: "Convert from", menu: fromMenu),
                                                      .init(symbol: "arrow.left.arrow.right", help: "Swap", action: .fill("\(plain(out, digits: 6)) \(to.symbol) to \(from.symbol)")),
                                                      .init(symbol: "ruler", title: to.symbol, help: "Convert to", menu: targetsMenu)])))
        }
        return rows
    }

    // MARK: Calculator

    /// Works out a typed sum ("12×8", "15% of 4800", "1,200 + 3"). Nil when it isn't one.
    static func evaluate(_ raw: String) -> Double? {
        let l = normalize(raw).lowercased()
        var e = l.hasPrefix("=") ? String(l.dropFirst()) : l
        if let m = rx(#"^([\d.,]+)\s*%\s*(?:of|の)\s*(.+)$"#, e) { e = "(\(m[1])/100)*(\(m[2]))" }
        e = e.replacingOccurrences(of: #"(\d),(\d{3})(?!\d)"#, with: "$1$2", options: .regularExpression)
        e = e.replacingOccurrences(of: #"(\d),(\d{3})(?!\d)"#, with: "$1$2", options: .regularExpression)
        e = e.replacingOccurrences(of: #"(?<=[\d)])\s*x\s*(?=[\d(])"#, with: "*", options: .regularExpression)
        for (a, b) in [("×", "*"), ("÷", "/"), ("−", "-"), ("–", "-"), ("**", "^"), ("√", "sqrt"), ("π", "pi"), ("＊", "*"), ("・", "*")] {
            e = e.replacingOccurrences(of: a, with: b)
        }
        return Calc.evaluate(e)
    }

    private static func calculator(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        guard let v = evaluate(q) else { return [] }
        let shown = fmt(v, digits: s.calcDecimals)
        var chips: [ToolCard.Chip] = []
        if v == v.rounded(), abs(v) < 1e12, abs(v) >= 1000 { chips.append(.init(label: "No commas", value: plain(v), action: .copy(plain(v)))) }
        if v != v.rounded() { chips.append(.init(label: "Rounded", value: fmt(v, digits: 2), action: .copy(plain(v, digits: 2)))) }
        chips.append(.init(label: "", value: "Keypad", action: .run(keepOpen: true) { enterScope(.calculator, q) }))
        return [Answer(title: "= " + shown, subtitle: q, symbol: "plus.forwardslash.minus", color: .systemOrange, action: .copy(plain(v)),
                       card: .big(.init(title: "Calculator", symbol: "plus.forwardslash.minus", color: .systemOrange, caption: q + " =", value: shown, chips: chips)))]
    }

    // MARK: Moon

    private static func moon(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        guard ["moon", "moon phase", "月齢", "月", "満月", "新月", "full moon", "new moon"].contains(l) else { return [] }
        let synodic = 29.530588853
        let ref = Date(timeIntervalSince1970: 947_182_440) // a new moon: 2000-01-06 18:14 UTC
        func phase(_ d: Date) -> Double {
            let days = d.timeIntervalSince(ref) / 86_400
            let p = days.truncatingRemainder(dividingBy: synodic) / synodic
            return p < 0 ? p + 1 : p
        }
        let p = phase(Date())
        let names = ["New moon", "Waxing crescent", "First quarter", "Waxing gibbous", "Full moon", "Waning gibbous", "Last quarter", "Waning crescent"]
        let emoji = ["🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘"]
        let i = Int((p * 8).rounded()) % 8
        let lit = Int(((1 - cos(2 * .pi * p)) / 2 * 100).rounded())
        let age = p * synodic
        let toFull = ((0.5 - p + 1).truncatingRemainder(dividingBy: 1)) * synodic
        let toNew = (1 - p) * synodic
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        let fullDate = df.string(from: Date().addingTimeInterval(toFull * 86_400))
        let newDate = df.string(from: Date().addingTimeInterval(toNew * 86_400))
        return [Answer(title: "\(names[i]) · \(lit)% lit", subtitle: String(format: "Moon age %.1f days (月齢 %.1f)", age, age), emoji: emoji[i], action: .copy(names[i]),
                       card: .moon(emoji: emoji[i], phase: names[i], detail: String(format: "%d%% lit · age %.1f days (月齢 %.1f)", lit, age, age),
                                   next: [("Full moon", "\(fullDate) · \(Int(toFull.rounded()))d"), ("New moon", "\(newDate) · \(Int(toNew.rounded()))d")]))]
    }

    // MARK: Holidays

    private static func holidays(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        guard ["holiday", "holidays", "祝日", "休日", "次の祝日", "next holiday", "japanese holidays", "public holidays", "祝日一覧"].contains(l) else { return [] }
        return LiveData.shared.holidays()
    }

    // MARK: System (info and actions)

    private static func system(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        SystemTools.answers(q, l, s)
    }
}

// MARK: - Calculator

/// A small expression parser: + − × ÷ ^ %, parentheses, functions (sqrt, sin, log…), pi and e.
/// Only answers when there is something to work out, so "1password" or a lone "42" stay app searches.
struct Calc {
    enum Tok: Equatable { case num(Double), id(String), op(Character), lp, rp, comma }

    private var toks: [Tok] = []
    private var i = 0

    private static let functions: Set<String> = ["sqrt", "cbrt", "abs", "ln", "log", "log2", "log10", "exp", "sin", "cos", "tan", "asin", "acos", "atan",
                                                 "sinh", "cosh", "tanh", "round", "floor", "ceil", "min", "max", "pow", "hypot"]
    private static let constants: [String: Double] = ["pi": .pi, "tau": 2 * .pi, "e": M_E, "phi": (1 + sqrt(5)) / 2]

    static func evaluate(_ s: String) -> Double? {
        var c = Calc()
        guard c.lex(s), !c.toks.isEmpty else { return nil }
        let worthIt = c.toks.contains { t in
            switch t {
            case .op, .lp: return true
            case .id(let n): return functions.contains(n) || (n.count > 1 && constants[n] != nil)
            default: return false
            }
        }
        guard worthIt, let v = c.expr(), c.i == c.toks.count, v.v.isFinite else { return nil }
        // "-5" or "(3)" alone isn't a calculation.
        if c.toks.count <= 3, case .num(let n)? = c.toks.last, n == abs(v.v) { return nil }
        return v.v
    }

    private struct V {
        var v: Double
        var pct = false
    }

    private mutating func lex(_ s: String) -> Bool {
        let chars = Array(s)
        var j = 0
        while j < chars.count {
            let ch = chars[j]
            if ch.isWhitespace { j += 1; continue }
            if ch.isNumber || ch == "." {
                var k = j
                while k < chars.count, chars[k].isNumber || chars[k] == "." { k += 1 }
                if k < chars.count, chars[k] == "e" || chars[k] == "E", k + 1 < chars.count,
                   chars[k + 1].isNumber || ((chars[k + 1] == "-" || chars[k + 1] == "+") && k + 2 < chars.count && chars[k + 2].isNumber) {
                    k += 2
                    while k < chars.count, chars[k].isNumber { k += 1 }
                }
                guard let n = Double(String(chars[j..<k])) else { return false }
                toks.append(.num(n))
                j = k
                continue
            }
            if ch.isLetter {
                var k = j
                while k < chars.count, chars[k].isLetter || chars[k].isNumber { k += 1 }
                let name = String(chars[j..<k]).lowercased()
                guard name == "mod" || Calc.functions.contains(name) || Calc.constants[name] != nil else { return false }
                toks.append(name == "mod" ? .op("m") : .id(name))
                j = k
                continue
            }
            switch ch {
            case "+", "-", "*", "/", "^", "%", "!", "°": toks.append(.op(ch))
            case "(", "[": toks.append(.lp)
            case ")", "]": toks.append(.rp)
            case ",": toks.append(.comma)
            default: return false
            }
            j += 1
        }
        return true
    }

    private func peek(_ k: Int = 0) -> Tok? { i + k < toks.count ? toks[i + k] : nil }

    private func startsValue(_ t: Tok?) -> Bool {
        switch t {
        case .num, .id, .lp: return true
        default: return false
        }
    }

    private mutating func expr() -> V? {
        guard var l = term() else { return nil }
        while case .op(let o)? = peek(), o == "+" || o == "-" {
            i += 1
            guard let r = term() else { return nil }
            let rv = r.pct ? l.v * r.v : r.v
            l = V(v: o == "+" ? l.v + rv : l.v - rv)
        }
        return l
    }

    private mutating func term() -> V? {
        guard var l = unary() else { return nil }
        while true {
            if case .op(let o)? = peek(), o == "*" || o == "/" || o == "m" || o == "%" {
                i += 1
                guard let r = unary() else { return nil }
                switch o {
                case "*": l = V(v: l.v * r.v)
                case "/": l = V(v: l.v / r.v)
                default: l = V(v: l.v.truncatingRemainder(dividingBy: r.v))
                }
            } else if startsValue(peek()) {
                // 2pi, 3(4+1)
                guard let r = unary() else { return nil }
                l = V(v: l.v * r.v)
            } else {
                return l
            }
        }
    }

    private mutating func unary() -> V? {
        if case .op(let o)? = peek(), o == "-" || o == "+" {
            i += 1
            guard let v = unary() else { return nil }
            return V(v: o == "-" ? -v.v : v.v, pct: v.pct)
        }
        return power()
    }

    private mutating func power() -> V? {
        guard let b = postfix() else { return nil }
        if case .op("^")? = peek() {
            i += 1
            guard let e = unary() else { return nil }
            return V(v: pow(b.v, e.v))
        }
        return b
    }

    private mutating func postfix() -> V? {
        guard var v = primary() else { return nil }
        while case .op(let o)? = peek() {
            if o == "%" {
                // "10 % 3" is a remainder; "10%" is a percentage.
                if startsValue(peek(1)) { break }
                i += 1
                v = V(v: v.v / 100, pct: true)
            } else if o == "!" {
                i += 1
                guard v.v >= 0, v.v <= 170, v.v == v.v.rounded() else { return nil }
                v = V(v: (1...max(1, Int(v.v))).reduce(1.0) { $0 * Double($1) })
            } else if o == "°" {
                i += 1
                v = V(v: v.v * .pi / 180)
            } else {
                break
            }
        }
        return v
    }

    private mutating func primary() -> V? {
        guard let t = peek() else { return nil }
        switch t {
        case .num(let n):
            i += 1
            return V(v: n)
        case .lp:
            i += 1
            guard let v = expr(), case .rp? = peek() else { return nil }
            i += 1
            return v
        case .id(let name):
            i += 1
            if let c = Calc.constants[name], !Calc.functions.contains(name) { return V(v: c) }
            var args: [Double] = []
            if case .lp? = peek() {
                i += 1
                while true {
                    guard let a = expr() else { return nil }
                    args.append(a.v)
                    if case .comma? = peek() { i += 1; continue }
                    guard case .rp? = peek() else { return nil }
                    i += 1
                    break
                }
            } else {
                // sqrt 16
                guard let a = power() else { return nil }
                args = [a.v]
            }
            return apply(name, args).map { V(v: $0) }
        default:
            return nil
        }
    }

    private func apply(_ f: String, _ a: [Double]) -> Double? {
        guard let x = a.first else { return nil }
        switch f {
        case "sqrt": return sqrt(x)
        case "cbrt": return cbrt(x)
        case "abs": return abs(x)
        case "ln": return log(x)
        case "log", "log10": return a.count == 2 ? log(a[1]) / log(x) : log10(x)
        case "log2": return log2(x)
        case "exp": return exp(x)
        case "sin": return sin(x)
        case "cos": return cos(x)
        case "tan": return tan(x)
        case "asin": return asin(x)
        case "acos": return acos(x)
        case "atan": return atan(x)
        case "sinh": return sinh(x)
        case "cosh": return cosh(x)
        case "tanh": return tanh(x)
        case "round": return a.count == 2 ? (x * pow(10, a[1])).rounded() / pow(10, a[1]) : x.rounded()
        case "floor": return floor(x)
        case "ceil": return ceil(x)
        case "min": return a.min()
        case "max": return a.max()
        case "pow": return a.count == 2 ? pow(x, a[1]) : nil
        case "hypot": return a.count == 2 ? hypot(x, a[1]) : nil
        default: return nil
        }
    }
}
