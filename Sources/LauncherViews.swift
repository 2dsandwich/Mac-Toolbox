import AppKit
import SwiftUI

private let listInset = Metrics.listInset
private let rowGap = Metrics.rowGap
private let textLeft: CGFloat = 26
/// Where a borderless NSTextField starts drawing its text, measured from snapshots.
private let fieldTextInset: CGFloat = 0

private func dynamic(dark: NSColor, light: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
}

let selectedFill = dynamic(dark: NSColor(white: 1, alpha: 0.145), light: NSColor(srgbRed: 15 / 255, green: 24 / 255, blue: 44 / 255, alpha: 0.08))
let hoverFill = dynamic(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(srgbRed: 15 / 255, green: 24 / 255, blue: 44 / 255, alpha: 0.05))
private let scopeShade = dynamic(dark: NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 32 / 255, alpha: 0.62),
                                 light: NSColor(srgbRed: 246 / 255, green: 246 / 255, blue: 248 / 255, alpha: 0.7))
private let placeholderInk = NSColor(name: nil) {
    $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0x87 / 255) : NSColor(white: 0, alpha: 0x66 / 255)
}

/// The card sits at the top centre of a fixed-size transparent window. Size changes animate
/// here in SwiftUI instead of resizing the window, so typing never makes it jump.
struct LauncherRoot: View {
    let model: LauncherModel
    let store: Store
    let clipboard: ClipboardStore
    var onActivate: (Int) -> Void
    var onTab: (Scope) -> Void
    var clipActions = ClipActions()
    var textActions = TextActions()
    var onPomodoro: (Pomodoro.Plan?) -> Void = { _ in }
    /// Buttons and chips inside answer cards.
    var onAnswerAction: (Answer.Action) -> Void = { _ in }
    var onTimerStart: () -> Void = {}
    var meetingActions = MeetingActions()
    var opaque = false

    var body: some View {
        let s = store.settings
        let scoped = model.scope != .apps
        let open = model.presented
        let base = scoped ? s.scopedCornerRadius : s.cornerRadius
        // With result rows showing, the card's corners follow the rows' curve (concentric), so they line up.
        let rowRadius = max(4, min(base - listInset, s.rowHeight / 2))
        let listed = !model.items.isEmpty && !model.scope.isPanel && model.scope != .clipboard
        let radius = listed ? min(base, rowRadius + listInset) : base
        let fullWidth = model.width(s)
        // The mode buttons share the bar's own width: while they show, the card gives up room for them.
        // Only on the plain search bar, before anything is typed.
        let tabs = s.showTabs && !s.quickModes.isEmpty && model.tabsShown && model.scope == .apps && model.query.isEmpty
        let tabsRoom = TabButtons.width(s.barHeight, count: min(4, s.quickModes.count)) + TabButtons.gap
        let width = tabs ? max(s.barHeight * 2, fullWidth - tabsRoom) : fullWidth
        let height = model.cardHeight(s)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let resize: Animation? = s.animations ? .smooth(duration: 0.24) : nil
        VStack(spacing: 0) {
            SearchBar(model: model, s: s, onTab: onTab, textActions: textActions, meetingActions: meetingActions, onPomodoro: onPomodoro, onAnswerAction: onAnswerAction,
                      onTimerStart: onTimerStart)
            // Tabs cross-fade while the card resizes (the switch runs inside one withAnimation).
            ZStack(alignment: .top) {
                if model.scope == .clipboard {
                    ClipboardArea(model: model, clipboard: clipboard, s: s, actions: clipActions, onActivate: onActivate)
                        .transition(.opacity)
                } else if model.scope == .text {
                    TextModeView(model: model, s: s, radius: radius, onCopy: textActions.copySelection, actions: textActions)
                        .transition(.opacity)
                } else if model.scope == .pomodoro, let pomodoro = model.pomodoro {
                    ClockHub(model: model, pomodoro: pomodoro, radius: radius)
                        .transition(.opacity)
                } else if model.scope == .calculator {
                    CalculatorView(model: model, radius: radius)
                        .transition(.opacity)
                } else if model.scope == .notes {
                    NoteBoardView(model: model, board: NoteBoard.shared, radius: radius)
                        .transition(.opacity)
                } else if model.scope == .translate {
                    TranslateView(model: model, translator: Translator.shared, radius: radius)
                        .transition(.opacity)
                } else if model.scope == .mixer {
                    MixerView(mixer: AudioMixer.shared, radius: radius, query: model.query)
                        .transition(.opacity)
                } else if model.scope == .meeting, let opened = model.openedMeeting {
                    PastMeetingView(past: opened, query: model.query, s: s, chat: model.pastChat, rename: meetingActions.rename)
                        .transition(.opacity)
                } else if model.scope == .meeting, model.meetingListMode {
                    if model.items.isEmpty {
                        Text(model.query.isEmpty ? "No meetings yet" : "No meetings match.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26)
                            .frame(height: Metrics.slot(s), alignment: .top)
                            .transition(.opacity)
                    } else {
                        ResultList(model: model, s: s, radius: max(4, min(radius - listInset, s.rowHeight / 2)), onActivate: onActivate)
                            .transition(.opacity)
                    }
                } else if model.scope == .meeting, let meeting = model.meeting {
                    MeetingView(meeting: meeting, query: model.query, s: s, chat: model.meetingCopilot)
                        .transition(.opacity)
                } else if model.scope == .library {
                    LibraryGrid(model: model, s: s, radius: max(8, min(radius - listInset, 18)), onActivate: onActivate)
                        .transition(.opacity)
                } else if !model.items.isEmpty {
                    ResultList(model: model, s: s, radius: max(4, min(radius - listInset, s.rowHeight / 2)), onActivate: onActivate, onAction: onAnswerAction)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .background { CardBackground(shape: shape, s: s, scoped: scoped, opaque: opaque) }
        .clipShape(shape)
        .animation(resize, value: height)
        .animation(resize, value: width)
        .animation(resize, value: radius)
        .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
        .frame(width: fullWidth, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if s.showTabs {
                TabButtons(active: model.scope, shown: tabs, size: s.barHeight, s: s, onTab: onTab)
                    .fixedSize()
                    .contentShape(Rectangle())
                    .allowsHitTesting(tabs)
                    .onHover { model.hoverTabs("buttons", $0) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.controlFrames["tabs"] = $0 }
            }
        }
        // Open: grows out of a slightly smaller, faded card; close: quick fade.
        .scaleEffect(open ? 1 : 0.94, anchor: .top)
        .opacity(open ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, Metrics.margin)
    }
}

private struct CardBackground: View {
    let shape: RoundedRectangle
    let s: Settings
    let scoped: Bool
    let opaque: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            if opaque || s.glass == .solid {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                Color.clear.glassEffect((s.glass == .clear ? Glass.clear : Glass.regular).tint(tint(dark)), in: shape)
            }
            // "Darkness": black over the glass (lighter touch in light mode so dark text stays readable).
            shape.fill(Color.black.opacity(dark ? s.darkness : s.darkness * 0.25))
            shape.fill(scopeShade).opacity(scoped && s.shadeScopes ? 1 : 0)
        }
    }

    /// The Moneybag popup tint: a whisper of grey (dark) or white (light), stronger inside a scope.
    private func tint(_ dark: Bool) -> Color {
        if s.customTint {
            let base = NSColor(hex: s.tintHex) ?? .gray
            return Color(nsColor: base.withAlphaComponent(min(1, (scoped ? 0.32 : 0.22) * s.tintStrength)))
        }
        let base = dark ? NSColor(hex: "#4C4C4F")! : NSColor.white
        let alpha = scoped ? (dark ? 0.1 : 0.08) : (dark ? 0.04 : 0.03)
        return Color(nsColor: base.withAlphaComponent(min(1, alpha * s.tintStrength)))
    }
}

// MARK: Bar

private struct SearchBar: View {
    let model: LauncherModel
    let s: Settings
    let onTab: (Scope) -> Void
    let textActions: TextActions
    let meetingActions: MeetingActions
    var onPomodoro: (Pomodoro.Plan?) -> Void = { _ in }
    var onAnswerAction: (Answer.Action) -> Void = { _ in }
    var onTimerStart: () -> Void = {}
    @State private var hovering = false

    /// The bar buttons for the open ⌘5 Clock tab.
    @ViewBuilder private func clockControls(_ p: Pomodoro) -> some View {
        let orange = Color(nsColor: .systemOrange)
        switch model.clockMode {
        case .focus:
            if !p.active {
                ClockButton(symbol: "play.fill", tint: PomodoroView.focusColor, help: "Start") {
                    onPomodoro(model.query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Pomodoro.parse(model.query))
                }
            }
        case .timer:
            if !Timers.shared.list.isEmpty {
                ClockButton(symbol: model.timerComposer ? "xmark" : "plus", help: model.timerComposer ? "Cancel" : "New timer") {
                    withAnimation(.smooth(duration: 0.25)) { model.timerComposer.toggle() }
                }
            }
        case .stopwatch:
            ClockButton(symbol: "plus", help: "New stopwatch") { Stopwatches.shared.add() }
        case .alarms:
            if model.alarmDraft == nil {
                ClockButton(symbol: "plus", help: "New alarm") { model.newAlarm() }
            } else {
                ClockButton(symbol: "checkmark", tint: orange, help: "Save") { model.saveAlarmDraft() }
            }
        }
    }

    /// The timer answer at the top of the results, if any (it gets a Start button in the bar).
    private var timerAnswer: Answer? {
        guard model.scope == .apps, case .answer(let a)? = model.items.first?.kind, case .timer? = a.card else { return nil }
        return a
    }

    var body: some View {
        let chipHeight = min(44, s.barHeight - 16)
        let chipPad = (s.barHeight - chipHeight) / 2
        let showChip = [.switcher, .web, .library, .clipboard, .weather].contains(model.scope) || model.scope.isPanel
        HStack(spacing: 12) {
            if showChip {
                ScopeChip(scope: model.scope, height: chipHeight, radius: max(4, s.scopedCornerRadius - chipPad),
                          title: model.scope == .web ? model.browser?.name : nil,
                          icon: model.scope == .web ? model.browser.map { IconCache.icon(forPath: $0.path) } : nil)
            }
            ZStack(alignment: .leading) {
                SearchField(model: model, fontSize: s.fontSize, placeholder: model.placeholder(s))
                if !model.ghost.isEmpty {
                    // The typed part is laid out invisibly so the ghost starts exactly where the text ends.
                    HStack(spacing: 0) {
                        Text(model.query).hidden()
                        Text(model.ghost).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                    .font(.system(size: s.fontSize))
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: fieldTextInset)
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            if model.scope == .text, model.screenText != nil {
                BarControls { TextControls(actions: textActions, codes: model.screenText?.codes ?? []) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.controlFrames["panel"] = $0 }
            } else if model.scope == .meeting, let meeting = model.meeting {
                BarControls { MeetingControls(meeting: meeting, model: model, onNew: meetingActions.new, onBack: meetingActions.back) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.controlFrames["panel"] = $0 }
            } else if model.scope == .pomodoro, let p = model.pomodoro {
                BarControls { clockControls(p) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.controlFrames["panel"] = $0 }
            } else if model.scope == .notes {
                BarControls {
                    ClockButton(symbol: "plus", help: "New note") {
                        NoteBoard.shared.add(model.query.trimmingCharacters(in: .whitespaces))
                        model.setQuery("")
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.controlFrames["panel"] = $0 }
            } else if model.scope == .calculator {
                BarControls {
                    PillButton(title: nil, symbol: "doc.on.doc", help: "Copy the result") {
                        let q = model.query.trimmingCharacters(in: .whitespaces)
                        if let v = Tools.evaluate(q) ?? Tools.number(Tools.normalize(q)) { onAnswerAction(.copy(Tools.plain(v))) }
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.controlFrames["panel"] = $0 }
            } else if let timer = timerAnswer {
                BarControls {
                    PillButton(title: "Start", symbol: "play.fill", tint: .orange, help: "Start the timer (↩)") { onAnswerAction(timer.action) }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.controlFrames["panel"] = $0 }
            }
        }
        .padding(.leading, showChip ? chipPad : textLeft - fieldTextInset)
        .padding(.trailing, model.scope.isPanel || timerAnswer != nil ? chipPad : textLeft)
        .frame(height: s.barHeight)
        .contentShape(Rectangle())
        .onHover { model.hoverTabs("bar", $0) }
        .onChange(of: model.presented) { _, open in
            if !open { model.resetTabHover() } // the pointer may leave while the popup is hidden
        }
    }
}

/// Apps, Clipboard, Text, Meeting and Pomodoro (⌘1–⌘5): separate glass circles, as tall as the bar,
/// that bubble out beside it while the pointer is on the bar (or on them).
struct TabButtons: View {
    let active: Scope
    let shown: Bool
    let size: CGFloat
    let s: Settings
    let onTab: (Scope) -> Void
    static let gap: CGFloat = 12

    static func width(_ size: CGFloat, count: Int) -> CGFloat { count > 0 ? CGFloat(count) * size + CGFloat(count - 1) * gap : 0 }

    /// Settings › Appearance picks them (up to four); ⌘2–⌘5 follow the same order. They only show on the apps bar.
    private var tabs: [(QuickButton, String)] {
        s.quickModes.prefix(4).enumerated().map { i, b in (b, "\(b.title) (⌘\(i + 2))") }
    }

    var body: some View {
        let tabs = self.tabs
        HStack(spacing: Self.gap) {
            if shown {
                ForEach(Array(tabs.enumerated()), id: \.element.0) { i, tab in
                    button(tab.0, tab.1)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.4, anchor: .leading).combined(with: .opacity).combined(with: .offset(x: -CGFloat(i + 1) * 24))
                                .animation(.spring(duration: 0.45, bounce: 0.3).delay(Double(i) * 0.035)),
                            removal: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity)
                                .animation(.easeIn(duration: 0.14).delay(Double(tabs.count - 1 - i) * 0.02))))
                }
            }
        }
        .frame(width: Self.width(size, count: tabs.count), height: size, alignment: .leading)
    }

    private func button(_ b: QuickButton, _ help: String) -> some View {
        Button {
            switch b {
            case .mode(let m): onTab(m.scope)
            case .app(let path): (NSApp.delegate as? AppDelegate)?.launcher.openQuickApp(path)
            }
        } label: {
            Group {
                switch b {
                case .mode(let m):
                    Image(systemName: m.scope.symbol)
                        .font(.system(size: size * 0.27, weight: m.scope == active ? .semibold : .medium))
                        .foregroundStyle(m.scope == active ? .primary : .secondary)
                case .app(let path):
                    Image(nsImage: IconCache.icon(forPath: path)).resizable().frame(width: size * 0.5, height: size * 0.5)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // The same glass and darkness as the bar, each circle on its own so neighbours never melt together.
        .background { CardBackground(shape: RoundedRectangle(cornerRadius: size / 2, style: .continuous), s: s, scoped: false, opaque: false) }
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        .help(help)
    }
}

private struct ScopeChip: View {
    let scope: Scope
    let height: CGFloat
    let radius: CGFloat
    var title: String?
    var icon: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: scope.symbol).font(.system(size: 13, weight: .medium))
            }
            Text(title ?? scope.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 13)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(0.08)))
        .transition(.opacity)
    }
}

struct SearchField: NSViewRepresentable {
    let model: LauncherModel
    let fontSize: Double
    let placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.usesSingleLineMode = true
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.lineBreakMode = .byClipping
        f.delegate = context.coordinator
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        model.field = f
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        let font = NSFont.systemFont(ofSize: fontSize)
        if f.font != font { f.font = font }
        let ph = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: placeholderInk])
        if f.placeholderAttributedString?.string != placeholder || f.placeholderAttributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont != font {
            f.placeholderAttributedString = ph
        }
        if f.stringValue != model.query { f.stringValue = model.query }
        model.field = f
    }

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: LauncherModel
        init(_ model: LauncherModel) { self.model = model }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            model.query = f.stringValue
            model.recompute()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            (NSApp.delegate as? AppDelegate)?.launcher.handle(sel) ?? false
        }
    }
}

// MARK: Results

private struct ResultList: View {
    let model: LauncherModel
    let s: Settings
    let radius: CGFloat
    let onActivate: (Int) -> Void
    var onAction: (Answer.Action) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.items.indices, id: \.self) { i in
                        ResultRow(item: model.items[i], scope: model.scope, selected: i == model.selection, hovered: i == model.hovered,
                                  s: s, radius: radius, onAction: onAction)
                            .padding(.vertical, rowGap)
                            .id(i)
                            .onTapGesture { onActivate(i) }
                            .onHover { inside in
                                if inside { model.hovered = i } else if model.hovered == i { model.hovered = nil }
                            }
                    }
                }
                .padding(.horizontal, listInset)
            }
            .scrollIndicators(.never)
            .frame(height: model.visibleListHeight(s))
            .padding(.bottom, listInset - rowGap)
            .onChange(of: model.selection) { _, i in proxy.scrollTo(i) }
        }
    }
}

private struct ResultRow: View {
    let item: ResultItem
    let scope: Scope
    let selected: Bool
    let hovered: Bool
    let s: Settings
    let radius: CGFloat
    var onAction: (Answer.Action) -> Void = { _ in }

    var body: some View {
        if case .answer(let a) = item.kind, let card = a.card {
            AnswerCardView(card: card, hint: a.hintText, selected: selected, hovered: hovered, radius: max(radius, 12), onAction: onAction)
                .frame(height: card.height)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 11) {
            if s.showIcons { ItemIcon(item: item, size: iconSize, corner: max(4, radius - iconInset)) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 15)).lineLimit(1)
                if let sub = item.subtitle, s.rowHeight >= 38 {
                    Text(sub).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.isRunning, scope == .apps {
                Circle().fill(Color.secondary.opacity(0.7)).frame(width: 5, height: 5)
            }
            if s.showHints {
                if let word = item.keyword {
                    Text(word).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }
        }
        .padding(.horizontal, s.showIcons ? iconInset : 13)
        .frame(height: s.rowHeight)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(selected ? selectedFill : hovered ? hoverFill : .clear))
        .contentShape(Rectangle())
    }

    /// The icon sits the same distance from the row's top, bottom and leading edge, and its corners follow the row's.
    private var iconInset: CGFloat { (s.rowHeight - iconSize) / 2 }

    private var iconSize: CGFloat { min(36, max(16, s.rowHeight * 0.62)) }

    private var hint: String {
        switch item.kind {
        case .app(let a) where a.path == AppIndex.appsLauncherPath: "All Apps ↩"
        case .app(let a): BrowserSites.browserPaths.contains(a.path) ? "⇥ sites   Open ↩" : "Open ↩"
        case .running: "Switch ↩"
        case .builtin(let b): b.scope != nil ? "Tab ⇥" : "↩"
        case .clip: "Paste ↩"
        case .site: "Open ↩"
        case .meetingFile: "Read ↩"
        case .setting: "Open ↩"
        case .answer(let a): a.hintText
        }
    }
}

private struct ItemIcon: View {
    let item: ResultItem
    let size: CGFloat
    /// Tile corners (concentric with the row); app icons keep their own shape.
    var corner: CGFloat?
    private var tile: CGFloat { corner ?? size * 0.26 }

    var body: some View {
        Group {
            switch item.kind {
            case .app(let a):
                Image(nsImage: IconCache.icon(forPath: a.path)).resizable()
            case .running(let r):
                Image(nsImage: r.icon ?? NSImage()).resizable()
            case .builtin(let b):
                symbol(b.symbol)
            case .clip:
                symbol("doc.on.clipboard")
            case .site(let site):
                if let img = item.image {
                    Image(nsImage: img).resizable().interpolation(.high)
                        .frame(width: size * 0.72, height: size * 0.72)
                        .frame(width: size, height: size)
                        .background(RoundedRectangle(cornerRadius: tile, style: .continuous).fill(Color.primary.opacity(0.06)))
                } else {
                    RoundedRectangle(cornerRadius: tile, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .overlay(Text(String(site.host.prefix(1)).uppercased()).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.secondary))
                }
            case .meetingFile:
                RoundedRectangle(cornerRadius: tile, style: .continuous)
                    .fill(Color.red.opacity(0.85).gradient)
                    .overlay(Image(systemName: "waveform").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white))
            case .setting(let pane):
                RoundedRectangle(cornerRadius: tile, style: .continuous)
                    .fill(Color(nsColor: pane.color).gradient)
                    .overlay(Image(systemName: pane.symbol).font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(.white))
            case .answer(let a):
                if let img = a.image {
                    Image(nsImage: img).resizable().interpolation(.none)
                        .clipShape(RoundedRectangle(cornerRadius: tile, style: .continuous))
                } else if let e = a.emoji {
                    RoundedRectangle(cornerRadius: tile, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .overlay(Text(e).font(.system(size: size * 0.6)))
                } else {
                    RoundedRectangle(cornerRadius: tile, style: .continuous)
                        .fill(Color(nsColor: a.color).gradient)
                        .overlay(Image(systemName: a.symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white))
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func symbol(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: tile, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .overlay(Image(systemName: name).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.secondary))
    }
}

// MARK: All Apps

/// MONEY!'s own app grid (instead of macOS's Apps, which opens Spotlight).
private struct LibraryGrid: View {
    let model: LauncherModel
    let s: Settings
    let radius: CGFloat
    let onActivate: (Int) -> Void

    var body: some View {
        if model.items.isEmpty {
            Text("No apps match.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26)
                .frame(height: 44)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: model.libraryColumns)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: 0) {
                        ForEach(model.items.indices, id: \.self) { i in
                            LibraryTile(item: model.items[i], selected: i == model.selection, hovered: i == model.hovered, radius: radius)
                                .frame(height: Metrics.libraryCell.height)
                                .id(i)
                                .onTapGesture { onActivate(i) }
                                .onHover { inside in
                                    if inside { model.hovered = i } else if model.hovered == i { model.hovered = nil }
                                }
                        }
                    }
                    .padding(listInset)
                }
                .scrollIndicators(.never)
                .frame(height: model.listHeight(s))
                .onChange(of: model.selection) { _, i in proxy.scrollTo(i) }
            }
        }
    }
}

private struct LibraryTile: View {
    let item: ResultItem
    let selected: Bool
    let hovered: Bool
    let radius: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if case .app(let a) = item.kind {
                    Image(nsImage: IconCache.icon(forPath: a.path)).resizable()
                } else {
                    Color.clear
                }
            }
            .frame(width: 56, height: 56)
            Text(item.title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
            Circle().fill(Color.secondary.opacity(item.isRunning ? 0.7 : 0)).frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(selected ? selectedFill : hovered ? hoverFill : .clear)
            .padding(2))
        .contentShape(Rectangle())
    }
}

// MARK: Clipboard

private struct ClipboardArea: View {
    let model: LauncherModel
    let clipboard: ClipboardStore
    let s: Settings
    let actions: ClipActions
    let onActivate: (Int) -> Void

    var body: some View {
        let height = Metrics.clipboardList(s) - (listInset - rowGap)
        let radius = max(4, min(s.scopedCornerRadius - listInset, s.rowHeight / 2))
        HStack(spacing: 0) {
            Group {
                if model.items.isEmpty {
                    Text(clipboard.clips.isEmpty ? (s.clipboardEnabled ? "Nothing copied yet" : "Clipboard history is off in Settings") : "No matches")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(model.items.indices, id: \.self) { i in
                                    if case .clip(let c) = model.items[i].kind {
                                        ClipRow(clip: c, clipboard: clipboard, selected: i == model.selection, hovered: i == model.hovered,
                                                s: s, radius: radius, onDelete: { actions.delete(c.id) })
                                            .padding(.vertical, rowGap)
                                            .id(i)
                                            .onTapGesture(count: 2) { onActivate(i) }
                                            .onTapGesture { model.selection = i }
                                            .onHover { inside in
                                                if inside { model.hovered = i } else if model.hovered == i { model.hovered = nil }
                                            }
                                    }
                                }
                            }
                            .padding(.horizontal, listInset)
                        }
                        .scrollIndicators(.never)
                        .onChange(of: model.selection) { _, i in proxy.scrollTo(i) }
                    }
                }
            }
            .frame(width: s.showPreview ? model.width(s) * 0.44 : nil)
            .frame(maxWidth: s.showPreview ? nil : .infinity)

            if s.showPreview {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                    .padding(.vertical, 6)
                ClipPreview(clip: selectedClip, clipboard: clipboard, s: s, actions: actions)
            }
        }
        .frame(height: height)
        .padding(.bottom, listInset - rowGap)
    }

    private var selectedClip: Clip? {
        if case .clip(let c)? = model.selected?.kind { return c }
        return nil
    }
}

private struct ClipRow: View {
    let clip: Clip
    let clipboard: ClipboardStore
    let selected: Bool
    let hovered: Bool
    let s: Settings
    let radius: CGFloat
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if s.showIcons { icon.frame(width: iconSize, height: iconSize) }
            Text(clip.title.isEmpty ? " " : clip.title).font(.system(size: 14)).lineLimit(1)
            Spacer(minLength: 6)
            if clip.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
            if hovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Delete from history (⌘⌫)")
            } else {
                Text(shortAge(clip.date)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: s.rowHeight)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(selected ? selectedFill : hovered ? hoverFill : .clear))
        .contentShape(Rectangle())
    }

    private var iconSize: CGFloat { min(30, max(14, s.rowHeight * 0.5)) }

    @ViewBuilder private var icon: some View {
        if clip.kind == .image, let img = clipboard.thumbnail(clip) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else if let id = clip.sourceBundleID, let img = IconCache.icon(forBundleID: id) {
            Image(nsImage: img).resizable()
        } else {
            Image(systemName: clip.kind == .image ? "photo" : "text.alignleft").foregroundStyle(.secondary)
        }
    }
}

private struct ClipPreview: View {
    let clip: Clip?
    let clipboard: ClipboardStore
    let s: Settings
    let actions: ClipActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let clip {
                Group {
                    switch clip.kind {
                    case .text:
                        ScrollView(.vertical) {
                            Text(String((clip.text ?? "").prefix(20_000)))
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .scrollIndicators(.automatic)
                    case .image:
                        if let img = clipboard.thumbnail(clip) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Text("Image missing").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                footer(clip)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(_ c: Clip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let id = c.sourceBundleID, let img = IconCache.icon(forBundleID: id) {
                    Image(nsImage: img).resizable().frame(width: 14, height: 14)
                }
                Text(details(c)).lineLimit(1)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ClipButton(title: "Paste", symbol: "arrow.turn.down.left", key: "↩") { actions.paste(c.id) }
                ClipButton(title: "Copy", symbol: "doc.on.doc", key: "⌘↩") { actions.copy(c.id) }
                ClipButton(title: c.pinned ? "Unpin" : "Pin", symbol: c.pinned ? "pin.slash" : "pin", key: "⌘P") { actions.pin(c.id) }
                Spacer(minLength: 0)
                ClipButton(title: "Delete", symbol: "trash", key: "⌘⌫", destructive: true) { actions.delete(c.id) }
            }
        }
    }

    private func details(_ c: Clip) -> String {
        var parts: [String] = []
        if let name = c.sourceName { parts.append(name) }
        parts.append(longAge(c.date))
        if c.kind == .text, let t = c.text {
            let words = t.split { $0.isWhitespace || $0.isNewline }.count
            parts.append("\(t.count) characters")
            if words > 1 { parts.append("\(words) words") }
        }
        return parts.joined(separator: " · ")
    }
}

func shortAge(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

private func longAge(_ d: Date) -> String {
    if Date().timeIntervalSince(d) < 60 { return "Just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f.localizedString(for: d, relativeTo: Date())
}

/// What the clipboard rows and preview buttons do (wired to the controller).
struct ClipActions {
    var paste: (UUID) -> Void = { _ in }
    var copy: (UUID) -> Void = { _ in }
    var pin: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
}

private struct ClipButton: View {
    let title: String
    let symbol: String
    let key: String
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // Icon only; the name and its key are in the tooltip.
            Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(destructive && hovering ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 28)
                .background(Circle().fill(destructive && hovering ? Color.red.opacity(0.15) : Color.primary.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(title) (\(key))")
        .onHover { hovering = $0 }
    }
}
