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
        PillButton(title: "Copy All", symbol: "doc.on.doc", help: "Copy every word (↩)") { actions.copyAll() }
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
    var rename: (String) -> Void = { _ in }
}

struct MeetingControls: View {
    let meeting: MeetingRecorder
    let model: LauncherModel
    let onNew: () -> Void
    let onBack: () -> Void

    var body: some View {
        if let opened = model.openedMeeting {
            PillButton(title: "All Meetings", symbol: "chevron.left", help: "Back to the list (⌫)") { onBack() }
            PillButton(title: nil, symbol: "doc.on.doc", help: "Copy notes and transcript") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(opened.text, forType: .string)
            }
            PillButton(title: nil, symbol: "folder", help: "Show in Finder") { meeting.showInFinder(opened.url) }
        } else if model.meetingListMode {
            PillButton(title: "New Meeting", symbol: "record.circle", tint: .red, help: "Start recording") { onNew() }
        } else {
            live
        }
    }

    @ViewBuilder private var live: some View {
        switch meeting.phase {
        case .recording, .paused:
            HStack(spacing: 7) {
                PulsingDot(active: meeting.phase == .recording)
                Text(meeting.clock).font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .padding(.trailing, 4)
            LanguageToggle(meeting: meeting)
            PillButton(title: nil, symbol: meeting.phase == .paused ? "play.fill" : "pause.fill",
                       help: meeting.phase == .paused ? "Resume" : "Pause") { meeting.togglePause() }
            PillButton(title: "Stop", symbol: "stop.fill", tint: .red, help: "Stop and write notes") { meeting.stop() }
        case .summarizing:
            EmptyView()
        case .done, .failed, .idle:
            PillButton(title: "Copy Notes", symbol: "doc.on.doc", help: "Copy the notes") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(meeting.summary.isEmpty ? meeting.transcript : meeting.summary + "\n\n" + meeting.transcript, forType: .string)
            }
            PillButton(title: nil, symbol: "folder", help: "Show the saved file in Finder") { meeting.showInFinder() }
            PillButton(title: "New", symbol: "record.circle", tint: .red, help: "Start a new meeting") { onNew() }
        }
    }
}

private struct LanguageToggle: View {
    let meeting: MeetingRecorder

    var body: some View {
        HStack(spacing: 0) {
            option(.english, "EN")
            option(.japanese, "日本語")
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .help("Language of the meeting")
    }

    private func option(_ l: DictationLanguage, _ title: String) -> some View {
        let on = meeting.language == l
        return Button { meeting.setLanguage(l) } label: {
            Text(title).font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(on ? .primary : .secondary)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Capsule().fill(on ? Color.primary.opacity(0.14) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct MeetingView: View {
    let meeting: MeetingRecorder
    let query: String
    let s: Settings
    var chat: MeetingCopilot?

    var body: some View {
        Group {
            switch meeting.phase {
            case .summarizing:
                VStack(spacing: 10) {
                    ThinkingDots().foregroundStyle(.secondary)
                    Text("Writing notes…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done:
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !meeting.summary.isEmpty { NotesView(markdown: meeting.summary) }
                        if !meeting.lines.isEmpty {
                            Text("TRANSCRIPT").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                            transcript
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 72) // room above the chat button
                }
                .scrollIndicators(.automatic)
                .overlay(alignment: .bottomTrailing) {
                        if let chat { ExpandingChat(copilot: chat, title: "Ask about this meeting", outerRadius: s.scopedCornerRadius, inset: Metrics.listInset).padding(.bottom, -Metrics.listInset) }
                }
            case .failed(let msg):
                Text(msg).font(.system(size: 13)).foregroundStyle(.secondary).padding(26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            default:
                live
            }
        }
        .frame(height: Metrics.clipboardList(s) - Metrics.listInset)
        .padding(.bottom, Metrics.listInset)
    }

    private var live: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let note = meeting.note {
                        Label(note, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if meeting.lines.isEmpty && meeting.volatileMe.isEmpty && meeting.volatileOthers.isEmpty {
                        Text(meeting.phase == .paused ? "Paused" : "Listening")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    transcript
                    if !meeting.volatileMe.isEmpty { LineRow(me: true, text: meeting.volatileMe, time: nil, live: true) }
                    if !meeting.volatileOthers.isEmpty { LineRow(me: false, text: meeting.volatileOthers, time: nil, live: true) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: meeting.lines.count) { _, _ in withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: meeting.volatileMe + meeting.volatileOthers) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var transcript: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        return ForEach(meeting.lines.filter { q.isEmpty || $0.text.localizedCaseInsensitiveContains(q) }) { l in
            LineRow(me: l.me, text: l.text, time: l.at, live: false)
        }
    }
}

private struct LineRow: View {
    let me: Bool
    let text: String
    let time: TimeInterval?
    let live: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(me ? "Me" : "Others")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(me ? Color.accentColor : .secondary)
                .frame(width: 46, alignment: .leading)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(live ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let time {
                Text(String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60))
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Renders Claude's Markdown notes: headings, bullets, checkboxes and inline styling.
struct NotesView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func line(_ raw: String) -> some View {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("# ") {
            inline(String(t.dropFirst(2))).font(.system(size: 18, weight: .semibold)).padding(.bottom, 2)
        } else if t.hasPrefix("## ") || t.hasPrefix("### ") {
            inline(String(t.drop { $0 == "#" }.dropFirst())).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 8)
        } else if t.hasPrefix("- [ ] ") || t.hasPrefix("- [x] ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: t.hasPrefix("- [x]") ? "checkmark.square" : "square").font(.system(size: 12)).foregroundStyle(.secondary)
                inline(String(t.dropFirst(6))).font(.system(size: 13.5))
            }
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("・") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(String(t.hasPrefix("・") ? t.dropFirst(1) : t.dropFirst(2))).font(.system(size: 13.5))
            }
        } else if !t.isEmpty {
            inline(t).font(.system(size: 13.5))
        }
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
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

/// A saved meeting, read back inside the popup: its name (editable), the notes, and a chat about it.
struct PastMeetingView: View {
    let past: MeetingRecorder.Past
    let query: String
    let s: Settings
    let chat: MeetingCopilot?
    let rename: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name this meeting", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .onSubmit { rename(name) }
                Text(past.date.formatted(date: .complete, time: .shortened)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 8)
            ScrollView {
                NotesView(markdown: filtered)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 72) // room above the chat button
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if let chat { ExpandingChat(copilot: chat, title: "Ask about this meeting", outerRadius: s.scopedCornerRadius, inset: Metrics.listInset).padding(.bottom, -Metrics.listInset) }
            }
        }
        .frame(height: Metrics.clipboardList(s) - Metrics.listInset)
        .padding(.bottom, Metrics.listInset)
        .onAppear { name = past.title }
        .onChange(of: past.url) { _, _ in name = past.title }
    }

    /// Typing in the bar keeps only the lines that mention it; the title line isn't repeated (it's the name above).
    private var filtered: String {
        let body = past.text.components(separatedBy: "\n").drop { !$0.hasPrefix("# ") }.dropFirst()
        let lines = past.text.contains("\n# ") || past.text.hasPrefix("# ") ? Array(body) : past.text.components(separatedBy: "\n")
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return lines.joined(separator: "\n") }
        return lines.filter { $0.hasPrefix("#") || $0.localizedCaseInsensitiveContains(q) }.joined(separator: "\n")
    }
}
