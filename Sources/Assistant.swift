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

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer = ""
        var sources: [Source] = []
        var failed = false
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
                    update(i, gen) { $0.answer = out }
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
        let history = messages + [["role": "user", "content": q]]
        var blocks: [[String: Any]] = []
        // A long search can pause the turn: sending the paused turn back lets it carry on.
        for _ in 0..<4 {
            let before = blocks
            let r = try await Claude.stream(system: Self.system(web: true), messages: blocks.isEmpty ? history : history + [["role": "assistant", "content": blocks]],
                                            model: c.model, effort: o.effort == "auto" ? task.effort : o.effort, maxTokens: c.maxTokens ?? task.maxTokens,
                                            tools: [Self.webSearch], timeout: task.timeout, fallback: o.fallback) { [weak self] now in
                guard let self, gen == self.generation else { return }
                self.updates += 1
                self.show(before + now, at: i, gen)
            }
            blocks = before + r.blocks
            if r.stop != "pause_turn" { break }
        }
        guard gen == generation else { return }
        show(blocks, at: i, gen)
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
        update(i, gen) {
            $0.answer = answer
            $0.sources = Array(sources.prefix(3))
        }
    }

    /// The basic search tool searches directly; the newer versions first run code over the results (dynamic
    /// filtering), which is slower than a quick answer wants.
    private static var webSearch: [String: Any] {
        ["type": "web_search_20250305", "name": "web_search", "max_uses": 3,
         "user_location": ["type": "approximate", "timezone": TimeZone.current.identifier]]
    }

    static func system(web: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return """
        You answer quick questions typed into a Mac launcher. Reply in the language of the question (Japanese question, Japanese answer). \
        Be short and direct: the answer first, in one to three sentences, or a few short bullets when a list is clearer. \
        No preamble, no headings, no restating the question, no offers of more help. \
        \(web ? "Search the web for anything current or changing (news, prices, scores, schedules, releases, opening hours); otherwise answer from what you know. Don't say that you are searching. " : "")\
        Today is \(f.string(from: Date())); the user's time zone is \(TimeZone.current.identifier).
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
        ]
        if busy {
            turns.append(Turn(question: "Best time of year to climb it?"))
            self.busy = true
        }
    }
}

/// The thread under the bar: one card, like an answer in the results, that grows with the answer and then scrolls.
struct AssistantView: View {
    let assistant: Assistant
    let radius: CGFloat

    static let maxCard: CGFloat = 440

    static func height(_ a: Assistant) -> CGFloat {
        guard !a.turns.isEmpty else { return 0 }
        return Metrics.rowGap + min(maxCard, max(a.contentHeight, 52)) + Metrics.listInset
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelLayout.inner(radius), style: .continuous)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(assistant.turns) { t in
                        if t.id != assistant.turns.first?.id { Divider().opacity(0.6) }
                        AssistantTurn(turn: t, busy: assistant.busy && t.id == assistant.turns.last?.id)
                    }
                }
                .padding(cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { assistant.contentHeight = $0 }
                .id("thread")
            }
            .scrollIndicators(.never)
            .onChange(of: assistant.turns.last?.answer) { _, _ in proxy.scrollTo("thread", anchor: .bottom) }
            .onChange(of: assistant.turns.count) { _, _ in proxy.scrollTo("thread", anchor: .bottom) }
        }
        .background(shape.fill(cardFill))
        .clipShape(shape)
        .padding(.horizontal, Metrics.listInset)
        .padding(.top, Metrics.rowGap)
        .padding(.bottom, Metrics.listInset)
        .frame(height: Self.height(assistant), alignment: .top)
    }
}

private struct AssistantTurn: View {
    let turn: Assistant.Turn
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(2)
            if turn.failed {
                Label(turn.answer, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
            } else if !turn.answer.isEmpty {
                NotesView(markdown: turn.answer)
            } else if busy {
                ThinkingDots().colorMultiply(.primary).frame(height: 18)
            }
            if !turn.sources.isEmpty {
                HStack(spacing: 6) {
                    ForEach(turn.sources, id: \.self) { SourceLink(source: $0) }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
