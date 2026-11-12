import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Rectangle-style window layouts for the frontmost window, by hotkey or from the popup.
enum WindowLayout: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case maximize, almostMaximize, center, restore, nextDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .leftTwoThirds: "Left Two Thirds"
        case .rightTwoThirds: "Right Two Thirds"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .center: "Center Window"
        case .restore: "Restore Window"
        case .nextDisplay: "Next Display"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .leftThird: "rectangle.leadingthird.inset.filled"
        case .centerThird: "rectangle.center.inset.filled"
        case .rightThird: "rectangle.trailingthird.inset.filled"
        case .leftTwoThirds: "rectangle.leadinghalf.inset.filled"
        case .rightTwoThirds: "rectangle.trailinghalf.inset.filled"
        case .maximize: "rectangle.fill"
        case .almostMaximize: "rectangle.inset.filled"
        case .center: "rectangle.center.inset.filled"
        case .restore: "arrow.uturn.backward"
        case .nextDisplay: "display.2"
        }
    }

    /// What you can type in the popup (after "window" / "move window to" is taken off).
    var keywords: [String] {
        switch self {
        case .leftHalf: ["left half", "left", "snap left", "左半分"]
        case .rightHalf: ["right half", "right", "snap right", "右半分"]
        case .topHalf: ["top half", "top", "upper half", "上半分"]
        case .bottomHalf: ["bottom half", "bottom", "lower half", "下半分"]
        case .topLeft: ["top left", "upper left", "top left quarter", "左上"]
        case .topRight: ["top right", "upper right", "top right quarter", "右上"]
        case .bottomLeft: ["bottom left", "lower left", "bottom left quarter", "左下"]
        case .bottomRight: ["bottom right", "lower right", "bottom right quarter", "右下"]
        case .leftThird: ["left third", "first third"]
        case .centerThird: ["center third", "centre third", "middle third"]
        case .rightThird: ["right third", "last third"]
        case .leftTwoThirds: ["left two thirds", "left 2/3", "first two thirds"]
        case .rightTwoThirds: ["right two thirds", "right 2/3", "last two thirds"]
        case .maximize: ["maximize", "maximise", "max window", "fill screen", "最大化"]
        case .almostMaximize: ["almost maximize", "almost maximise", "almost max"]
        case .center: ["center", "centre", "center window", "centre window", "中央"]
        case .restore: ["restore", "restore window", "unsnap", "元のサイズ"]
        case .nextDisplay: ["next display", "next screen", "other display", "other screen", "move to next display", "次のディスプレイ"]
        }
    }

    /// Rectangle's defaults: ⌃⌥ arrows for halves, ⌃⌥↩ maximize, ⌃⌥C centre, ⌃⌥⌫ restore, ⌃⌥⌘→ next display.
    var defaultHotKey: HotKey {
        let ctrlOpt = UInt32(controlKey | optionKey)
        switch self {
        case .leftHalf: return HotKey(keyCode: UInt32(kVK_LeftArrow), modifiers: ctrlOpt)
        case .rightHalf: return HotKey(keyCode: UInt32(kVK_RightArrow), modifiers: ctrlOpt)
        case .topHalf: return HotKey(keyCode: UInt32(kVK_UpArrow), modifiers: ctrlOpt)
        case .bottomHalf: return HotKey(keyCode: UInt32(kVK_DownArrow), modifiers: ctrlOpt)
        case .maximize: return HotKey(keyCode: UInt32(kVK_Return), modifiers: ctrlOpt)
        case .center: return HotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: ctrlOpt)
        case .restore: return HotKey(keyCode: UInt32(kVK_Delete), modifiers: ctrlOpt)
        case .nextDisplay: return HotKey(keyCode: UInt32(kVK_RightArrow), modifiers: ctrlOpt | UInt32(cmdKey))
        default: return .none
        }
    }

    /// The saved key wins; layouts never changed in Settings keep their default.
    func hotKey(_ s: Settings) -> HotKey { s.windowHotKeys[rawValue] ?? defaultHotKey }

    /// Pressing the same half again goes 1/2 → 2/3 → 1/3, like Rectangle.
    var cycles: Bool { [.leftHalf, .rightHalf, .topHalf, .bottomHalf].contains(self) }

    /// Layouts that are a place on the screen, so moving to another display can put the window in the same place there.
    var isPlacement: Bool { ![.center, .restore, .nextDisplay].contains(self) }
}

/// A screen as the frame math sees it (AppKit coordinates: origin at the primary screen's bottom left, y up).
struct Display: Equatable {
    var frame: CGRect
    /// Without the menu bar and the Dock.
    var visible: CGRect

    @MainActor static var current: [Display] { NSScreen.screens.map { Display(frame: $0.frame, visible: $0.visibleFrame) } }
}

/// The frame math, kept free of AX so `--layout-test` can check it on made-up screens.
enum WindowMath {
    static let cycle: [CGFloat] = [1.0 / 2, 2.0 / 3, 1.0 / 3]

    /// Where `layout` puts a window that is now at `window`, on a screen whose usable area is `v`.
    static func target(_ layout: WindowLayout, window: CGRect, visible v: CGRect, step: Int = 0) -> CGRect {
        let f = cycle[step % cycle.count]
        let w = v.width, h = v.height
        let r: CGRect
        switch layout {
        case .leftHalf: r = CGRect(x: v.minX, y: v.minY, width: w * f, height: h)
        case .rightHalf: r = CGRect(x: v.maxX - w * f, y: v.minY, width: w * f, height: h)
        case .topHalf: r = CGRect(x: v.minX, y: v.maxY - h * f, width: w, height: h * f)
        case .bottomHalf: r = CGRect(x: v.minX, y: v.minY, width: w, height: h * f)
        case .topLeft: r = CGRect(x: v.minX, y: v.midY, width: w / 2, height: h / 2)
        case .topRight: r = CGRect(x: v.midX, y: v.midY, width: w / 2, height: h / 2)
        case .bottomLeft: r = CGRect(x: v.minX, y: v.minY, width: w / 2, height: h / 2)
        case .bottomRight: r = CGRect(x: v.midX, y: v.minY, width: w / 2, height: h / 2)
        case .leftThird: r = CGRect(x: v.minX, y: v.minY, width: w / 3, height: h)
        case .centerThird: r = CGRect(x: v.minX + w / 3, y: v.minY, width: w / 3, height: h)
        case .rightThird: r = CGRect(x: v.maxX - w / 3, y: v.minY, width: w / 3, height: h)
        case .leftTwoThirds: r = CGRect(x: v.minX, y: v.minY, width: w * 2 / 3, height: h)
        case .rightTwoThirds: r = CGRect(x: v.maxX - w * 2 / 3, y: v.minY, width: w * 2 / 3, height: h)
        case .maximize: r = v
        case .almostMaximize: r = CGRect(x: v.midX - w * 0.45, y: v.midY - h * 0.45, width: w * 0.9, height: h * 0.9)
        case .center, .restore, .nextDisplay:
            let size = CGSize(width: min(window.width, w), height: min(window.height, h))
            r = CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
        }
        return snapped(r)
    }

    /// Whole points, rounded edge by edge so neighbouring halves and thirds meet without a gap.
    static func snapped(_ r: CGRect) -> CGRect {
        let x0 = r.minX.rounded(), y0 = r.minY.rounded(), x1 = r.maxX.rounded(), y1 = r.maxY.rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// AppKit ↔ AX. AX puts the origin at the primary screen's top left with y down; the same flip works both ways.
    static func flip(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The screen showing most of the window (or the nearest one if it's off every screen).
    static func displayIndex(for window: CGRect, in displays: [Display]) -> Int? {
        guard !displays.isEmpty else { return nil }
        let areas = displays.map { d -> CGFloat in
            let i = d.frame.intersection(window)
            return i.isNull ? 0 : i.width * i.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        let c = CGPoint(x: window.midX, y: window.midY)
        return displays.indices.min { dist(c, displays[$0].frame) < dist(c, displays[$1].frame) }
    }

    private static func dist(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// Displays in the order "next display" walks them: left to right, then top to bottom.
    static func ordered(_ displays: [Display]) -> [Display] {
        displays.sorted { $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.maxY > $1.frame.maxY }
    }

    static func nextDisplay(after current: Display, in displays: [Display]) -> Display? {
        let o = ordered(displays)
        guard o.count > 1, let i = o.firstIndex(of: current) else { return nil }
        return o[(i + 1) % o.count]
    }

    /// A window that isn't in a layout keeps its size (shrunk to fit) and its relative place on the other screen.
    static func moved(_ window: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let size = CGSize(width: min(window.width, to.width), height: min(window.height, to.height))
        let rx = from.width > 0 ? (window.midX - from.minX) / from.width : 0.5
        let ry = from.height > 0 ? (window.midY - from.minY) / from.height : 0.5
        let r = CGRect(x: to.minX + rx * to.width - size.width / 2, y: to.minY + ry * to.height - size.height / 2, width: size.width, height: size.height)
        return snapped(clamped(r, in: to))
    }

    static func clamped(_ r: CGRect, in v: CGRect) -> CGRect {
        var o = r
        o.size.width = min(r.width, v.width)
        o.size.height = min(r.height, v.height)
        o.origin.x = min(max(r.minX, v.minX), v.maxX - o.width)
        o.origin.y = min(max(r.minY, v.minY), v.maxY - o.height)
        return o
    }

    /// Windows with a minimum (or maximum) size end up a different size than asked. Keep them on the edge the
    /// layout is against (right half stays on the right, top half at the top) and on the screen.
    static func settled(_ target: CGRect, actual size: CGSize, visible v: CGRect) -> CGRect {
        func axis(_ lo: CGFloat, _ hi: CGFloat, _ vlo: CGFloat, _ vhi: CGFloat, _ len: CGFloat, preferHigh: Bool) -> CGFloat {
            let atLo = abs(lo - vlo) < 1, atHi = abs(hi - vhi) < 1
            if atHi && (!atLo || preferHigh) { return hi - len }
            if atLo { return lo }
            return (lo + hi) / 2 - len / 2
        }
        // Full height: keep the title bar at the top (AppKit's high y).
        let x = axis(target.minX, target.maxX, v.minX, v.maxX, size.width, preferHigh: false)
        let y = axis(target.minY, target.maxY, v.minY, v.maxY, size.height, preferHigh: true)
        return clamped(CGRect(origin: CGPoint(x: x, y: y), size: size), in: v)
    }

    static func same(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The next step of the 1/2 → 2/3 → 1/3 cycle: only when the same half is pressed again and the window is still
    /// where it was put (moved by hand, it starts over at 1/2).
    static func step(_ layout: WindowLayout, previous: (layout: WindowLayout, step: Int, frame: CGRect)?, current: CGRect) -> Int {
        guard layout.cycles, let p = previous, p.layout == layout, same(p.frame, current) else { return 0 }
        return (p.step + 1) % cycle.count
    }
}

/// Moves and resizes other apps' windows through Accessibility (the permission paste already uses).
@MainActor final class WindowMover {
    static let shared = WindowMover()

    /// What MONEY! last did to a window: where it was before (for Restore), and the layout it's in.
    private struct Record {
        let window: AXUIElement
        var restore: CGRect
        var layout: WindowLayout
        var step: Int
        var frame: CGRect
    }

    private var records: [Record] = []

    /// The focused window of `pid` (the frontmost app when nil).
    func perform(_ layout: WindowLayout, pid: pid_t? = nil) {
        guard Paster.trusted else { Paster.requestAccess(); return }
        guard let pid = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let w = Self.focusedWindow(pid: pid) else { return }
        withEnhancedUIOff(pid) { _ = apply(layout, to: w) }
    }

    /// Applies `layout` and returns the window's frame afterwards (AppKit coordinates), or nil if it couldn't be moved.
    @discardableResult func apply(_ layout: WindowLayout, to w: AXUIElement, displays given: [Display]? = nil) -> CGRect? {
        let displays = given ?? Display.current
        guard !Self.isFullScreen(w), let primary = displays.first(where: { $0.frame.origin == .zero }) ?? displays.first,
              let axNow = Self.frame(of: w) else { return nil }
        let H = primary.frame.height
        let now = WindowMath.flip(axNow, primaryHeight: H)
        let i = records.firstIndex { CFEqual($0.window, w) }
        let rec = i.map { records[$0] }
        // Still where MONEY! put it: the layout and Restore carry on. Moved since: start afresh from here.
        let untouched = rec.map { WindowMath.same($0.frame, now) } ?? false

        if layout == .restore {
            guard let rec, let i else { return nil }
            records.remove(at: i)
            return set(w, rec.restore, H: H)
        }
        guard let di = WindowMath.displayIndex(for: now, in: displays) else { return nil }
        let display = displays[di]
        var applied = layout, step = 0, target: CGRect
        if layout == .nextDisplay {
            guard let next = WindowMath.nextDisplay(after: display, in: displays) else { return nil }
            if untouched, let rec, rec.layout.isPlacement {
                applied = rec.layout
                step = rec.step
                target = WindowMath.target(applied, window: now, visible: next.visible, step: step)
            } else {
                target = WindowMath.moved(now, from: display.visible, to: next.visible)
            }
        } else {
            step = WindowMath.step(layout, previous: untouched ? rec.map { ($0.layout, $0.step, $0.frame) } : nil, current: now)
            target = WindowMath.target(layout, window: now, visible: display.visible, step: step)
        }
        let visible = displays[WindowMath.displayIndex(for: target, in: displays) ?? di].visible
        guard var after = set(w, target, H: H) else { return nil }
        if !WindowMath.same(after, target, tolerance: 1) {
            // A minimum size (or a terminal's character grid) won: keep it against the layout's edge.
            let fixed = WindowMath.settled(target, actual: after.size, visible: visible)
            if !WindowMath.same(fixed, after, tolerance: 0.5) { after = set(w, fixed, H: H, sizeToo: false) ?? after }
        }
        let restore = untouched ? rec!.restore : now
        let record = Record(window: w, restore: restore, layout: applied, step: step, frame: after)
        if let i { records[i] = record } else { records.append(record) }
        if records.count > 40 { records.removeFirst(records.count - 40) }
        return after
    }

    /// Size, position, then size again: a window moving to a smaller screen is clipped to it until it's there.
    private func set(_ w: AXUIElement, _ appKit: CGRect, H: CGFloat, sizeToo: Bool = true) -> CGRect? {
        let ax = WindowMath.flip(appKit, primaryHeight: H)
        var origin = ax.origin, size = ax.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return nil }
        if sizeToo { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sz) }
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
        if sizeToo { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sz) }
        return Self.frame(of: w).map { WindowMath.flip($0, primaryHeight: H) }
    }

    /// Apps with AXEnhancedUserInterface on (Chrome, Electron with a screen reader hint) animate each change; turn it off meanwhile.
    private func withEnhancedUIOff(_ pid: pid_t, _ body: () -> Void) {
        let app = AXUIElementCreateApplication(pid)
        let key = "AXEnhancedUserInterface" as CFString
        var v: CFTypeRef?
        let on = AXUIElementCopyAttributeValue(app, key, &v) == .success && (v as? Bool) == true
        if on { AXUIElementSetAttributeValue(app, key, kCFBooleanFalse) }
        body()
        if on { AXUIElementSetAttributeValue(app, key, kCFBooleanTrue) }
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attr as CFString, &v) == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() {
                return (v as! AXUIElement)
            }
        }
        return nil
    }

    /// The window's frame in AX coordinates.
    static func frame(of w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private static func isFullScreen(_ w: AXUIElement) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &v) == .success && (v as? Bool) == true
    }
}

/// The popup's window and app commands: "left half", "maximize", "next display", "quit other apps"…
@MainActor enum WindowCommands {
    /// The app that was frontmost when the popup opened (the popup never takes focus, but keep it in case).
    private static var target: NSRunningApplication?
    /// A quit waiting for a second ↩, for the text it was asked with.
    private static var armed: (command: String, query: String)?

    static func popupOpened() {
        let front = NSWorkspace.shared.frontmostApplication
        target = front?.processIdentifier == getpid() ? nil : front
        armed = nil
    }

    private static var targetApp: NSRunningApplication? {
        if let t = target, !t.isTerminated { return t }
        let front = NSWorkspace.shared.frontmostApplication
        return front?.processIdentifier == getpid() ? nil : front
    }

    private enum AppCommand: String, CaseIterable {
        case quitAll, quitOthers, hideOthers
        var title: String {
            switch self {
            case .quitAll: "Quit All Apps"
            case .quitOthers: "Quit Other Apps"
            case .hideOthers: "Hide Other Apps"
            }
        }
        var keywords: [String] {
            switch self {
            case .quitAll: ["quit all apps", "quit all", "quit everything", "close all apps", "すべて終了", "全部終了"]
            case .quitOthers: ["quit other apps", "quit others", "quit all other apps", "他のアプリを終了"]
            case .hideOthers: ["hide other apps", "hide others", "hide all other apps", "他を隠す", "他のアプリを隠す"]
            }
        }
    }

    static func answers(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        if armed?.query != l { armed = nil }
        var text = l
        for p in ["move window to ", "move window ", "window to ", "window ", "snap window "] where text.hasPrefix(p) { text.removeFirst(p.count); break }
        if text.hasSuffix(" window") { text.removeLast(" window".count) }
        guard !text.isEmpty else { return [] }

        // Exact words first, then commands that start with what's typed (4+ letters, so "le" stays an app search).
        func score(_ keywords: [String], minPrefix: Int) -> Int {
            keywords.contains(text) ? 2 : text.count >= minPrefix && keywords.contains { $0.hasPrefix(text) } ? 1 : 0
        }
        var rows: [(Answer, Int)] = []
        let app = targetApp
        for layout in WindowLayout.allCases {
            let sc = score(layout.keywords, minPrefix: 4)
            guard sc > 0 else { continue }
            let pid = app?.processIdentifier
            rows.append((Answer(title: layout.title, subtitle: app?.localizedName, symbol: layout.symbol, color: .systemBlue,
                                action: .run(keepOpen: false) {
                                    // After the popup is gone, so it's never the window that moves.
                                    DispatchQueue.main.async { WindowMover.shared.perform(layout, pid: pid) }
                                }), sc))
        }
        // "quit" alone stays Quit MONEY!; these need a second word started.
        for c in AppCommand.allCases {
            let sc = score(c.keywords, minPrefix: 6)
            if sc > 0 { rows.append((answer(c, query: l), sc)) }
        }
        return rows.enumerated().sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .prefix(5).map(\.element.0)
    }

    /// Regular apps that would be quit or hidden: never Finder (when quitting) or MONEY!.
    private static func apps(_ c: AppCommand) -> [NSRunningApplication] {
        let keep = c == .quitAll ? nil : targetApp?.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { a in
            a.activationPolicy == .regular && !a.isTerminated && a.processIdentifier != getpid() && a.processIdentifier != keep
                && (c == .hideOthers || a.bundleIdentifier != "com.apple.finder")
        }
    }

    private static func names(_ apps: [NSRunningApplication]) -> String {
        let n = apps.compactMap(\.localizedName)
        return n.count > 4 ? n.prefix(4).joined(separator: ", ") + " +\(n.count - 4)" : n.joined(separator: ", ")
    }

    /// The first ↩ on a quit that covers several apps (`--layout-test` calls it too; it never quits anything).
    static func arm(_ command: String, query: String) {
        armed = (command, query)
        LiveData.shared.onUpdate?()
    }

    private static func answer(_ c: AppCommand, query: String) -> Answer {
        let list = apps(c)
        if c == .hideOthers {
            return Answer(title: c.title, subtitle: list.isEmpty ? nil : names(list), symbol: "eye.slash.fill", color: .systemGray,
                          action: .run(keepOpen: false) { list.forEach { _ = $0.hide() } })
        }
        guard !list.isEmpty else { return Answer(title: c.title, subtitle: "No other apps open", symbol: "power", color: .systemRed) }
        let quit = Answer.Action.run(keepOpen: false) {
            // A normal quit: apps can still ask to save.
            list.forEach { _ = $0.terminate() }
            Tools.flash(list.count == 1 ? "Quitting \(list[0].localizedName ?? "app")" : "Quitting \(list.count) apps", "", "power")
        }
        if list.count == 1 { return Answer(title: c.title, subtitle: names(list), symbol: "power", color: .systemRed, action: quit) }
        // More than one app: the first ↩ turns the row into the question, the second quits.
        if armed?.command == c.rawValue {
            return Answer(title: "Quit \(list.count) apps?", subtitle: names(list), symbol: "power", color: .systemRed, action: quit, hint: "Quit ↩")
        }
        return Answer(title: c.title, subtitle: names(list), symbol: "power", color: .systemRed,
                      action: .run(keepOpen: true) { arm(c.rawValue, query: query) })
    }
}

/// Settings › Hotkeys: the on/off switch and a key for each layout.
struct WindowHotkeysSection: View {
    @Bindable var store: Store

    var body: some View {
        Section {
            Toggle("Window layout hotkeys", isOn: $store.settings.windowLayouts)
            if store.settings.windowLayouts {
                ForEach(WindowLayout.allCases) { l in
                    HStack {
                        Label(l.title, systemImage: l.symbol)
                        Spacer()
                        HotKeyField(hotKey: Binding(get: { l.hotKey(store.settings) }, set: { store.settings.windowHotKeys[l.rawValue] = $0 }))
                            .frame(width: 150, height: 26)
                    }
                }
            }
        }
    }
}
