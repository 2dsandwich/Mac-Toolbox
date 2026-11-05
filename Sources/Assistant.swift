import AppKit
import Observation
import SwiftUI

/// Ask: quick questions in the launcher. Only Tab in the empty search bar opens it, so AI never starts by accident.
/// Answers are short and in the language asked; follow-ups continue the thread. On Claude it can search the web.
@MainActor @Observable final class Assistant {
    static let shared = Assistant()

    struct Source: Hashable {
        let title: String
        let url: URL
    }

    /// What it's doing before the answer starts: shown in its place instead of the model's own reasoning.
    enum Status: Hashable {
        case thinking, searching(String?), reading(Int)
        /// One of Ask's own tools (AskTools.swift): what it's doing and its symbol.
        case using(String, String)
        var label: String {
            switch self {
            case .using(let label, _): label
            case .thinking: "Thinking"
            case .searching(let q?): "Searching \u{201C}\(q)\u{201D}"
            case .searching(nil): "Searching the web"
            case .reading(let n): n > 0 ? "Reading \(n) results" : "Reading results"
            }
        }
        var symbol: String {
            switch self {
            case .using(_, let symbol): symbol
            case .thinking: "sparkles"
            case .searching: "magnifyingglass"
            case .reading: "doc.text.magnifyingglass"
            }
        }
    }

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer = ""
        var sources: [Source] = []
        var failed = false
        var status: Status = .thinking
    }

    var turns: [Turn] = []
    var busy = false
    /// The thread's laid-out height, so the card fits it.
    var contentHeight: CGFloat = 0
    /// Claude's side of the thread, block for block: search results have to go back exactly as they came.
    @ObservationIgnored private var messages: [[String: Any]] = []
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Streamed updates for the current answer (for the dev hook).
    @ObservationIgnored private(set) var updates = 0

    var lastAnswer: String? { turns.last { !$0.failed && !$0.answer.isEmpty }?.answer }

    func reset() {
        work?.cancel()
        work = nil
        generation += 1
        turns = []
        messages = []
        busy = false
        contentHeight = 0
    }

    /// Sends a question; false when it can't be sent yet (nothing typed, or still answering).
    @discardableResult func ask(_ raw: String) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return false }
        let s = Store.shared.settings
        if let why = AI.problem(.assistant, s) {
            turns.append(Turn(question: q, answer: why, failed: true))
            return true
        }
        let earlier = turns.filter { !$0.failed && !$0.answer.isEmpty }
        turns.append(Turn(question: q))
        let i = turns.count - 1
        let gen = generation
        let c = AI.choice(.assistant, s)
        busy = true
        updates = 0
        work = Task {
            do {
                if c.provider == .anthropic {
                    try await askClaude(q, c, s, at: i, gen)
                } else {
                    let out = try await AI.complete(.assistant, system: Self.system(web: false),
                                                    user: Self.flatten(earlier, q, budget: AI.budget(.assistant, s)))
                    update(i, gen) { $0.answer = Self.withoutReasoning(out) }
                }
            } catch {
                if !Task.isCancelled {
                    update(i, gen) {
                        $0.answer = error.localizedDescription
                        $0.failed = true
                    }
                }
            }
            if gen == generation { busy = false }
        }
        return true
    }

    private func update(_ i: Int, _ gen: Int, _ change: (inout Turn) -> Void) {
        guard gen == generation, turns.indices.contains(i) else { return }
        change(&turns[i])
    }

    private func askClaude(_ q: String, _ c: TaskModel, _ s: Settings, at i: Int, _ gen: Int) async throws {
        let o = AI.options(.anthropic, s)
        let task = AITask.assistant
        var history = messages + [["role": "user", "content": q]]
        var blocks: [[String: Any]] = []
        // Ask's own tools (AskTools.swift): earlier steps of this answer, kept for the status line and the answer.
        var steps: [[String: Any]] = []
        let tools = [Self.webSearch] + AskTools.definitions(s, history: history)
        let turnID = turns[i].id
        // A long search can pause the turn: sending the paused turn back lets it carry on.
        for _ in 0..<10 {
            let before = blocks, earlier = steps
            let r = try await Claude.stream(system: Self.system(web: true), messages: blocks.isEmpty ? history : history + [["role": "assistant", "content": blocks]],
                                            model: c.model, effort: o.effort == "auto" ? task.effort : o.effort, maxTokens: c.maxTokens ?? task.maxTokens,
                                            tools: tools, timeout: task.timeout, fallback: o.fallback) { [weak self] now in
                guard let self, gen == self.generation else { return }
                self.updates += 1
                self.show(earlier + before + now, at: i, gen)
            }
            blocks = before + r.blocks
            if r.stop == "pause_turn" { continue }
            // AskTools hook: run the app's tools it asked for, send the results back, and carry on.
            guard r.stop == "tool_use", gen == generation else { break }
            let results = await AskTools.shared.run(blocks, turn: turnID)
            history += [["role": "assistant", "content": blocks], ["role": "user", "content": results]]
            steps += blocks
            blocks = []
        }
        guard gen == generation else { return }
        show(steps + blocks, at: i, gen)
        guard turns.indices.contains(i), !turns[i].answer.isEmpty else { throw Claude.Failure.empty }
        messages = history + [["role": "assistant", "content": blocks]]
    }

    /// The answer is the text after the last search (what comes before it is "let me look that up"), with the
    /// pages it cites, one per site.
    private func show(_ blocks: [[String: Any]], at i: Int, _ gen: Int) {
        let talk: Set<String> = ["text", "thinking", "redacted_thinking"]
        let start = (blocks.lastIndex { !talk.contains($0["type"] as? String ?? "") } ?? -1) + 1
        let texts = blocks[min(start, blocks.count)...].filter { $0["type"] as? String == "text" }
        let answer = texts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var sources: [Source] = []
        for case let cite as [String: Any] in texts.flatMap({ $0["citations"] as? [Any] ?? [] }) {
            guard let u = (cite["url"] as? String).flatMap(URL.init(string:)), !sources.contains(where: { $0.url.host == u.host }) else { continue }
            sources.append(Source(title: cite["title"] as? String ?? u.host ?? "", url: u))
        }
        // Where it is, from the last block that isn't the answer itself.
        var status = Assistant.Status.thinking
        if let last = blocks.last(where: { !($0["type"] as? String == "text" && ($0["text"] as? String ?? "").isEmpty) }) {
            switch last["type"] as? String {
            case "server_tool_use": status = .searching((last["input"] as? [String: Any])?["query"] as? String)
            case "web_search_tool_result": status = .reading((last["content"] as? [Any])?.count ?? 0)
            case "tool_use": status = AskTools.status(last)
            default: break
            }
        }
        update(i, gen) {
            $0.answer = answer
            $0.sources = Array(sources.prefix(3))
            $0.status = status
        }
    }

    /// Local reasoning models write their thinking inside <think> tags before the answer: only the answer shows.
    static func withoutReasoning(_ s: String) -> String {
        guard let r = s.range(of: "</think>") else { return s.hasPrefix("<think>") ? "" : s }
        return String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The basic search tool searches directly; the newer versions first run code over the results (dynamic
    /// filtering), which is slower than a quick answer wants.
    private static var webSearch: [String: Any] {
        ["type": "web_search_20250305", "name": "web_search", "max_uses": 3,
         "user_location": AskTools.searchLocation(Store.shared.settings)]
    }

    static func system(web: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return """
        You answer quick questions typed into a Mac launcher. \
        Write the whole answer, card text included, in the language of the question and only that language (English question, English answer; \
        Japanese question, Japanese answer). Never mix in another language, even when the sources are in one: translate what you use from them. \
        Names keep their usual spelling in that language. \
        Be as short as the question allows: the answer first, at most 2 sentences (about 50 words; in Japanese about 100 characters), \
        or up to 5 one-line bullets when a list is clearer. Longer only when the user asks for detail. \
        When one of the cards below fits, always use it: a card doesn't count toward that length, and the text around it stays a sentence at most. \
        No preamble, no headings, no restating the question, no caveats unless they matter, no offers of more help. \
        \(web ? "Search the web whenever the answer could be recent, local, changing or something you aren't sure of (news, prices, scores, weather, schedules, releases, opening hours, people, products, places); answer from memory only for settled facts. Don't say that you are searching. " : "")\
        Today is \(f.string(from: Date())); the user's time zone is \(TimeZone.current.identifier).
        \(web ? "\n" + AskTools.prompt(Store.shared.settings) + "\n" : "")

        \(AskCards.prompt)
        """
    }

    /// Models without Claude's message history get the thread so far written into the question.
    private static func flatten(_ earlier: [Turn], _ q: String, budget: Int) -> String {
        guard !earlier.isEmpty else { return q }
        let past = earlier.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
        return "Earlier in this conversation:\n\n" + String(past.suffix(max(0, budget - q.count - 200))) + "\n\n---\n\n" + q
    }

    /// A thread for snapshots (the last question still being answered with `busy`).
    func demo(busy: Bool) {
        reset()
        turns = [
            Turn(question: "How tall is Mount Fuji?", answer: "**3,776 m** (12,388 ft). It's Japan's highest mountain, on the border of Shizuoka and Yamanashi.",
                 sources: [Source(title: "Mount Fuji - Wikipedia", url: URL(string: "https://en.wikipedia.org/wiki/Mount_Fuji")!),
                           Source(title: "Mount Fuji | Britannica", url: URL(string: "https://www.britannica.com/place/Mount-Fuji")!)]),
            Turn(question: "最後に噴火したのはいつ？", answer: "1707年の宝永噴火が最後です。それ以来、300年以上噴火していません。",
                 sources: [Source(title: "富士山 - Wikipedia", url: URL(string: "https://ja.wikipedia.org/wiki/富士山")!)]),
            Turn(question: "Best time of year to climb it?", answer: """
                **Early July to early September**, when the trails and mountain huts are open.
                - Mid-July to late August has the steadiest weather
                - Weekdays are far less crowded than Obon week
                """, sources: [Source(title: "Climbing Mt. Fuji", url: URL(string: "https://www.fujisan-climb.jp/en/")!)]),
            Turn(question: "Can I make it there and back in a day from Tokyo?", answer: "The request timed out. Check your connection and try again.", failed: true),
        ]
        if busy {
            var t = Turn(question: "Which trail is easiest for a first climb?")
            // `--status searching|reading`: the line shown before the answer starts.
            let args = CommandLine.arguments
            if let k = args.firstIndex(of: "--status"), k + 1 < args.count {
                t.status = args[k + 1] == "searching" ? .searching("easiest Mt Fuji trail for beginners") : args[k + 1] == "reading" ? .reading(5) : .thinking
            }
            turns.append(t)
            self.busy = true
        }
    }

    /// Streams a made-up answer into the question `demo(busy: true)` left open, in uneven bursts like the real
    /// stream, so snapshots can catch the fade part way. No network.
    func demoStream() {
        let text = "The **Yoshida Trail** from the Fuji Subaru Line 5th Station. It has the most huts and first-aid posts, " +
            "and the climb takes about 6 hours up and 4 down.\n- Start in the early afternoon and sleep in a hut near the 8th station\n" +
            "- Leave before 3 am to see the sunrise from the summit"
        let sizes = [14, 3, 22, 9, 40, 6, 18, 31, 12, 27, 8, 35, 20, 60]
        let gen = generation, i = turns.count - 1
        work = Task {
            var n = 0
            for size in sizes where n < text.count {
                try? await Task.sleep(for: .milliseconds(90))
                n = min(text.count, n + size)
                update(i, gen) { $0.answer = String(text.prefix(n)) }
            }
            update(i, gen) {
                $0.answer = text
                $0.sources = [Source(title: "Yoshida Trail", url: URL(string: "https://www.fujisan-climb.jp/en/trails/yoshida.html")!)]
            }
            if gen == generation { busy = false }
        }
    }
}

/// The thread under the bar: one card that reads like a chat, newest exchange on top. Your question is a bubble on
/// the right, the answer plain text on the left with its sources under it. The card grows with the answer, then scrolls.
struct AssistantView: View {
    let assistant: Assistant
    let radius: CGFloat

    static let maxCard: CGFloat = 440

    static func height(_ a: Assistant) -> CGFloat {
        guard !a.turns.isEmpty else { return 0 }
        return Metrics.rowGap + min(maxCard, max(a.contentHeight, 52)) + Metrics.listInset
    }

    static var animates: Bool { Store.shared.settings.animations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelLayout.inner(radius), style: .continuous)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(assistant.turns.reversed()) { t in
                        AssistantTurn(turn: t, busy: assistant.busy && t.id == assistant.turns.last?.id)
                            .transition(.opacity)
                    }
                }
                .padding(cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { assistant.contentHeight = $0 }
                .id("thread")
            }
            .scrollIndicators(.never)
            // A new question goes to the top: show it there.
            .onChange(of: assistant.turns.count) { _, _ in proxy.scrollTo("thread", anchor: .top) }
        }
        // New questions slide the thread down; a growing answer eases the turns under it down.
        .animation(Self.animates ? .smooth(duration: 0.3) : nil, value: assistant.turns.count)
        .animation(Self.animates ? .smooth(duration: 0.3) : nil, value: assistant.turns.last?.answer.count)
        .background(shape.fill(cardFill))
        .clipShape(shape)
        .padding(.horizontal, Metrics.listInset)
        .padding(.top, Metrics.rowGap)
        .padding(.bottom, Metrics.listInset)
        .frame(height: Self.height(assistant), alignment: .top)
    }
}

/// One exchange: the question as a bubble, then the answer, which dissolves in as it streams.
private struct AssistantTurn: View {
    let turn: Assistant.Turn
    let busy: Bool
    /// How much of the answer is revealed (see `NotesView.shown`); a turn still being answered starts hidden.
    @State private var shown: Double

    init(turn: Assistant.Turn, busy: Bool) {
        self.turn = turn
        self.busy = busy
        _shown = State(initialValue: busy ? 0 : Self.full(turn.answer))
    }

    private static func full(_ s: String) -> Double { Double(s.count) + FadeIn.ramp }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.question)
                .font(.system(size: 13.5))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.primary.opacity(0.1)))
                .padding(.leading, 56)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if turn.failed {
                Label(turn.answer, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
            } else if !turn.answer.isEmpty {
                AskAnswer(text: turn.answer, shown: shown)
            } else if busy {
                StatusLine(status: turn.status)
            }
            AskReceipts(turn: turn.id)
            if !turn.sources.isEmpty {
                HStack(spacing: 6) {
                    ForEach(turn.sources, id: \.self) { SourceLink(source: $0) }
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(AssistantView.animates ? .easeOut(duration: 0.3) : nil, value: turn.sources)
        .onChange(of: turn.answer) { old, new in reveal(old, new) }
    }

    /// Paces the reveal: each arrival takes longer the more it brings, so bursts glide in instead of jumping.
    private func reveal(_ old: String, _ new: String) {
        guard AssistantView.animates else { shown = Self.full(new); return }
        if !new.hasPrefix(old) {
            // The answer started over (text after a web search replaces what came before it).
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { shown = 0 }
        }
        let fresh = Double(new.count - (new.hasPrefix(old) ? old.count : 0))
        withAnimation(.linear(duration: min(1.4, max(0.35, fresh / 110)))) { shown = Self.full(new) }
    }
}

/// A cited page, as a small chip with its site's name (the page title on hover).
private struct SourceLink: View {
    let source: Assistant.Source
    @State private var hover = false

    var body: some View {
        Button {
            (NSApp.delegate as? AppDelegate)?.launcher.hide()
            NSWorkspace.shared.open(source.url)
        } label: {
            Text(source.url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? source.title)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(hover ? 0.14 : 0.075)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(source.title)
        .onHover { hover = $0 }
    }
}

/// What Ask is doing while there's no answer yet: an icon and a word or two with a light passing over them,
/// changing in place as it goes from thinking to searching to reading.
private struct StatusLine: View {
    let status: Assistant.Status

    var body: some View {
        ZStack(alignment: .leading) {
            line.id(status).transition(.opacity.combined(with: .offset(y: 3)))
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.22), value: status)
    }

    private var label: some View {
        HStack(spacing: 7) {
            Image(systemName: status.symbol).font(.system(size: 12, weight: .medium))
            Text(status.label).font(.system(size: 13.5)).lineLimit(1).truncationMode(.middle)
        }
    }

    private var line: some View {
        label
            .foregroundStyle(.secondary)
            .overlay {
                TimelineView(.animation) { t in
                    GeometryReader { g in
                        let x = (t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6) * (g.size.width + 120) - 60
                        LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 60)
                            .offset(x: x)
                    }
                }
                .mask { label }
                .allowsHitTesting(false)
            }
    }
}
