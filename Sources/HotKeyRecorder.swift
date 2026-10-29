import AppKit
import SwiftUI

/// Click, then press a shortcut. Shows held modifiers live; Esc cancels, Delete clears.
/// AppKit view so it catches every key, including ⌘ combinations that would otherwise go to menus.
final class HotKeyRecorderView: NSView {
    var hotKey = HotKey.none { didSet { needsDisplay = true } }
    var onChange: ((HotKey) -> Void)?
    private var recording = false
    private var held: NSEvent.ModifierFlags = []
    private var warning: String?
    private var hovering = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    private var clearRect: NSRect { NSRect(x: bounds.maxX - 24, y: 0, width: 24, height: bounds.height) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !recording, !hotKey.isEmpty, clearRect.contains(p) {
            commit(.none)
            return
        }
        if recording {
            finish()
        } else {
            window?.makeFirstResponder(self)
            recording = true
            warning = nil
            HotKeyCenter.shared.pause()
            needsDisplay = true
        }
    }

    override func resignFirstResponder() -> Bool {
        finish()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self, event.type == .keyDown else { return false }
        capture(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { return }
        held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        warning = nil
        needsDisplay = true
    }

    private func capture(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.isEmpty, e.keyCode == 53 { // Esc
            window?.makeFirstResponder(nil)
            return
        }
        if mods.isEmpty, e.keyCode == 51 || e.keyCode == 117 { // Delete
            commit(.none)
            window?.makeFirstResponder(nil)
            return
        }
        if let k = HotKey(event: e) {
            commit(k)
            window?.makeFirstResponder(nil)
        } else {
            warning = "Add ⌘, ⌥ or ⌃"
            NSSound.beep()
            needsDisplay = true
        }
    }

    private func commit(_ k: HotKey) {
        hotKey = k
        onChange?(k)
    }

    private func finish() {
        guard recording else { return }
        recording = false
        held = []
        warning = nil
        HotKeyCenter.shared.resume()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        if recording {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(hovering ? 0.12 : 0.07).setFill()
            path.fill()
        }

        let text: String
        let color: NSColor
        if recording {
            text = warning ?? (held.isEmpty ? "Press keys…" : HotKey.modifierSymbols(held) + "…")
            color = warning == nil ? .controlAccentColor : .systemOrange
        } else if hotKey.isEmpty {
            text = hovering ? "Click to record" : "None"
            color = .tertiaryLabelColor
        } else {
            text = hotKey.display
            color = .labelColor
        }
        let font = hotKey.isEmpty || recording ? NSFont.systemFont(ofSize: 12) : NSFont.systemFont(ofSize: 13, weight: .medium)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = attr.size()
        let showClear = !recording && !hotKey.isEmpty && hovering
        let room = showClear ? bounds.width - 24 : bounds.width
        attr.draw(at: NSPoint(x: (room - size.width) / 2, y: (bounds.height - size.height) / 2))

        if showClear, let x = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear") {
            let img = x.withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor])))!
            let s = img.size
            img.draw(in: NSRect(x: clearRect.midX - s.width / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
    }
}

struct HotKeyField: NSViewRepresentable {
    @Binding var hotKey: HotKey

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let v = HotKeyRecorderView()
        v.hotKey = hotKey
        v.onChange = { hotKey = $0 }
        v.setContentHuggingPriority(.required, for: .horizontal)
        return v
    }

    func updateNSView(_ v: HotKeyRecorderView, context: Context) {
        if v.hotKey != hotKey { v.hotKey = hotKey }
        v.onChange = { hotKey = $0 }
    }
}

extension HotKey {
    static func modifierSymbols(_ f: NSEvent.ModifierFlags) -> String {
        (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "")
    }
}
