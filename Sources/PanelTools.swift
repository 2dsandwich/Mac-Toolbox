import AppKit
import SwiftUI

/// Even spacing for the full views: one inset from the card's edges and between blocks, and corners
/// that follow the card's (the card's radius minus the inset), so every curve is concentric.
enum PanelLayout {
    /// From the card's edges (same as the mode chip in the bar).
    static let inset: CGFloat = Metrics.listInset
    /// Between blocks and keys.
    static let gap: CGFloat = 8
    static func inner(_ radius: CGFloat) -> CGFloat { max(6, radius - inset) }
}

/// A rounded block inside a full view.
struct Block<Content: View>: View {
    let radius: CGFloat
    var fill: Double = 0.06
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: PanelLayout.inner(radius), style: .continuous).fill(Color.primary.opacity(fill)))
    }
}

// MARK: Calculator (keypad)

struct CalculatorView: View {
    let model: LauncherModel
    let radius: CGFloat

    static let keyHeight: CGFloat = 50
    static let displayHeight: CGFloat = 84
    static var height: CGFloat { PanelLayout.inset * 2 + PanelLayout.gap * 5 + displayHeight + keyHeight * 5 }

    private static let rows: [[String]] = [
        ["AC", "⌫", "( )", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "−"],
        ["1", "2", "3", "+"],
        ["%", "0", ".", "="],
    ]

    var body: some View {
        let gap = PanelLayout.gap
        VStack(spacing: gap) {
            Block(radius: radius) { display }
                .frame(height: Self.displayHeight)
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(row, id: \.self) { key in
                        Button { model.calcPress(key) } label: { Text(key).font(.system(size: key.count > 2 ? 17 : 21, weight: .medium, design: .rounded)) }
                            .buttonStyle(KeyStyle(kind: kind(key), radius: PanelLayout.inner(radius)))
                            .frame(height: Self.keyHeight)
                    }
                }
            }
        }
        .padding(PanelLayout.inset)
    }

    private var display: some View {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        let value = q.isEmpty ? 0 : Tools.evaluate(q) ?? Tools.number(Tools.normalize(q))
        return VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 10) {
                ForEach(model.calcHistory.prefix(2).reversed(), id: \.self) { h in
                    Button { model.setQuery(String(h.split(separator: "=").last ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")) } label: {
                        Text(h).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Use this result")
                }
                Spacer(minLength: 0)
            }
            .frame(height: 16)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                Text(q.isEmpty || value == nil ? " " : "=").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value.map { Tools.fmt($0, digits: Store.shared.settings.calcDecimals) } ?? "…")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .textSelection(.enabled)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.2), value: value)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func kind(_ key: String) -> KeyStyle.Kind {
        if key == "=" { return .equals }
        if ["÷", "×", "−", "+"].contains(key) { return .op }
        if ["AC", "⌫", "( )", "%"].contains(key) { return .function }
        return .digit
    }
}

private struct KeyStyle: ButtonStyle {
    enum Kind { case digit, function, op, equals }
    let kind: Kind
    let radius: CGFloat
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        let orange = Color(nsColor: .systemOrange)
        let fill: Color = switch kind {
        case .digit: .primary.opacity(0.1)
        case .function: .primary.opacity(0.2)
        case .op: orange.opacity(0.28)
        case .equals: orange
        }
        configuration.label
            .foregroundStyle(kind == .equals ? Color.white : kind == .op ? orange : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.18 : hover ? 0.06 : 0)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hover = $0 }
    }
}

// MARK: Volume mixer

struct MixerView: View {
    let mixer: AudioMixer
    let radius: CGFloat
    let query: String

    static let rowHeight: CGFloat = 54
    static func height(_ apps: Int) -> CGFloat {
        let rows = CGFloat(min(max(apps, 1), 5) + 1)
        return PanelLayout.inset * 2 + rows * rowHeight + (rows - 1) * PanelLayout.gap
    }

    var body: some View {
        let gap = PanelLayout.gap
        let shown = mixer.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        VStack(spacing: gap) {
            Block(radius: radius, fill: 0.09) {
                // Sized like an app icon's artwork (which has its own margin inside the 34 pt frame).
                MixerRow(icon: AnyView(Image(systemName: mixer.masterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.blue.gradient))
                                        .frame(width: 34, height: 34)),
                         name: "Output", detail: mixer.problem ?? "",
                         value: Binding(get: { Double(mixer.master) }, set: { mixer.setMaster(Float($0)) }),
                         muted: mixer.masterMuted, toggleMute: { mixer.setMasterMuted(!mixer.masterMuted) })
            }
            .frame(height: Self.rowHeight)
            ScrollView(.vertical) {
                VStack(spacing: gap) {
                    if shown.isEmpty {
                        Block(radius: radius) {
                            Image(systemName: query.isEmpty ? "speaker.slash" : "magnifyingglass").font(.system(size: 18)).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(height: Self.rowHeight)
                    }
                    ForEach(shown) { app in
                        Block(radius: radius) {
                            MixerRow(icon: AnyView(Image(nsImage: app.icon).resizable().frame(width: 34, height: 34)),
                                     name: app.name, detail: app.playing ? "Playing" : "",
                                     value: Binding(get: { Double(mixer.volume(app.id)) }, set: { mixer.setVolume(Float($0), for: app.id) }),
                                     muted: mixer.muted.contains(app.id), toggleMute: { mixer.toggleMute(app.id) })
                        }
                        .frame(height: Self.rowHeight)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(PanelLayout.inset)
        .onAppear { mixer.startWatching() }
        .onDisappear { mixer.stopWatching() }
    }
}

private struct MixerRow: View {
    let icon: AnyView
    let name: String
    let detail: String
    let value: Binding<Double>
    let muted: Bool
    let toggleMute: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(width: 150, alignment: .leading)
            Slider(value: value, in: 0...1)
                .controlSize(.small)
                .opacity(muted ? 0.4 : 1)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            PillButton(title: nil, symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", tint: muted ? .red : nil, help: muted ? "Unmute" : "Mute", action: toggleMute)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
    }
}

// MARK: Now playing

/// Song, artist and controls. Works as a result card and in the notch.
struct MediaCard: View {
    let media: NowPlaying
    var artSize: CGFloat = 56
    var corner: CGFloat = 10

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let art = media.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else if let icon = media.appIcon {
                    Image(nsImage: icon).resizable().padding(8).background(Color.primary.opacity(0.08))
                } else {
                    Image(systemName: "music.note").font(.system(size: artSize * 0.4)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.primary.opacity(0.08))
                }
            }
            .frame(width: artSize, height: artSize)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(media.available ? media.songTitle : "Nothing playing in Music or Spotify")
                    .font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                Text(media.available ? [media.artistLine, media.album].filter { !$0.isEmpty }.joined(separator: " · ") : "")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                if media.available, media.duration > 0 {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let pos = media.livePosition
                        HStack(spacing: 8) {
                            Text(Pomodoro.clock(pos)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.12))
                                    Capsule().fill(Color.primary.opacity(0.6)).frame(width: geo.size.width * min(1, pos / max(media.duration, 1)))
                                }
                            }
                            .frame(height: 4)
                            Text(Pomodoro.clock(media.duration)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        .padding(.top, 3)
                    }
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                PillButton(title: nil, symbol: "backward.fill", help: "Previous") { media.previous() }
                PillButton(title: nil, symbol: media.playing ? "pause.fill" : "play.fill", tint: .primary, help: "Play / pause") { media.playPause() }
                PillButton(title: nil, symbol: "forward.fill", help: "Next") { media.next() }
            }
        }
    }
}
