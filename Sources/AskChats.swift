import AppKit
import Observation
import SwiftUI

/// A saved Ask conversation.
struct AskChat: Codable, Identifiable {
    var id = UUID()
    /// The first question.
    var title: String
    /// Last asked.
    var date: Date
    var turns: [Assistant.Turn]
    /// Claude's side of the thread as JSON, sent back exactly as it came when the chat continues.
    var messages: String

    func matches(_ q: String) -> Bool {
        q.isEmpty || turns.contains { $0.question.localizedStandardContains(q) || $0.answer.localizedStandardContains(q) }
    }
}

/// Every Ask chat, newest first (`~/Library/Application Support/MONEY/ask-chats.json`).
@MainActor @Observable final class AskChats {
    static let shared = AskChats()

    private(set) var all: [AskChat] = [] { didSet { scheduleSave() } }
    /// Off for snapshots and tests: they never read or write the real chats.
    @ObservationIgnored private var persist = !CommandLine.arguments.contains { $0.hasSuffix("-snapshot") || $0.hasSuffix("-test") }
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MONEY", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ask-chats.json")
    }

    private init() {
        guard persist, let data = try? Data(contentsOf: Self.url) else { return }
        all = (try? JSONDecoder().decode([AskChat].self, from: data)) ?? []
    }

    func matching(_ q: String) -> [AskChat] {
        let q = q.trimmingCharacters(in: .whitespaces)
        return all.filter { $0.matches(q) }
    }

    /// Adds the chat, or updates it, and moves it to the top.
    func save(_ chat: AskChat) {
        all.removeAll { $0.id == chat.id }
        all.insert(chat, at: 0)
    }

    func delete(_ id: UUID) { all.removeAll { $0.id == id } }
    func clear() { all = [] }

    private func scheduleSave() {
        guard persist else { return }
        saveWork?.cancel()
        let snapshot = all
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Made-up chats for snapshots and tests (never saved).
    func useDemo() {
        persist = false
        let day: TimeInterval = 86_400
        func chat(_ q: String, _ a: String, _ ago: TimeInterval, _ more: [(String, String)] = []) -> AskChat {
            let turns = ([(q, a)] + more).map { Assistant.Turn(question: $0.0, answer: $0.1) }
            return AskChat(title: q, date: Date().addingTimeInterval(-ago), turns: turns, messages: "[]")
        }
        all = [
            chat("How tall is Mount Fuji?", "**3,776 m** (12,388 ft).", 600, [("最後に噴火したのはいつ？", "1707年の宝永噴火が最後です。")]),
            chat("Convert 180 g of butter to cups", "About **0.8 cups** (180 g ÷ 227 g per cup).", 3 * 3600),
            chat("What's a good name for a jazz cafe in Shimokitazawa?", "- Blue Note Shimo\n- Slow Groove\n- Kissa Tempo", day + 200),
            chat("How do I undo the last git commit but keep the changes?", "`git reset --soft HEAD~1`", 3 * day),
            chat("新幹線で東京から京都まで何分？", "のぞみで約**2時間15分**です。", 9 * day),
            chat("Best time of year to see the cherry blossoms in Kyoto?", "**Late March to early April**.", 40 * day),
        ]
    }
}

/// When a chat was last asked, short: "14:05", "Yesterday", "Mon", "Oct 3".
func chatAge(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    if let week = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date())), d >= week { return d.formatted(.dateTime.weekday(.abbreviated)) }
    return d.formatted(.dateTime.month(.abbreviated).day())
}

/// Ask with an empty thread: earlier chats under the bar, filtered by what's typed. ↑↓ pick one, ↩ continues it.
struct AskChatList: View {
    let assistant: Assistant
    let chats: [AskChat]
    let s: Settings
    let radius: CGFloat
    let onOpen: (AskChat) -> Void
    @State private var hovered: UUID?

    static let maxRows = 6

    static func height(_ count: Int, _ s: Settings) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(min(count, maxRows)) * Metrics.slot(s) + Metrics.listInset - Metrics.rowGap
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(chats.enumerated()), id: \.element.id) { i, chat in
                        row(chat, selected: assistant.pick == i)
                            .padding(.vertical, Metrics.rowGap)
                            .id(i)
                            .onTapGesture { onOpen(chat) }
                            .onHover { inside in
                                if inside { hovered = chat.id } else if hovered == chat.id { hovered = nil }
                            }
                    }
                }
                .padding(.horizontal, Metrics.listInset)
            }
            .scrollIndicators(.never)
            .frame(height: CGFloat(min(chats.count, Self.maxRows)) * Metrics.slot(s))
            .padding(.bottom, Metrics.listInset - Metrics.rowGap)
            .onChange(of: assistant.pick) { _, i in if let i { proxy.scrollTo(i) } }
        }
    }

    private func row(_ chat: AskChat, selected: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "bubble.left").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
            Text(chat.title).font(.system(size: 15)).lineLimit(1)
            Spacer(minLength: 8)
            Text(chatAge(chat.date)).font(.system(size: 11.5)).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.horizontal, 13)
        .frame(height: s.rowSize)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(selected ? selectedFill : hovered == chat.id ? hoverFill : .clear))
        .contentShape(Rectangle())
    }
}

/// Settings › AI: the saved chats, to open again or delete.
struct AskChatsSection: View {
    let chats: AskChats
    @State private var showAll = false
    @State private var confirmClear = false

    var body: some View {
        Section {
            if chats.all.isEmpty {
                Text("No chats yet").foregroundStyle(.secondary)
            }
            ForEach(showAll ? chats.all : Array(chats.all.prefix(5))) { chat in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title).lineLimit(1)
                        Text("\(chatAge(chat.date)) · \(chat.turns.count == 1 ? "1 question" : "\(chat.turns.count) questions")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") { (NSApp.delegate as? AppDelegate)?.launcher.openChat(chat) }
                    Button { chats.delete(chat.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete")
                }
            }
            if !chats.all.isEmpty {
                HStack {
                    if chats.all.count > 5 { Button(showAll ? "Show fewer" : "Show all \(chats.all.count)") { showAll.toggle() } }
                    Spacer()
                    Button("Delete all chats…", role: .destructive) { confirmClear = true }
                }
            }
        } header: {
            Text("Ask chats")
        }
        .confirmationDialog("Delete all \(chats.all.count) chats?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { chats.clear() }
        }
    }
}
