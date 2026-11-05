import AppKit
import Observation
import SwiftUI

// The meeting notepad: Markdown on disk, styled like Notion while you type. Markers ("- ", "## ", "- [ ] ") stay in the
// text but are hidden or drawn as bullets, boxes and bars; "/" opens a menu of blocks at the caret.

// MARK: - Lines

/// One line of Markdown, as far as the notepad cares.
struct MDLine: Equatable {
    enum Kind: Equatable { case text, heading(Int), bullet, numbered(Int), todo(Bool), quote, toggle(Bool), divider, fence, code, row, rule }
    let kind: Kind
    /// Leading spaces and tabs (characters), and the nesting level they make (two spaces or a tab each).
    var indent = 0
    var level = 0
    /// Characters after the indent before the content ("- [ ] " is 6).
    var marker = 0
    var content: Int { indent + marker }

    /// Lists, headings, quotes and toggles: their marker is hidden or drawn, so the caret never stops inside it.
    var hidesMarker: Bool {
        switch kind {
        case .heading, .bullet, .numbered, .todo, .quote, .toggle: true
        case .text: indent > 0
        default: false
        }
    }

    static func parse(_ s: String, inCode: Bool) -> MDLine {
        let lead = s.prefix { $0 == " " || $0 == "\t" }
        let r = s.dropFirst(lead.count)
        if r.hasPrefix("```") { return MDLine(kind: .fence) }
        if inCode { return MDLine(kind: .code) }
        let level = lead.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let line = { (k: Kind, m: Int) in MDLine(kind: k, indent: lead.count, level: level, marker: m) }
        let t = r.trimmingCharacters(in: .whitespaces)
        if lead.isEmpty, ["---", "***", "___"].contains(t) { return MDLine(kind: .divider) }
        for h in 1...3 where r.hasPrefix(String(repeating: "#", count: h) + " ") { return line(.heading(h), h + 1) }
        for box in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] "] where r.hasPrefix(box) { return line(.todo(box.lowercased().contains("x")), 6) }
        if r.hasPrefix("- ") || r.hasPrefix("* ") || r.hasPrefix("+ ") { return line(.bullet, 2) }
        let digits = r.prefix { $0.isASCII && $0.isNumber }
        if (1...3).contains(digits.count), r.dropFirst(digits.count).hasPrefix(". ") { return line(.numbered(Int(digits) ?? 1), digits.count + 2) }
        if r.hasPrefix("> ") { return line(.quote, 2) }
        if r.hasPrefix("▸ ") || r.hasPrefix("▾ ") { return line(.toggle(r.hasPrefix("▾")), 2) }
        if lead.isEmpty, r.hasPrefix("|") { return MDLine(kind: t.contains("-") && t.allSatisfy({ "|:- ".contains($0) }) ? .rule : .row) }
        return line(.text, 0)
    }

    /// The cells of a table row, trimmed ("| a | b |" is ["a", "b"]).
    static func cells(_ row: String) -> [String] {
        var parts = row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
}

// MARK: - Slash menu

struct SlashItem: Identifiable, Equatable {
    enum Action: Equatable { case block(String), divider, code, table, date, time, mention(String) }
    let title: String
    /// An SF Symbol, or a short label such as "H1".
    let icon: String
    var keys = ""
    let action: Action
    var id: String { title }

    static let blocks = [
        SlashItem(title: "Text", icon: "text.alignleft", keys: "plain paragraph", action: .block("")),
        SlashItem(title: "Heading 1", icon: "H1", keys: "h1 title", action: .block("# ")),
        SlashItem(title: "Heading 2", icon: "H2", keys: "h2 subtitle", action: .block("## ")),
        SlashItem(title: "Heading 3", icon: "H3", keys: "h3", action: .block("### ")),
        SlashItem(title: "Bulleted list", icon: "list.bullet", keys: "ul bullet points", action: .block("- ")),
        SlashItem(title: "Numbered list", icon: "list.number", keys: "ol ordered", action: .block("1. ")),
        SlashItem(title: "To-do list", icon: "checkmark.square", keys: "todo checkbox task action", action: .block("- [ ] ")),
        SlashItem(title: "Toggle list", icon: "chevron.right", keys: "collapse details fold", action: .block("▾ ")),
        SlashItem(title: "Quote", icon: "text.quote", keys: "blockquote citation", action: .block("> ")),
        SlashItem(title: "Divider", icon: "minus", keys: "hr line separator rule", action: .divider),
        SlashItem(title: "Code", icon: "chevron.left.forwardslash.chevron.right", keys: "snippet pre", action: .code),
        SlashItem(title: "Table", icon: "tablecells", keys: "grid rows columns", action: .table),
        SlashItem(title: "Date", icon: "calendar", keys: "today stamp", action: .date),
        SlashItem(title: "Time", icon: "clock", keys: "now stamp", action: .time),
    ]

    /// What "/query" shows: blocks and people whose name or keywords start with it, title matches first.
    static func matching(_ query: String, people: [String]) -> [SlashItem] {
        let all = blocks + people.map { SlashItem(title: $0, icon: "person", keys: "mention @ person", action: .mention($0)) }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        let words = { (s: String) in s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let title = all.filter { $0.title.lowercased().hasPrefix(q) || words($0.title).contains { $0.hasPrefix(q) } }
        let keys = all.filter { i in !title.contains(i) && words(i.keys).contains { $0.hasPrefix(q) } }
        return title + keys
    }
}

/// The menu "/" opens: what's typed after the slash, the row picked, and where the caret is (in the editor's coordinates).
@MainActor @Observable final class SlashMenu {
    var isOpen = false
    var query = "" { didSet { if query != oldValue { index = 0 } } }
    var index = 0
    var anchor = CGRect.zero
    var people: [String] = []
    @ObservationIgnored var at = 0
    @ObservationIgnored var pick: (SlashItem) -> Void = { _ in }

    var items: [SlashItem] { SlashItem.matching(query, people: people) }

    func move(_ by: Int) {
        let n = items.count
        if n > 0 { index = (index + by + n) % n }
    }

    func close() {
        isOpen = false
        query = ""
    }
}

// MARK: - The editor

/// The notepad: a Markdown text view with a "/" menu over it.
struct NoteEditor: View {
    @Binding var text: String
    var people: [String] = []
    var bottom: CGFloat = 0
    var placeholder = "Write notes"
    @State private var slash = SlashMenu()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                NoteTextBox(text: $text, slash: slash, people: people, bottom: bottom)
                if text.isEmpty {
                    Text(placeholder).font(.system(size: MDStyle.size)).foregroundStyle(.tertiary)
                        .padding(.leading, PanelLayout.inset).allowsHitTesting(false)
                }
                if slash.isOpen, !slash.items.isEmpty {
                    let size = SlashMenuView.size(slash.items.count)
                    let below = slash.anchor.maxY + 6
                    SlashMenuView(menu: slash)
                        .offset(x: min(max(PanelLayout.inset, slash.anchor.minX), geo.size.width - size.width - PanelLayout.inset),
                                y: below + size.height <= geo.size.height ? below : max(0, slash.anchor.minY - 6 - size.height))
                        .transition(.opacity.animation(.easeOut(duration: 0.12)))
                }
            }
        }
    }
}

/// The blocks to pick from, Notion style: an icon and a name per row, the picked one on a soft fill.
struct SlashMenuView: View {
    let menu: SlashMenu
    static let row: CGFloat = 30
    static let pad: CGFloat = 6
    static let radius: CGFloat = 14

    static func size(_ count: Int) -> CGSize { CGSize(width: 232, height: CGFloat(min(count, 8)) * row + pad * 2) }

    var body: some View {
        let items = menu.items
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        Button { menu.pick(item) } label: { label(item, on: i == menu.index) }
                            .buttonStyle(.plain)
                            .onHover { if $0 { menu.index = i } }
                            .id(i)
                    }
                }
                .padding(Self.pad)
            }
            .scrollIndicators(.never)
            .onChange(of: menu.index) { _, i in proxy.scrollTo(i) }
        }
        .frame(width: Self.size(items.count).width, height: Self.size(items.count).height)
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Color(white: 0.17)))
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    private func label(_ item: SlashItem, on: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if item.icon.first?.isUppercase == true {
                    Text(item.icon).font(.system(size: 11, weight: .bold))
                } else {
                    Image(systemName: item.icon).font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 20)
            Text(item.title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.row)
        .background(RoundedRectangle(cornerRadius: Self.radius - Self.pad, style: .continuous).fill(Color.primary.opacity(on ? 0.12 : 0)))
        .contentShape(Rectangle())
    }
}

private struct NoteTextBox: NSViewRepresentable {
    @Binding var text: String
    let slash: SlashMenu
    let people: [String]
    let bottom: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let tv = NoteTextView(frame: .zero, textContainer: container)
        tv.slash = slash
        tv.people = people
        slash.pick = { [weak tv] in tv?.choose($0) }
        storage.delegate = context.coordinator
        tv.delegate = context.coordinator
        context.coordinator.view = tv
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
        tv.frame = NSRect(origin: .zero, size: scroll.contentSize)
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NoteTextView else { return }
        tv.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        if tv.people != people {
            tv.people = people
            tv.restyle()
        }
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
        }
        if scroll.contentInsets.bottom != bottom { scroll.contentInsets.bottom = bottom }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: NoteTextBox
        weak var view: NoteTextView?

        init(_ parent: NoteTextBox) { self.parent = parent }

        nonisolated func textStorage(_ s: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength: Int) {
            guard mask.contains(.editedCharacters) else { return }
            // Not while a Japanese word is still being composed (that keeps its underline); it's styled once committed.
            MainActor.assumeIsolated { if view?.hasMarkedText() != true { view?.restyle() } }
        }

        func textDidChange(_ n: Notification) {
            guard let tv = view else { return }
            if parent.text != tv.string { parent.text = tv.string }
            tv.followSlash()
        }

        func textViewDidChangeSelection(_ n: Notification) {
            view?.followSlash()
            view?.matchTyping()
        }

        func textView(_ tv: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
            view?.snap(old, new) ?? new
        }
    }
}

// MARK: - Finished notes

/// The parts of the notes that aren't lines of text: tables, dividers and toggles. Everything else stays one text.
enum NoteBlock: Equatable {
    case text(String), table([[String]]), divider, toggle(String, inside: String, open: Bool)

    /// The blocks, each with where it starts in the Markdown (in characters, for the fade-in).
    static func split(_ md: String) -> [(block: NoteBlock, at: Int)] {
        let lines = md.components(separatedBy: "\n")
        var out: [(NoteBlock, Int)] = [], text: [String] = []
        var at = 0, textAt = 0, i = 0, code = false
        let level = { (s: String) in s.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2 }
        func flush() {
            if !text.isEmpty { out.append((.text(text.joined(separator: "\n")), textAt)) }
            text = []
        }
        func take(_ n: Int) { for k in i..<(i + n) { at += lines[k].count + 1 }; i += n }
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { code.toggle() }
            if !code, t.hasPrefix("|"), i + 1 < lines.count, MDLine.parse(lines[i + 1].trimmingCharacters(in: .whitespaces), inCode: false).kind == .rule {
                flush()
                let start = at
                var rows = [MDLine.cells(t)], n = 2
                while i + n < lines.count, lines[i + n].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(MDLine.cells(lines[i + n].trimmingCharacters(in: .whitespaces)))
                    n += 1
                }
                out.append((.table(rows), start))
                take(n)
            } else if !code, MDLine.parse(lines[i], inCode: false).kind == .divider {
                flush()
                out.append((.divider, at))
                take(1)
            } else if !code, t.hasPrefix("▸ ") || t.hasPrefix("▾ ") {
                flush()
                let start = at, depth = level(lines[i])
                var n = 1
                while i + n < lines.count, !lines[i + n].trimmingCharacters(in: .whitespaces).isEmpty, level(lines[i + n]) > depth { n += 1 }
                let inside = lines[(i + 1)..<(i + n)].map { String($0.dropFirst(min(2 * (depth + 1), $0.prefix { $0 == " " }.count))) }
                out.append((.toggle(String(t.dropFirst(2)), inside: inside.joined(separator: "\n"), open: t.hasPrefix("▾")), start))
                take(n)
            } else {
                if text.isEmpty { textAt = at }
                text.append(lines[i])
                take(1)
            }
        }
        flush()
        return out
    }
}
