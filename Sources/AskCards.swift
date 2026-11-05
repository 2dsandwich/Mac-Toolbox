import AppKit
import AVFoundation
import Observation
import SwiftUI

/// Cards inside Ask's answers. The model puts a fenced ```card {json}``` block where a card says it better than
/// prose (weather, prices, places, steps, recipes…); the answer is split into text and cards as it streams, and a
/// card still arriving shows as a skeleton. Weather, money, stocks and clocks carry only what to look up: the
/// numbers come live from the same sources as the launcher's own cards. Code fences and Markdown tables are drawn
/// natively too.
@MainActor enum AskCards {
    static let prompt = """
    The app draws cards. When a question is one of the kinds below, answer with its card in a fenced block, for example:
    ```card
    {"type":"weather","place":"Osaka"}
    ```
    The card is the answer: add one short sentence only for what it doesn't show, and never repeat its contents. At most two cards.
    - weather {"place", "show":"rain" for umbrella questions}: live forecast. Don't search or write any numbers.
    - money {"amount","from","to"} currency or crypto as ISO codes (BTC, ETH): live rate, don't search.
    - stock {"symbol"} Yahoo Finance ticker (AAPL, 7203.T, ^N225, BTC-USD): live price and chart. Search only to explain a move.
    - time {"place","zone"} with an IANA zone; to convert a time add "at":"HH:mm" (24 h), "from","fromZone".
    - places {"title","items":[{"name","kind","rating","reviews","price","address","hours","open":true/false,"url"}]}: restaurants, cafés, bars, shops, sights; up to 5, from search results.
    - steps {"title","items":[{"title","detail"}]}: how to do something.
    - recipe {"title","serves","time","ingredients":[],"steps":[]}: how to cook or make a dish or drink.
    - score {"league","games":[{"home","away","homeScore","awayScore","status"}]}: results and live games.
    - timeline {"title","items":[{"when","what"}]}: schedules, histories, release dates.
    - facts {"title","subtitle","facts":[["label","value"]],"url"}: who or what someone or something is (a person, company, place, product); 4 to 6 facts.
    - phrase {"text","reading","lang" (BCP 47),"meaning"}: a translation or how to say something.
    Comparisons ("A vs B", "A or B", "difference between", "which is better") are always a Markdown table: a column per option, a row per point that matters, then one short line with the pick. No bullets. Code goes in a fenced block with its language.
    """

    /// A card's corner: round enough to sit calmly next to the question bubbles.
    static let radius: CGFloat = 14

    /// What sets a card apart from the text around it: a slightly darker well behind it, no line and no light fill.
    static var well: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.black.opacity(0.24))
    }

    static func head(_ type: String?) -> (symbol: String, title: String, color: NSColor) {
        switch type {
        case "weather": ("cloud.sun.fill", "Weather", .systemBlue)
        case "money": ("dollarsign.circle.fill", "Currency", .systemGreen)
        case "stock": ("chart.line.uptrend.xyaxis", "Stocks", .systemGreen)
        case "time": ("clock.fill", "World clock", .systemIndigo)
        case "places": ("mappin.and.ellipse", "Places", .systemRed)
        case "steps": ("list.number", "Steps", .systemTeal)
        case "recipe": ("fork.knife", "Recipe", .systemOrange)
        case "score": ("sportscourt.fill", "Scores", .systemGreen)
        case "timeline": ("calendar", "Timeline", .systemPurple)
        case "facts": ("text.book.closed.fill", "At a glance", .systemBrown)
        case "phrase": ("character.bubble.fill", "Translation", .systemPurple)
        default: ("sparkles", "Answer", .systemGray)
        }
    }

    static func open(_ url: URL) {
        (NSApp.delegate as? AppDelegate)?.launcher.hide()
        NSWorkspace.shared.open(url)
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// What a button on one of the launcher's cards does here (menus that refill the bar don't apply).
    static func perform(_ a: Answer.Action) {
        switch a {
        case .copy(let s), .copySecret(let s), .paste(let s): copy(s)
        case .open(let u): open(u)
        case .copyImage(let i):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([i])
        case .run(_, let f): f()
        case .fill, .none: break
        }
    }

    /// The live lookup behind a weather or money card: a cache key and the launcher's own answer for it.
    static func live(_ c: AskCard) -> (key: String, make: @MainActor () -> [Answer])? {
        let s = Store.shared.settings
        switch c.type {
        case "weather":
            let place = c.j.s("place") ?? ""
            let rain = c.j.s("show") == "rain"
            return ("wx:\(place.lowercased()):\(rain)", { LiveData.shared.weather(place: place, kind: rain ? .rain : .full, s) })
        case "money":
            guard let from = c.j.s("from").flatMap(Tools.currencyCode), let to = c.j.s("to").flatMap(Tools.currencyCode) else { return nil }
            let amount = c.j.d("amount") ?? 1
            return ("fx:\(amount):\(from):\(to)", { LiveData.shared.convert(amount, from: from, to: [to]) })
        default:
            return nil
        }
    }

    /// Clocks for a time card: the place beside here, or a time somewhere turned into the other place's time.
    static func clocks(_ j: AskJSON) -> ToolCard? {
        func zone(_ name: String?, _ id: String?) -> (String, TimeZone)? {
            if let id, let tz = TimeZone(identifier: id) {
                return (name ?? String(id.split(separator: "/").last ?? "").replacingOccurrences(of: "_", with: " "), tz)
            }
            return name.flatMap(Tools.zone).map { ($0.name, $0.tz) }
        }
        guard let to = zone(j.s("place"), j.s("zone")) else { return nil }
        let here = TimeZone.current
        if let at = j.s("at").flatMap({ Tools.rx(#"^(\d{1,2}):(\d{2})"#, $0) }), let h = Int(at[1]), let m = Int(at[2]) {
            let from = zone(j.s("from"), j.s("fromZone")) ?? (Tools.localName, here)
            var cal = Calendar.current
            cal.timeZone = from.1
            guard let d = cal.date(bySettingHour: h % 24, minute: m, second: 0, of: Date()) else { return nil }
            return .clocks([.init(name: from.0, zone: from.1, at: d, here: from.1 == here), .init(name: to.0, zone: to.1, at: d, here: to.1 == here)], convert: true)
        }
        let same = to.1.secondsFromGMT() == here.secondsFromGMT()
        return .clocks([.init(name: to.0, zone: to.1, here: same)] + (same ? [] : [.init(name: Tools.localName, zone: here, here: true)]), convert: false)
    }
}

// MARK: Parsing

/// Lenient reads from the model's JSON: numbers and strings stand in for each other.
struct AskJSON {
    let v: [String: Any]

    func s(_ k: String) -> String? {
        switch v[k] {
        case let x as String:
            let t = x.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.doubleValue.formatted()
        default: return nil
        }
    }

    func d(_ k: String) -> Double? {
        if let n = v[k] as? NSNumber { return n.doubleValue }
        return (v[k] as? String).flatMap { Double($0.replacingOccurrences(of: ",", with: "")) }
    }

    func b(_ k: String) -> Bool? { v[k] as? Bool }

    func list(_ k: String) -> [AskJSON] { (v[k] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).map(AskJSON.init) } }

    func strings(_ k: String) -> [String] {
        (v[k] as? [Any] ?? []).compactMap { x in
            if let s = x as? String { return s }
            if let d = x as? [String: Any] { return AskJSON(v: d).s("text") ?? AskJSON(v: d).s("title") }
            return nil
        }
    }

    /// [["label","value"]], [{"label","value"}] or {"label":"value"}.
    func pairs(_ k: String) -> [(String, String)] {
        if let d = v[k] as? [String: Any] { return d.keys.sorted().compactMap { key in AskJSON(v: d).s(key).map { (key, $0) } } }
        return (v[k] as? [Any] ?? []).compactMap { x in
            if let a = x as? [Any], a.count >= 2 { return ("\(a[0])", "\(a[1])") }
            if let o = x as? [String: Any] {
                let j = AskJSON(v: o)
                if let l = j.s("label") ?? j.s("name"), let v = j.s("value") { return (l, v) }
            }
            return nil
        }
    }
}

struct AskCard {
    let type: String
    let j: AskJSON
}

enum AskPart {
    /// Markdown, and where it starts in the text shown so far (for the fade-in).
    case text(String, at: Int)
    case card(AskCard)
    /// A card whose JSON hasn't closed yet, with its type once that has arrived.
    case pending(String?)
    case code(String, lang: String)
    case table([[String]])
}

@MainActor enum AskParse {
    static let types: Set<String> = ["weather", "money", "stock", "time", "places", "steps", "recipe", "score", "timeline", "facts", "phrase"]

    static func parts(_ s: String) -> [AskPart] {
        var out: [AskPart] = [], text: [String] = [], at = 0
        func flush() {
            let t = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            text = []
            guard !t.isEmpty else { return }
            out.append(.text(t, at: at))
            at += t.count
        }
        let lines = s.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flush()
                var head = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                // ```card, or a fence named after the card's type (```recipe).
                let named = types.contains(head.lowercased())
                let isCard = named || head.lowercased().hasPrefix("card") || head.hasPrefix("{")
                var body: [String] = [], closed = false
                if isCard {
                    // ```card {...}``` can come on one line.
                    var rest = named ? "" : head.lowercased().hasPrefix("card") ? String(head.dropFirst(4)) : head
                    if rest.hasSuffix("```") { rest.removeLast(3); closed = true }
                    if !rest.trimmingCharacters(in: .whitespaces).isEmpty { body.append(rest) }
                    head = "card"
                }
                i += 1
                while !closed, i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l == "```" || (isCard && l.hasSuffix("```")) {
                        if l != "```" { body.append(String(l.dropLast(3))) }
                        closed = true
                    } else {
                        body.append(lines[i])
                    }
                    i += 1
                }
                let raw = body.joined(separator: "\n")
                let hint = typeHint(raw) ?? (named ? head.lowercased() : nil)
                if isCard || (head.lowercased() == "json" && hint.map(types.contains) == true) {
                    if !closed {
                        out.append(.pending(hint))
                    } else if let c = card(raw, hint) {
                        out.append(c)
                    } else if let fallback = plain(raw) {
                        text = [fallback]
                        flush()
                    }
                } else {
                    out.append(.code(raw, lang: head))
                }
                continue
            }
            if t.hasPrefix("|") {
                var rows: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                let rule = { (r: String) in r.contains("-") && r.allSatisfy { "|-: ".contains($0) } }
                if rows.count >= 2, rule(rows[1]) {
                    flush()
                    out.append(.table(rows.enumerated().filter { $0.offset != 1 }.map { cells($0.element) }))
                } else if !(rows.count == 1 && i == lines.count) {
                    // (A lone last line is a table's head still arriving: it waits.)
                    text += rows
                }
                continue
            }
            text.append(lines[i])
            i += 1
        }
        flush()
        return out
    }

    private static func typeHint(_ raw: String) -> String? {
        Tools.rx(#""type"\s*:\s*"(\w+)""#, raw).map { $0[1].lowercased() }
    }

    private static func card(_ raw: String, _ hint: String?) -> AskPart? {
        guard let d = raw.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let type = (o["type"] as? String)?.lowercased() ?? hint, types.contains(type) else { return nil }
        return .card(AskCard(type: type, j: AskJSON(v: o)))
    }

    /// A card of a kind the app doesn't draw: its words as plain lines. Broken JSON shows nothing.
    private static func plain(_ raw: String) -> String? {
        guard let d = raw.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let j = AskJSON(v: o)
        let lines = o.keys.sorted().filter { $0 != "type" }.compactMap { k in j.s(k).map { "- \($0)" } }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func cells(_ row: String) -> [String] {
        var r = Substring(row)
        if r.hasPrefix("|") { r = r.dropFirst() }
        if r.hasSuffix("|") { r = r.dropLast() }
        return r.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: Live data

/// Looks up live cards one at a time (the launcher's lookups keep one request per kind, so two at once would
/// cancel each other), and fetches stock quotes.
@MainActor @Observable final class AskLive {
    static let shared = AskLive()

    struct Quote {
        var name: String
        var exchange: String
        var currency: String
        var price: Double
        var previous: Double
        var closes: [Double]
        var dayLow: Double?, dayHigh: Double?
        var yearLow: Double?, yearHigh: Double?
        var decimals: Int
    }

    private(set) var answers: [String: (answer: Answer, time: Date)] = [:]
    private(set) var quotes: [String: (quote: Quote, time: Date)] = [:]
    private(set) var failedQuotes = Set<String>()
    @ObservationIgnored private var queue: [(key: String, make: @MainActor () -> [Answer])] = []
    @ObservationIgnored private var asked: [String: Date] = [:]

    /// The launcher's answer for this card once it has a card (or an error); nil while it loads.
    func answer(_ key: String, _ make: @escaping @MainActor () -> [Answer]) -> Answer? {
        if let a = answers[key], Date().timeIntervalSince(a.time) < 600 { return a.answer }
        if let t = asked[key], Date().timeIntervalSince(t) < 600 { return answers[key]?.answer }
        asked[key] = Date()
        queue.append((key, make))
        if queue.count == 1 { Task { await drain() } }
        return answers[key]?.answer
    }

    private func drain() async {
        while let (key, make) = queue.first {
            for _ in 0..<60 {
                let r = make()
                if let a = r.first(where: { $0.card != nil }) ?? r.first(where: { $0.color == .systemOrange }) {
                    answers[key] = (a, Date())
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            queue.removeFirst()
        }
    }

    func quote(_ symbol: String, _ range: String) -> Quote? {
        let key = symbol + "|" + range
        if let q = quotes[key], Date().timeIntervalSince(q.time) < 120 { return q.quote }
        if asked[key].map({ Date().timeIntervalSince($0) < 120 }) != true {
            asked[key] = Date()
            Task {
                do {
                    quotes[key] = (try await Self.fetch(symbol, range), Date())
                } catch {
                    failedQuotes.insert(key)
                }
            }
        }
        return quotes[key]?.quote
    }

    /// Yahoo Finance's chart feed (no key): price, previous close and the closes over the range.
    private static func fetch(_ symbol: String, _ range: String) async throws -> Quote {
        let interval = ["1d": "5m", "1mo": "1d", "1y": "1wk"][range] ?? "1d"
        let sym = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(sym)?range=\(range)&interval=\(interval)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = ((o["chart"] as? [String: Any])?["result"] as? [Any])?.first as? [String: Any],
              let m = r["meta"] as? [String: Any], let price = (m["regularMarketPrice"] as? NSNumber)?.doubleValue else { throw URLError(.cannotParseResponse) }
        let num = { (k: String) in (m[k] as? NSNumber)?.doubleValue }
        let quote = ((r["indicators"] as? [String: Any])?["quote"] as? [Any])?.first as? [String: Any]
        let closes = (quote?["close"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        let prev = (range == "1d" ? num("previousClose") : nil) ?? num("chartPreviousClose") ?? closes.first ?? price
        return Quote(name: m["shortName"] as? String ?? m["longName"] as? String ?? symbol, exchange: m["fullExchangeName"] as? String ?? "",
                     currency: m["currency"] as? String ?? "", price: price, previous: prev, closes: closes,
                     dayLow: num("regularMarketDayLow"), dayHigh: num("regularMarketDayHigh"), yearLow: num("fiftyTwoWeekLow"), yearHigh: num("fiftyTwoWeekHigh"),
                     decimals: (m["priceHint"] as? NSNumber)?.intValue ?? 2)
    }
}

// MARK: Views

/// An answer as text and cards. Plain answers are the same single text as before.
struct AskAnswer: View {
    let text: String
    let shown: Double

    var body: some View {
        let parts = AskParse.parts(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(parts.indices, id: \.self) { i in
                part(parts[i]).transition(.opacity)
            }
        }
    }

    @ViewBuilder private func part(_ p: AskPart) -> some View {
        switch p {
        case .text(let t, let at):
            // Streaming: words fade in. All there: a text view you can select across and click links in.
            if shown - Double(at) >= Double(t.count) + FadeIn.ramp { SelectableNotes(markdown: t) } else { NotesView(markdown: t, shown: shown - Double(at)) }
        case .card(let c): AskCardView(card: c)
        case .pending(let type): AskSkeleton(type: type)
        case .code(let code, let lang): CodeBlock(code: code, lang: lang)
        case .table(let rows): TableCard(rows: rows)
        }
    }
}

struct AskCardView: View {
    let card: AskCard

    var body: some View {
        let j = card.j
        switch card.type {
        case "weather", "money": LiveCard(card: card)
        case "time":
            if let c = AskCards.clocks(j) { ToolCardBox(card: c) }
        case "stock": StockCard(symbol: (j.s("symbol") ?? "").uppercased())
        case "places": PlacesCard(j: j)
        case "steps": StepsCard(j: j)
        case "recipe": RecipeCard(j: j)
        case "score": ScoreCard(j: j)
        case "timeline": TimelineCard(j: j)
        case "facts": FactsCard(j: j)
        case "phrase": PhraseCard(j: j)
        default: EmptyView()
        }
    }
}

/// The header every card starts with (the same as the launcher's cards).
private struct AskHeader: View {
    let head: (symbol: String, title: String, color: NSColor)
    var detail: String?

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(Color(nsColor: head.color).gradient)
                .frame(width: 18, height: 18)
                .overlay(Image(systemName: head.symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white))
            Text(detail.map { "\(head.title) · \($0)" } ?? head.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
        }
    }
}

/// A card: header, content, a hairline round it.
private struct AskBox<Content: View>: View {
    let type: String?
    var detail: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.gap + 4) {
            AskHeader(head: AskCards.head(type), detail: detail)
            content()
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskCards.well)
    }
}

/// A round 32 pt button.
private struct AskIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

private func inline(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

/// Where a card will be while its JSON is still arriving (or its live data loading).
private struct AskSkeleton: View {
    let type: String?

    var body: some View {
        AskBox(type: type) {
            TimelineView(.animation(paused: !AssistantView.animates)) { t in
                let pulse = AssistantView.animates ? 0.5 + 0.5 * sin(t.date.timeIntervalSinceReferenceDate * 3) : 0.5
                VStack(alignment: .leading, spacing: 10) {
                    ForEach([0.45, 0.85, 0.7], id: \.self) { w in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.05 + 0.04 * pulse))
                            .frame(width: 520 * w, height: 11)
                    }
                }
            }
        }
    }
}

/// One of the launcher's own cards (weather, currency, clocks), drawn the same way here.
private struct ToolCardBox: View {
    let card: ToolCard

    var body: some View {
        AnswerCardView(card: card, hint: "", selected: false, hovered: false, radius: AskCards.radius, onAction: AskCards.perform)
            .fixedSize(horizontal: false, vertical: true)
            .background(AskCards.well)
    }
}

private struct LiveCard: View {
    let card: AskCard

    var body: some View {
        if let live = AskCards.live(card) {
            if let a = AskLive.shared.answer(live.key, live.make) {
                if let c = a.card {
                    ToolCardBox(card: stripped(c))
                } else {
                    Label(a.title, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            } else {
                AskSkeleton(type: card.type)
            }
        }
    }

    /// The currency card's pickers refill the launcher's bar, which isn't here.
    private func stripped(_ c: ToolCard) -> ToolCard {
        guard case .big(var b) = c else { return c }
        b.controls = []
        return .big(b)
    }
}

// MARK: Code and tables

private struct CodeBlock: View {
    let code: String
    let lang: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(lang.isEmpty ? "Code" : lang).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                AskIcon(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    AskCards.copy(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
            }
            ScrollView(.horizontal) {
                Text(code).font(.system(size: 12.5, design: .monospaced)).lineSpacing(3).textSelection(.enabled).fixedSize()
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, cardPadding)
        .padding(.top, cardPadding - 8)
        .padding(.bottom, cardPadding)
        .background(AskCards.well)
    }
}

private struct TableCard: View {
    let rows: [[String]]

    var body: some View {
        let n = rows.map(\.count).max() ?? 0
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            ForEach(rows.indices, id: \.self) { r in
                if r > 0 { Divider().opacity(0.5).gridCellUnsizedAxes(.horizontal) }
                GridRow(alignment: .top) {
                    ForEach(0..<n, id: \.self) { c in
                        // The first column fits its labels; the others share the rest.
                        Text(inline(c < rows[r].count ? rows[r][c] : " "))
                            .font(.system(size: r == 0 ? 11.5 : 12.5, weight: r == 0 ? .semibold : c == 0 ? .medium : .regular))
                            .foregroundStyle(r == 0 ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.vertical, 8)
                            .frame(maxWidth: c == 0 ? nil : .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, cardPadding)
        .padding(.vertical, cardPadding - 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskCards.well)
    }
}

// MARK: Cards drawn from the model's JSON

/// Restaurants, shops, sights: name, rating, kind and price, whether it's open, and buttons to the map and the site.
private struct PlacesCard: View {
    let j: AskJSON

    var body: some View {
        let items = Array(j.list("items").prefix(5))
        AskBox(type: "places", detail: j.s("title")) {
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    if i > 0 { Divider().opacity(0.5) }
                    row(items[i]).padding(.vertical, 9)
                }
            }
            .padding(.vertical, -9)
        }
    }

    private func row(_ p: AskJSON) -> some View {
        let name = p.s("name") ?? ""
        let meta = [p.s("kind"), p.s("price")].compactMap { $0 }.joined(separator: " · ")
        let map = URL(string: "https://www.google.com/maps/search/?api=1&query=" +
                      ([name, p.s("address")].compactMap { $0 }.joined(separator: " ").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if let r = p.d("rating") {
                        Image(systemName: "star.fill").font(.system(size: 9.5)).foregroundStyle(.yellow)
                        Text(String(format: "%.1f", r)).foregroundStyle(.primary)
                        if let n = p.s("reviews") { Text("(\(n))") }
                        if !meta.isEmpty { Text("·") }
                    }
                    Text(meta)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    if let open = p.b("open") {
                        Text(open ? "Open" : "Closed").foregroundStyle(open ? Color.green : Color.red).fontWeight(.medium)
                        if p.s("hours") != nil || p.s("address") != nil { Text("·") }
                    }
                    Text([p.s("hours"), p.s("address")].compactMap { $0 }.joined(separator: " · ")).truncationMode(.tail)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let site = p.s("url").flatMap(URL.init(string:)), site.scheme?.hasPrefix("http") == true {
                AskIcon(symbol: "safari", help: site.host ?? "Website") { AskCards.open(site) }
            }
            if let map { AskIcon(symbol: "map", help: "Map") { AskCards.open(map) } }
        }
    }
}

/// Numbered steps joined by a line.
private struct StepsCard: View {
    let j: AskJSON

    var body: some View {
        let items = j.list("items")
        let plain = items.isEmpty ? j.strings("items") : []
        let count = max(items.count, plain.count)
        AskBox(type: "steps", detail: j.s("title")) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    let title = items.isEmpty ? plain[i] : items[i].s("title") ?? items[i].s("text") ?? ""
                    let detail = items.isEmpty ? nil : items[i].s("detail")
                    Numbered(index: i + 1, last: i == count - 1) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(inline(title)).font(.system(size: 13.5, weight: detail == nil ? .regular : .semibold))
                            if let detail { Text(inline(detail)).font(.system(size: 12.5)).foregroundStyle(.secondary) }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// A marker (number or dot) at the left with a line down to the next one.
private struct Numbered<Content: View>: View {
    let index: Int?
    let last: Bool
    var gap: CGFloat = 14
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let index {
                    Text("\(index)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                } else {
                    Circle().fill(Color.white.opacity(0.55)).frame(width: 7, height: 7).frame(width: 22, height: 18)
                }
            }
            content().padding(.top, index == nil ? 0 : 2).padding(.bottom, last ? 0 : gap)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .topLeading) {
            if !last {
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1)
                    .padding(.top, index == nil ? 15 : 26).padding(.bottom, 4).offset(x: 10.5)
            }
        }
    }
}

/// What's needed, as a checklist you can tick, then the method.
private struct RecipeCard: View {
    let j: AskJSON
    @State private var have = Set<Int>()

    var body: some View {
        let ingredients = j.strings("ingredients"), steps = j.strings("steps")
        AskBox(type: "recipe") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    if let t = j.s("title") { Text(t).font(.system(size: 17, weight: .semibold)) }
                    HStack(spacing: 14) {
                        if let n = j.s("serves") { Label("Serves \(n)", systemImage: "person.2") }
                        if let t = j.s("time") { Label(t, systemImage: "clock") }
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Ingredients", systemImage: "basket").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(ingredients.indices, id: \.self) { i in
                            Button {
                                if have.contains(i) { have.remove(i) } else { have.insert(i) }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Image(systemName: have.contains(i) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 12)).foregroundStyle(have.contains(i) ? Color.green : Color.secondary)
                                    Text(inline(ingredients[i])).font(.system(size: 12.5)).strikethrough(have.contains(i)).opacity(have.contains(i) ? 0.5 : 1)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Method", systemImage: "frying.pan").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    ForEach(steps.indices, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 14, alignment: .trailing)
                            Text(inline(steps[i])).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// Games: home and away either side of the score, the winner bright, live games marked.
private struct ScoreCard: View {
    let j: AskJSON

    var body: some View {
        let games = j.list("games").isEmpty ? [j] : j.list("games")
        AskBox(type: "score", detail: j.s("league")) {
            VStack(spacing: 0) {
                ForEach(games.indices, id: \.self) { i in
                    if i > 0 { Divider().opacity(0.5) }
                    game(games[i], big: games.count == 1).padding(.vertical, games.count == 1 ? 0 : 8)
                }
            }
            .padding(.vertical, games.count == 1 ? 0 : -8)
        }
    }

    private func game(_ g: AskJSON, big: Bool) -> some View {
        let h = g.d("homeScore"), a = g.d("awayScore")
        let status = g.s("status") ?? ""
        let live = status.lowercased().contains("live") || status.contains("'") || status.lowercased().contains("half")
        let lead = { (mine: Double?, theirs: Double?) -> Bool in (mine ?? 0) > (theirs ?? 0) || h == nil }
        return HStack(spacing: 12) {
            team(g.s("home") ?? "", bright: lead(h, a), big: big).frame(maxWidth: .infinity, alignment: .trailing)
            VStack(spacing: 2) {
                Text(h == nil || a == nil ? "–" : "\(g.s("homeScore")!)  –  \(g.s("awayScore")!)")
                    .font(.system(size: big ? 30 : 19, weight: .semibold, design: .rounded)).monospacedDigit()
                if !status.isEmpty {
                    Text(status).font(.system(size: 11, weight: live ? .semibold : .regular)).foregroundStyle(live ? Color.red : Color.secondary).lineLimit(1)
                }
            }
            .frame(minWidth: big ? 110 : 84)
            team(g.s("away") ?? "", bright: lead(a, h), big: big).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func team(_ name: String, bright: Bool, big: Bool) -> some View {
        Text(name).font(.system(size: big ? 15 : 13.5, weight: .semibold)).foregroundStyle(bright ? .primary : .secondary).lineLimit(1)
    }
}

/// Dates down the left, what happens beside each, joined by a line.
private struct TimelineCard: View {
    let j: AskJSON

    var body: some View {
        let items = j.list("items")
        AskBox(type: "timeline", detail: j.s("title")) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 10) {
                        Text(items[i].s("when") ?? "").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading).padding(.top, 1)
                        Numbered(index: nil, last: i == items.count - 1, gap: 12) {
                            Text(inline(items[i].s("what") ?? items[i].s("text") ?? "")).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// A person, place or thing: its name and what it is, the key facts in two columns, a link to read more.
private struct FactsCard: View {
    let j: AskJSON

    var body: some View {
        let facts = j.pairs("facts")
        AskBox(type: "facts") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let t = j.s("title") { Text(t).font(.system(size: 17, weight: .semibold)) }
                        if let s = j.s("subtitle") { Text(s).font(.system(size: 12.5)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    if let u = j.s("url").flatMap(URL.init(string:)), u.scheme?.hasPrefix("http") == true {
                        AskIcon(symbol: "arrow.up.right", help: u.host ?? "Open") { AskCards.open(u) }
                    }
                }
                Divider().opacity(0.5)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                    ForEach(facts.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(facts[i].0).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            Text(inline(facts[i].1)).font(.system(size: 13.5, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// How to say it: the words large, how they sound, what they mean, with buttons to hear and copy them.
private struct PhraseCard: View {
    let j: AskJSON
    @State private var copied = false
    private static let voice = AVSpeechSynthesizer()

    var body: some View {
        let text = j.s("text") ?? ""
        let lang = j.s("lang")
        AskBox(type: "phrase", detail: lang.flatMap { Locale.current.localizedString(forIdentifier: $0) }) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(text).font(.system(size: 22, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let r = j.s("reading") { Text(r).font(.system(size: 13.5)).foregroundStyle(.secondary) }
                    if let m = j.s("meaning") { Text(inline(m)).font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.top, 4) }
                }
                Spacer(minLength: 8)
                AskIcon(symbol: "speaker.wave.2.fill", help: "Listen") {
                    let u = AVSpeechUtterance(string: text)
                    u.voice = lang.flatMap(AVSpeechSynthesisVoice.init(language:))
                    Self.voice.stopSpeaking(at: .immediate)
                    Self.voice.speak(u)
                }
                AskIcon(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    AskCards.copy(text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
            }
        }
    }
}

/// A share, index or coin: live price, the change over the range, its chart, and the day's and year's ranges.
private struct StockCard: View {
    let symbol: String
    @State private var range = "1d"

    var body: some View {
        let live = AskLive.shared
        if let q = live.quote(symbol, range) ?? (range == "1d" ? nil : live.quotes[symbol + "|1d"]?.quote) {
            card(q)
        } else if live.failedQuotes.contains(symbol + "|" + range) {
            Label("No price for \(symbol)", systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
        } else {
            AskSkeleton(type: "stock")
        }
    }

    private func card(_ q: AskLive.Quote) -> some View {
        let change = q.price - q.previous
        let pct = q.previous == 0 ? 0 : change / q.previous * 100
        let color = change >= 0 ? Color.green : Color.red
        let f = { (v: Double) in v.formatted(.number.precision(.fractionLength(q.decimals))) }
        return AskBox(type: "stock", detail: q.exchange.isEmpty ? nil : q.exchange) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(q.name) · \(symbol)").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(f(q.price)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text(q.currency).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                            Text("\(change >= 0 ? "+" : "−")\(f(abs(change)))  (\(change >= 0 ? "+" : "−")\(String(format: "%.2f", abs(pct)))%)")
                                .font(.system(size: 13.5, weight: .semibold)).monospacedDigit().foregroundStyle(color)
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 2) {
                        ForEach([("1d", "1D"), ("1mo", "1M"), ("1y", "1Y")], id: \.0) { r in
                            Button { range = r.0 } label: {
                                Text(r.1).font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(range == r.0 ? .primary : .secondary)
                                    .frame(width: 34, height: 24)
                                    .background(Capsule().fill(Color.primary.opacity(range == r.0 ? 0.14 : 0)))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spark(values: q.closes, base: range == "1d" ? q.previous : nil, color: color).frame(height: 84)
                HStack(spacing: 18) {
                    if let lo = q.dayLow, let hi = q.dayHigh { stat("Day", "\(f(lo)) – \(f(hi))") }
                    if let lo = q.yearLow, let hi = q.yearHigh { stat("52 weeks", "\(f(lo)) – \(f(hi))") }
                    stat("Previous close", f(q.previous))
                    Spacer(minLength: 0)
                    if let u = URL(string: "https://finance.yahoo.com/quote/\(symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol)") {
                        AskIcon(symbol: "arrow.up.right", help: "Yahoo Finance") { AskCards.open(u) }
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
        }
    }
}

/// A price line with a soft fill under it; a dotted line at the previous close.
private struct Spark: View {
    let values: [Double]
    let base: Double?
    let color: Color

    var body: some View {
        GeometryReader { g in
            let lo = min(values.min() ?? 0, base ?? .infinity), hi = max(values.max() ?? 1, base ?? -.infinity)
            let span = max(hi - lo, 1e-9)
            let pt = { (i: Int, v: Double) in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)), y: g.size.height * (1 - CGFloat((v - lo) / span)))
            }
            let line = Path { p in
                for (i, v) in values.enumerated() { i == 0 ? p.move(to: pt(i, v)) : p.addLine(to: pt(i, v)) }
            }
            ZStack {
                if let base {
                    Path { p in
                        let y = g.size.height * (1 - CGFloat((base - lo) / span))
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: g.size.width, y: y))
                    }
                    .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                if values.count > 1 {
                    Path { p in
                        p.addPath(line)
                        p.addLine(to: CGPoint(x: pt(values.count - 1, values.last!).x, y: g.size.height))
                        p.addLine(to: CGPoint(x: 0, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    line.stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// MARK: Snapshots

extension Assistant {
    /// One canned answer for the snapshot hook (`--cards <name>`). Live cards load before it's drawn.
    func demoCards(_ name: String) {
        guard let (q, a) = AskCards.demos[name] else { return }
        demo(busy: false)
        turns = [Turn(question: q, answer: a)]
        let until = Date().addingTimeInterval(12)
        func waiting() -> Bool {
            AskParse.parts(a).contains { p in
                guard case .card(let c) = p else { return false }
                if let l = AskCards.live(c) { return AskLive.shared.answer(l.key, l.make) == nil }
                if c.type == "stock", let s = c.j.s("symbol")?.uppercased() {
                    return AskLive.shared.quote(s, "1d") == nil && !AskLive.shared.failedQuotes.contains(s + "|1d")
                }
                return false
            }
        }
        while waiting(), Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }
}

extension AskCards {
    static let demos: [String: (String, String)] = [
        "weather": ("Weather in Kyoto this weekend?", """
            Mostly dry, with showers likely on Sunday afternoon.
            ```card
            {"type":"weather","place":"Kyoto"}
            ```
            """),
        "rain": ("Do I need an umbrella today?", "```card\n{\"type\":\"weather\",\"place\":\"Tokyo\",\"show\":\"rain\"}\n```"),
        "money": ("How much is 250 euros in yen?", "```card\n{\"type\":\"money\",\"amount\":250,\"from\":\"EUR\",\"to\":\"JPY\"}\n```"),
        "stock": ("How is Apple stock doing?", """
            Up sharply today after its quarterly results beat expectations.
            ```card
            {"type":"stock","symbol":"AAPL"}
            ```
            """),
        "time": ("If it's 3pm in Tokyo, what time is it in New York?", """
            ```card
            {"type":"time","place":"New York","zone":"America/New_York","at":"15:00","from":"Tokyo","fromZone":"Asia/Tokyo"}
            ```
            """),
        "places": ("Good ramen near Shibuya station?", """
            ```card
            {"type":"places","title":"Ramen near Shibuya","items":[
             {"name":"Ichiran Shibuya","kind":"Tonkotsu ramen","rating":4.4,"reviews":"6,200","price":"¥1,000–2,000","address":"1-22-7 Jinnan, Shibuya","hours":"Open 24 hours","open":true,"url":"https://ichiran.com"},
             {"name":"Afuri Harajuku","kind":"Yuzu shio ramen","rating":4.3,"reviews":"3,100","price":"¥1,000–2,000","address":"3-63-1 Sendagaya","hours":"until 23:00","open":true},
             {"name":"Hayashi","kind":"Tonkotsu shoyu","rating":4.5,"reviews":"1,900","price":"¥1,000","address":"1-14-11 Dogenzaka","hours":"opens 11:30","open":false}
            ]}
            ```
            Hayashi sells out most days, so go early.
            """),
        "compare": ("AirPods Pro 3 vs Sony WF-1000XM6?", """
            Both cancel noise very well; the choice mostly comes down to your phone.
            | | AirPods Pro 3 | Sony WF-1000XM6 |
            |---|---|---|
            | Price | $249 | $329 |
            | Battery | 8 h (ANC on) | 8 h (ANC on) |
            | Best with | iPhone | Android or both |
            | Extras | Heart rate, hearing aid | LDAC, multipoint |
            """),
        "steps": ("How do I reset SMC on a Mac?", """
            Apple silicon Macs don't have an SMC to reset; a restart does the same thing. On an Intel Mac with the T2 chip:
            ```card
            {"type":"steps","title":"Reset the SMC","items":[
             {"title":"Shut down the Mac","detail":"Apple menu › Shut Down, then wait 10 seconds."},
             {"title":"Hold Control, Option and Shift","detail":"Hold the right Shift key with them for 7 seconds."},
             {"title":"Add the power button","detail":"Keep all four held for another 7 seconds, then let go."},
             {"title":"Turn it back on","detail":"Wait a few seconds and press the power button."}
            ]}
            ```
            """),
        "recipe": ("Quick oyakodon recipe for two", """
            ```card
            {"type":"recipe","title":"Oyakodon","serves":2,"time":"20 min","ingredients":["2 chicken thighs","1 onion","3 eggs","150 ml dashi","2 tbsp soy sauce","2 tbsp mirin","1 tsp sugar","2 bowls of rice","Mitsuba or scallions"],
             "steps":["Slice the onion thinly and cut the chicken into bite-size pieces.","Simmer dashi, soy sauce, mirin and sugar; add the onion for 3 minutes.","Add the chicken and cook for 5 minutes until done.","Pour in lightly beaten eggs, cover for 1 minute and take off the heat while still soft.","Slide over hot rice and top with mitsuba."]}
            ```
            """),
        "score": ("Arsenal score?", """
            ```card
            {"type":"score","league":"Premier League","games":[{"home":"Arsenal","away":"Chelsea","homeScore":2,"awayScore":1,"status":"Final"}]}
            ```
            Saka scored the winner in the 78th minute.
            """),
        "scores": ("NBA scores last night", """
            ```card
            {"type":"score","league":"NBA","games":[
             {"home":"Lakers","away":"Warriors","homeScore":118,"awayScore":112,"status":"Final"},
             {"home":"Celtics","away":"Knicks","homeScore":96,"awayScore":101,"status":"Final/OT"},
             {"home":"Nuggets","away":"Suns","homeScore":54,"awayScore":49,"status":"Live · Q2 3:12"}
            ]}
            ```
            """),
        "timeline": ("When are the next Apple events?", """
            ```card
            {"type":"timeline","title":"Apple, 2027","items":[
             {"when":"Mar 2027","what":"Spring launch, usually iPads and Macs by press release"},
             {"when":"Jun 7, 2027","what":"**WWDC** keynote: iOS 21 and macOS 28"},
             {"when":"Sep 2027","what":"iPhone event"},
             {"when":"Oct 2027","what":"Macs with M6, if the pattern holds"}
            ]}
            ```
            Only WWDC has a date so far.
            """),
        "facts": ("Who is Hayao Miyazaki?", """
            Japanese animator and director who co-founded Studio Ghibli.
            ```card
            {"type":"facts","title":"Hayao Miyazaki","subtitle":"Animator, director, manga artist","url":"https://en.wikipedia.org/wiki/Hayao_Miyazaki",
             "facts":[["Born","January 5, 1941, Tokyo"],["Studio","Studio Ghibli (1985)"],["Known for","Spirited Away, My Neighbor Totoro"],["Awards","Academy Award, 2003 and 2024"],["Latest film","The Boy and the Heron (2023)"],["Age","85"]]}
            ```
            """),
        "phrase": ("How do I say \"could I get the check\" in Japanese?", """
            ```card
            {"type":"phrase","text":"お会計お願いします","reading":"Okaikei onegai shimasu","lang":"ja","meaning":"Could I have the bill, please"}
            ```
            In a casual place, catching the staff's eye and making an X with two fingers works too.
            """),
        "code": ("Python one-liner to dedupe a list but keep order", """
            ```python
            unique = list(dict.fromkeys(items))
            ```
            Dicts keep insertion order since Python 3.7, so the first of each value stays.
            """),
        "partial": ("Best sushi near Ginza?", """
            Three places that take walk-ins at lunch:
            ```card
            {"type":"places","title":"Sushi near Ginza","items":[
             {"name":"Sushi no Midori","kind":"Sushi","rating":4.
            """),
    ]
}
