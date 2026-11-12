import AppKit
import SwiftUI

/// What the ⌘3 view's buttons do (wired to the controller).
struct TextActions {
    var copySelection: () -> Void = {}
    var copyAll: () -> Void = {}
    var retake: () -> Void = {}
    /// A scanned QR code or barcode: open it (links) or copy it.
    var code: (ScreenTextResult.Code) -> Void = { _ in }
}

/// Small pill buttons at the right end of the bar in Text and Meeting modes.
struct BarControls<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 6) { content() }
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
    }
}

struct PillButton: View {
    let title: String?
    let symbol: String
    var tint: Color? = nil
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                if let title { Text(title).font(.system(size: 12.5, weight: .medium)) }
            }
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            .padding(.horizontal, title == nil ? 0 : 11)
            .frame(width: title == nil ? 32 : nil, height: 32)
            .background(Capsule().fill((tint ?? .primary).opacity(hovering ? 0.2 : 0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct TextControls: View {
    let actions: TextActions
    var codes: [ScreenTextResult.Code] = []

    var body: some View {
        if let c = codes.first {
            PillButton(title: c.url != nil ? "Open QR link" : "Copy QR", symbol: "qrcode", tint: .green, help: c.payload) { actions.code(c) }
        }
        PillButton(title: "Copy all", symbol: "doc.on.doc", help: "Copy every word (↩)") { actions.copyAll() }
        PillButton(title: nil, symbol: "viewfinder", help: "Capture another area (⌘3)") { actions.retake() }
    }
}

// MARK: ⌘3 Text

/// The captured picture with every word outlined. Drag across words to highlight them; letting go copies them.
struct TextModeView: View {
    let model: LauncherModel
    let s: Settings
    let radius: CGFloat
    let onCopy: () -> Void
    var actions = TextActions()
    @State private var anchor: Int?

    var body: some View {
        Group {
            if let r = model.screenText {
                let size = model.textDisplaySize
                let q = model.query.trimmingCharacters(in: .whitespaces).lowercased()
                ZStack(alignment: .bottom) {
                    Image(nsImage: r.image).resizable().interpolation(.high)
                        .frame(width: size.width, height: size.height)
                    Canvas { ctx, _ in
                        for (i, t) in r.tokens.enumerated() {
                            let rect = frame(t.box, size).insetBy(dx: -1.5, dy: -1.5)
                            let selected = model.textSelection?.contains(i) == true
                            let match = !q.isEmpty && t.text.lowercased().contains(q)
                            let color: Color = selected ? .accentColor.opacity(0.42) : match ? .yellow.opacity(0.5) : .white.opacity(0.13)
                            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
                    Color.clear
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    if anchor == nil { anchor = token(at: v.startLocation, r, size, exact: true) ?? -1 }
                                    guard let a = anchor, a >= 0, let b = token(at: v.location, r, size, exact: false) else {
                                        model.textSelection = nil
                                        return
                                    }
                                    model.textSelection = min(a, b)...max(a, b)
                                }
                                .onEnded { _ in
                                    anchor = nil
                                    if model.textSelection != nil { onCopy() }
                                }
                        )
                        .onContinuousHover { phase in
                            if case .active(let p) = phase, token(at: p, r, size, exact: true) != nil { NSCursor.iBeam.set() } else { NSCursor.arrow.set() }
                        }
                    ForEach(r.codes.indices, id: \.self) { i in
                        let c = r.codes[i]
                        let box = frame(c.box, size)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.green, lineWidth: 2.5)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.green.opacity(0.12)))
                            .frame(width: box.width + 8, height: box.height + 8)
                            .position(x: box.midX, y: box.midY)
                            .allowsHitTesting(false)
                        Button { actions.code(c) } label: {
                            Label(c.url.map { $0.host ?? $0.absoluteString } ?? Tools.oneLine(c.payload, 40), systemImage: c.url != nil ? "arrow.up.right.square.fill" : "doc.on.doc.fill")
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(Capsule().fill(Color.green))
                                .foregroundStyle(.white)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(c.url != nil ? "Open \(c.payload)" : "Copy \(c.payload)")
                        .fixedSize()
                        .position(x: min(max(box.midX, 90), size.width - 90), y: min(box.maxY + 24, size.height - 20))
                    }
                    if let toast = model.textToast {
                        Label(toast, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12.5, weight: .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Capsule().fill(.black.opacity(0.72)))
                            .foregroundStyle(.white)
                            .padding(.bottom, 12)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: max(6, radius - Metrics.listInset), style: .continuous))
                .padding(.horizontal, Metrics.listInset)
                .padding(.bottom, Metrics.listInset)
            } else if let status = model.textStatus {
                HStack(spacing: 8) {
                    if status.hasPrefix("Reading") { ThinkingDots().foregroundStyle(.secondary) }
                    Text(status).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .frame(height: 44, alignment: .top)
            }
        }
    }

    private func frame(_ box: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
    }

    /// The word under `p`, or (while dragging) the nearest one so gaps between words don't break the selection.
    private func token(at p: CGPoint, _ r: ScreenTextResult, _ size: CGSize, exact: Bool) -> Int? {
        var best: (Int, CGFloat)?
        for (i, t) in r.tokens.enumerated() {
            let f = frame(t.box, size).insetBy(dx: -3, dy: -3)
            if f.contains(p) { return i }
            guard !exact else { continue }
            let dx = max(f.minX - p.x, 0, p.x - f.maxX), dy = max(f.minY - p.y, 0, p.y - f.maxY)
            let d = dx * dx + dy * dy * 4 // prefer the same line
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
}

// MARK: ⌘4 Meeting

struct MeetingActions {
    var new: () -> Void = {}
    var back: () -> Void = {}
}

struct MeetingControls: View {
    let meeting: MeetingRecorder
    let model: LauncherModel
    let onNew: () -> Void
    let onBack: () -> Void

    var body: some View {
        if let opened = model.openedMeeting {
            PillButton(title: "All meetings", symbol: "chevron.left", help: "Back to the list (⌫)") { onBack() }
            documentButtons(opened)
        } else if model.meetingListMode {
            PillButton(title: "New meeting", symbol: "record.circle", tint: .red, help: "Start recording") { onNew() }
        } else {
            live
        }
    }

    private func documentButtons(_ doc: MeetingDoc) -> some View {
        Group {
            CopyMenu(doc: doc)
            ShareButton(url: doc.url)
            PillButton(title: nil, symbol: "folder", help: "Show in Finder") { meeting.showInFinder(doc.url) }
        }
    }

    @ViewBuilder private var live: some View {
        switch meeting.phase {
        case .recording, .paused:
            HStack(spacing: 7) {
                PulsingDot(active: meeting.phase == .recording)
                Text(meeting.clock).font(.system(size: 13, weight: .semibold).monospacedDigit()).fixedSize()
            }
            .padding(.trailing, 4)
            LanguageToggle(meeting: meeting)
            PillButton(title: nil, symbol: meeting.phase == .paused ? "play.fill" : "pause.fill",
                       help: meeting.phase == .paused ? "Resume" : "Pause") { meeting.togglePause() }
            PillButton(title: "Stop", symbol: "stop.fill", tint: .red, help: "Stop and write notes") { meeting.stop() }
        case .summarizing:
            EmptyView()
        case .done, .failed, .idle:
            documentButtons(meeting.doc)
            PillButton(title: "New", symbol: "record.circle", tint: .red, help: "Start a new meeting") { onNew() }
        }
    }
}

/// The meeting's language in one small pill: mixed (each language heard by its own recognizer), English or Japanese.
struct LanguageToggle: View {
    let meeting: MeetingRecorder

    private static let options: [(DictationLanguage, String)] = [(.both, "Mixed"), (.english, "EN"), (.japanese, "日本語")]

    var body: some View {
        Menu {
            ForEach(Self.options, id: \.0) { l, title in
                Button { meeting.setLanguage(l) } label: {
                    if meeting.language == l { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Text(Self.options.first { $0.0 == meeting.language }?.1 ?? "EN")
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Language of the meeting")
    }
}

/// ⌘4 while a meeting records or just ended: the meeting as a document (as in the floating window).
struct MeetingView: View {
    let meeting: MeetingRecorder
    let query: String
    let s: Settings
    var chat: MeetingCopilot?

    var body: some View {
        Group {
            if case .failed(let msg) = meeting.phase {
                Text(msg).font(.system(size: 13)).foregroundStyle(.secondary).padding(PanelLayout.inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                MeetingPage(doc: meeting.doc, recorder: meeting, chat: chat, query: query, outerRadius: s.scopedCornerRadius)
                    .id(meeting.doc.id)
            }
        }
        .padding(.top, PanelLayout.gap)
        .frame(height: Metrics.clipboardList(s))
    }
}

/// ⌘4 with nothing recording: past meetings (and today's events to record) with a chat across all of them.
struct MeetingHome: View {
    let model: LauncherModel
    let s: Settings
    let radius: CGFloat
    let onActivate: (Int) -> Void

    var body: some View {
        // Nothing to list (or to chat about): one line, and New meeting in the bar.
        if model.items.isEmpty {
            EmptyLine(text: model.query.isEmpty ? "No meetings yet" : "No meetings match")
        } else {
            list
        }
    }

    private var list: some View {
        let room = ExpandingChat.buttonSize(outerRadius: s.scopedCornerRadius, inset: PanelLayout.inset) + PanelLayout.inset
        // As tall as there's room for above the chat button: sized by its rows, a long list overflowed the
        // panel and was centred, pushing the first rows up under the search bar.
        let labels = Self.labels(model.items)
        return MeetingList(model: model, s: s, radius: radius, labels: labels, onActivate: onActivate,
                           height: min(model.visibleListHeight(s) + CGFloat(labels.count) * Self.labelHeight,
                                       Metrics.clipboardList(s) - room - (Metrics.listInset - Metrics.rowGap)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                if let chat = model.allChat { ExpandingChat(copilot: chat, title: chat.title, outerRadius: s.scopedCornerRadius, inset: PanelLayout.inset) }
            }
            .frame(height: Metrics.clipboardList(s))
    }

    static let labelHeight: CGFloat = 24

    /// "Today" over the events still to come and "Recorded" over the saved meetings, when both are listed.
    static func labels(_ items: [ResultItem]) -> [Int: String] {
        guard let first = items.firstIndex(where: { if case .meetingFile = $0.kind { true } else { false } }), first > 0 else { return [:] }
        return [0: "Today", first: "Recorded"]
    }
}

/// The meetings as rows like the search bar's results, with the section labels between them.
private struct MeetingList: View {
    let model: LauncherModel
    let s: Settings
    let radius: CGFloat
    let labels: [Int: String]
    let onActivate: (Int) -> Void
    let height: CGFloat
    @State private var moreBelow = false

    var body: some View {
        let icon = min(36, max(16, s.rowSize * 0.62)), inset = (s.rowSize - icon) / 2
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.items.indices, id: \.self) { i in
                        if let label = labels[i] {
                            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.35))
                                .padding(.horizontal, s.showIcons ? inset : 13).padding(.bottom, 3)
                                .frame(height: MeetingHome.labelHeight, alignment: .bottom)
                        }
                        row(model.items[i], i, icon: icon, inset: inset)
                            .padding(.vertical, Metrics.rowGap)
                            .id(i)
                            .onTapGesture { onActivate(i) }
                            .onHover { inside in
                                if inside { model.hovered = i } else if model.hovered == i { model.hovered = nil }
                            }
                    }
                }
                .padding(.horizontal, Metrics.listInset)
            }
            .scrollIndicators(.never)
            .frame(height: height, alignment: .top)
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y + g.containerSize.height < g.contentSize.height - 2 } action: { _, more in
                moreBelow = more
            }
            // Fades out at the bottom while there's more below, as Tasks does.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: moreBelow ? 30 : 0)
                }
            }
            .padding(.bottom, Metrics.listInset - Metrics.rowGap)
            .onChange(of: model.selection) { _, i in proxy.scrollTo(i) }
        }
    }

    private func row(_ item: ResultItem, _ i: Int, icon: CGFloat, inset: CGFloat) -> some View {
        let tile = RoundedRectangle(cornerRadius: max(4, radius - inset), style: .continuous)
        return HStack(spacing: 11) {
            if s.showIcons {
                Group {
                    if case .meetingEvent(let e) = item.kind {
                        tile.fill(Color(nsColor: e.color).gradient)
                            .overlay(Image(systemName: e.link != nil ? "video.fill" : "calendar").font(.system(size: icon * 0.4, weight: .semibold)))
                    } else {
                        tile.fill(Color.red.opacity(0.85).gradient)
                            .overlay(Image(systemName: "waveform").font(.system(size: icon * 0.45, weight: .semibold)))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: icon, height: icon)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 15)).lineLimit(1)
                if let sub = item.subtitle, s.rowSize >= 38 {
                    Text(sub).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, s.showIcons ? inset : 13)
        .frame(height: s.rowSize)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(i == model.selection ? selectedFill : i == model.hovered ? hoverFill : .clear))
        .contentShape(Rectangle())
    }
}

/// Renders Claude's Markdown notes: headings, bullets, checkboxes and inline styling.
/// `shown` (in characters of `markdown`) reveals streamed text: what's past it is hidden and the last
/// `FadeIn.ramp` characters before it fade in. Animating `shown` makes new text dissolve in instead of popping.
struct NotesView: View, Animatable {
    let markdown: String
    /// Your own notes: where the AI notes kept your words, they show bright and the rest dimmer.
    var mine: [String] = []
    /// Room above headings and where the text has a blank line (meeting notes, emails).
    var spaced = false
    var shown = Double.infinity
    /// Selectable text takes every click, links included: Ask turns it off so its links open.
    var selectable = true

    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    var body: some View {
        let blocks = NoteBlock.split(markdown)
        if blocks.count == 1, case .text(let t) = blocks[0].block {
            text(t, shown: shown)
        } else {
            VStack(alignment: .leading, spacing: spaced ? 12 : 8) {
                ForEach(blocks.indices, id: \.self) { i in
                    let reveal = shown - Double(blocks[i].at)
                    switch blocks[i].block {
                    case .text(let t): text(t, shown: reveal)
                    case .table(let rows): NoteTable(rows: rows).opacity(reveal > 0 ? 1 : 0)
                    case .divider: Rectangle().fill(Color.primary.opacity(0.16)).frame(height: 1).opacity(reveal > 0 ? 1 : 0)
                    case .toggle(let title, let inside, let open):
                        NoteToggle(title: title, inside: inside, open: open, spaced: spaced).opacity(reveal > 0 ? 1 : 0)
                    }
                }
            }
        }
    }

    @ViewBuilder private func text(_ md: String, shown: Double) -> some View {
        // One text for the whole thing, so a selection can run across every line.
        let text = Text(Self.attributed(md, mine: mine, spaced: spaced))
            .font(.app(.answers, 13.5))
            .lineSpacing(5)
            .textRenderer(FadeIn(shown: shown))
            .contentTransition(.identity) // new text fades in by `shown`, never by cross-fading the whole thing
            .fixedSize(horizontal: false, vertical: true)
        if selectable { text.textSelection(.enabled) } else { text }
    }

    static func attributed(_ markdown: String, mine: [String] = [], spaced: Bool = false) -> AttributedString {
        var out = AttributedString()
        // The lines to show: code keeps its spaces, the rest is trimmed and keeps how deep it was nested.
        var lines: [(text: String, level: Int, code: Bool, blankBefore: Bool)] = []
        var code = false, blank = false
        for raw in markdown.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { code.toggle(); continue }
            if t.isEmpty { blank = true; continue }
            let lead = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            lines.append((code ? raw : t, code ? 0 : lead / 2, code, blank))
            blank = false
        }
        // Each of your lines brightens once, where it first shows up.
        var cues = mine.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*•・#[]xX ").union(.whitespaces)) }.filter { $0.count >= 3 }
        let dim = !cues.isEmpty
        let inline = { (raw: String) in dim ? Self.marked(Self.inline(raw), &cues) : Self.inline(raw) }
        let faint = { (s: String) in
            var a = AttributedString(s)
            a.foregroundColor = .secondary
            return a
        }
        for (n, line) in lines.enumerated() {
            let t = line.text
            if n > 0 {
                out += AttributedString("\n")
                if spaced, !line.code, t.hasPrefix("#") || line.blankBefore {
                    var gap = AttributedString("\n")
                    gap.font = .system(size: t.hasPrefix("#") ? 9 : 5)
                    out += gap
                }
            }
            if line.level > 0 { out += AttributedString(String(repeating: "\u{2003}", count: line.level)) }
            if line.code {
                var c = AttributedString(t)
                c.font = .system(size: 12.5, design: .monospaced)
                c.foregroundColor = .secondary
                out += c
            } else if let num = t.range(of: #"^\d{1,3}\. "#, options: .regularExpression) {
                out += faint(t[num].trimmingCharacters(in: .whitespaces) + "\u{2002}") + inline(String(t[num.upperBound...]))
            } else if t.hasPrefix("> ") {
                out += faint("│\u{2002}") + inline(String(t.dropFirst(2)))
            } else if t.hasPrefix("# ") {
                var h = Self.inline(String(t.dropFirst(2)))
                h.font = .app(.answers, 18, weight: .semibold)
                out += h
            } else if t.hasPrefix("## ") || t.hasPrefix("### ") {
                var h = Self.inline(String(t.drop { $0 == "#" }.dropFirst()))
                h.font = .app(.answers, 12, weight: .semibold)
                h.foregroundColor = .secondary
                out += h
            } else if t.hasPrefix("- [ ] ") || t.hasPrefix("- [x] ") || t.hasPrefix("- [X] ") {
                var box = AttributedString(t.hasPrefix("- [ ]") ? "☐\u{2002}" : "☑\u{2002}")
                box.foregroundColor = .secondary
                out += box + inline(String(t.dropFirst(6)))
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("・") {
                var dot = AttributedString("•\u{2002}")
                dot.foregroundColor = .secondary
                out += dot + inline(String(t.hasPrefix("・") ? t.dropFirst(1) : t.dropFirst(2)))
            } else {
                out += inline(t)
            }
        }
        return out
    }

    /// Dims a line the AI wrote, keeping your own words in it bright (exactly, or most of a line's words).
    private static func marked(_ line: AttributedString, _ cues: inout [String]) -> AttributedString {
        var a = line
        a.foregroundColor = Color.primary.opacity(0.6)
        let words = { (s: String) in Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }) }
        let have = words(String(a.characters))
        cues.removeAll { c in
            if let r = a.range(of: c, options: .caseInsensitive) {
                a[r].foregroundColor = Color.primary
                return true
            }
            let w = words(c)
            guard w.count >= 3, Double(w.intersection(have).count) / Double(w.count) >= 0.75 else { return false }
            a.foregroundColor = Color.primary
            return true
        }
        return a
    }

    private static func inline(_ raw: String) -> AttributedString {
        // A line still streaming in can end inside **bold** or `code`: close it so the markers never show.
        var s = raw
        for mark in ["**", "`"] where s.components(separatedBy: mark).count % 2 == 0 { s += mark }
        return linked((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Bare web addresses become links too (Markdown links already are).
    private static func linked(_ text: AttributedString) -> AttributedString {
        var a = text
        let plain = String(a.characters)
        for m in detector?.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) ?? [] {
            guard let url = m.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let r = Range(m.range, in: plain) else { continue }
            let lo = a.characters.index(a.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: r.lowerBound))
            let hi = a.characters.index(lo, offsetBy: plain.distance(from: r.lowerBound, to: r.upperBound))
            if a[lo..<hi].runs.allSatisfy({ $0.link == nil }) { a[lo..<hi].link = url }
        }
        return a
    }
}

/// A Markdown table in the notes: the first row bold, a light grid, scrolling sideways when it's wide.
struct NoteTable: View {
    let rows: [[String]]

    var body: some View {
        let cols = rows.map(\.count).max() ?? 0
        let line = Color.primary.opacity(0.16)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            Text(NotesView.attributed(rows[r].indices.contains(c) ? rows[r][c] : ""))
                                .font(.system(size: 13.5, weight: r == 0 ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(minWidth: 56, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .overlay(alignment: .trailing) { if c < cols - 1 { line.frame(width: 1) } }
                                .overlay(alignment: .bottom) { if r < rows.count - 1 { line.frame(height: 1) } }
                        }
                    }
                }
            }
            .fixedSize()
            .overlay(shape.strokeBorder(line, lineWidth: 1))
            .clipShape(shape)
            .padding(1)
        }
        .scrollIndicators(.never)
        .textSelection(.enabled)
    }
}

/// A toggle in the notes: its title with an arrow, what's inside shown when open.
struct NoteToggle: View {
    let title: String
    let inside: String
    let spaced: Bool
    @State private var open: Bool

    init(title: String, inside: String, open: Bool, spaced: Bool) {
        self.title = title
        self.inside = inside
        self.spaced = spaced
        _open = State(initialValue: open)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.smooth(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 14)
                    Text(NotesView.attributed(title)).font(.system(size: 13.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open, !inside.isEmpty {
                NotesView(markdown: inside, spaced: spaced).padding(.leading, 22)
            }
        }
    }
}

/// Draws a text's glyphs up to `shown`, each one fading in over the `ramp` characters before it.
struct FadeIn: TextRenderer {
    static let ramp = 28.0
    var shown: Double

    func opacity(_ i: Double) -> Double {
        let x = min(1, max(0, (shown - i) / Self.ramp))
        return x * x * (3 - 2 * x)
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        var i = 0.0
        for line in layout {
            guard shown < .infinity else { ctx.draw(line); continue }
            for run in line {
                for glyph in run {
                    let a = opacity(i)
                    i += 1
                    guard a > 0 else { continue }
                    var c = ctx
                    c.opacity = a
                    c.draw(glyph)
                }
            }
        }
    }
}

// MARK: ⌘5 Pomodoro

/// The Focus view: a big clock, the plan you're typing, presets, and the controls once it runs.
struct PomodoroView: View {
    let pomodoro: Pomodoro
    let query: String
    /// Presets fill in the plan; Start (in the bar) or ↩ begins it.
    let pick: (String) -> Void

    static let focusColor = Color(red: 1, green: 0x6A / 255, blue: 0x55 / 255)
    private static let breakColor = Color(red: 0x4C / 255, green: 0xD0 / 255, blue: 0x7D / 255)

    var body: some View {
        let p = pomodoro
        let preview = query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Pomodoro.parse(query)
        let accent = p.phase == .rest ? Self.breakColor : Self.focusColor
        let left = p.active ? p.remaining : (preview ?? p.plan).focus * 60
        let status = p.active ? p.status : preview.map(Pomodoro.describe) ?? "Ready"
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text(Pomodoro.clock(left))
                    .font(.system(size: 44, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: Pomodoro.clock(left))
                HStack(spacing: 6) {
                    Circle().fill(p.active || preview != nil ? accent : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                    Text(status).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.bottom, 8)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(accent).frame(width: proxy.size.width * (p.active ? p.progress : 0))
                        .animation(.linear(duration: 0.9), value: p.progress)
                }
            }
            .frame(height: 3)
            HStack(spacing: 6) {
                if p.active {
                    ClockButton(symbol: p.paused ? "play.fill" : "pause.fill", tint: accent, help: p.paused ? "Resume" : "Pause") { p.toggle() }
                    ClockButton(symbol: "forward.end.fill", help: p.phase == .focus ? "Skip to break" : "Skip break") { p.skip() }
                    Spacer(minLength: 0)
                    ClockButton(symbol: "stop.fill", help: "Stop") { p.stop() }
                } else {
                    ForEach(Pomodoro.presets.indices, id: \.self) { i in
                        let plan = Pomodoro.presets[i]
                        let picked = preview.map { $0.focus == plan.focus && $0.short == plan.short } ?? false
                        PillButton(title: "\(Int(plan.focus))/\(Int(plan.short))", symbol: "timer", tint: picked ? Self.focusColor : nil,
                                   help: "Use \(Pomodoro.describe(plan)). Start it with Start or ↩") {
                            pick("\(Int(plan.focus))/\(Int(plan.short))/\(Int(plan.long))")
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
    }
}
