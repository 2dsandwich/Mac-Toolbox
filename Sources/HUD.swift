import AppKit
import SwiftUI

// Small pieces shared by the notch and the popup.

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct Waveform: View {
    let levels: [Float]
    let active: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(active ? 0.9 : 0.4))
                    .frame(width: 3, height: 4 + CGFloat(levels[i]) * 20)
            }
        }
        .frame(height: 24)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { t in
            let phase = t.date.timeIntervalSinceReferenceDate * 3
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(.white).frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * max(0, sin(phase - Double(i) * 0.8)))
                }
            }
        }
    }
}

struct PulsingDot: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !active)) { t in
            let p = active ? 0.55 + 0.45 * abs(sin(t.date.timeIntervalSinceReferenceDate * 2)) : 0.5
            Circle().fill(Color.red.opacity(p)).frame(width: 9, height: 9)
        }
    }
}
