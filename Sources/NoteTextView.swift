import AppKit

// The notepad's text view: Markdown styled as you type (markers hidden or drawn as bullets, boxes, bars and a
// table grid), Notion's keys (↩ carries lists on, ⇥ nests and moves between cells, ⌫ undoes a marker), and the "/" menu.

// MARK: - Styling

/// How each kind of line looks. The look is attributes over the Markdown; bullets, boxes, bars and grids are drawn.
@MainActor enum MDStyle {
    static let size: CGFloat = 14
    static var body: NSFont { Fonts.ns(.answers, size) }
    static let hiddenFont = NSFont.systemFont(ofSize: 0.5)
    /// Width of one nesting level and of a list marker.
    static let step: CGFloat = 22
    static let tint = NSColor(red: 0.18, green: 0.72, blue: 0.45, alpha: 1)

    enum Deco {
        case dot(Int, level: Int), box(Int, done: Bool), chevron(Int, open: Bool), bar(NSRange), divider(NSRange)
        /// A table: its line ranges (the second is the |---| rule) and the pipes of its first row.
        case table([NSRange], pipes: [Int])
    }

    struct Output {
        var lines: [(range: NSRange, line: MDLine, attrs: [NSAttributedString.Key: Any])] = []
        var decos: [Deco] = []
        var hidden: [NSRange] = []
        var tables: [[NSRange]] = []
    }

    static func headingFont(_ h: Int) -> NSFont { Fonts.ns(.answers, [20, 17, 15][h - 1], weight: .semibold) }

    static func paragraph(head: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 0, spacing: CGFloat = 4, height: CGFloat = 0, max: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.headIndent = head
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineSpacing = spacing
        p.minimumLineHeight = height
        p.maximumLineHeight = max
        return p
    }

    static func width(_ s: String, _ font: NSFont) -> CGFloat { NSAttributedString(string: s, attributes: [.font: font]).size().width }

    static func apply(_ s: NSTextStorage, names: [String]) -> Output {
        var out = Output()
        let ns = s.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        var parsed: [(NSRange, MDLine)] = []
        var inCode = false
        ns.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, r, _, _ in
            let l = MDLine.parse(ns.substring(with: r), inCode: inCode)
            if l.kind == .fence { inCode.toggle() }
            parsed.append((r, l))
        }
        // A table is a row, then a |---| rule, then more rows. Rows anywhere else are plain text.
        var inTable = Set<Int>()
        var i = 0
        while i < parsed.count {
            guard parsed[i].1.kind == .row, i + 1 < parsed.count, parsed[i + 1].1.kind == .rule else {
                if parsed[i].1.kind == .row || parsed[i].1.kind == .rule { parsed[i].1 = MDLine(kind: .text) }
                i += 1
                continue
            }
            var j = i + 2
            while j < parsed.count, parsed[j].1.kind == .row { j += 1 }
            inTable.formUnion(i..<j)
            out.tables.append(parsed[i..<j].map(\.0))
            i = j
        }
        // Children of a closed toggle (deeper lines right under it) fold away.
        var folded = Set<Int>()
        for (n, (_, l)) in parsed.enumerated() where l.kind == .toggle(false) {
            var j = n + 1
            while j < parsed.count, parsed[j].0.length > 0, parsed[j].1.level > l.level || parsed[j].1.kind == .code { folded.insert(j); j += 1 }
            if j > n + 1 { out.hidden.append(NSUnionRange(parsed[n + 1].0, parsed[j - 1].0)) }
        }

        let base: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph()]
        s.setAttributes(base, range: full)
        let hide = { (r: NSRange) in
            guard r.length > 0 else { return }
            s.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: r)
        }
        let space = width(" ", body)
        for (n, (r, l)) in parsed.enumerated() where !inTable.contains(n) {
            var attrs = base
            if folded.contains(n) {
                attrs = [.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: paragraph(spacing: 0, max: 0.01)]
                s.setAttributes(attrs, range: r)
                out.lines.append((r, l, attrs))
                continue
            }
            let indentW = CGFloat(l.level) * step
            if l.indent > 0 {
                let ir = NSRange(location: r.location, length: l.indent)
                hide(ir)
                s.addAttribute(.kern, value: indentW, range: NSRange(location: NSMaxRange(ir) - 1, length: 1))
            }
            let m = NSRange(location: r.location + l.indent, length: min(l.marker, r.length - l.indent))
            let gap = NSRange(location: NSMaxRange(m) - 1, length: 1) // the space after a marker
            let pad = { (w: CGFloat) in s.addAttribute(.kern, value: w, range: gap) }
            var head = indentW
            switch l.kind {
            case .heading(let h):
                hide(m)
                let f = headingFont(h)
                attrs[.font] = f
                // As tall as its text even while empty (the marker is hidden).
                attrs[.paragraphStyle] = paragraph(before: h == 1 ? 12 : 8, after: 2, height: ceil(f.ascender - f.descender + f.leading))
            case .bullet:
                hide(NSRange(location: m.location, length: 1))
                pad(step - space)
                out.decos.append(.dot(m.location, level: l.level))
                head += step
            case .todo(let done):
                hide(NSRange(location: m.location, length: 5))
                pad(step - space)
                out.decos.append(.box(m.location, done: done))
                head += step
                if done {
                    attrs[.foregroundColor] = NSColor.secondaryLabelColor
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            case .numbered:
                let label = NSRange(location: m.location, length: m.length - 1)
                let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
                s.addAttributes([.font: font, .foregroundColor: NSColor.secondaryLabelColor], range: label)
                pad(max(4, step - width(ns.substring(with: label), font) - space))
                head += step
            case .quote:
                hide(NSRange(location: m.location, length: 1))
                pad(16 - space)
                out.decos.append(.bar(r))
                head += 16
            case .toggle(let open):
                hide(NSRange(location: m.location, length: 1))
                pad(step - space)
                out.decos.append(.chevron(m.location, open: open))
                head += step
            case .divider:
                attrs[.font] = hiddenFont
                attrs[.foregroundColor] = NSColor.clear
                attrs[.paragraphStyle] = paragraph(spacing: 0, height: 24)
                out.decos.append(.divider(r))
            case .fence:
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
                attrs[.foregroundColor] = NSColor.tertiaryLabelColor
            case .code:
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            case .text, .row, .rule:
                break
            }
            if head > 0, l.kind != .divider, l.kind != .heading(1), l.kind != .heading(2), l.kind != .heading(3) { attrs[.paragraphStyle] = paragraph(head: head) }
            let content = NSRange(location: r.location + l.content, length: max(0, r.length - l.content))
            s.addAttributes(attrs, range: content)
            s.addAttribute(.paragraphStyle, value: attrs[.paragraphStyle] ?? paragraph(), range: r)
            mentions(s, content, names)
            out.lines.append((r, l, attrs))
        }
        for t in out.tables { table(s, t, &out) }
        return out
    }

    /// "@Name" for the people in the meeting, in green.
    private static func mentions(_ s: NSTextStorage, _ r: NSRange, _ names: [String]) {
        let ns = s.string as NSString
        for name in names where !name.isEmpty {
            var from = r.location
            while from < NSMaxRange(r) {
                let hit = ns.range(of: "@" + name, options: [], range: NSRange(location: from, length: NSMaxRange(r) - from))
                guard hit.location != NSNotFound else { break }
                s.addAttributes([.foregroundColor: tint, .font: NSFont.systemFont(ofSize: size, weight: .medium)], range: hit)
                from = NSMaxRange(hit)
            }
        }
    }

    /// Lines the columns up: the space before each pipe is stretched to the column's widest cell, the pipes are
    /// hidden, and the grid is drawn where they are.
    static let tableGap: CGFloat = 6

    private static func table(_ s: NSTextStorage, _ rows: [NSRange], _ out: inout Output) {
        let ns = s.string as NSString
        let headFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold), cellFont = NSFont.systemFont(ofSize: 13.5)
        let pipes = rows.map { r in (0..<r.length).filter { ns.character(at: r.location + $0) == 124 }.map { r.location + $0 } }
        var widths: [CGFloat] = []
        for (n, r) in rows.enumerated() where n != 1 {
            let font = n == 0 ? headFont : cellFont
            let p = pipes[n]
            // Rows pad their text inside the grid; the first and last get `tableGap` more, outside it.
            let style = paragraph(before: n == 0 ? 6 + tableGap : 6, after: n == rows.count - 1 ? 6 + tableGap : 6, spacing: 0)
            s.addAttributes([.font: font, .paragraphStyle: style], range: r)
            for k in 0..<max(0, p.count - 1) {
                let w = width(ns.substring(with: NSRange(location: p[k] + 1, length: p[k + 1] - p[k] - 1)), font)
                if widths.count <= k { widths.append(0) }
                widths[k] = max(widths[k], w)
            }
            out.lines.append((r, MDLine(kind: .row), [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]))
        }
        for n in rows.indices where n != 1 {
            let font = n == 0 ? headFont : cellFont
            let p = pipes[n]
            for k in 0..<max(0, p.count - 1) {
                let w = width(ns.substring(with: NSRange(location: p[k] + 1, length: p[k + 1] - p[k] - 1)), font)
                s.addAttribute(.kern, value: max(56, widths[k] + 12) - w, range: NSRange(location: p[k + 1] - 1, length: 1))
            }
            for i in p { s.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: i, length: 1)) }
        }
        s.setAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: paragraph(spacing: 0, height: 1, max: 1)], range: rows[1])
        out.lines.append((rows[1], MDLine(kind: .rule), [:]))
        out.decos.append(.table(rows, pipes: pipes[0]))
    }
}

// MARK: - Text view

final class NoteTextView: NSTextView {
    var slash: SlashMenu?
    var people: [String] = []
    private(set) var styled = MDStyle.Output()

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textContainerInset = NSSize(width: PanelLayout.inset, height: 0)
        font = MDStyle.body
        typingAttributes = [.font: MDStyle.body, .foregroundColor: NSColor.labelColor, .paragraphStyle: MDStyle.paragraph()]
        insertionPointColor = MDStyle.tint
    }

    required init?(coder: NSCoder) { fatalError() }

    private var ns: NSString { string as NSString }

    func restyle() {
        guard let s = textStorage else { return }
        styled = MDStyle.apply(s, names: people)
        needsDisplay = true
    }

    /// The line at a location, as last styled (the empty line after a final newline is plain text).
    func line(at loc: Int) -> (range: NSRange, line: MDLine)? {
        if let l = styled.lines.first(where: { loc >= $0.range.location && loc <= NSMaxRange($0.range) }) { return (l.range, l.line) }
        let start = ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0)).location
        return (NSRange(location: start, length: max(0, loc - start)), MDLine(kind: .text))
    }

    /// New text takes the look of the line it's typed in (an empty heading types big).
    func matchTyping() {
        let loc = selectedRange().location
        guard let l = styled.lines.first(where: { loc >= $0.range.location && loc <= NSMaxRange($0.range) }), !l.attrs.isEmpty else { return }
        typingAttributes = l.attrs
    }

    // MARK: Editing

    func replace(_ r: NSRange, _ s: String, caret: Int? = nil) {
        guard shouldChangeText(in: r, replacementString: s) else { return }
        textStorage?.replaceCharacters(in: r, with: s)
        didChangeText()
        setSelectedRange(NSRange(location: caret ?? r.location + (s as NSString).length, length: 0))
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let loc = selectedRange().location
        if typed == "/" || typed == "／", let slash {
            let before = loc >= 2 ? ns.substring(with: NSRange(location: loc - 2, length: 1)) : "\n"
            if before == " " || before == "\n" || before == "\t" || line(at: loc).map({ loc - 1 == $0.range.location + $0.line.content }) == true {
                slash.at = loc - 1
                slash.people = people
                slash.query = ""
                slash.isOpen = true
                followSlash()
            }
        } else if typed == " " {
            shortcut(at: loc)
        }
    }

    /// Markdown shortcuts that need rewriting: "[] " and "[ ] " make a to-do, "* " a bullet.
    private func shortcut(at loc: Int) {
        guard let (r, l) = line(at: loc), l.kind == .text || l.kind == .bullet else { return }
        let start = r.location + l.indent
        let typed = ns.substring(with: NSRange(location: start, length: loc - start))
        if typed == "[] " || typed == "[ ] " {
            replace(NSRange(location: start, length: loc - start), "- [ ] ")
        } else if typed == "* " {
            replace(NSRange(location: start, length: 2), "- ")
        }
    }

    override func doCommand(by sel: Selector) {
        if let slash, slash.isOpen {
            switch sel {
            case #selector(moveUp(_:)): return slash.move(-1)
            case #selector(moveDown(_:)): return slash.move(1)
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                let items = slash.items
                if items.indices.contains(slash.index) { return choose(items[slash.index]) }
            case #selector(cancelOperation(_:)): return slash.close()
            default: break
            }
        }
        switch sel {
        case #selector(insertNewline(_:)) where newline(): return
        case #selector(insertTab(_:)) where tab(forward: true): return
        case #selector(insertBacktab(_:)) where tab(forward: false): return
        case #selector(deleteBackward(_:)) where backspace(): return
        default: super.doCommand(by: sel)
        }
    }

    /// ↩ carries a list on ("- ", "1. " → "2. ", "- [ ] "), and on an empty item leaves it (outdents first).
    private func newline() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0, let (r, l) = line(at: sel.location) else { return false }
        let empty = r.length <= l.content
        let indent = ns.substring(with: NSRange(location: r.location, length: l.indent))
        switch l.kind {
        case .bullet, .todo, .numbered, .quote:
            if empty { leave(r, l); return true }
            let next = switch l.kind {
            case .todo: "- [ ] "
            case .numbered(let n): "\(n + 1). "
            default: ns.substring(with: NSRange(location: r.location + l.indent, length: l.marker))
            }
            replace(sel, "\n" + indent + next)
        case .toggle(let open):
            if empty { leave(r, l); return true }
            if !open, let fold = styled.hidden.first(where: { $0.location == NSMaxRange(r) + 1 }) {
                replace(NSRange(location: NSMaxRange(fold), length: 0), "\n" + indent)
            } else {
                replace(sel, "\n" + indent + "  ")
            }
        case .text where l.indent > 0:
            if empty { leave(r, l) } else { replace(sel, "\n" + indent) }
        case .row:
            tableNewline(r)
        case .fence:
            // An opening fence with nothing closing it: close it and type inside.
            let fences = styled.lines.filter { $0.line.kind == .fence }
            guard fences.count % 2 == 1, fences.last?.range == r, sel.location == NSMaxRange(r) else { return false }
            replace(sel, "\n\n```", caret: sel.location + 1)
        default:
            return false
        }
        return true
    }

    /// Out of a list item: one level out if nested, else back to plain text.
    private func leave(_ r: NSRange, _ l: MDLine) {
        let caret = selectedRange().location
        if l.level > 0 {
            let cut = ns.character(at: r.location) == 9 ? 1 : 2
            replace(NSRange(location: r.location, length: cut), "", caret: caret - cut)
        } else {
            replace(NSRange(location: r.location + l.indent, length: l.marker), "", caret: caret - l.marker)
        }
    }

    /// ⌫ at the start of a list item, heading or quote turns it back into text.
    private func backspace() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0, let (r, l) = line(at: sel.location), l.hidesMarker, l.content > 0, sel.location == r.location + l.content else { return false }
        leave(r, l)
        return true
    }

    /// ⇥ moves between table cells, nests list items (⇧⇥ un-nests), and indents code.
    private func tab(forward: Bool) -> Bool {
        let sel = selectedRange()
        guard let (r, l) = line(at: sel.location) else { return false }
        switch l.kind {
        case .row:
            jumpCell(r, forward: forward)
        case .code:
            guard forward else { return false }
            replace(sel, "    ")
        case .bullet, .todo, .numbered, .toggle, .quote, .text:
            guard l.kind != .text || l.indent > 0 else { return false }
            if forward {
                replace(NSRange(location: r.location, length: 0), "  ", caret: sel.location + 2)
            } else if l.indent > 0 {
                let cut = ns.character(at: r.location) == 9 ? 1 : min(2, l.indent)
                replace(NSRange(location: r.location, length: cut), "", caret: max(r.location, sel.location - cut))
            }
        default:
            return false
        }
        return true
    }

    // MARK: Tables

    private func table(containing loc: Int) -> [NSRange]? {
        styled.tables.first { t in t.contains { loc >= $0.location && loc <= NSMaxRange($0) } }
    }

    private func pipes(_ r: NSRange) -> [Int] {
        (0..<r.length).filter { ns.character(at: r.location + $0) == 124 }.map { r.location + $0 }
    }

    /// Puts the caret in cell `k` of a row: its text selected, or between the spaces of an empty one.
    private func select(cell k: Int, in r: NSRange) {
        let p = pipes(r)
        guard p.count > k + 1 else { return setSelectedRange(NSRange(location: NSMaxRange(r), length: 0)) }
        let inner = NSRange(location: p[k] + 1, length: p[k + 1] - p[k] - 1)
        let text = ns.substring(with: inner)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            setSelectedRange(NSRange(location: inner.location + min(1, inner.length), length: 0))
        } else {
            let start = inner.location + (text as NSString).range(of: trimmed).location
            setSelectedRange(NSRange(location: start, length: (trimmed as NSString).length))
        }
    }

    private func jumpCell(_ r: NSRange, forward: Bool) {
        guard let t = table(containing: r.location), let row = t.firstIndex(of: r) else { return }
        let p = pipes(r), loc = selectedRange().location
        let k = max(0, (p.lastIndex { $0 < loc } ?? 0))
        let rows = t.enumerated().filter { $0.offset != 1 }.map(\.element)
        guard let at = rows.firstIndex(of: t[row]) else { return }
        if forward {
            if k + 1 < p.count - 1 { return select(cell: k + 1, in: r) }
            if at + 1 < rows.count { return select(cell: 0, in: rows[at + 1]) }
            addRow(after: r)
        } else {
            if k > 0 { return select(cell: k - 1, in: r) }
            if at > 0 { select(cell: max(0, pipes(rows[at - 1]).count - 2), in: rows[at - 1]) }
        }
    }

    private func addRow(after r: NSRange) {
        guard let t = table(containing: r.location) else { return }
        let below = r == t[0] ? t[1] : r
        let cells = max(1, pipes(t[0]).count - 1)
        let row = "|" + String(repeating: "  |", count: cells)
        replace(NSRange(location: NSMaxRange(below), length: 0), "\n" + row, caret: NSMaxRange(below) + 3)
    }

    /// ↩ in a table adds a row under this one; on an empty row it ends the table.
    private func tableNewline(_ r: NSRange) {
        guard let t = table(containing: r.location) else { return }
        if r != t[0], MDLine.cells(ns.substring(with: r)).allSatisfy(\.isEmpty) {
            replace(r, "")
        } else {
            addRow(after: r)
        }
    }

    /// Rewrites the table around the caret (cells as text, row by row; the rule is rebuilt).
    private func editTable(_ change: (inout [[String]], _ row: Int, _ col: Int) -> Void) {
        let loc = selectedRange().location
        guard let t = table(containing: loc), let rowAt = t.firstIndex(where: { loc >= $0.location && loc <= NSMaxRange($0) }) else { return }
        var rows = t.enumerated().filter { $0.offset != 1 }.map { MDLine.cells(ns.substring(with: $0.element)) }
        let width = rows.map(\.count).max() ?? 1
        rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        let col = max(0, (pipes(t[rowAt]).lastIndex { $0 < loc } ?? 0))
        change(&rows, rowAt == 0 ? 0 : max(0, rowAt - 1), min(col, width - 1))
        guard let cols = rows.first?.count, cols > 0 else {
            return replace(NSUnionRange(t[0], t[t.count - 1]), "")
        }
        var lines = rows.map(MDLine.row)
        lines.insert(MDLine.row(Array(repeating: "---", count: cols)), at: 1)
        replace(NSUnionRange(t[0], t[t.count - 1]), lines.joined(separator: "\n"), caret: t[0].location + 2)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = super.menu(for: event) ?? NSMenu()
        guard table(containing: selectedRange().location) != nil else { return m }
        m.insertItem(.separator(), at: 0)
        for (title, sel) in [("Delete Column", #selector(deleteColumn)), ("Delete Row", #selector(deleteRow)), ("Add Column", #selector(addColumn)), ("Add Row", #selector(addRowItem))] {
            m.insertItem(NSMenuItem(title: title, action: sel, keyEquivalent: ""), at: 0)
        }
        return m
    }

    @objc private func addRowItem() { editTable { rows, row, _ in rows.insert(Array(repeating: "", count: rows[0].count), at: row + 1) } }
    @objc private func addColumn() { editTable { rows, _, col in for i in rows.indices { rows[i].insert("", at: col + 1) } } }
    @objc private func deleteRow() { editTable { rows, row, _ in if rows.count > 1, row > 0 { rows.remove(at: row) } } }
    @objc private func deleteColumn() { editTable { rows, _, col in for i in rows.indices { rows[i].remove(at: col) }; if rows[0].isEmpty { rows = [] } } }

    // MARK: Slash menu

    /// Keeps the menu on what's typed after "/"; closes it when the slash goes, the caret leaves, or nothing matches.
    func followSlash() {
        guard let slash, slash.isOpen else { return }
        let sel = selectedRange()
        guard sel.length == 0, isSlash(slash.at), sel.location > slash.at else { return slash.close() }
        let q = ns.substring(with: NSRange(location: slash.at + 1, length: sel.location - slash.at - 1))
        guard !q.contains("\n"), !q.hasPrefix(" "), q.count <= 24 else { return slash.close() }
        slash.query = q
        if slash.items.isEmpty { return slash.close() }
        if let lm = layoutManager, let tc = textContainer {
            let g = lm.glyphRange(forCharacterRange: NSRange(location: slash.at, length: 1), actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: g, in: tc).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            if let scroll = enclosingScrollView {
                rect = convert(rect, to: scroll)
                rect.origin.y = scroll.isFlipped ? rect.minY : scroll.bounds.height - rect.maxY
            }
            slash.anchor = rect
        }
    }

    /// "/", or the full-width "／" Japanese input types.
    private func isSlash(_ i: Int) -> Bool { i < ns.length && [47, 0xFF0F].contains(ns.character(at: i)) }

    func choose(_ item: SlashItem) {
        guard let slash else { return }
        let at = slash.at, caret = selectedRange().location
        slash.close()
        if caret > at, isSlash(at) { replace(NSRange(location: at, length: caret - at), "", caret: at) }
        guard let (r, l) = line(at: at) else { return }
        let empty = r.length <= l.content && l.kind == .text && l.indent == 0
        /// A block of its own: in place of an empty line, else under this one.
        let block = { (text: String, caret: Int) in
            if empty { self.replace(r, text, caret: r.location + caret) } else { self.replace(NSRange(location: NSMaxRange(r), length: 0), "\n" + text, caret: NSMaxRange(r) + 1 + caret) }
        }
        switch item.action {
        case .block(let prefix):
            let marker = l.kind == .row || l.kind == .rule || l.kind == .code || l.kind == .fence ? 0 : l.marker
            let m = NSRange(location: r.location + l.indent, length: marker)
            replace(m, prefix, caret: at - marker + (prefix as NSString).length)
        case .divider: block("---\n", 4)
        case .code: block("```\n\n```", 4)
        case .table:
            let row = "|  |  |  |"
            block([row, "| --- | --- | --- |", row, row].joined(separator: "\n"), 2)
        case .date: replace(NSRange(location: at, length: 0), Date().formatted(date: .long, time: .omitted))
        case .time: replace(NSRange(location: at, length: 0), Date().formatted(date: .omitted, time: .shortened))
        case .mention(let name): replace(NSRange(location: at, length: 0), "@\(name) ")
        }
    }

    // MARK: Caret

    /// Keeps the caret out of hidden markers and folded toggles: ← from the start of an item goes to the line above.
    func snap(_ old: NSRange, _ new: NSRange) -> NSRange {
        guard new.length == 0 else { return new }
        let loc = new.location
        if let h = styled.hidden.first(where: { loc >= $0.location && loc <= NSMaxRange($0) }) {
            let ahead = old.location < h.location && NSMaxRange(h) + 1 <= ns.length
            return NSRange(location: ahead ? NSMaxRange(h) + 1 : max(0, h.location - 1), length: 0)
        }
        guard let (r, l) = line(at: loc), l.hidesMarker, l.content > 0 else { return new }
        let start = r.location + l.content
        guard loc < start, loc >= r.location else { return new }
        if old.length == 0, old.location == start, r.location > 0 { return NSRange(location: r.location - 1, length: 0) }
        return NSRange(location: min(start, NSMaxRange(r)), length: 0)
    }

    // MARK: Drawing

    private func x(_ i: Int) -> CGFloat {
        guard let lm = layoutManager else { return 0 }
        let g = lm.glyphIndexForCharacter(at: i)
        guard g < lm.numberOfGlyphs else { return lm.usedRect(for: textContainer!).maxX + textContainerOrigin.x }
        return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + lm.location(forGlyphAt: g).x + textContainerOrigin.x
    }

    /// The baseline of the line holding character `i`.
    private func baseline(_ i: Int) -> CGFloat {
        guard let lm = layoutManager, lm.numberOfGlyphs > 0 else { return 0 }
        let g = min(lm.glyphIndexForCharacter(at: i), lm.numberOfGlyphs - 1)
        return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY + textContainerOrigin.y + lm.location(forGlyphAt: g).y
    }

    private func box(_ r: NSRange) -> CGRect {
        guard let lm = layoutManager, r.length > 0 else { return .zero }
        let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var rect = CGRect.null
        lm.enumerateLineFragments(forGlyphRange: g) { f, _, _, _, _ in rect = rect.union(f) }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    private func symbol(_ name: String, _ size: CGFloat, _ color: NSColor, at c: CGPoint, weight: NSFont.Weight = .regular) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Where a marker's drawing goes (and where a click toggles it).
    func markerCenter(_ i: Int) -> CGPoint {
        CGPoint(x: x(i) + MDStyle.step / 2 - 3, y: baseline(i) - MDStyle.body.xHeight / 2)
    }

    override func draw(_ dirty: NSRect) {
        super.draw(dirty)
        let line = NSColor.labelColor.withAlphaComponent(0.16)
        for d in styled.decos {
            switch d {
            case .dot(let i, let level):
                let c = markerCenter(i), r = CGRect(x: c.x - 2.75, y: c.y - 2.75, width: 5.5, height: 5.5)
                NSColor.labelColor.withAlphaComponent(0.85).set()
                switch level % 3 {
                case 1: let p = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1.1; p.stroke()
                case 2: NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).fill()
                default: NSBezierPath(ovalIn: r).fill()
                }
            case .box(let i, let done):
                let c = markerCenter(i)
                symbol(done ? "checkmark.square.fill" : "square", 14, done ? MDStyle.tint : .secondaryLabelColor, at: CGPoint(x: c.x + 1, y: c.y))
            case .chevron(let i, let open):
                symbol(open ? "chevron.down" : "chevron.right", 10, .secondaryLabelColor, at: markerCenter(i), weight: .semibold)
            case .bar(let r):
                let b = box(r)
                NSColor.labelColor.withAlphaComponent(0.35).set()
                NSBezierPath(roundedRect: CGRect(x: x(r.location) + 1, y: b.minY, width: 3, height: b.height - 2), xRadius: 1.5, yRadius: 1.5).fill()
            case .divider(let r):
                let b = box(r)
                line.set()
                NSBezierPath(rect: CGRect(x: textContainerOrigin.x, y: b.midY.rounded() - 0.5, width: bounds.width - textContainerOrigin.x * 2, height: 1)).fill()
            case .table(let rows, let pipes):
                guard let first = pipes.first, let last = pipes.last, first < last else { continue }
                let frames = rows.enumerated().filter { $0.offset != 1 }.map { box($0.element) }
                guard let top = frames.first.map({ $0.minY + MDStyle.tableGap }), let end = frames.last?.maxY else { continue }
                let bottom = end - (rows.count > 2 ? MDStyle.tableGap : 0)
                let pipeW = MDStyle.width("|", MDStyle.body) / 2
                let left = x(first) + pipeW, right = x(last) + pipeW
                let frame = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                line.set()
                let border = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
                border.lineWidth = 1
                border.stroke()
                for p in pipes.dropFirst().dropLast() { NSBezierPath(rect: CGRect(x: x(p) + pipeW - 0.5, y: top, width: 1, height: bottom - top)).fill() }
                for f in frames.dropLast() { NSBezierPath(rect: CGRect(x: left, y: f.maxY - 0.5, width: right - left, height: 1)).fill() }
            }
        }
    }

    /// A click on a to-do's box ticks it; on a toggle's arrow opens or closes it.
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        for d in styled.decos {
            switch d {
            case .box(let i, let done) where hit(i, p):
                return replace(NSRange(location: i + 3, length: 1), done ? " " : "x", caret: selectedRange().location)
            case .chevron(let i, let open) where hit(i, p):
                return replace(NSRange(location: i, length: 1), open ? "▸" : "▾", caret: selectedRange().location)
            default: continue
            }
        }
        super.mouseDown(with: e)
    }

    private func hit(_ i: Int, _ p: CGPoint) -> Bool {
        let c = markerCenter(i)
        return abs(p.x - c.x) <= 10 && abs(p.y - c.y) <= 10
    }
}
