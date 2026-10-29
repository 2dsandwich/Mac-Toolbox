import AppKit
import SwiftUI

enum MenuAction {
    case apps, clipboard, text, dictate, meeting, focus, settings, quit
    case notes, calculator, translate, mixer, library, stats
    case copy(Clip)
}

/// The menu bar panel: a glass card under the menu bar icon with everything Halo does.
@MainActor final class MenuPanel {
    private let panel: NSPanel
    private var monitors: [Any] = []

    init(content: some View) {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = FirstMouseHostingView(rootView: AnyView(content))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
    }

    var isShown: Bool { panel.isVisible }
    var debugFrame: String { "frame \(panel.frame) alpha \(panel.alphaValue) fitting \(panel.contentView?.fittingSize ?? .zero)" }

    func setSharing(_ hidden: Bool) { panel.sharingType = hidden ? .none : .readOnly }

    func toggle(under button: NSStatusBarButton) { isShown ? close() : show(under: button) }

    func show(under button: NSStatusBarButton) {
        guard let window = button.window, let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 10 || size.height < 10 { size = host.intrinsicContentSize }
        if size.width < 10 || size.height < 10 { size = NSSize(width: 380, height: 600) }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        let esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.close() }; return nil }
            return e
        }
        monitors = [outside, esc].compactMap { $0 }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        })
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The panel's corners, and the concentric ones inside it (its radius less its inset).
enum MenuLayout {
    static let radius: CGFloat = 26
    static let inset: CGFloat = 16
    static var inner: CGFloat { radius - inset }
}

struct MenuView: View {
    @Bindable var store: Store
    let clipboard: ClipboardStore
    let meeting: MeetingRecorder
    let pomodoro: Pomodoro
    let act: (MenuAction) -> Void

    var body: some View {
        let s = store.settings
        let timers = Timers.shared
        VStack(alignment: .leading, spacing: 14) {
            header
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                Tile(title: "Search", symbol: "magnifyingglass", key: s.launcherHotKey.display) { act(.apps) }
                Tile(title: "Clipboard", symbol: "doc.on.clipboard", key: s.clipboardHotKey.display) { act(.clipboard) }
                Tile(title: "Text", symbol: "text.viewfinder", key: "⌘3") { act(.text) }
                Tile(title: "Dictate", symbol: "mic.fill", key: s.fnDictation ? "Fn" : s.dictationHotKey.display) { act(.dictate) }
                Tile(title: meeting.isRunning ? "Meeting" : "Record", symbol: "waveform", key: meeting.isRunning ? meeting.clock : "⌘4",
                     tint: meeting.isRunning ? .red : nil) { act(.meeting) }
                Tile(title: "Clock", symbol: "clock.fill", key: pomodoro.active ? pomodoro.clock : timers.next.map { Pomodoro.clock($0.remaining(timers.now)) } ?? "⌘5",
                     tint: pomodoro.active || timers.next != nil ? Color(red: 1, green: 0.42, blue: 0.33) : nil) { act(.focus) }
                Tile(title: "Notes", symbol: "note.text", key: NoteBoard.shared.notes.isEmpty ? "" : "\(NoteBoard.shared.notes.count)") { act(.notes) }
                Tile(title: "Calculate", symbol: "plus.forwardslash.minus", key: "") { act(.calculator) }
                Tile(title: "Translate", symbol: "character.bubble.fill", key: "") { act(.translate) }
                Tile(title: "Volume", symbol: "slider.vertical.3", key: "") { act(.mixer) }
                Tile(title: "All Apps", symbol: "square.grid.3x3.fill", key: "") { act(.library) }
                Tile(title: "Stats", symbol: "chart.bar.fill", key: stats.streak > 1 ? "\(stats.streak) days" : "") { act(.stats) }
            }
            today
            if meeting.isRunning { meetingRow }
            if pomodoro.active { pomodoroRow }
            ForEach(timers.list.filter { !$0.finished }.prefix(2)) { t in timerRow(t) }
            if s.clipboardEnabled, !clipboard.clips.isEmpty { recents }
            VStack(spacing: 2) {
                switchRow("Clipboard history", "clock.arrow.circlepath", $store.settings.clipboardEnabled)
                switchRow("Dictation", "mic", $store.settings.dictationEnabled)
                switchRow("Dynamic notch", "rectangle.topthird.inset.filled", $store.settings.notchEnabled)
                switchRow("Hide from screen sharing", "eye.slash", $store.settings.hideFromScreenShare)
            }
            HStack {
                FooterButton(title: "Settings…", key: "⌘,") { act(.settings) }
                Spacer()
                FooterButton(title: "Quit MONEY!", key: "⌘Q") { act(.quit) }
            }
        }
        .padding(MenuLayout.inset)
        .frame(width: 380)
        .background {
            RoundedRectangle(cornerRadius: MenuLayout.radius, style: .continuous).fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: MenuLayout.radius, style: .continuous))
            RoundedRectangle(cornerRadius: MenuLayout.radius, style: .continuous).fill(Color.black.opacity(store.settings.darkness * 0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: MenuLayout.radius, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("MONEY!").font(.system(size: 15, weight: .semibold))
                if !status.isEmpty { Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            IconButton(symbol: "gearshape", help: "Settings (⌘,)") { act(.settings) }
        }
    }

    private var stats: Stats { Stats.shared }

    /// What's going on right now, or how today has gone.
    private var status: String {
        var parts: [String] = []
        if meeting.isRunning { parts.append("Recording · \(meeting.clock)") }
        if pomodoro.active { parts.append("\(pomodoro.status) · \(pomodoro.clock)") }
        let running = Timers.shared.running.count
        if running > 0 { parts.append(running == 1 ? "1 timer" : "\(running) timers") }
        if NowPlaying.shared.playing, !NowPlaying.shared.songTitle.isEmpty { parts.append("♪ \(NowPlaying.shared.songTitle)") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return ""
    }

    /// Today in numbers; opens Settings › Stats.
    private var today: some View {
        Button { act(.stats) } label: {
            HStack(spacing: 0) {
                todayItem(Int(stats.today(.words)), "words", "mic.fill", .pink)
                todayItem(Int(stats.today(.appsOpened) + stats.today(.answers)), "searches", "magnifyingglass", .blue)
                todayItem(Int(stats.today(.copies)), "copies", "doc.on.clipboard", .teal)
                todayItem(Int(stats.today(.focusMinutes)), "focus min", "timer", Color(red: 1, green: 0.42, blue: 0.33))
            }
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: MenuLayout.inner, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: MenuLayout.inner, style: .continuous).fill(Color.white.opacity(0.06)))
        .help("Today · open Stats")
    }

    private func todayItem(_ n: Int, _ caption: String, _ symbol: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                Text(n.formatted()).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            Text(caption).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func timerRow(_ t: CountdownTimer) -> some View {
        let timers = Timers.shared
        return LiveRow(dot: .orange, title: t.label.isEmpty ? "Timer" : t.label, detail: Pomodoro.clock(t.remaining(timers.now))) {
            IconButton(symbol: t.paused ? "play.fill" : "pause.fill", help: t.paused ? "Resume" : "Pause") { timers.toggle(t) }
            IconButton(symbol: "xmark", help: "Remove") { timers.remove(t) }
        }
    }

    private var meetingRow: some View {
        LiveRow(dot: .red, title: meeting.phase == .paused ? "Meeting paused" : "Recording meeting", detail: meeting.clock) {
            IconButton(symbol: "text.bubble", help: "Open the meeting window") { act(.meeting) }
            IconButton(symbol: "stop.fill", help: "Stop and write notes") { meeting.stop() }
        }
    }

    private var pomodoroRow: some View {
        LiveRow(dot: pomodoro.phase == .rest ? .green : Color(red: 1, green: 0.42, blue: 0.33), title: pomodoro.status, detail: pomodoro.clock) {
            IconButton(symbol: pomodoro.paused ? "play.fill" : "pause.fill", help: "Pause / resume") { pomodoro.toggle() }
            IconButton(symbol: "xmark", help: "Stop") { pomodoro.stop() }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Recently copied").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Show All") { act(.clipboard) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
            ForEach(clipboard.ordered.prefix(3)) { c in
                RecentRow(clip: c, clipboard: clipboard) { act(.copy(c)) }
            }
        }
    }

    private func switchRow(_ title: String, _ symbol: String, _ value: Binding<Bool>) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
            }
            .font(.system(size: 12.5))
            Spacer()
            Toggle("", isOn: value).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
    }
}

private struct Tile: View {
    let title: String
    let symbol: String
    let key: String
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(tint ?? .white).frame(height: 20)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                Text(key.isEmpty ? " " : key).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: MenuLayout.inner, style: .continuous))
        }
        .buttonStyle(.plain)
        // Separate glass per tile (no shared container), so they never melt together.
        .glassEffect(hovering ? Glass.regular.tint(.white.opacity(0.12)).interactive() : Glass.regular.interactive(),
                     in: RoundedRectangle(cornerRadius: MenuLayout.inner, style: .continuous))
        .onHover { hovering = $0 }
    }
}

private struct LiveRow<Buttons: View>: View {
    let dot: Color
    let title: String
    let detail: String
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Text(detail).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            buttons()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: MenuLayout.inner, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

private struct RecentRow: View {
    let clip: Clip
    let clipboard: ClipboardStore
    let action: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            action()
            copied = true
        } label: {
            HStack(spacing: 8) {
                icon.frame(width: 16, height: 16)
                Text(clip.title).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 6)
                Text(copied ? "Copied" : hovering ? "Copy" : shortAge(clip.date))
                    .font(.system(size: 11)).foregroundStyle(copied ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: MenuLayout.inner, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        if clip.kind == .image, let img = clipboard.thumbnail(clip) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).clipShape(RoundedRectangle(cornerRadius: 3))
        } else if let id = clip.sourceBundleID, let img = IconCache.icon(forBundleID: id) {
            Image(nsImage: img).resizable()
        } else {
            Image(systemName: clip.sourceName == "Dictation" ? "mic" : "text.alignleft").foregroundStyle(.secondary)
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.18 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

private struct FooterButton: View {
    let title: String
    let key: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12.5))
                Text(key).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: MenuLayout.inner, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
