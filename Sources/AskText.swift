import AppKit
import SwiftUI

/// A finished answer's text in a real text view, so you can both select across every line and click its links
/// (SwiftUI's selectable text takes the click for selecting, and links in it never open). While the answer is
/// still streaming it's drawn by `NotesView`, which fades the words in; this takes over once it's all there.
struct SelectableNotes: NSViewRepresentable {
    let markdown: String

    /// Takes the first click too: the launcher is a panel that doesn't activate the app, and a link should open at once.
    final class TextView: NSTextView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> NSTextView {
        let v = TextView()
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.textContainerInset = .zero
        v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = true
        v.isVerticallyResizable = false
        v.isHorizontallyResizable = false
        v.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        v.delegate = context.coordinator
        v.textStorage?.setAttributedString(Self.appKit(NotesView.attributed(markdown)))
        context.coordinator.shown = markdown
        return v
    }

    func updateNSView(_ v: NSTextView, context: Context) {
        guard context.coordinator.shown != markdown else { return }
        context.coordinator.shown = markdown
        v.textStorage?.setAttributedString(Self.appKit(NotesView.attributed(markdown)))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let container = v.textContainer, let layout = v.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var shown = ""

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            MainActor.assumeIsolated { Assistant.open(url) }
            return true
        }
    }

    /// The same text `NotesView` draws (same characters, sizes and colours), as AppKit attributes.
    static func appKit(_ a: AttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 5
        for run in a.runs {
            var font = NSFont.systemFont(ofSize: 13.5)
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { font = .monospacedSystemFont(ofSize: 12.5, weight: .regular) }
                if intent.contains(.stronglyEmphasized) { font = .systemFont(ofSize: font.pointSize, weight: .bold) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            }
            // A run with its own font is a heading (the only place the notes set one besides code).
            if run.swiftUI.font != nil, run.inlinePresentationIntent?.contains(.code) != true {
                font = .systemFont(ofSize: 15, weight: .semibold)
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para,
                                                         .foregroundColor: run.swiftUI.foregroundColor == nil ? NSColor.labelColor : NSColor.secondaryLabelColor]
            if let url = run.link { attrs[.link] = url }
            out.append(NSAttributedString(string: String(a[run.range].characters), attributes: attrs))
        }
        return out
    }
}
