import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored as a Carbon key code + Carbon modifier mask.
struct HotKey: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let none = HotKey(keyCode: UInt32.max, modifiers: 0)
    static let launcherDefault = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
    static let dictationDefault = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    static let commandDefault = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey))
    static let escape = HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0)
    static let clipboardDefault = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey))
    static let switcherDefault = HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey))

    var isEmpty: Bool { keyCode == UInt32.max }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Builds a shortcut from a key press. Plain keys need a modifier; F-keys don't.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let code = Int(event.keyCode)
        let functionKey = HotKey.functionKeys.contains(code)
        guard functionKey || mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(code), modifiers: mods)
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        return f
    }

    var hasShift: Bool { modifiers & UInt32(shiftKey) != 0 }
    var withShift: HotKey { HotKey(keyCode: keyCode, modifiers: modifiers | UInt32(shiftKey)) }

    var display: String {
        guard !isEmpty else { return "" }
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + HotKey.keyName(Int(keyCode))
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Tab: "⇥", kVK_Return: "↩", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func keyName(_ code: Int) -> String {
        if let s = special[code] { return s }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Registers global hotkeys with Carbon. No Accessibility permission needed.
@MainActor final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Entry {
        let ref: EventHotKeyRef
        let pressed: () -> Void
        let released: (() -> Void)?
        let transient: Bool
    }

    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    private var paused = 0
    /// Called to put every hotkey back after recording a new one.
    var reload: (() -> Void)?
    /// Shortcuts macOS refused (usually because another app already uses them).
    private(set) var failed: [String] = []

    /// Registers a hotkey; `released` makes hold-to-talk possible.
    func register(_ key: HotKey, released: (() -> Void)? = nil, _ pressed: @escaping () -> Void) {
        guard paused == 0 else { return }
        _ = add(key, pressed: pressed, released: released, transient: false)
    }

    /// A short-lived hotkey (e.g. Esc while dictating) that survives `unregisterAll`. Returns a token for `remove`.
    func registerTransient(_ key: HotKey, _ pressed: @escaping () -> Void) -> UInt32? {
        add(key, pressed: pressed, released: nil, transient: true)
    }

    func remove(_ token: UInt32?) {
        guard let token, let e = entries.removeValue(forKey: token) else { return }
        UnregisterEventHotKey(e.ref)
    }

    private func add(_ key: HotKey, pressed: @escaping () -> Void, released: (() -> Void)?, transient: Bool) -> UInt32? {
        guard !key.isEmpty else { return nil }
        installIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x464C_4B31), id: id) // "FLK1"
        guard RegisterEventHotKey(key.keyCode, key.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else {
            failed.append(key.display)
            return nil
        }
        entries[id] = Entry(ref: ref, pressed: pressed, released: released, transient: transient)
        return id
    }

    func unregisterAll() {
        failed = []
        for (id, e) in entries where !e.transient {
            UnregisterEventHotKey(e.ref)
            entries.removeValue(forKey: id)
        }
    }

    /// While a shortcut is being recorded, existing hotkeys must not swallow the keys.
    func pause() {
        paused += 1
        unregisterAll()
    }

    func resume() {
        paused = max(0, paused - 1)
        if paused == 0 { reload?() }
    }

    fileprivate func fire(_ id: UInt32, released: Bool) {
        guard let e = entries[id] else { return }
        if released { e.released?() } else { e.pressed() }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id, released: released) }
            return noErr
        }, 2, &specs, nil, nil)
    }
}

/// macOS's own ⌘Space (Spotlight). MONEY! can take the shortcut over, and give it back.
enum SpotlightShortcut {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    /// 64 = Show Spotlight search (⌘Space).
    private static let id = "64"

    static var enabled: Bool {
        CFPreferencesAppSynchronize(domain)
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any],
              let entry = all[id] as? [String: Any] else { return true }
        return (entry["enabled"] as? NSNumber)?.boolValue ?? true
    }

    /// Writes the setting the way System Settings does, then tells the system to reload its shortcuts.
    static func set(enabled on: Bool) {
        let entry = """
        <dict><key>enabled</key><\(on ? "true" : "false")/><key>value</key><dict><key>parameters</key>\
        <array><integer>32</integer><integer>49</integer><integer>1048576</integer></array><key>type</key><string>standard</string></dict></dict>
        """
        run("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add", id, entry])
        run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
