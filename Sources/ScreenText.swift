import AppKit
import NaturalLanguage
import ScreenCaptureKit
import Vision

/// What ⌘3 found: the captured picture and every word on it, in reading order.
struct ScreenTextResult {
    struct Token {
        let text: String
        let spaceBefore: Bool
        let line: Int
        /// Normalized, top-left origin.
        let box: CGRect
    }

    /// A QR code or barcode found in the capture.
    struct Code {
        let payload: String
        /// Normalized, top-left origin.
        let box: CGRect
        var url: URL? {
            guard let u = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = u.scheme?.lowercased(),
                  ["http", "https", "mailto", "tel", "sms", "facetime", "maps"].contains(scheme) else { return nil }
            return u
        }
    }

    let image: NSImage
    /// The captured area in points (its natural on-screen size).
    let size: CGSize
    let tokens: [Token]
    var codes: [Code] = []

    func text(_ range: ClosedRange<Int>) -> String {
        var out = ""
        var lastLine: Int?
        for i in range where tokens.indices.contains(i) {
            let t = tokens[i]
            if let l = lastLine, l != t.line {
                out += "\n"
            } else if lastLine != nil, t.spaceBefore {
                out += " "
            }
            out += t.text
            lastLine = t.line
        }
        return out
    }

    var fullText: String { tokens.isEmpty ? "" : text(0...(tokens.count - 1)) }
}

enum ScreenText {
    /// Captures `rect` (global Cocoa coordinates) without Flick's own windows.
    static func capture(_ rect: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // ScreenCaptureKit uses top-left origin global coordinates.
        let cgRect = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        guard let display = content.displays.first(where: { $0.frame.intersects(cgRect) }) ?? content.displays.first else {
            throw NSError(domain: "MONEY!", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to capture"])
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        let local = cgRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).intersection(CGRect(origin: .zero, size: display.frame.size))
        cfg.sourceRect = local
        let scale = NSScreen.screens.first { $0.frame.intersects(rect) }?.backingScaleFactor ?? 2
        cfg.width = Int(local.width * scale)
        cfg.height = Int(local.height * scale)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// On-device OCR (English + Japanese), split into words you can highlight.
    static func recognize(_ image: CGImage, pointSize: CGSize, codes findCodes: Bool = true) async -> ScreenTextResult {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.automaticallyDetectsLanguage = true
            let barcodes = VNDetectBarcodesRequest()
            try? VNImageRequestHandler(cgImage: image).perform(findCodes ? [request, barcodes] : [request])
            var seen = Set<String>()
            let codes: [ScreenTextResult.Code] = (barcodes.results ?? []).compactMap { b in
                guard let payload = b.payloadStringValue, !payload.isEmpty, seen.insert(payload).inserted else { return nil }
                let r = b.boundingBox
                return .init(payload: payload, box: CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height))
            }
            let observations = (request.results ?? []).sorted {
                abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
            }
            var tokens: [ScreenTextResult.Token] = []
            for (lineIndex, obs) in observations.enumerated() {
                guard let cand = obs.topCandidates(1).first else { continue }
                tokens += words(in: cand, line: lineIndex)
            }
            return ScreenTextResult(image: NSImage(cgImage: image, size: pointSize), size: pointSize, tokens: tokens, codes: codes)
        }.value
    }

    /// Splits a recognized line into words (NLTokenizer handles Japanese, which has no spaces);
    /// punctuation sticks to the word before it.
    private static func words(in cand: VNRecognizedText, line: Int) -> [ScreenTextResult.Token] {
        let s = cand.string
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = s
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { r, _ in
            ranges.append(r)
            return true
        }
        if ranges.isEmpty { ranges = [s.startIndex..<s.endIndex] }
        var out: [ScreenTextResult.Token] = []
        for (i, r) in ranges.enumerated() {
            let start = i == 0 ? s.startIndex : r.lowerBound
            let end = i + 1 < ranges.count ? ranges[i + 1].lowerBound : s.endIndex
            let chunk = String(s[start..<end])
            let text = chunk.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let gapBefore = i > 0 && s[ranges[i - 1].upperBound..<r.lowerBound].contains(where: \.isWhitespace)
            let spaceBefore = gapBefore || (i > 0 && String(s[ranges[i - 1].lowerBound..<r.lowerBound]).last?.isWhitespace == true)
            let textRange = (s[start..<end].firstIndex { !$0.isWhitespace } ?? start)..<end
            guard let box = (try? cand.boundingBox(for: textRange))?.boundingBox else { continue }
            out.append(.init(text: text, spaceBefore: spaceBefore, line: line,
                             box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)))
        }
        return out
    }
}

/// Full-screen "drag over the text" picker on every display. Calls back with the rectangle, or nil on Esc.
@MainActor final class RegionPicker {
    private var windows: [NSWindow] = []
    private var done: ((CGRect?) -> Void)?
    private var monitor: Any?
    /// Esc taken system-wide while picking, so it never reaches the app underneath.
    private var escToken: UInt32?

    func pick(_ completion: @escaping (CGRect?) -> Void) {
        done = completion
        for screen in NSScreen.screens {
            let w = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onDone = { [weak self] r in self?.finish(r.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }) }
            w.contentView = view
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSApp.activate()
        windows.first { $0.screen == NSScreen.main }?.makeKey()
        NSCursor.crosshair.push()
        NSCursor.crosshair.set()
        escToken = HotKeyCenter.shared.registerTransient(.escape) { [weak self] in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.finish(nil) }; return nil }
            return e
        }
    }

    private func finish(_ rect: CGRect?) {
        guard let done else { return }
        self.done = nil
        NSCursor.pop()
        HotKeyCenter.shared.remove(escToken)
        escToken = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        // Let the dim layer leave the screen before it's captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { done(rect.flatMap { $0.width >= 6 && $0.height >= 6 ? $0 : nil }) }
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class PickerView: NSView {
    var onDone: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // The crosshair even while MONEY! isn't the active app (other apps would otherwise set their own pointer).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func mouseDown(with e: NSEvent) {
        NSCursor.crosshair.set()
        start = convert(e.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        NSCursor.crosshair.set()
        current = convert(e.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        current = convert(e.locationInWindow, from: nil)
        onDone?(selection)
    }

    override func rightMouseDown(with event: NSEvent) { onDone?(nil) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        if let r = selection {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 1.5
            path.stroke()
            let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attrs)
            let pill = NSRect(x: r.maxX - size.width - 14, y: r.minY - size.height - 12, width: size.width + 12, height: size.height + 6)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            label.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 3), withAttributes: attrs)
        }
    }
}
