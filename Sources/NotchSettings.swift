import AppKit
import SwiftUI

// Settings › Notch: a picture of the notch, closed and open, that follows the switches under it. It's drawn from the
// notch's own parts (its shape, buttons, rings, art) with made-up content: IslandView itself reads what's really
// playing, the calendar, the agents and the camera, and the real notch shares those in this process.

/// What the notch can show, as Settings › Notch draws it and switches it.
enum NotchThing: String, CaseIterable, Identifiable {
    case media, lyrics, timer, stopwatch, focus, meeting, dictation, event, classes, agents, shelf, battery, downloads
    var id: String { rawValue }
    var title: String {
        switch self {
        case .media: "What’s playing"
        case .lyrics: "Lyrics"
        case .timer: "Timers"
        case .stopwatch: "Stopwatches"
        case .focus: "Focus"
        case .meeting: "Meetings"
        case .dictation: "Dictation"
        case .event: "Next event"
        case .classes: "Classes"
        case .agents: "Coding agents"
        case .shelf: "Shelf"
        case .battery: "Battery"
        case .downloads: "Downloads"
        }
    }
    var setting: WritableKeyPath<Settings, Bool> {
        switch self {
        case .media: \.mediaInNotch
        case .lyrics: \.notchLyrics
        case .timer: \.notchTimers
        case .stopwatch: \.notchStopwatch
        case .focus: \.notchFocus
        case .meeting: \.notchMeeting
        case .dictation: \.notchDictation
        case .event: \.notchEvents
        case .classes: \.notchClasses
        case .agents: \.notchAgents
        case .shelf: \.notchShelf
        case .battery: \.notchBattery
        case .downloads: \.notchDownloads
        }
    }
    /// Its made-up time (or word) in the closed notch and on its tile.
    var time: String {
        switch self {
        case .timer: "4:12"
        case .stopwatch: "1:07"
        case .focus: "18:40"
        case .meeting: "12:05"
        case .event: "12 min"
        case .classes: "8m"
        case .agents: "Asks"
        case .shelf: "3"
        case .battery: "54%"
        case .downloads: "Report.pdf"
        default: ""
        }
    }
    var caption: String {
        switch self {
        case .timer: "Tea"
        case .focus: "Focus"
        case .meeting: "Recording"
        case .event: "Design review"
        case .classes: "Linear Algebra · B-204"
        default: ""
        }
    }
    /// The one control on its tile.
    var button: (symbol: String, tint: Color?) {
        switch self {
        case .meeting: ("stop.fill", .red)
        case .event: ("video.fill", .green)
        case .classes: ("xmark", nil)
        default: ("pause.fill", nil)
        }
    }
    /// Shown as tiles in the open notch (and first when nothing plays), in the notch's own order.
    static let tiled: [NotchThing] = [.timer, .meeting, .focus, .stopwatch, .classes, .event]
    /// In the closed notch, in the notch's own order (a coding agent last here: it only shows while one waits on you).
    static let closed: [NotchThing] = [.media, .timer, .meeting, .focus, .stopwatch, .classes, .event, .agents, .shelf]
    /// Brief notes that have the closed notch to themselves for a moment (shown alone while their tile is pointed at).
    static let notes: [NotchThing] = [.battery, .downloads]
}

/// The preview's song and its cover: Blinding Lights' real cover from Apple's public catalogue (fetched once, then kept
/// in Caches), the made-up one until it's there or when offline.
@MainActor private enum Demo {
    static var art: NSImage { Cover.shared.image ?? placeholder }
    private static let placeholder = AppDelegate.demoArt()
    /// The desktop picture of the screen with the notch (else the main one), shrunk once: a full-size HEIC is large.
    static let wallpaper: NSImage? = {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen), let full = NSImage(contentsOf: url) else { return nil }
        let w: CGFloat = 1200, h = w * full.size.height / max(1, full.size.width)
        let small = NSImage(size: NSSize(width: w, height: h))
        small.lockFocus()
        full.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        small.unlockFocus()
        return small
    }()
    static let levels: [Float] = (0..<20).map { Float(0.2 + 0.6 * abs(sin(Double($0) * 0.7))) }
    static let seed = CGSize(width: 186, height: 32)
    static let lines = ["Line one of the song", "Line two, a little longer than the first", "Line three of the song", "Line four comes next"]
}

@MainActor @Observable private final class Cover {
    static let shared = Cover()
    var image: NSImage?
    private static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "MONEY").appendingPathComponent("preview-cover.jpg")

    private init() {
        if let i = NSImage(contentsOf: Self.file) { image = i; return }
        Task {
            guard let search = URL(string: "https://itunes.apple.com/lookup?id=1499378607"), // Blinding Lights, After Hours (search results shift)
                  let (data, _) = try? await URLSession.shared.data(from: search),
                  let hit = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]])?.first,
                  let link = (hit["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "300x300bb"), let url = URL(string: link),
                  let (bytes, _) = try? await URLSession.shared.data(from: url), let i = NSImage(data: bytes) else { return }
            try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: Self.file)
            image = i
        }
    }
}

/// A thing's icon as the closed notch draws it.
struct NotchIcon: View {
    let thing: NotchThing

    var body: some View {
        switch thing {
        case .media: AlbumArt(image: Demo.art, missing: false).frame(width: IslandModel.artSize, height: IslandModel.artSize)
        case .lyrics: symbol("quote.bubble.fill", .white)
        case .timer: ProgressRing(progress: 0.62, color: .orange, size: 16, lineWidth: 3)
        case .stopwatch: symbol("stopwatch.fill", .orange)
        case .focus: ProgressRing(progress: 0.4, color: PomodoroView.focusColor, size: 16, lineWidth: 3)
        case .meeting: Circle().fill(Color.red).frame(width: 9, height: 9)
        case .dictation: MiniWave(levels: Demo.levels)
        case .event: symbol("calendar", .red)
        case .classes: symbol("graduationcap.fill", .teal)
        case .agents: AgentStateIcon(state: .needsYou, size: 15)
        case .shelf: symbol("tray.full.fill", .white.opacity(0.85))
        case .battery: symbol("bolt.fill", .green)
        case .downloads: symbol("arrow.down.circle.fill", .blue)
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
    }
}

/// A glance left of the notch with made-up numbers (the real one samples the Mac, and Wi-Fi and the weather ask for location).
struct DemoGlance: View {
    let item: BandItem

    var body: some View {
        Group {
            switch item {
            case .battery: BatteryGlance.icon(Battery.State(pct: 82)).fixedSize()
            case .time: Text("9:41").font(BandGlance.font)
            case .date: label("calendar", "Wed 11")
            case .weather: label("cloud.sun.fill", "18°")
            case .event:
                HStack(spacing: 6) {
                    Circle().fill(Color.purple).frame(width: 7, height: 7)
                    Text("12 min").font(BandGlance.font)
                }
            case .cpu: label("cpu", "12%")
            case .memory: label("memorychip", "48%")
            case .network:
                VStack(alignment: .leading, spacing: 0) {
                    Text("↑ " + BandGlance.rate(24 * 1024))
                    Text("↓ " + BandGlance.rate(1.2 * 1024 * 1024))
                }
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
            case .wifi: label("wifi", "Home")
            case .privacy:
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").foregroundStyle(Color.orange)
                    Image(systemName: "video.fill").foregroundStyle(Color.white.opacity(0.3))
                }
                .font(.system(size: 12, weight: .medium))
            case .disk: label("internaldrive", "212 GB")
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .fixedSize()
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            Text(text).font(BandGlance.font)
        }
    }
}

// MARK: The pane

struct NotchPane: View {
    @Bindable var store: Store
    /// The tile under the pointer comes to the front of the picture.
    @State private var hovered: NotchThing?

    var body: some View {
        let s = store.settings
        VStack(spacing: 0) {
            // The picture stays put while the settings under it scroll.
            NotchPreview(store: store, spotlight: hovered)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            Form {
                Section {
                    Toggle("Use the notch", isOn: $store.settings.notchEnabled)
                }
                Section("Show") {
                    ThingTiles(store: store, hovered: $hovered)
                }
                .disabled(!s.notchEnabled)
                Section("Left of the notch when open") {
                    GlancePicker(store: store)
                }
                .disabled(!s.notchEnabled)
                Section {
                    Toggle("Line being sung under the closed notch", isOn: $store.settings.notchLyricLine)
                    Toggle("Words fill in as they’re sung", isOn: $store.settings.notchLyricsFill)
                    Toggle("Open the player on its lyrics", isOn: $store.settings.notchLyricsOpen)
                    seconds("Timing", $store.settings.lyricsOffset, -1...1, step: 0.05, format: "%+.2f s")
                } header: {
                    Text("Lyrics")
                } footer: {
                    Text("If the words run ahead of the song, move the timing later (+); if they lag, earlier (−).").font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!s.notchEnabled || !s.mediaInNotch || !s.notchLyrics)
                Section("Next event") {
                    Picker("Show before it starts", selection: $store.settings.notchEventLead) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { m in Text(m == 60 ? "1 hour" : "\(m) minutes").tag(m) }
                    }
                    LabeledContent("Calendars") {
                        Button("Choose in Accounts") { NotificationCenter.default.post(name: .showSettingsPane, object: Pane.google) }
                    }
                }
                .disabled(!s.notchEnabled || !s.notchEvents)
                Section("Classes") {
                    Picker("Alert before class", selection: $store.settings.notchClassLead) {
                        ForEach([5, 10, 15, 20, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    Toggle("Time left while a class is on", isOn: $store.settings.notchClassLive)
                    LabeledContent("Timetable") {
                        Button("Open in Settings") { NotificationCenter.default.post(name: .showSettingsPane, object: Pane.timetable) }
                    }
                }
                .disabled(!s.notchEnabled || !s.notchClasses)
                AgentsSettings(store: store)
                Section("Opening") {
                    Toggle("Open when the pointer rests on it", isOn: $store.settings.notchHoverExpand)
                    seconds("Wait before opening", $store.settings.notchHoverDelay, 0...1, step: 0.05, format: "%.2f s")
                        .disabled(!s.notchHoverExpand)
                    seconds("Close after leaving", $store.settings.notchCollapseDelay, 0.2...3, step: 0.1, format: "%.1f s")
                    seconds("Extra width when open", $store.settings.notchExtraWidth, 0...160, step: 10, format: "%.0f pt")
                    seconds("Notes stay", $store.settings.notchToastScale, 0.5...3, step: 0.25, format: "%g×")
                }
                .disabled(!s.notchEnabled)
                Section {
                    Toggle("Hide while an app is full screen", isOn: $store.settings.notchHideInFullScreen)
                    Toggle("Show in screenshots, recordings and screen sharing", isOn: $store.settings.notchInCaptures)
                } footer: {
                    Text("In full screen, alarms, dictation and coding agents waiting on you still show.").font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!s.notchEnabled)
                Section {
                    HStack {
                        Spacer()
                        Button("Reset notch settings") { resetNotch() }
                    }
                }
            }
        }
    }

    private func seconds(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, format: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 180)
                Text(String(format: format, value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
        }
    }

    /// Everything on this pane back to how it started, the order included.
    private func resetNotch() {
        let d = Settings()
        withAnimation {
            for t in NotchThing.allCases { store.settings[keyPath: t.setting] = d[keyPath: t.setting] }
            store.settings.notchEnabled = d.notchEnabled
            store.settings.notchEventLead = d.notchEventLead
            store.settings.notchClassLead = d.notchClassLead
            store.settings.notchClassLive = d.notchClassLive
            store.settings.notchLyricsOpen = d.notchLyricsOpen
            store.settings.notchLyricLine = d.notchLyricLine
            store.settings.notchLyricsFill = d.notchLyricsFill
            store.settings.notchInCaptures = d.notchInCaptures
            store.settings.notchBand = d.notchBand
            store.settings.notchHideInFullScreen = d.notchHideInFullScreen
            store.settings.notchHoverExpand = d.notchHoverExpand
            store.settings.notchHoverDelay = d.notchHoverDelay
            store.settings.notchCollapseDelay = d.notchCollapseDelay
            store.settings.notchExtraWidth = d.notchExtraWidth
            store.settings.notchToastScale = d.notchToastScale
            store.settings.lyricsOffset = d.lyricsOffset
        }
    }
}

/// One tile per thing the notch shows: its notch icon and name, lit while it's on. Click to switch.
private struct ThingTiles: View {
    @Bindable var store: Store
    @Binding var hovered: NotchThing?
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
            ForEach(NotchThing.allCases) { t in
                let on = store.settings[keyPath: t.setting]
                // Lyrics come with the song.
                let usable = enabled && (t != .lyrics || store.settings.mediaInNotch)
                Button {
                    withAnimation(.snappy(duration: 0.2)) { store.settings[keyPath: t.setting].toggle() }
                } label: {
                    VStack(spacing: 6) {
                        NotchIcon(thing: t)
                            .frame(width: 44, height: 28)
                            .background(Capsule().fill(Color.black))
                            .opacity(on ? 1 : 0.35)
                        Text(t.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                            .foregroundStyle(on ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .disabled(!usable)
                .opacity(usable ? 1 : 0.45)
                .onHover { hovered = $0 && on ? t : (hovered == t ? nil : hovered) }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Every glance as it looks in the notch, with its name: the chosen ones lit and numbered.
private struct GlancePicker: View {
    @Bindable var store: Store

    var body: some View {
        let band = Array(store.settings.notchBand.prefix(2))
        // An even grid: every chip the same size, the glance over its name.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(BandItem.allCases) { item in
                let i = band.firstIndex(of: item)
                VStack(spacing: 6) {
                    DemoGlance(item: item)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black))
                    Text(Self.label(item)).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                }
                .overlay(alignment: .topTrailing) {
                    if let i {
                        Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 16, height: 16).background(Circle().fill(Color.accentColor)).offset(x: 4, y: -4)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(i != nil ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(i != nil ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { toggle(item, band) } }
                .draggable(item.rawValue) { DemoGlance(item: item).padding(8).background(Capsule().fill(Color.black)) }
                .help(item.title)
            }
        }
        .padding(.vertical, 4)
    }

    /// The glance's name short enough for one line in its chip (the full one is its tooltip).
    static func label(_ item: BandItem) -> String {
        switch item {
        case .network: "Network"
        case .privacy: "Mic and camera"
        case .disk: "Disk space"
        default: item.title
        }
    }

    /// On if it was off (a third replaces the second), off if it was on.
    private func toggle(_ item: BandItem, _ band: [BandItem]) {
        store.settings.notchBand = band.contains(item) ? band.filter { $0 != item } : Array(band.prefix(1)) + [item]
    }
}

// MARK: The picture

/// The notch closed and open, as the settings below would have it, over a stand-in desktop. Glances dropped on it go
/// first (left half) or second (right half).
private struct NotchPreview: View {
    @Bindable var store: Store
    var spotlight: NotchThing?
    @State private var targeted = false
    @State private var width: CGFloat = 560

    /// The open notch shrinks to fit the pane's width, and never past this height.
    static let openMax: CGFloat = 170
    /// Desktop left and right of the open notch.
    static let side: CGFloat = 36

    var body: some View {
        let s = store.settings
        let on = s.notchEnabled
        let things = NotchThing.allCases.filter { on && s[keyPath: $0.setting] }
        let open = OpenNotch(things: things, spotlight: spotlight, settings: s)
        let size = open.size
        // One scale for both, as on the screen, and desktop on either side: the notch hangs well clear of the screen's
        // rounded corners (the open one filling the strip ran its top corners into them).
        let k = min(1, (width - 2 * Self.side) / size.width, Self.openMax / size.height)
        VStack(spacing: 8) {
            screen(k) {
                ClosedNotch(things: things, spotlight: spotlight, settings: s)
                    .scaleEffect(k, anchor: .top)
            }
            .frame(height: 64 * k)
            screen(k) {
                open.frame(width: size.width, height: size.height)
                    .scaleEffect(k, anchor: .top)
                    .frame(width: size.width * k, height: size.height * k, alignment: .top)
            }
            .frame(height: size.height * k + 16)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: targeted ? 2 : 0))
            .dropDestination(for: String.self) { items, at in
                guard let item = items.first.flatMap(BandItem.init(rawValue:)) else { return false }
                var band = s.notchBand.prefix(2).filter { $0 != item }
                band.insert(item, at: min(at.x < width / 2 ? 0 : 1, band.count))
                withAnimation(.snappy(duration: 0.2)) { store.settings.notchBand = Array(band.prefix(2)) }
                return true
            } isTargeted: { targeted = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(.snappy(duration: 0.25), value: s)
        .animation(.snappy(duration: 0.25), value: spotlight)
    }

    /// A strip of desktop with the menu bar along its top (as tall as the notch, at the picture's scale).
    private func screen(_ k: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color.black.opacity(0.25)).frame(height: Demo.seed.height * k)
            content().allowsHitTesting(false)
        }
        .padding(.bottom, 18) // some desktop under the notch, as on the screen
        .frame(maxWidth: .infinity)
        // Behind, so the picture takes the strip's size rather than setting it: the top of your own desktop, as the notch
        // sits over it.
        .background {
            if let w = Demo.wallpaper {
                GeometryReader { g in
                    Image(nsImage: w).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height, alignment: .top).clipped()
                }
            } else {
                LinearGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.45), Color(red: 0.45, green: 0.3, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The closed notch: up to three things across it, the first one's time after its icon, both sides the same width.
private struct ClosedNotch: View {
    let things: [NotchThing]
    let spotlight: NotchThing?
    let settings: Settings

    private static let pad = IslandModel.compactPad, gap = IslandModel.compactGap

    /// What shows: dictation alone while it's on the go (hovering its tile), else the first three in the notch's order.
    private var shown: [NotchThing] {
        if let spotlight, spotlight == .dictation || NotchThing.notes.contains(spotlight), things.contains(spotlight) { return [spotlight] }
        var list = NotchThing.closed.filter(things.contains)
        if let spotlight, let i = list.firstIndex(of: spotlight) { list.insert(list.remove(at: i), at: 0) }
        return Array(list.prefix(IslandModel.compactMax))
    }

    var body: some View {
        let shown = self.shown
        let seed = Demo.seed
        if shown.isEmpty {
            IslandShape(ear: 6, top: 0, bottom: 10).fill(Color.black).frame(width: seed.width, height: seed.height)
        } else {
            let text = shown.first(where: NotchThing.tiled.contains) ?? shown[0]
            let apart = shown.count == 1
            let left = Array(shown.prefix(1)), right = Array(shown.dropFirst())
            let side = apart ? max(Self.pad + iconWidth(text) + Self.gap, Self.gap + textWidth(text) + Self.pad)
                : max(sideWidth(left, text), sideWidth(right, text))
            VStack(spacing: 5) {
                HStack(spacing: 0) {
                    HStack(spacing: Self.gap) { ForEach(left) { item($0, text: $0 == text && !apart) } }
                        .padding(.leading, Self.pad)
                        .frame(width: side, alignment: .leading)
                    Color.clear.frame(width: seed.width)
                    HStack(spacing: Self.gap) {
                        if apart { trailing(text) }
                        ForEach(right) { item($0, text: $0 == text) }
                    }
                    .padding(.trailing, Self.pad)
                    .frame(width: side, alignment: .trailing)
                }
                .frame(height: seed.height)
                .background(IslandShape(ear: 12, top: 0, bottom: 12).fill(Color.black))
                if shown.contains(.media), things.contains(.lyrics), settings.notchLyricLine {
                    LyricLine(text: Demo.lines[1], fill: settings.notchLyricsFill, size: 12.5)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black))
                }
            }
        }
    }

    private func item(_ t: NotchThing, text: Bool) -> some View {
        HStack(spacing: Self.gap) {
            NotchIcon(thing: t).frame(width: iconWidth(t), height: iconWidth(t))
            if text { trailing(t) }
        }
    }

    @ViewBuilder private func trailing(_ t: NotchThing) -> some View {
        switch t {
        case .media: EqualizerBars(playing: true, color: .red)
        case .dictation: Image(systemName: "mic.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
        case .agents: Text(t.time).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.orange)
        case .battery, .downloads: Text(t.time).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
        default: Text(t.time).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        }
    }

    private func iconWidth(_ t: NotchThing) -> CGFloat { t == .media ? IslandModel.artSize : IslandModel.iconSize }

    private func textWidth(_ t: NotchThing) -> CGFloat {
        switch t {
        case .media: IslandModel.artSize
        case .dictation: 16
        case .battery, .downloads: ceil((t.time as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium)]).width)
        default: ceil((t.time as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)]).width)
        }
    }

    private func sideWidth(_ items: [NotchThing], _ text: NotchThing) -> CGFloat {
        Self.pad + items.map { iconWidth($0) + ($0 == text ? Self.gap + textWidth($0) : 0) }.reduce(0, +) + Self.gap * CGFloat(items.count)
    }
}

/// A line of lyrics, half sung: lit word by word when they fill in, else all at once.
private struct LyricLine: View {
    let text: String
    let fill: Bool
    let size: CGFloat

    var body: some View {
        let words = text.split(separator: " ")
        let sung = fill ? words.count / 2 : words.count
        let lit = Text(words.prefix(sung).joined(separator: " ")).foregroundStyle(.white)
        let rest = Text(words.dropFirst(sung).joined(separator: " ")).foregroundStyle(.white.opacity(0.35))
        Text("\(lit) \(rest)")
            .font(.system(size: size, weight: size > 14 ? .bold : .medium))
            .lineLimit(1)
    }
}

/// The open notch: the band (glances left, buttons right) over the first thing, the rest as tiles beside it.
private struct OpenNotch: View {
    let things: [NotchThing]
    let spotlight: NotchThing?
    let settings: Settings

    private var media: Bool { things.contains(.media) && spotlight.map { $0 == .media || !NotchThing.tiled.contains($0) } ?? true }
    private var lyricsFace: Bool { media && things.contains(.lyrics) && settings.notchLyricsOpen }
    /// The first thing when nothing plays, and the tiles.
    private var tiled: [NotchThing] {
        var list = NotchThing.tiled.filter(things.contains)
        if let spotlight, let i = list.firstIndex(of: spotlight) { list.insert(list.remove(at: i), at: 0) }
        return list
    }
    private var main: NotchThing? { media ? .media : tiled.first }
    private var tiles: [NotchThing] { Array(tiled.filter { $0 != main }.prefix(4)) }
    private var glances: [BandItem] { settings.notchEnabled ? Array(settings.notchBand.prefix(2)) : [] }
    private var buttons: [String] {
        guard settings.notchEnabled else { return [] }
        return (things.contains(.agents) ? ["terminal"] : []) + ["web.camera", "gearshape"]
    }

    private static let side = IslandModel.expandedInset + 12, b = IslandView.rowButton, gap = IslandGeometry.gap
    private static let tileW = IslandGeometry.tileWidth, tileH = IslandGeometry.tileHeight

    private var lane: CGFloat {
        let g = glances.map(\.width).reduce(0, +) + CGFloat(max(0, glances.count - 1)) * IslandModel.bandGap
        return max(CGFloat(buttons.count) * (Self.b + Self.gap) - Self.gap, g)
    }
    private var openWidth: CGFloat { max(400, Demo.seed.width + 2 * IslandModel.notchClearance + 2 * (Self.side + lane)) }
    private var mainWidth: CGFloat { openWidth - 2 * Self.side }
    private var rows: Int { tiles.count > 1 ? 2 : 1 }
    private var columns: Int { (tiles.count + rows - 1) / rows }
    private var tilesHeight: CGFloat { tiles.isEmpty ? 0 : CGFloat(rows) * Self.tileH + CGFloat(rows - 1) * Self.gap }
    private var detailHeight: CGFloat { main == .media ? (lyricsFace ? IslandView.lyricsHeight : IslandView.artBig) : main == nil ? IslandView.artBig : 56 }
    private var contentTop: CGFloat { Demo.seed.height + 6 }

    var size: CGSize {
        guard settings.notchEnabled else { return Demo.seed }
        return CGSize(width: openWidth + CGFloat(columns) * (Self.tileW + Self.gap),
                      height: contentTop + max(detailHeight, tilesHeight) + IslandModel.expandedInset)
    }

    var body: some View {
        if !settings.notchEnabled {
            IslandShape(ear: 6, top: 0, bottom: 10).fill(Color.black)
        } else {
            ZStack(alignment: .top) {
                IslandShape(ear: 12, top: 0, bottom: IslandView.cardRadius + IslandModel.expandedInset).fill(Color.black)
                HStack(spacing: 0) {
                    HStack(spacing: IslandModel.bandGap) { ForEach(glances) { DemoGlance(item: $0) } }
                        .frame(width: lane, alignment: .leading)
                    Spacer(minLength: 0)
                    HStack(spacing: Self.gap) { ForEach(buttons, id: \.self) { RoundButton(symbol: $0, tint: nil, size: Self.b) {} } }
                        .frame(width: lane, alignment: .trailing)
                }
                .padding(.horizontal, Self.side)
                .frame(height: Demo.seed.height)
                HStack(alignment: .center, spacing: Self.gap) {
                    first.frame(width: mainWidth, height: detailHeight, alignment: .topLeading)
                    if !tiles.isEmpty {
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(Self.tileH), spacing: Self.gap), count: rows), spacing: Self.gap) {
                            ForEach(tiles) { tile($0, width: Self.tileW, height: Self.tileH) }
                        }
                    }
                }
                .padding(.horizontal, Self.side)
                .padding(.top, contentTop)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder private var first: some View {
        switch main {
        case .media?: lyricsFace ? AnyView(lyricsPlayer) : AnyView(player)
        case let t?: tile(t, width: mainWidth, height: 56)
        case nil: idleHome
        }
    }

    private var player: some View {
        HStack(alignment: .top, spacing: 14) {
            AlbumArt(image: Demo.art, missing: false).frame(width: IslandView.artBig, height: IslandView.artBig)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    song
                    Spacer(minLength: 0)
                    EqualizerBars(playing: true, color: .red)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text("1:20")
                    Capsule().fill(Color.white.opacity(0.14)).frame(height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(Color.white.opacity(0.8)).frame(width: 60, height: 4) }
                    Text("-2:00")
                }
                .font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    controls
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .trailing) { if things.contains(.lyrics) { RoundButton(symbol: "quote.bubble", tint: nil, size: Self.b) {} } }
            }
        }
    }

    private var lyricsPlayer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                AlbumArt(image: Demo.art, missing: false).frame(width: Self.b, height: Self.b)
                song
                Spacer(minLength: 0)
                controls
                RoundButton(symbol: "quote.bubble.fill", tint: .white, size: Self.b) {}
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(Demo.lines[0]).foregroundStyle(.white.opacity(0.35)).font(.system(size: 20, weight: .bold))
                LyricLine(text: Demo.lines[1], fill: settings.notchLyricsFill, size: 20)
                ForEach(Demo.lines.suffix(2), id: \.self) { Text($0).foregroundStyle(.white.opacity(0.35)).font(.system(size: 20, weight: .bold)) }
            }
            .lineLimit(1)
        }
    }

    private var song: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Blinding Lights").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            Text("The Weeknd").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6))
        }
        .lineLimit(1)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            RoundButton(symbol: "backward.fill", tint: nil, size: Self.b) {}
            RoundButton(symbol: "pause.fill", tint: .pink, size: Self.b) {}
            RoundButton(symbol: "forward.fill", tint: nil, size: Self.b) {}
        }
    }

    /// Nothing running: the time and date, and the quick starts.
    private var idleHome: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("9:41").font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Text("Wednesday, November 11").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            HStack(spacing: Self.gap) {
                Spacer(minLength: 0)
                ForEach(["mic.fill", "record.circle", "timer", "doc.on.clipboard"], id: \.self) { RoundButton(symbol: $0, tint: nil, size: Self.b) {} }
            }
        }
    }

    /// A tile, as in the open notch: icon, time over what it is, its one control.
    private func tile(_ t: NotchThing, width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 8) {
            NotchIcon(thing: t).frame(width: Self.b, height: Self.b)
            VStack(alignment: .leading, spacing: 0) {
                Text(t.time).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                if !t.caption.isEmpty { Text(t.caption).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.55)) }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            RoundButton(symbol: t.button.symbol, tint: t.button.tint, size: Self.b) {}
        }
        .padding(.horizontal, IslandView.rowPad)
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: IslandView.cardRadius, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}
