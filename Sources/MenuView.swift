import AppKit
import SwiftUI

enum MenuAction {
    case apps, text, meeting, settings, quit
}

/// The menu bar panel: a glass card under the menu bar icon with what's running, a few actions and the main switches.
@MainActor final class MenuPanel {
    private let panel: NSPanel
    private var monitors: [Any] = []

    init(content: some View) {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.borderless, .nonactivatingPanel],
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
        if size.width < 10 || size.height < 10 { size = NSSize(width: 300, height: 400) }
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
    static let inset: CGFloat = PanelLayout.inset
    static var inner: CGFloat { radius - inset }
}

/// Only what you'd reach the menu bar for: what's running now with its controls, the actions without a hotkey of
/// their own, the main switches, Settings and Quit. Every mode is one hotkey away in the popup, so they aren't here.
struct MenuView: View {
    @Bindable var store: Store
    let meeting: MeetingRecorder
    let pomodoro: Pomodoro
    let act: (MenuAction) -> Void

    var body: some View {
        let timers = Timers.shared.list.filter { !$0.finished }.prefix(3)
        VStack(alignment: .leading, spacing: PanelLayout.gap) {
            if meeting.isRunning || pomodoro.active || !timers.isEmpty {
                VStack(spacing: 0) {
                    if meeting.isRunning { meetingRow }
                    if pomodoro.active { pomodoroRow }
                    ForEach(timers) { timerRow($0) }
                }
                Divider()
            }
            VStack(spacing: 0) {
                MenuRow(title: "Open MONEY!", symbol: "magnifyingglass", key: store.settings.launcherHotKey.display) { act(.apps) }
                if !meeting.isRunning { MenuRow(title: "New meeting", symbol: "waveform") { act(.meeting) } }
                MenuRow(title: "Text from screen", symbol: "text.viewfinder") { act(.text) }
            }
            Divider()
            VStack(spacing: 0) {
                switchRow("Clipboard history", "clock.arrow.circlepath", $store.settings.clipboardEnabled)
                switchRow("Dictation", "mic", $store.settings.dictationEnabled)
                switchRow("Dynamic notch", "rectangle.topthird.inset.filled", $store.settings.notchEnabled)
                switchRow("Hide from screen sharing", "eye.slash", $store.settings.hideFromScreenShare)
            }
            Divider()
            VStack(spacing: 0) {
                MenuRow(title: "Settings…", symbol: "gearshape", key: "⌘,") { act(.settings) }
                MenuRow(title: "Quit MONEY!", symbol: "power", key: "⌘Q") { act(.quit) }
            }
        }
        .padding(MenuLayout.inset)
        .frame(width: 300)
        .background {
            RoundedRectangle(cornerRadius: MenuLayout.radius, style: .continuous).fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: MenuLayout.radius, style: .continuous))
            RoundedRectangle(cornerRadius: MenuLayout.radius, style: .continuous).fill(Color.black.opacity(store.settings.shade * 0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: MenuLayout.radius, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func timerRow(_ t: CountdownTimer) -> some View {
        let timers = Timers.shared
        return LiveRow(dot: .orange, title: t.label.isEmpty ? "Timer" : t.label, detail: Pomodoro.clock(t.remaining(timers.now))) {
            IconButton(symbol: t.paused ? "play.fill" : "pause.fill", help: t.paused ? "Resume" : "Pause") { timers.toggle(t) }
            IconButton(symbol: "xmark", help: "Remove") { timers.remove(t) }
        }
    }

    private var meetingRow: some View {
        LiveRow(dot: .red, title: meeting.phase == .paused ? "Meeting paused" : "Recording", detail: meeting.clock) {
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

    private func switchRow(_ title: String, _ symbol: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: value).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
    }
}

/// A plain menu line: icon, title, its key on the right; highlighted under the pointer.
private struct MenuRow: View {
    let title: String
    let symbol: String
    var key = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(.system(size: 13))
                Spacer()
                Text(key).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: MenuLayout.inner, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            Circle().fill(dot).frame(width: 8, height: 8).frame(width: 18)
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(detail).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) { buttons() }
        }
        .padding(.leading, 8)
        .frame(height: 40)
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
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.18 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
