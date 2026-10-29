import AppKit
import AVFoundation
import Speech
import ServiceManagement
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store.shared
    private(set) var clipboard: ClipboardStore!
    private(set) var launcher: LauncherController!
    private(set) var dictation: DictationController!
    private(set) var meeting: MeetingRecorder!
    private(set) var pomodoro: Pomodoro!
    var island: IslandModel!
    private var islandController: IslandController!
    private let fnKeys = FnKeyMonitor()
    private var copilot: MeetingCopilot!
    private var copilotWindow: CopilotWindow!
    private var meetingWasRunning = false
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    private var registered = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        clipboard = ClipboardStore(store: store)
        Stats.shared.importHistory(clipboard.clips)
        launcher = LauncherController(store: store, clipboard: clipboard)
        launcher.openSettings = { [weak self] in self?.showSettings() }
        dictation = DictationController(store: store, clipboard: clipboard)
        meeting = MeetingRecorder(store: store)
        launcher.model.meeting = meeting
        pomodoro = Pomodoro()
        launcher.model.pomodoro = pomodoro
        island = IslandModel(pomodoro: pomodoro, dictation: dictation, meeting: meeting)
        island.isLauncherShowing = { [weak self] in self?.launcher.isShown ?? false }
        copilot = MeetingCopilot(store: store, meeting: meeting)
        copilotWindow = CopilotWindow(store: store, meeting: meeting, copilot: copilot)
        launcher.model.meetingCopilot = copilot
        islandController = IslandController(model: island, openMeeting: { [weak self] in self?.showMeetingWindow() })
        launcher.island = island
        dictation.onChange = { [weak self] in self?.island.refresh() }
        dictation.onNote = { [weak self] text in self?.island.flash(text, symbol: "doc.on.clipboard.fill", color: .white, seconds: 2.4, note: true) }
        meeting.onChange = { [weak self] in
            guard let self else { return }
            self.island.refresh()
            // A new meeting brings up the floating window (and starts its questions afresh).
            if self.meeting.isRunning, !self.meetingWasRunning {
                self.copilot.reset()
                if self.store.settings.meetingOverlay { self.copilotWindow.show() }
            }
            self.meetingWasRunning = self.meeting.isRunning
        }
        pomodoro.onChange = { [weak self] in self?.island.refresh() }
        Stopwatches.shared.onChange = { [weak self] in self?.island.refresh() }
        Timers.shared.onChange = { [weak self] in self?.island.refresh() }
        ClockSound.announce = { [weak self] title, detail, symbol in self?.island.flash(title, detail, symbol: symbol, color: .orange, seconds: 4) }
        Alarms.shared.onChange = { [weak self] in self?.island.refresh() }
        NowPlaying.shared.onChange = { [weak self] in self?.island.refresh() }
        NowPlaying.shared.start()
        _ = AudioMixer.shared // re-applies saved per-app levels
        pomodoro.announce = { [weak self] title, detail in
            self?.island.flash(title, detail, symbol: "timer", color: Color(red: 1, green: 0.42, blue: 0.33), seconds: 3)
        }
        launcher.onVisibilityChange = { [weak self] in self?.island.refresh() }
        SpeechModels.shared.refresh()
        fnKeys.onPress = { [weak self] m in self?.dictation.pressed(m) }
        fnKeys.onRelease = { [weak self] m in self?.dictation.released(m) }
        fnKeys.onOtherKey = { [weak self] in self?.dictation.abortIfJustStarted() }

        if runDevHook(CommandLine.arguments) { return }

        // Every launch starts hidden from screen sharing; turning it off only lasts until Halo quits.
        if !store.settings.hideFromScreenShare { store.settings.hideFromScreenShare = true }
        HotKeyCenter.shared.reload = { [weak self] in self?.registerHotKeys(force: true) }
        store.onChange = { [weak self] old in self?.apply(old) }
        apply(nil)
        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation?.shutDown()
    }

    /// Opening the app again (Finder, Launchpad, Flick itself) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func apply(_ old: Settings?) {
        let s = store.settings
        registerHotKeys()
        updateStatusItem()
        clipboard.apply()
        launcher.applySettings()
        if let old, old.searchFolders != s.searchFolders { launcher.index.refresh(folders: s.searchFolders) }
        if old == nil || old?.launchAtLogin != s.launchAtLogin { syncLoginItem() }
        if s.dictationEnabled && s.fnDictation { fnKeys.start() } else { fnKeys.stop() }
        launcher.panel.sharingType = s.hideFromScreenShare ? .none : .readOnly
        islandController.setSharing(!s.notchInCaptures)
        copilotWindow.applyPrivacy()
    }

    // MARK: Hotkeys

    func registerHotKeys(force: Bool = false) {
        let s = store.settings
        let keys = [("launcher", s.launcherHotKey), ("clipboard", s.clipboardHotKey), ("switcher", s.switcherHotKey), ("copilot", s.copilotHotKey),
                    ("dictation", s.dictationEnabled ? s.dictationHotKey : .none), ("command", s.dictationEnabled ? s.commandHotKey : .none)]
        let wanted = keys.map { "\($0.0)=\($0.1.keyCode)/\($0.1.modifiers)" }.joined(separator: ";")
        guard force || wanted != registered else { return }
        registered = wanted
        let hk = HotKeyCenter.shared
        hk.unregisterAll()
        hk.register(s.launcherHotKey) { [weak self] in self?.launcher.toggle(.apps) }
        hk.register(s.clipboardHotKey) { [weak self] in self?.launcher.toggle(.clipboard) }
        hk.register(s.switcherHotKey) { [weak self] in self?.launcher.switcherPressed(backward: false) }
        hk.register(s.copilotHotKey) { [weak self] in self?.copilotWindow.toggle() }
        if s.dictationEnabled {
            hk.register(s.dictationHotKey, released: { [weak self] in self?.dictation.released(.dictate) }) { [weak self] in
                self?.dictation.pressed(.dictate)
            }
            hk.register(s.commandHotKey, released: { [weak self] in self?.dictation.released(.command) }) { [weak self] in
                self?.dictation.pressed(.command)
            }
        }
        if !s.switcherHotKey.isEmpty, !s.switcherHotKey.hasShift {
            hk.register(s.switcherHotKey.withShift) { [weak self] in self?.launcher.switcherPressed(backward: true) }
        }
    }

    /// The floating meeting window, or the popup's Meeting view if the window is turned off.
    func showMeetingWindow() {
        if store.settings.meetingOverlay { copilotWindow.show() } else { launcher.openMeeting() }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        let s = store.settings
        guard s.showMenuBarIcon else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = MenuBarIcon.image
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        }
    }

    lazy var menuPanel = MenuPanel(content: MenuView(store: store, clipboard: clipboard, meeting: meeting, pomodoro: pomodoro) { [weak self] action in
        self?.menuAction(action)
    })

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        menuPanel.setSharing(store.settings.hideFromScreenShare)
        menuPanel.toggle(under: button)
    }

    private func menuAction(_ action: MenuAction) {
        if case .copy(let c) = action {
            clipboard.write(c, plain: false) // keep the panel open so you can see "Copied"
            return
        }
        menuPanel.close()
        switch action {
        case .apps: launcher.show(.apps)
        case .clipboard: launcher.show(.clipboard)
        case .text: launcher.startScreenText()
        case .dictate:
            // Hands-free; press the dictation key (or Fn) again to finish.
            dictation.startHandsFree()
        case .meeting:
            if !meeting.isRunning, meeting.phase != .summarizing { meeting.reset(); meeting.start() }
            showMeetingWindow()
        case .focus: launcher.show(.pomodoro)
        case .notes: launcher.show(.notes)
        case .calculator: launcher.show(.calculator)
        case .translate: launcher.show(.translate)
        case .mixer: launcher.show(.mixer)
        case .library: launcher.show(.library)
        case .stats: showSettings(pane: .stats)
        case .settings: showSettings()
        case .quit: NSApp.terminate(nil)
        case .copy: break
        }
    }

    @objc private func menuSettings() { showSettings() }

    // MARK: Settings window

    func showSettings(pane: Pane = .general) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "MONEY! Settings"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 680, height: 460)
            let hc = NSHostingController(rootView: SettingsView(store: store, clipboard: clipboard, launcher: launcher, pane: pane)
                .frame(minWidth: 680, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity))
            // The window keeps its size when switching sections; each page scrolls inside it.
            hc.sizingOptions = []
            w.contentViewController = hc
            w.setContentSize(NSSize(width: 760, height: 580))
            w.center()
            w.delegate = self
            settingsWindow = w
        }
        // Show in the Dock and ⌘Tab while Settings is open; back to a pure background app after.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Login item

    private func syncLoginItem() {
        let service = SMAppService.mainApp
        let want = store.settings.launchAtLogin
        if want, service.status != .enabled { try? service.register() }
        if !want, service.status == .enabled { try? service.unregister() }
    }

    // MARK: Menu (gives the text fields ⌘A/⌘C/⌘V/⌘Z)

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit MONEY!", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

/// The menu bar glyph: a dollar note with wings (the app's 💸), drawn as a template so it follows the menu bar's colour.
enum MenuBarIcon {
    static let image: NSImage = {
        let img = make()
        img.isTemplate = true
        img.accessibilityDescription = "MONEY!"
        return img
    }()

    private static func make() -> NSImage {
        NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            NSColor.black.set()
            // Wings: three feathers each side, swept up and out.
            func wing(_ side: CGFloat) {
                let cx: CGFloat = 11
                for (i, len) in [CGFloat(6.0), 5.0, 3.8].enumerated() {
                    let fi = CGFloat(i)
                    let y = 10.2 - fi * 2.0
                    let p = NSBezierPath()
                    let x0 = cx + side * 4.4
                    p.move(to: NSPoint(x: x0, y: y))
                    p.curve(to: NSPoint(x: x0 + side * len, y: y + 4.2 - fi * 1.5),
                            controlPoint1: NSPoint(x: x0 + side * len * 0.5, y: y),
                            controlPoint2: NSPoint(x: x0 + side * len * 0.85, y: y + 2.0 - fi * 0.6))
                    p.lineWidth = 1.4
                    p.lineCapStyle = .round
                    p.stroke()
                }
            }
            wing(-1)
            wing(1)
            // The note, tilted.
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            ctx.translateBy(x: 11, y: 7.6)
            ctx.rotate(by: -0.12)
            let note = NSBezierPath(roundedRect: NSRect(x: -5, y: -4.3, width: 10, height: 8.6), xRadius: 2, yRadius: 2)
            note.fill()
            // "$" knocked out.
            NSGraphicsContext.current!.compositingOperation = .destinationOut
            let font = NSFont.systemFont(ofSize: 8.2, weight: .heavy)
            let s = NSAttributedString(string: "$", attributes: [.font: font, .foregroundColor: NSColor.black])
            let sz = s.size()
            s.draw(at: NSPoint(x: -sz.width / 2, y: -sz.height / 2 + 0.2))
            ctx.restoreGState()
            return true
        }
    }
}
