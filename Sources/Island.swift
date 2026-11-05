import AppKit
import Observation
import SwiftUI

// The dynamic notch (ported from Moneybag Island). It grows out of the notch for whatever Flick is doing:
// dictation, a meeting, the Pomodoro timer, or a quick confirmation. Hover to expand for controls.

enum IslandStage { case hidden, seed, compact, expanded }

struct IslandGeometry: Equatable {
    var hasNotch: Bool
    var notchHeight: CGFloat
    var screenFrame: NSRect
    var centerX: CGFloat
    var topInset: CGFloat
    var seedSize: CGSize
    var compactSize: CGSize
    var expandedSize: CGSize

    /// Room for the closed notch at its widest, and the open one with every column of tiles (or the camera), with two
    /// glances in the band.
    var panelSize: CGSize {
        CGSize(width: max(expandedSize.width + 200 + CGFloat(Self.maxColumns) * (Self.tileWidth + Self.gap), compactSize.width + 460) + 48,
               height: expandedSize.height + CGFloat(Self.maxRows) * Self.rowHeight + topInset + 24)
    }
    static let rowHeight: CGFloat = 52
    static let maxRows = 5
    /// The open notch: everything after the first thing is a tile beside it, two to a column, up to three columns.
    static let tileWidth: CGFloat = 156
    static let tileHeight: CGFloat = rowHeight - 10
    static let gap: CGFloat = 8
    static let maxColumns = 3
    var panelFrame: NSRect {
        NSRect(x: centerX - panelSize.width / 2, y: screenFrame.maxY - panelSize.height, width: panelSize.width, height: panelSize.height)
    }

    static func current() -> IslandGeometry {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            let frame = screen.frame
            let height = screen.safeAreaInsets.top
            let left = screen.auxiliaryTopLeftArea?.width ?? (frame.width - 200) / 2
            let right = screen.auxiliaryTopRightArea?.width ?? (frame.width - 200) / 2
            let width = max(80, frame.width - left - right)
            return IslandGeometry(hasNotch: true, notchHeight: height, screenFrame: frame, centerX: frame.minX + left + width / 2, topInset: 0,
                                  seedSize: CGSize(width: width, height: height), compactSize: CGSize(width: width + 150, height: height),
                                  expandedSize: CGSize(width: max(400, width + 200), height: height + 112))
        }
        return plain((NSScreen.main ?? NSScreen.screens.first)?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
    }

    /// A screen without a notch: a pill just under the top edge.
    static func plain(_ frame: NSRect) -> IslandGeometry {
        IslandGeometry(hasNotch: false, notchHeight: 32, screenFrame: frame, centerX: frame.midX, topInset: 5,
                       seedSize: CGSize(width: 64, height: 32), compactSize: CGSize(width: 190, height: 32),
                       expandedSize: CGSize(width: 380, height: 124))
    }
}

/// For opening: a light spring.
let islandSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)
/// For shrinking: critically damped, so the shape never dips below the physical notch and bounces back.
let islandSettle = Animation.spring(response: 0.45, dampingFraction: 1)

@MainActor @Observable final class IslandModel {
    enum Activity: Equatable { case alarm, dictation, toast, meeting, pomodoro, timer, stopwatch, media, event }

    var stage = IslandStage.hidden {
        didSet {
            guard stage != oldValue else { return }
            // The camera and a tile brought to the front last only while it's open.
            if stage != .expanded { camera = false; focus = nil }
            onStage?(stage)
        }
    }
    /// The open notch shows the front camera as a mirror (the camera runs only while it shows).
    var camera = false { didSet { if !camera { CameraMirror.shared.stop() } } }
    /// Opened by hovering the bare notch with nothing running: the idle home (time, next event, weather, quick starts).
    var idleOpen = false
    /// A tile tapped in the open notch: it takes the main spot until the notch closes.
    var focus: Slot?
    /// The player shows the song's lyrics in place of its timeline (Settings keeps the choice).
    var lyricsFace: Bool { Lyrics.shared.hasLines && (lyricsOverride ?? Store.shared.settings.notchLyricsOpen) }
    /// `--island-snapshot --lyrics-face`: the lyrics face without touching the saved settings.
    var lyricsOverride: Bool?
    var contentVisible = false
    var hovering = false
    var geometry = IslandGeometry.current()
    /// A passing message. A `note` shows its words in the closed notch too (otherwise it's just its icon there).
    var toast: (title: String, detail: String, symbol: String, color: Color, note: Bool)?
    /// Everything happening now, most urgent first. The notch widens for each one.
    var activities: [Activity] = []
    var activity: Activity? { activities.first }
    /// A full-screen app is in front on the notch's screen.
    var fullScreen = false
    /// Rubber band while swiping on the trackpad: down (or, negative, up) and sideways, in points.
    var pull = CGSize.zero
    /// The pointer is over the notch (give or take a moment): it doesn't close on its own then.
    @ObservationIgnored var pointerInside = false
    /// Sideways over the player: true for the next song.
    @ObservationIgnored var skip: (Bool) -> Void = { $0 ? NowPlaying.shared.next() : NowPlaying.shared.previous() }
    /// The one tap of the trackpad: on opening by hover, and where a swipe acts (never for a button: those are silent).
    @ObservationIgnored var haptic: () -> Void = { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }

    @ObservationIgnored let pomodoro: Pomodoro
    @ObservationIgnored let dictation: DictationController
    @ObservationIgnored private var wasPolishing = false
    @ObservationIgnored let meeting: MeetingRecorder
    @ObservationIgnored var onStage: ((IslandStage) -> Void)?
    @ObservationIgnored var lastInteraction = Date()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    @ObservationIgnored var isLauncherShowing: () -> Bool = { false }

    init(pomodoro: Pomodoro, dictation: DictationController, meeting: MeetingRecorder) {
        self.pomodoro = pomodoro
        self.dictation = dictation
        self.meeting = meeting
    }

    /// The one order there is: alarms and dictation first, then what's playing, timers, meetings, focus, stopwatches,
    /// messages and events.
    private static let order: [Activity] = [.alarm, .dictation, .media, .timer, .meeting, .pomodoro, .stopwatch, .toast, .event]
    private func rank(_ a: Activity) -> Int { Self.order.firstIndex(of: a) ?? 99 }

    func activity(for slot: Slot) -> Activity {
        switch slot {
        case .alarm: .alarm
        case .dictation: .dictation
        case .toast: .toast
        case .meeting: .meeting
        case .pomodoro: .pomodoro
        case .timer: .timer
        case .stopwatch: .stopwatch
        case .media: .media
        case .event: .event
        }
    }

    /// Everything in the notch, in the order the closed notch reads left to right: each running timer (soonest first)
    /// and stopwatch on its own.
    var compactOrder: [Slot] {
        var out: [Slot] = []
        for a in activities.sorted(by: { rank($0) < rank($1) }) {
            switch a {
            case .timer:
                let t = Timers.shared
                out += t.running.sorted { $0.remaining(t.now) < $1.remaining(t.now) }.map { .timer($0.id) }
            case .stopwatch: out += Stopwatches.shared.running.map { .stopwatch($0.id) }
            default: out.append(slot(for: a))
            }
        }
        return out
    }

    /// Closed, at most three.
    var compactShown: [Slot] { Array(compactOrder.prefix(Self.compactMax)) }

    /// One thing in the notch: each running timer and stopwatch gets its own.
    enum Slot: Hashable {
        case alarm, dictation, toast, meeting, pomodoro, timer(UUID), stopwatch(UUID), media, event
        var key: String {
            switch self {
            case .timer(let id): "timer-\(id)"
            case .stopwatch(let id): "stopwatch-\(id)"
            default: "\(self)"
            }
        }
    }

    func slot(for a: Activity) -> Slot {
        switch a {
        case .alarm: .alarm
        case .dictation: .dictation
        case .toast: .toast
        case .meeting: .meeting
        case .pomodoro: .pomodoro
        case .media: .media
        case .event: .event
        case .timer: Timers.shared.next.map { .timer($0.id) } ?? .toast
        case .stopwatch: Stopwatches.shared.running.first.map { .stopwatch($0.id) } ?? .toast
        }
    }

    /// Expanded: playback on top, then everything else in the closed notch's order, every running timer and
    /// stopwatch on its own. A tapped tile goes first. (While dictating, dictation is all there is.)
    var slots: [Slot] {
        var out: [Slot] = activities.contains(.media) ? [.media] : []
        out += compactOrder.filter { $0 != .media }
        if let focus, let k = out.firstIndex(of: focus) { out.insert(out.remove(at: k), at: 0) }
        return Array(out.prefix(IslandGeometry.maxRows + 1))
    }

    /// The icons drawn on their own over the notch, flying between their spots as it opens and closes: the closed
    /// notch's, or the first thing's and each tile's.
    var iconSlots: [Slot] {
        switch stage {
        case .compact: return compactLayout.order
        case .expanded:
            guard !camera, let first = slots.first else { return [] }
            return (first == .dictation ? [] : [first]) + tiles
        default: return []
        }
    }

    /// Open: the tiles beside the first thing.
    var tiles: [Slot] { camera ? [] : Array(slots.dropFirst()) }
    /// One row for a lone tile, else two (as tall as the player), filling columns left to right.
    var tileRows: Int { tiles.count > 1 ? 2 : 1 }
    var tileColumns: Int { min(IslandGeometry.maxColumns, (tiles.count + tileRows - 1) / tileRows) }
    /// Width the columns of tiles add (counted even while the camera shows, so the notch doesn't jump sideways).
    var tilesWidth: CGFloat {
        let n = slots.count - 1, rows = n > 1 ? 2 : 1, cols = min(IslandGeometry.maxColumns, max(0, n + rows - 1) / rows)
        return CGFloat(cols) * (IslandGeometry.tileWidth + IslandGeometry.gap)
    }
    var tilesHeight: CGFloat { tiles.isEmpty ? 0 : CGFloat(tileRows) * IslandGeometry.tileHeight + CGFloat(tileRows - 1) * IslandGeometry.gap }

    /// Space between the open notch's content and the shape's sides (past the ears).
    var sideInset: CGFloat { Self.expandedInset + (geometry.hasNotch ? 12 : 0) }
    /// The first thing's width in the open notch.
    var mainWidth: CGFloat { openWidth - 2 * sideInset }
    /// Each side of the band: the room the buttons on the right or the glances on the left need, whichever is more.
    var bandLane: CGFloat {
        let items = bandItems
        return max(Self.bandButtons, items.map(\.width).reduce(0, +) + CGFloat(max(0, items.count - 1)) * Self.bandGap)
    }
    /// The glances left of the notch (Settings › Notch).
    var bandItems: [BandItem] { bandOverride ?? Array(Store.shared.settings.notchBand.prefix(2)) }
    /// `--island-snapshot --band a,b`: other glances without touching the saved settings.
    var bandOverride: [BandItem]?
    static let bandButtons: CGFloat = 2 * IslandView.rowButton + IslandGeometry.gap
    static let bandGap: CGFloat = 12
    /// Kept clear between the band and the camera housing, on each side. The housing reaches a couple of points past
    /// the gap the menu bar leaves (`auxiliaryTopLeftArea`/`…RightArea`), so this leaves a real 10 pt.
    static let notchClearance: CGFloat = 12
    /// The open notch's width before tiles: the base, or wider so each side of the band clears the camera housing.
    var openWidth: CGFloat {
        let g = geometry
        let middle = g.hasNotch ? g.seedSize.width + 2 * Self.notchClearance : Self.bandGap
        return max(g.expandedSize.width, middle + 2 * (sideInset + bandLane))
    }
    /// The band at the top of the open notch (beside the notch, at menu-bar height), and where the content starts.
    var bandHeight: CGFloat { geometry.hasNotch ? geometry.notchHeight : 32 }
    var bandTop: CGFloat { geometry.hasNotch ? 0 : 8 }
    var contentTop: CGFloat { bandTop + bandHeight + 6 }
    /// The mirror: the open notch's full width, as tall as the camera's shape at the first thing's width (so a notch
    /// widened by tiles shows a wider crop, not a taller notch).
    var cameraHeight: CGFloat { (mainWidth * 3 / 4).rounded() } // a camera's own 4:3, at the notch's base width

    /// Hands-free: cancel and finish buttons in the open notch (under the band at menu-bar height, where clicks
    /// don't always land). The words themselves never show.
    var dictationControls: Bool { dictation.handsFree && [.starting, .listening].contains(dictation.phase) }

    /// Dictation shown in the top strip (beside the notch) of the expanded notch.
    var dictationInStrip: Bool {
        if case .failed = dictation.phase { return slots.first != .dictation }
        return activities.contains(.dictation)
    }

    /// Height of the first item's detail in the expanded notch.
    var detailHeight: CGFloat {
        switch slots.first {
        case .media: lyricsFace ? IslandView.lyricsHeight : IslandView.artBig
        case .timer: 56
        case .stopwatch: 56
        case .pomodoro: 80
        case .meeting: 90
        case .alarm: 48
        case .toast: 42
        case .event: 46
        case .dictation:
            if case .failed = dictation.phase { 48 } else { dictationControls ? IslandView.rowButton : 0 }
        case nil: IslandView.artBig // the idle home, opened with nothing running (as tall as the player)
        }
    }

    struct CompactLayout {
        var left: [Slot] = []
        var right: [Slot] = []
        /// Whose time shows, just after its icon (or right of the notch when it's alone).
        var text: Slot?
        var textWidth: CGFloat = 0
        /// The one thing there is: its icon left of the notch, its time right.
        var textApart = false
        /// Each side's width. Both sides match so the notch stays centred.
        var side: CGFloat = 0
        var order: [Slot] { left + right }
        var keys: [String] { left.map(\.key) + ["|"] + right.map(\.key) }
    }

    var compactLayout: CompactLayout { layout(for: compactShown) }

    /// Collapsed: up to three things read left to right across the notch, split so the sides come out as even as
    /// they can; both sides take the wider one's width so the notch stays centred, within twice the bare notch.
    func layout(for shown: [Slot]) -> CompactLayout {
        guard !shown.isEmpty else { return CompactLayout() }
        let pad = geometry.hasNotch ? Self.compactPad : 10, gap = Self.compactGap
        var L = CompactLayout()
        L.text = shown.first { [.timer, .stopwatch, .pomodoro, .meeting, .event].contains(activity(for: $0)) && slotTextWidth($0) > 0 }
            ?? (slotTextWidth(shown[0]) > 0 ? shown[0] : nil)
        L.textWidth = L.text.map(slotTextWidth) ?? 0
        if shown.count == 1 {
            L.left = shown
            L.textApart = L.text != nil
            let inset = shown[0] == .media ? Self.artInset : 0
            L.side = max(pad + inset + Self.iconWidth(shown[0]) + gap, L.textApart ? gap + L.textWidth + pad + inset : 0)
        } else {
            var best = (k: 1, width: CGFloat.infinity)
            for k in 1..<shown.count {
                let w = max(sideWidth(Array(shown[..<k]), L), sideWidth(Array(shown[k...]), L))
                if w < best.width { best = (k, w) }
            }
            L.left = Array(shown[..<best.k])
            L.right = Array(shown[best.k...])
            L.side = best.width
        }
        // Never more than twice the bare notch: with too much to fit, the last thing waits in the open notch
        // (times never get cut); only a lone long time truncates.
        let over = L.side - geometry.seedSize.width / 2
        if over > 0, shown.count > 1 { return layout(for: Array(shown.dropLast())) }
        if over > 0, L.text != nil {
            let cut = min(over, max(0, L.textWidth - 28))
            L.textWidth -= cut
            L.side -= cut
        }
        return L
    }

    static let compactGap: CGFloat = 6

    /// Width of one side holding `items` (in from the shape's edge, out to the notch).
    private func sideWidth(_ items: [Slot], _ L: CompactLayout) -> CGFloat {
        let pad = geometry.hasNotch ? Self.compactPad : 10, gap = Self.compactGap
        return pad + items.map { itemWidth($0, L) }.reduce(0, +) + gap * CGFloat(items.count)
            + (items.contains(.media) ? Self.artInset : 0)
    }

    /// An icon, plus its time if it's the one showing it.
    func itemWidth(_ s: Slot, _ L: CompactLayout) -> CGFloat {
        Self.iconWidth(s) + (s == L.text && !L.textApart ? Self.compactGap + L.textWidth : 0)
    }

    /// Centre of each thing in a closed layout, from the shape's left edge.
    func centers(_ L: CompactLayout) -> [Slot: CGFloat] {
        let pad = geometry.hasNotch ? Self.compactPad : 10, gap = Self.compactGap
        var out: [Slot: CGFloat] = [:]
        var x = pad + (L.left.first == .media ? Self.artInset : 0)
        for s in L.left {
            out[s] = x + Self.iconWidth(s) / 2
            x += itemWidth(s, L) + gap
        }
        let content = L.right.map { itemWidth($0, L) }.reduce(0, +) + gap * CGFloat(max(0, L.right.count - 1))
        x = L.side + geometry.seedSize.width + L.side - pad - (L.right.last == .media ? Self.artInset : 0) - content
        for s in L.right {
            out[s] = x + Self.iconWidth(s) / 2
            x += itemWidth(s, L) + gap
        }
        return out
    }

    /// Width of the time (or mark) a slot shows in the closed notch.
    func slotTextWidth(_ s: Slot) -> CGFloat {
        switch s {
        case .timer(let id):
            let t = Timers.shared
            return textWidth(Pomodoro.clock(t.list.first { $0.id == id }?.remaining(t.now) ?? 0))
        case .stopwatch(let id):
            let w = Stopwatches.shared
            return textWidth(Stopwatch.format(w.list.first { $0.id == id }?.elapsed(w.now) ?? 0, hundredths: false))
        default: return compactTrailingWidth(activity(for: s))
        }
    }

    private func textWidth(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)]).width)
    }

    var shapeSize: CGSize {
        switch stage {
        case .hidden, .seed: return geometry.seedSize
        case .compact:
            // Sized to what it shows: the first activity's icon left of the notch, its text right, and a small icon for
            // each other one. Never wider than twice the bare notch (the text truncates instead).
            let L = compactLayout
            return CGSize(width: geometry.seedSize.width + L.side * 2, height: geometry.compactSize.height)
        case .expanded:
            // The band, then the first thing with the tiles beside it (wider before taller), or the mirror.
            let content = camera ? cameraHeight : max(detailHeight, tilesHeight)
            return CGSize(width: openWidth + (camera ? 0 : tilesWidth), height: contentTop + content + Self.expandedInset)
        }
    }

    /// Re-decides what the notch shows (called whenever dictation, meeting, timer or a toast changes).
    func refresh() {
        var list: [Activity] = []
        let s = Store.shared.settings
        if Alarms.shared.ringing != nil { list.append(.alarm) }
        if dictation.isActive, s.notchDictation { list.append(.dictation) }
        if toast != nil { list.append(.toast) }
        if meeting.isRunning, s.notchMeeting { list.append(.meeting) } // shown straight away, popup open or not
        if pomodoro.active, s.notchFocus { list.append(.pomodoro) }
        if !Timers.shared.running.isEmpty, s.notchTimers { list.append(.timer) }
        if !Stopwatches.shared.running.isEmpty, s.notchStopwatch { list.append(.stopwatch) }
        if s.notchEvents, CalendarEvents.shared.upcoming != nil { list.append(.event) }
        if !s.notchEnabled { list.removeAll() }
        list.sort { rank($0) < rank($1) }
        // Paused stays: the song goes away only when Music or Spotify is quit or stopped.
        if NowPlaying.shared.available, Store.shared.settings.mediaInNotch { list.append(.media) }
        // Over a full-screen app, only what can't wait: a ringing alarm, and dictation you started.
        if fullScreen, s.notchHideInFullScreen { list.removeAll { $0 != .alarm && $0 != .dictation } }
        // While dictating, the notch is only dictation (open or closed): the player and the rest come back after.
        // A ringing alarm still shows, so it can be stopped.
        if list.contains(.dictation) { list.removeAll { $0 != .dictation && $0 != .alarm } }
        if list != activities {
            withAnimation(list.count < activities.count ? islandSettle : islandSpring) { activities = list }
        }
        // Dictation takes the band the camera button sits in: the mirror closes.
        if camera, dictationInStrip { withAnimation(islandSettle) { camera = false } }
        let next = list.first
        guard next != nil else {
            if !idleOpen { hide() } // opened by hover with nothing running: it stays until the pointer leaves
            return
        }
        show()
        // Hands-free dictation opens for its buttons, and a failure to explain itself; push-to-talk stays closed.
        // Polishing happens in the closed notch: an open one closes when it starts.
        let polishing = dictation.phase == .processing
        if polishing, !wasPolishing { collapse() }
        wasPolishing = polishing
        if next == .dictation, !polishing {
            if dictationWantsRoom { expand(haptic: false) } else if stage == .expanded, !pointerInside { collapse() }
        }
    }

    /// Dictation holds the notch open for hands-free's buttons, or a failure to explain.
    var dictationWantsRoom: Bool {
        if case .failed = dictation.phase { return true }
        return dictationControls
    }


    // MARK: Trackpad

    enum SwipePhase { case began, changed, ended }
    private struct Swipe { var x: CGFloat = 0, y: CGFloat = 0, axis: Axis?, ours = false, done = false }
    @ObservationIgnored private var swipe: Swipe?
    var swiping: Bool { swipe?.ours == true }

    /// Two fingers on the trackpad over the notch (finger travel in points, down and right positive): down opens the
    /// closed notch, up closes the open one, sideways over the player skips the song. The shape gives a little as the
    /// fingers move and one tap of the trackpad marks the moment it acts. True when the notch took the event (otherwise
    /// it goes on to whatever is under the pointer, like the dictation words' scroll view).
    func swipe(_ phase: SwipePhase, dx: CGFloat, dy: CGFloat, overPlayer: Bool) -> Bool {
        if phase == .began { swipe = Swipe() }
        guard var w = swipe else { return false }
        if phase == .ended {
            swipe = nil
            if pull != .zero { withAnimation(islandSpring) { pull = .zero } }
            return w.ours
        }
        w.x += dx
        w.y += dy
        if w.axis == nil, hypot(w.x, w.y) > 6 {
            w.axis = abs(w.x) > abs(w.y) ? .horizontal : .vertical
            w.ours = w.axis == .vertical ? (stage == .compact || (stage == .expanded && slots.first != .dictation))
                : stage == .expanded && slots.first == .media && !camera && overPlayer
        }
        defer { swipe = w }
        guard w.ours else { return false }
        lastInteraction = Date()
        func rubber(_ d: CGFloat, _ limit: CGFloat) -> CGFloat { (d < 0 ? -1 : 1) * limit * (1 - 1 / (abs(d) * 0.55 / limit + 1)) }
        if w.done { return true }
        if w.axis == .horizontal {
            pull = CGSize(width: rubber(w.x, 22), height: 0)
            guard abs(w.x) > 48 else { return true }
            w.done = true
            haptic()
            skip(w.x < 0) // fingers to the left: the next song
            withAnimation(islandSpring) { pull = .zero }
        } else if stage == .compact {
            pull = CGSize(width: 0, height: rubber(max(0, w.y), 14))
            guard w.y > 26 else { return true }
            w.done = true
            withAnimation(islandSpring) { pull = .zero }
            expand()
        } else {
            pull = CGSize(width: 0, height: rubber(w.y, 14))
            guard w.y < -26 else { return true }
            w.done = true
            haptic()
            withAnimation(islandSettle) { pull = .zero }
            collapse()
        }
        return true
    }

    /// Content starts this far in from the shape's edge (past the 12 pt ears that meet the screen edge).
    static let compactPad: CGFloat = 22
    static let compactMax = 3

    /// Closed, only times (and a few live marks) show as text; everything else is just its icon.
    func compactTrailingWidth(_ a: Activity) -> CGFloat {
        switch a {
        case .pomodoro, .meeting, .timer, .stopwatch, .media, .event: return trailingWidth(a)
        case .dictation:
            switch dictation.phase {
            case .starting, .listening, .processing: return 16
            default: return 0
            }
        case .toast: return toast?.note == true ? compactTextWidth(.toast) : 0
        case .alarm: return 0
        }
    }
    /// Space between the expanded notch's content and its sides and bottom (past the ears), all the same.
    static let expandedInset: CGFloat = 18
    static let iconSize: CGFloat = 18
    /// Album art reads better a little bigger than the other icons.
    static let artSize: CGFloat = 22
    static func iconWidth(_ s: Slot) -> CGFloat { s == .media ? artSize : iconSize }
    /// Extra room left of the art so it doesn't crowd the shape's curved edge.
    static let artInset: CGFloat = 2


    /// Width of the text (or mark) right of the notch for an activity.
    func trailingWidth(_ a: Activity) -> CGFloat {
        func w(_ s: String, _ size: CGFloat, mono: Bool = false) -> CGFloat {
            let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size, weight: .medium)
            return ceil((s as NSString).size(withAttributes: [.font: font]).width)
        }
        switch a {
        case .pomodoro: return w(pomodoro.clock, 15, mono: true)
        case .meeting: return w(meeting.clock, 14, mono: true)
        case .timer:
            let t = Timers.shared
            return w(t.next.map { Pomodoro.clock($0.remaining(t.now)) } ?? "00:00", 14, mono: true)
        case .stopwatch: return w(Stopwatch.format(Stopwatches.shared.running.first?.elapsed(Stopwatches.shared.now) ?? 0, hundredths: false), 14, mono: true)
        case .media: return Self.artSize // the visualizer, as wide as the art across the notch
        case .event: return w(CalendarEvents.shared.upcoming?.countdown(CalendarEvents.shared.now) ?? "", 14, mono: true)
        case .dictation, .toast, .alarm: return compactTextWidth(a)
        }
    }

    /// The words beside the notch for an activity, so the notch grows to fit them instead of cutting them off.
    private func compactTextWidth(_ a: Activity) -> CGFloat {
        let text: String
        switch a {
        case .dictation:
            switch dictation.phase {
            case .done(let m): text = m
            case .failed: text = "Couldn't dictate"
            case .processing: return 16
            default: return 14
            }
        case .toast: text = toast?.title ?? ""
        case .alarm: text = Alarms.shared.ringing.map { $0.label.isEmpty ? $0.time : $0.label } ?? ""
        default: text = ""
        }
        return (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium)]).width
    }

    func flash(_ title: String, _ detail: String = "", symbol: String = "checkmark.circle.fill", color: Color = .green, seconds: Double = 1.8, note: Bool = false) {
        toastWork?.cancel()
        withAnimation(islandSpring) { toast = (title, detail, symbol, color, note) }
        refresh()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(islandSettle) { self.toast = nil }
                self.refresh()
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Closing all the way is under way: asking again doesn't restart it (the pointer check asks 20 times a second,
    /// and each restart pushed the close back, so an idle notch never went away).
    private var hiding = false

    func show() {
        hiding = false
        generation += 1
        let current = generation
        switch stage {
        case .compact, .expanded:
            if !contentVisible { withAnimation(.easeOut(duration: 0.25)) { contentVisible = true } }
            return
        case .hidden:
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                contentVisible = false
                hovering = false
                stage = .seed
            }
        case .seed:
            break
        }
        after(0.05) {
            guard current == self.generation else { return }
            withAnimation(islandSpring) { self.stage = .compact }
        }
        after(0.26) {
            guard current == self.generation else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.contentVisible = true }
        }
    }

    func hide() {
        guard stage != .hidden, !hiding else { return }
        hiding = true
        generation += 1
        let current = generation
        withAnimation(.easeIn(duration: 0.14)) {
            contentVisible = false
            hovering = false
        }
        after(0.12) {
            guard current == self.generation else { return }
            withAnimation(islandSettle) { self.stage = .seed }
        }
        after(0.7) {
            guard current == self.generation else { return }
            self.hiding = false
            self.stage = .hidden
        }
    }

    func expand(haptic: Bool = true) {
        guard stage == .compact || stage == .seed else { return }
        // Called off: a close under way, and the steps of a `show()` still to come (they used to land a moment later and
        // close the notch again, so dictation starting hands-free opened, closed and opened).
        hiding = false
        generation += 1
        if haptic { self.haptic() }
        lastInteraction = Date()
        withAnimation(islandSpring) {
            hovering = false
            stage = .expanded
            contentVisible = true
        }
    }

    func collapse() {
        guard stage == .expanded else { return }
        // Opened with nothing running: there's no closed notch to go back to.
        if activities.isEmpty {
            idleOpen = false
            withAnimation(islandSettle) { camera = false }
            return hide()
        }
        idleOpen = false
        withAnimation(islandSettle) { stage = .compact }
    }

    /// The bare notch was hovered with nothing running: it opens straight from the notch's own shape.
    func openIdle() {
        guard stage == .hidden, activities.isEmpty, Store.shared.settings.notchEnabled else { return }
        generation += 1
        idleOpen = true
        haptic()
        lastInteraction = Date()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            contentVisible = false
            stage = .seed
        }
        after(0.03) {
            guard self.idleOpen, self.stage == .seed else { return }
            withAnimation(islandSpring) {
                self.stage = .expanded
                self.contentVisible = true
            }
        }
    }

    private func after(_ s: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { work() } }
    }
}

// MARK: - Window

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    /// Trackpad swipes over the notch; true when the notch took the event.
    var onScroll: ((NSEvent, NSPoint) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        // With where it happened in the panel (a test's made-up event has no window yet: its location is on the screen).
        if event.type == .scrollWheel,
           onScroll?(event, event.window == nil ? convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow) == true { return }
        super.sendEvent(event)
    }
}

@MainActor final class IslandController {
    let model: IslandModel
    private let panel: IslandPanel
    private var tracker: Timer?
    /// Tests only: a pointer position to use instead of the real one.
    var mouseOverride: NSPoint?
    func trackOnce() { track() }
    var notchRect: NSRect { shapeRect() }
    /// Off-screen snapshots: the pointer checks stop, so nothing brings the real panel forward.
    func freeze() {
        frozen = true
        tracker?.invalidate()
        tracker = nil
        moveMonitors.forEach(NSEvent.removeMonitor)
        moveMonitors = []
    }
    private var frozen = false
    private var clickMonitor: Any?
    private var moveMonitors: [Any] = []
    private var hoverSince: Date?
    private var lastOver = Date.distantPast
    /// Where the pointer counts as near (kept from the last check, so a pointer move costs next to nothing).
    private var reach = NSRect.zero
    /// Polling the pointer 20 times a second (near the notch, open, or mid-gesture) rather than waiting for it to move.
    private var fast = false

    init(model: IslandModel, openMeeting: @escaping () -> Void) {
        self.model = model
        panel = IslandPanel(contentRect: model.geometry.panelFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar (24), so clicks in the band at menu-bar height land here. No `isFloatingPanel`: setting
        // it puts the level back to floating (3), under the menu bar, which then takes those clicks.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // On one Space at a time, so it slides away with the desktop when you swipe; on arrival it's brought over to the
        // new Space and fades in (on every Space at once, it stood still while the desktop moved under it).
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        let host = FirstMouseHostingView(rootView: IslandView(model: model, openMeeting: openMeeting))
        host.sizingOptions = []
        panel.contentView = host
        model.onStage = { [weak self] stage in self?.stageChanged(stage) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.activity != .dictation else { return }
                self.model.collapse()
            }
        }
        panel.onScroll = { [weak self] e, at in self?.scrolled(e, at: at) ?? false }
        // Watched from the start: with nothing running yet the notch is hidden, and hovering it must still open it.
        setTracking(fast: false)
        // Entering or leaving full screen switches Spaces; the window settles a moment later, so look twice.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.followSpaceSoon()
                    self?.checkFullScreen()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { self?.checkFullScreen() } }
                }
            }
        }
    }

    private func checkFullScreen() {
        let full = Self.frontIsFullScreen(on: model.geometry.screenFrame)
        guard full != model.fullScreen else { return }
        model.fullScreen = full
        model.refresh()
    }

    /// Whether the app in front is full screen on this screen: Accessibility says so (it has its own Space), or one of
    /// its windows covers the whole screen (games and video players that skip the Space).
    static func frontIsFullScreen(on screen: NSRect) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return false }
        // Window server coordinates start at the top left of the main screen.
        let top = NSScreen.screens.first?.frame.maxY ?? screen.maxY
        let cg = CGRect(x: screen.minX, y: top - screen.maxY, width: screen.width, height: screen.height)
        if AXIsProcessTrusted() {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.25) // a hung app mustn't stall the notch
            var win: CFTypeRef?, full: CFTypeRef?, pos: CFTypeRef?
            if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success, let win,
               CFGetTypeID(win) == AXUIElementGetTypeID() {
                let w = win as! AXUIElement
                if AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &full) == .success, (full as? Bool) == true {
                    var p = CGPoint.zero
                    if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success, let pos,
                       CFGetTypeID(pos) == AXValueGetTypeID() { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
                    if cg.insetBy(dx: -1, dy: -1).contains(CGPoint(x: p.x + 1, y: p.y + 1)) { return true }
                }
            }
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { w in
            guard w[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier, w[kCGWindowLayer as String] as? Int == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return false }
            return abs(r.minX - cg.minX) < 1 && abs(r.minY - cg.minY) < 1 && r.width >= cg.width - 1 && r.height >= cg.height - 1
        }
    }

    /// Trackpad only (a mouse wheel's clicks would open it by accident), and never the coasting after the fingers lift.
    /// Over the lyrics face's lines, scrolling (mouse wheel too) moves through the song instead, and never swipes.
    func scrolled(_ e: NSEvent, at local: NSPoint) -> Bool {
        let g = model.geometry
        // On the screen: the panel sits at `panelFrame` (tests send it to an off-screen copy of the same size).
        let p = NSPoint(x: g.panelFrame.minX + local.x, y: g.panelFrame.minY + local.y)
        let depth = g.screenFrame.maxY - g.topInset - p.y
        let left = g.centerX - model.shapeSize.width / 2 + model.sideInset
        if !model.swiping, model.stage == .expanded, model.slots.first == .media, model.lyricsFace,
           depth > model.contentTop + IslandView.rowButton + 10, depth < model.contentTop + IslandView.lyricsHeight,
           p.x > left, p.x < left + model.mainWidth {
            // A mouse wheel moves a line a click, eased; a trackpad follows the fingers.
            withAnimation(e.hasPreciseScrollingDeltas ? nil : .easeOut(duration: 0.2)) {
                Lyrics.shared.scroll(by: -e.scrollingDeltaY / (e.hasPreciseScrollingDeltas ? 26 : 1))
            }
            return true
        }
        guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return model.swiping }
        let phase: IslandModel.SwipePhase
        if e.phase.contains(.began) { phase = .began } else if e.phase.contains(.ended) || e.phase.contains(.cancelled) { phase = .ended } else { phase = .changed }
        // Finger travel, whatever the scrolling direction is set to.
        let k: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        // The player is the first thing, left of the tiles.
        let playerRight = left + model.mainWidth
        let over = depth < model.contentTop + model.detailHeight + 8 && p.x < playerRight + 4
        let took = model.swipe(phase, dx: e.scrollingDeltaX * k, dy: e.scrollingDeltaY * k, overPlayer: over)
        if took { setTracking(fast: true) }
        return took
    }

    func setSharing(_ hidden: Bool) { panel.sharingType = hidden ? .none : .readOnly }
    /// For `--island-snapshot`: the panel's window level (it must be above the menu bar's).
    var panelLevel: Int { panel.level.rawValue }

    private func layout() {
        let g = IslandGeometry.current()
        if g != model.geometry { model.geometry = g }
        panel.setFrame(g.panelFrame, display: true)
    }

    /// A new Space came in: the notch, left behind on the old one, comes over and fades in.
    private func followSpace() {
        guard !frozen, model.stage != .hidden, !panel.isOnActiveSpace else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
    }

    /// The Space notification can come before the switch settles (or not at all, e.g. into a full-screen app):
    /// looked at again shortly after, and on every pointer check, so the notch is never left on another Space.
    private func followSpaceSoon() {
        followSpace()
        for d in [0.15, 0.5] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in MainActor.assumeIsolated { self?.followSpace() } } }
    }

    private func stageChanged(_ stage: IslandStage) {
        if stage == .hidden {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            // Still watched (slowly, faster near the notch) so hovering the bare notch can open it.
            tracker?.invalidate()
            tracker = nil
            setTracking(fast: false)
        } else if !panel.isVisible || !panel.isOnActiveSpace {
            layout()
            panel.orderFrontRegardless()
            setTracking(fast: true)
        }
    }

    /// Near the notch the pointer is checked 20 times a second. Farther off, there's only a check a second plus a
    /// look at each pointer move, which brings back the fast checks the moment it comes near (so hovering isn't slower).
    private func setTracking(fast: Bool) {
        guard !frozen, tracker == nil || self.fast != fast else { return }
        self.fast = fast
        tracker?.invalidate()
        let t = Timer(timeInterval: fast ? 1.0 / 20.0 : 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        t.tolerance = fast ? 0.005 : 0.3
        RunLoop.main.add(t, forMode: .common)
        tracker = t
        if fast {
            moveMonitors.forEach(NSEvent.removeMonitor)
            moveMonitors = []
        } else if moveMonitors.isEmpty {
            let moved = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.fast, self.tracker != nil, self.reach.contains(NSEvent.mouseLocation) else { return }
                    self.setTracking(fast: true)
                    self.track()
                }
            }
            let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let m = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { _ in moved() }) { moveMonitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { e in moved(); return e }) { moveMonitors.append(m) }
        }
    }

    /// The closed or open shape, as it sits on the screen.
    private func shapeRect(scale k: CGFloat = 1) -> NSRect {
        let g = model.geometry
        let size = model.shapeSize
        return NSRect(x: g.centerX - size.width * k / 2, y: g.screenFrame.maxY - g.topInset - size.height * k,
                      width: size.width * k, height: size.height * k + g.topInset + 1)
    }

    /// Within reach of the notch: a quick flick could land on it before the next slow check.
    private func near(_ p: NSPoint) -> Bool {
        reach = shapeRect().insetBy(dx: -220, dy: -180)
        return reach.contains(p)
    }

    /// Clicks only land on the island itself; hovering it for a moment expands it.
    private func track() {
        guard !frozen else { return }
        let mouse = mouseOverride ?? NSEvent.mouseLocation
        if model.stage != .hidden { followSpace() }
        if model.stage == .hidden {
            // Nothing running: hovering the notch itself for a moment opens it.
            let s = Store.shared.settings
            let over = s.notchHoverExpand && !(model.fullScreen && s.notchHideInFullScreen) && shapeRect().contains(mouse)
            if over {
                if hoverSince == nil { hoverSince = Date() }
                if let since = hoverSince, Date().timeIntervalSince(since) > s.notchHoverDelay {
                    hoverSince = nil
                    model.openIdle()
                }
            } else {
                hoverSince = nil
            }
            return setTracking(fast: near(mouse))
        }
        let rect = shapeRect(scale: model.hovering ? 1.05 : 1)
        let interactive = model.stage == .compact || model.stage == .expanded
        let over = interactive && model.contentVisible && rect.contains(mouse)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        // A moment's grace before the pointer counts as gone, so grazing the edge (or the top of the screen) doesn't
        // flicker the hover or restart its wait.
        let now = Date()
        if over { lastOver = now }
        let inside = interactive && model.contentVisible && now.timeIntervalSince(lastOver) < 0.1
        model.pointerInside = inside
        let s = Store.shared.settings
        let hover = inside && model.stage == .compact && s.notchHoverExpand
        if model.hovering != hover { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { model.hovering = hover } }
        if hover {
            if hoverSince == nil { hoverSince = Date() }
            if let since = hoverSince, Date().timeIntervalSince(since) > s.notchHoverDelay {
                hoverSince = nil
                model.expand()
            }
        } else {
            hoverSince = nil
        }
        if model.stage == .expanded {
            if inside || model.swiping {
                model.lastInteraction = Date()
            } else if Date().timeIntervalSince(model.lastInteraction) > s.notchCollapseDelay,
                      !(model.activity == .dictation && (model.dictationWantsRoom || model.dictation.phase == .processing)) {
                model.collapse()
            }
        }
        setTracking(fast: model.stage == .expanded || model.hovering || model.swiping || near(mouse))
    }
}

// MARK: - Views

struct IslandShape: Shape {
    var ear: CGFloat
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(ear, AnimatablePair(top, bottom)) }
        set {
            ear = newValue.first
            top = newValue.second.first
            bottom = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let e = max(0, min(ear, rect.width / 4, rect.height / 2))
        let left = rect.minX + e, right = rect.maxX - e
        let body = right - left
        let t = e > 0 ? 0 : max(0, min(top, body / 2, rect.height / 2))
        let b = max(0, min(bottom, body / 2, rect.height - max(e, t)))
        var path = Path()
        func corner(_ from: CGPoint, _ apex: CGPoint, _ to: CGPoint) {
            let k: CGFloat = 0.58
            path.addCurve(to: to, control1: CGPoint(x: from.x + (apex.x - from.x) * k, y: from.y + (apex.y - from.y) * k),
                          control2: CGPoint(x: to.x + (apex.x - to.x) * k, y: to.y + (apex.y - to.y) * k))
        }
        if e > 0 {
            let start = CGPoint(x: rect.minX, y: rect.minY)
            path.move(to: start)
            corner(start, CGPoint(x: left, y: rect.minY), CGPoint(x: left, y: rect.minY + e))
        } else {
            path.move(to: CGPoint(x: left, y: rect.minY + t))
        }
        path.addLine(to: CGPoint(x: left, y: rect.maxY - b))
        corner(CGPoint(x: left, y: rect.maxY - b), CGPoint(x: left, y: rect.maxY), CGPoint(x: left + b, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - b, y: rect.maxY))
        corner(CGPoint(x: right - b, y: rect.maxY), CGPoint(x: right, y: rect.maxY), CGPoint(x: right, y: rect.maxY - b))
        if e > 0 {
            path.addLine(to: CGPoint(x: right, y: rect.minY + e))
            corner(CGPoint(x: right, y: rect.minY + e), CGPoint(x: right, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: right, y: rect.minY + t))
            corner(CGPoint(x: right, y: rect.minY + t), CGPoint(x: right, y: rect.minY), CGPoint(x: right - t, y: rect.minY))
            path.addLine(to: CGPoint(x: left + t, y: rect.minY))
            corner(CGPoint(x: left + t, y: rect.minY), CGPoint(x: left, y: rect.minY), CGPoint(x: left, y: rect.minY + t))
        }
        path.closeSubpath()
        return path
    }
}

private let focusColor = Color(red: 0xFF / 255, green: 0x6A / 255, blue: 0x55 / 255)
private let breakColor = Color(red: 0x4C / 255, green: 0xD0 / 255, blue: 0x7D / 255)

private struct ProgressRing: View {
    var progress: Double
    var color: Color
    var size: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.001, progress))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct RoundButton: View {
    var symbol: String
    var tint: Color?
    var size: CGFloat = 32 // IslandView.rowButton: one button size all through the open notch
    /// Breathes while on (the lyrics button while the song plays).
    var breathing = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.375, weight: .bold))
                .foregroundStyle(tint ?? .white)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.breathe.pulse, options: .repeat(.continuous), isActive: breathing)
                .frame(width: size, height: size)
                .background(Circle().fill(tint.map { $0.opacity(0.24) } ?? Color.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
    }
}

struct IslandView: View {
    let model: IslandModel
    let openMeeting: () -> Void
    @Namespace private var ns

    private var shape: IslandShape {
        let g = model.geometry
        if g.hasNotch {
            switch model.stage {
            // The bottom corners match the ears where it meets the screen edge, and don't change when it opens.
            case .expanded: return IslandShape(ear: 12, top: 0, bottom: IslandView.cardRadius + IslandModel.expandedInset) // concentric with the cards
            case .compact: return IslandShape(ear: 12, top: 0, bottom: 12)
            default: return IslandShape(ear: 6, top: 0, bottom: 10)
            }
        }
        return model.stage == .expanded ? IslandShape(ear: 0, top: 30, bottom: 30) : IslandShape(ear: 0, top: 16, bottom: 16)
    }

    var body: some View {
        let size = model.shapeSize
        let shape = self.shape
        ZStack(alignment: .top) {
            shape.fill(Color.black)
                // Swiping down stretches it a little (the content stays put); up, it shrinks a touch.
                .frame(width: size.width, height: size.height + max(0, model.pull.height))
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                        // Open and closed cross-fade while the shape springs between sizes; shared icons glide across.
                        if model.stage == .compact {
                            compact
                                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.28).delay(0.1)),
                                                        removal: .opacity.animation(.easeOut(duration: 0.16))))
                        }
                        if model.stage == .expanded {
                            expanded
                                // Grows out of the notch with the shape; leaves quicker and smaller, so closing feels light.
                                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.8, anchor: .top)).animation(islandSpring.delay(0.04)),
                                                        removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)).animation(.easeOut(duration: 0.16))))
                        }
                        flyingIcons
                    }
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .opacity(model.contentVisible ? 1 : 0)
                    .clipShape(shape)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .contentShape(shape)
                // Size and position follow what's inside: a spring when it opens, no bounce otherwise.
                .animation(model.stage == .expanded ? islandSpring : islandSettle, value: size)
                .onTapGesture { model.expand(haptic: false) }
                .scaleEffect((model.hovering ? 1.05 : 1) * (1 + min(0, model.pull.height) / 350), anchor: .top)
                .opacity(model.stage == .hidden ? 0 : 1)
                .padding(.top, model.geometry.topInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) { ClosedLyricLine(model: model) }
        .environment(\.colorScheme, .dark)
    }

    /// Every icon in the notch drawn once, above both faces, on the spot its face leaves for it. Opening, closing or
    /// bringing a tile to the front, each flies to its new spot with the shape's own spring: the closed notch's album
    /// art grows into the player's and back as one picture, rather than two copies cross-fading.
    private var flyingIcons: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.iconSlots, id: \.self) { s in
                slotIcon(s)
                    .matchedGeometryEffect(id: s.key, in: ns, isSource: false)
                    .offset(x: s == .media && model.stage == .expanded && model.slots.first == .media ? model.pull.width : 0)
                    // The shape's own springs: the faces' quick fades would otherwise carry them there ahead of it.
                    .animation(model.stage == .expanded ? islandSpring : islandSettle, value: model.stage)
                    .animation(islandSpring, value: model.lyricsFace)
                    .animation(islandSpring, value: model.focus)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: Compact: something on each side of the notch

    private var compact: some View {
        let g = model.geometry
        return closedContent(model.compactLayout)
            .frame(height: g.compactSize.height)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(islandSettle, value: model.compactLayout.keys)
    }

    /// The closed notch's contents: each side's things read left to right, a time just after its icon. Both
    /// sides are the same width so the notch stays centred.
    private func closedContent(_ L: IslandModel.CompactLayout) -> some View {
        let g = model.geometry
        let pad = g.hasNotch ? IslandModel.compactPad : 10
        return HStack(spacing: 0) {
            HStack(spacing: IslandModel.compactGap) {
                ForEach(L.left, id: \.self) { s in closedItem(s, L) }
            }
            .padding(.leading, pad + (L.left.first == .media ? IslandModel.artInset : 0))
            .frame(width: L.side, alignment: .leading)
            Color.clear.frame(width: g.seedSize.width)
            HStack(spacing: IslandModel.compactGap) {
                if L.textApart, let t = L.text {
                    slotText(t).lineLimit(1).truncationMode(.tail).frame(width: L.textWidth, alignment: .trailing)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
                ForEach(L.right, id: \.self) { s in closedItem(s, L) }
            }
            .padding(.trailing, pad + (L.right.last == .media || (L.textApart && L.text == .media) ? IslandModel.artInset : 0))
            .frame(width: L.side, alignment: .trailing)
        }
    }

    @ViewBuilder private func closedItem(_ s: IslandModel.Slot, _ L: IslandModel.CompactLayout) -> some View {
        HStack(spacing: IslandModel.compactGap) {
            spot(s, size: IslandModel.iconWidth(s))
            if s == L.text, !L.textApart {
                slotText(s).lineLimit(1).truncationMode(.tail).frame(width: L.textWidth, alignment: .leading)
            }
        }
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    /// A slot's time in the closed notch: each timer and stopwatch its own.
    @ViewBuilder private func slotText(_ s: IslandModel.Slot) -> some View {
        switch s {
        case .timer(let id):
            let t = Timers.shared
            let clock = Pomodoro.clock(t.list.first { $0.id == id }?.remaining(t.now) ?? 0)
            Text(clock).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white).rolling(clock, down: true)
        case .stopwatch(let id):
            let w = Stopwatches.shared
            let clock = Stopwatch.format(w.list.first { $0.id == id }?.elapsed(w.now) ?? 0, hundredths: false)
            Text(clock).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white).rolling(clock)
        default: compactTrailing(model.activity(for: s))
        }
    }

    /// Where a slot's icon goes: an empty spot its flying icon (`flyingIcons`) takes the place and size of.
    private func spot(_ slot: IslandModel.Slot, size: CGFloat = 18) -> some View {
        Color.clear
            .frame(width: size, height: size)
            .matchedGeometryEffect(id: slot.key, in: ns, isSource: true)
    }

    @ViewBuilder private func slotIcon(_ slot: IslandModel.Slot) -> some View {
        switch slot {
        case .timer(let id):
            let t = Timers.shared
            ProgressRing(progress: t.list.first { $0.id == id }?.progress(t.now) ?? 0, color: .orange, size: 16, lineWidth: 3)
        case .stopwatch: Image(systemName: "stopwatch.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
        case .alarm: leading(.alarm)
        case .dictation: leading(.dictation)
        case .toast: leading(.toast)
        case .meeting: leading(.meeting)
        case .pomodoro: leading(.pomodoro)
        case .media: leading(.media)
        case .event: leading(.event)
        }
    }

    @ViewBuilder private func leading(_ activity: IslandModel.Activity?) -> some View {
        switch activity {
        case .pomodoro:
            let p = model.pomodoro
            ProgressRing(progress: p.progress, color: p.phase == .rest ? breakColor : focusColor, size: 16, lineWidth: 3).opacity(p.paused ? 0.4 : 1)
        case .meeting:
            PulsingDot(active: model.meeting.phase == .recording)
        case .dictation:
            switch model.dictation.phase {
            case .processing: Image(systemName: "mic.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            case .done: Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.yellow)
            case .starting, .listening: MiniWave(levels: model.dictation.levels)
            case .idle: EmptyView() // on its way out: nothing new flashes up as it fades
            }
        case .toast:
            if let t = model.toast { Image(systemName: t.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.color) }
        case .alarm:
            Image(systemName: "alarm.waves.left.and.right.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                .symbolEffect(.bounce, options: .repeating)
        case .stopwatch:
            Image(systemName: "stopwatch.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
        case .timer:
            let t = Timers.shared
            ProgressRing(progress: t.next?.progress(t.now) ?? 0, color: .orange, size: 16, lineWidth: 3)
        case .media:
            AlbumArt(image: NowPlaying.shared.artwork, missing: NowPlaying.shared.artMissing)
        case .event:
            Image(systemName: "calendar").font(.system(size: 13, weight: .semibold)).foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func compactTrailing(_ a: IslandModel.Activity?) -> some View {
        switch a {
        case .pomodoro, .meeting, .timer, .stopwatch, .media, .event: trailing(a)
        case .dictation:
            switch model.dictation.phase {
            case .processing: PolishSpinner(size: 14, line: 2).frame(width: 16, height: 16)
            case .starting, .listening:
                // Yellow and crossed out while nothing comes in from the microphone.
                let d = model.dictation
                Image(systemName: d.noSound ? "mic.slash.fill" : d.handsFree ? "lock.fill" : d.mode == .command ? "wand.and.stars" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(d.noSound ? Color.yellow : .white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            default: EmptyView()
            }
        case .toast where model.toast?.note == true: trailing(a)
        default: EmptyView()
        }
    }

    @ViewBuilder private func trailing(_ activity: IslandModel.Activity?) -> some View {
        switch activity {
        case .pomodoro:
            let p = model.pomodoro
            Text(p.clock)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(p.paused ? 0.6 : 1))
                .rolling(p.clock, down: true)
        case .meeting:
            Text(model.meeting.clock).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white).rolling(model.meeting.clock)
        case .dictation:
            switch model.dictation.phase {
            case .done(let msg): Text(msg).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            case .processing: PolishSpinner(size: 14, line: 2).frame(width: 16, height: 16)
            case .failed: Text("Couldn't dictate").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            default: Image(systemName: model.dictation.mode == .command ? "wand.and.stars" : "mic.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
        case .toast:
            if let t = model.toast { Text(t.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1) }
        case .alarm:
            Text(Alarms.shared.ringing.map { $0.label.isEmpty ? $0.time : $0.label } ?? "").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
        case .stopwatch:
            let s = Stopwatches.shared
            let clock = Stopwatch.format(s.running.first?.elapsed(s.now) ?? 0, hundredths: false)
            Text(clock).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white).rolling(clock)
        case .timer:
            let t = Timers.shared
            let clock = t.next.map { Pomodoro.clock($0.remaining(t.now)) } ?? ""
            Text(clock).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white).rolling(clock, down: true)
        case .media:
            EqualizerBars(playing: NowPlaying.shared.playing, color: ArtTint.color(NowPlaying.shared.artwork))
        case .event:
            let c = CalendarEvents.shared
            Text(c.upcoming?.countdown(c.now) ?? "").font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        case nil:
            EmptyView()
        }
    }

    // MARK: Expanded: details and controls

    @ViewBuilder private var expanded: some View {
        let slots = model.slots
        Group {
            if model.camera {
                CameraView()
                    .frame(height: model.cameraHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                // The first thing, with the rest as tiles beside it: the notch grows wider before it grows taller.
                HStack(alignment: .center, spacing: IslandGeometry.gap) {
                    if let first = slots.first {
                        detail(first)
                            .frame(width: model.mainWidth)
                            .offset(x: first == .media ? model.pull.width : 0)
                            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.08)), removal: .opacity.animation(.easeOut(duration: 0.1))))
                    } else {
                        // Something starting from here (dictation from its button) takes over without the two overlapping.
                        idleHome.frame(width: model.mainWidth)
                            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.08)), removal: .opacity.animation(.easeOut(duration: 0.1))))
                    }
                    if !model.tiles.isEmpty { tileGrid }
                }
                .transition(.opacity)
            }
        }
        .animation(islandSpring, value: slots)
        .padding(.horizontal, model.sideInset)
        .padding(.top, model.contentTop)
        .padding(.bottom, IslandModel.expandedInset)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) { band.padding(.top, model.bandTop) }
    }

    /// Nothing running: the time and date with what's next today, the weather, and on the button lane four quick starts
    /// (dictate, record a meeting, a timer, the clipboard). With Music or Spotify open but stopped, the last song, to
    /// play again. As tall as the player.
    private var idleHome: some View {
        let b = Self.rowButton
        let app = NSApp.delegate as? AppDelegate
        let weather = BandData.shared.weather
        return VStack(alignment: .leading, spacing: 0) {
            TimelineView(.everyMinute) { ctx in
                HStack(alignment: .center, spacing: 12) {
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        if let e = BandData.nextToday {
                            HStack(spacing: 6) {
                                Circle().fill(Color(nsColor: e.color)).frame(width: 7, height: 7)
                                Text(e.title).foregroundStyle(.white.opacity(0.85))
                                Text(e.start > ctx.date ? e.start.formatted(date: .omitted, time: .shortened) : "Now").foregroundStyle(.white.opacity(0.55))
                            }
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if let w = weather {
                        VStack(alignment: .trailing, spacing: 1) {
                            HStack(spacing: 6) {
                                Image(systemName: w.symbol).font(.system(size: 15, weight: .medium))
                                Text("\(w.temp)°").font(.system(size: 20, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            Text("\(w.hi)° / \(w.lo)°").font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                        }
                        .transition(.opacity)
                    }
                }
            }
            .frame(height: 44)
            Spacer(minLength: 0)
            HStack(spacing: IslandGeometry.gap) {
                if let last = NowPlaying.shared.last { lastSong(last) }
                Spacer(minLength: 0)
                RoundButton(symbol: "mic.fill", tint: nil, size: b) { model.dictation.startHandsFree() }.help("Dictate")
                RoundButton(symbol: "record.circle", tint: nil, size: b) {
                    let m = model.meeting
                    if !m.isRunning, m.phase != .summarizing { m.reset(); m.start() }
                    app?.showMeetingWindow()
                }
                .help("Record a Meeting")
                RoundButton(symbol: "timer", tint: nil, size: b) { model.collapse(); app?.launcher.show(.timer) }.help("Timer")
                RoundButton(symbol: "doc.on.clipboard", tint: nil, size: b) { model.collapse(); app?.launcher.show(.clipboard) }.help("Clipboard")
            }
            .frame(height: b)
        }
        .frame(height: Self.artBig)
        .animation(.easeOut(duration: 0.25), value: weather?.temp)
        .onAppear { BandData.shared.watch(.weather, true) }
        .onDisappear { BandData.shared.watch(.weather, false) }
    }

    /// The song from before the player stopped: its art (tap to play it again) and its name.
    private func lastSong(_ s: NowPlaying.Last) -> some View {
        Button { NowPlaying.shared.play(s) } label: {
            HStack(spacing: 10) {
                AlbumArt(image: s.artwork)
                    .frame(width: Self.rowButton, height: Self.rowButton)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.4))
                        Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    Text(s.artist).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("Play in \(s.appID == "com.spotify.client" ? "Spotify" : "Music")")
    }

    /// The tiles beside the first thing, two to a column. Tap one to bring it to the front (with all its controls).
    private var tileGrid: some View {
        let tiles = model.tiles, rows = model.tileRows
        let w = IslandGeometry.tileWidth, h = IslandGeometry.tileHeight, gap = IslandGeometry.gap
        return ZStack(alignment: .topLeading) {
            ForEach(Array(tiles.prefix(rows * IslandGeometry.maxColumns).enumerated()), id: \.element) { k, slot in
                tile(slot)
                    .contentShape(RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous))
                    .onTapGesture { withAnimation(islandSpring) { model.focus = slot } }
                    .padding(.leading, CGFloat(k / rows) * (w + gap))
                    .padding(.top, CGFloat(k % rows) * (h + gap))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(width: CGFloat(model.tileColumns) * (w + gap) - gap, height: model.tilesHeight, alignment: .topLeading)
    }

    /// The band beside the notch, at menu-bar height: the glances from Settings left of the notch and the settings and
    /// camera buttons right of it; while dictating, the waveform (a spinner while it polishes) and the mic in the same
    /// two lanes, crossing over in place. Each lane stops well short of the camera housing.
    private var band: some View {
        let lane = model.bandLane
        let dictating = model.dictationInStrip
        let d = model.dictation
        let polishing = d.phase == .processing
        return HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if !dictating {
                    HStack(spacing: IslandModel.bandGap) {
                        ForEach(model.bandItems) { BandGlance(item: $0) }
                    }
                    .transition(.opacity)
                } else if polishing {
                    PolishSpinner().transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Waveform(levels: Array(d.levels.suffix(Int((lane + 2.5) / 5.5))), active: d.phase == .listening)
                        .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                }
            }
            .frame(width: lane, alignment: .leading)
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                if !dictating {
                    HStack(spacing: IslandGeometry.gap) {
                        RoundButton(symbol: "gearshape", tint: nil, size: Self.rowButton) {
                            model.collapse()
                            (NSApp.delegate as? AppDelegate)?.showSettings(pane: .notch)
                        }
                        .help("Settings")
                        if CameraMirror.available {
                            RoundButton(symbol: model.camera ? "web.camera.fill" : "web.camera", tint: model.camera ? .white : nil, size: Self.rowButton) {
                                withAnimation(islandSpring) { model.camera.toggle() }
                            }
                            .help(model.camera ? "Close Mirror" : "Mirror")
                        }
                    }
                    .transition(.opacity)
                } else if !polishing {
                    // Yellow and crossed out while nothing comes in from the microphone.
                    Image(systemName: d.noSound ? "mic.slash.fill" : d.mode == .command ? "wand.and.stars" : "mic.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(d.noSound ? Color.yellow : .white.opacity(0.85))
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.opacity)
                }
            }
            .frame(width: lane, alignment: .trailing)
        }
        .animation(.easeInOut(duration: 0.22), value: dictating)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: polishing)
        .padding(.horizontal, model.sideInset)
        .frame(height: model.bandHeight)
    }

    @ViewBuilder private func detail(_ slot: IslandModel.Slot) -> some View {
        switch slot {
        case .media: mediaDetail
        case .timer(let id): timerDetail(id)
        case .stopwatch(let id): stopwatchDetail(id)
        case .alarm: alarmDetail
        case .toast: toastDetail
        case .dictation: dictationDetail
        case .pomodoro: HStack(alignment: .top, spacing: 12) { spot(slot, size: 24).padding(.top, 2); pomodoroDetail }
        case .meeting: HStack(alignment: .top, spacing: 12) { spot(slot, size: 24).padding(.top, 2); meetingDetail }
        case .event: AnyView(eventDetail) // spelled out: inferred, it trips the compiler's opaque-type check with the swipe offset
        }
    }

    private var pomodoroDetail: some View {
        let p = model.pomodoro
        let color = p.phase == .rest ? breakColor : focusColor
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.status).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.paused ? Color.white.opacity(0.55) : color)
                    Text(p.clock)
                        .font(.system(size: 40, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(p.paused ? 0.65 : 1))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .rolling(p.clock, down: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    RoundButton(symbol: p.paused ? "play.fill" : "pause.fill", tint: color) { p.toggle() }
                    RoundButton(symbol: "forward.end.fill", tint: nil) { p.skip() }
                    RoundButton(symbol: "xmark", tint: nil) { p.stop() }
                }
            }
            bar(p.progress, color.opacity(p.paused ? 0.45 : 1))
        }
    }

    private var meetingDetail: some View {
        let m = model.meeting
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        PulsingDot(active: m.phase == .recording)
                        Text(m.phase == .paused ? "Meeting paused" : "Recording meeting").font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
                    }
                    Text(m.clock).font(.system(size: 40, weight: .semibold).monospacedDigit()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6).rolling(m.clock)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    RoundButton(symbol: m.phase == .paused ? "play.fill" : "pause.fill", tint: .red) { m.togglePause() }
                    RoundButton(symbol: "text.alignleft", tint: nil) { openMeeting() }
                    RoundButton(symbol: "stop.fill", tint: nil) { m.stop() }
                }
            }
            Text(m.lines.last?.text ?? "Listening…")
                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The words never show: hands-free, the cancel and finish buttons; a failure, what went wrong. (The waveform is
    /// in the band beside the notch.)
    private var dictationDetail: some View {
        let d = model.dictation
        return HStack(spacing: 12) {
            if case .failed(let msg) = d.phase {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(msg).font(.system(size: 13)).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
            }
            Spacer(minLength: 0)
            if model.dictationControls {
                HStack(spacing: 8) {
                    RoundButton(symbol: "xmark", tint: nil, size: Self.rowButton) { d.cancel() }.help("Cancel")
                    RoundButton(symbol: "stop.fill", tint: focusColor, size: Self.rowButton) { d.stop() }.help("Finish and paste")
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: model.dictationControls)
    }

    private var alarmDetail: some View {
        let a = Alarms.shared
        return HStack(spacing: 12) {
            spot(.alarm, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.ringing?.label.isEmpty == false ? a.ringing!.label : "Alarm").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(a.ringing?.time ?? "").font(.system(size: 26, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
            }
            Spacer(minLength: 0)
            RoundButton(symbol: "zzz", tint: nil) { a.snooze() }
            RoundButton(symbol: "stop.fill", tint: .orange) { a.dismiss() }
        }
    }

    @ViewBuilder private func stopwatchDetail(_ id: UUID) -> some View {
        let s = Stopwatches.shared
        if let w = s.list.first(where: { $0.id == id }) {
            HStack(spacing: 12) {
                spot(.stopwatch(id), size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(w.laps.isEmpty ? "Stopwatch" : "Stopwatch · lap \(w.laps.count + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                    Text(Stopwatch.format(w.elapsed(s.now))).font(.system(size: 34, weight: .semibold).monospacedDigit()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
                RoundButton(symbol: "flag.fill", tint: nil) { s.lap(w) }
                RoundButton(symbol: w.running ? "pause.fill" : "play.fill", tint: .orange) { s.toggle(w) }
            }
        }
    }

    @ViewBuilder private func timerDetail(_ id: UUID) -> some View {
        let t = Timers.shared
        if let n = t.list.first(where: { $0.id == id }) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    spot(.timer(id), size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(n.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange).lineLimit(1)
                        let clock = Pomodoro.clock(n.remaining(t.now))
                        Text(clock).font(.system(size: 34, weight: .semibold).monospacedDigit()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6).rolling(clock, down: true)
                    }
                    Spacer(minLength: 0)
                    RoundButton(symbol: "goforward.60", tint: nil) { t.extend(n, 60) }
                    RoundButton(symbol: n.paused ? "play.fill" : "pause.fill", tint: .orange) { t.toggle(n) }
                    RoundButton(symbol: "xmark", tint: nil) { t.remove(n) }
                }
                bar(n.progress(t.now), .orange)
            }
        }
    }

    /// The open player. Its usual face: big art on the left; beside it the song, the time, and the controls centred under
    /// them (the lyrics button at the end of the lane). Its lyrics face, a little taller: the art shrinks into a header
    /// with the song and the controls, and the lines being sung fill the space below.
    private var mediaDetail: some View {
        // One set of views in both faces: switching only moves and resizes them (the art shrinks into the header, the
        // song slides beside it, the buttons rise to the header's end), while the time and visualizer fade out and the
        // lines fade in. Swapping two separate layouts made the song show twice and the art jump mid-way.
        let m = NowPlaying.shared
        let on = model.lyricsFace
        let w = model.mainWidth, b = Self.rowButton, gap: CGFloat = 14, big = Self.artBig
        let artSize = on ? b : big
        let textX = artSize + gap
        let trioWidth = 3 * b + 2 * gap
        let trioX = on ? w - b - gap - trioWidth : textX + (w - textX - trioWidth) / 2
        let rowY = on ? 0 : big - b
        let titleWidth = max(0, on ? trioX - gap - textX : w - textX - 24)
        let tint = ArtTint.color(m.artwork)
        return ZStack(alignment: .topLeading) {
            // Under everything, so lines still fading out never draw over the art growing back.
            if on {
                LyricLines(lyrics: Lyrics.shared, tint: tint, live: model.contentVisible)
                    .id(Lyrics.shared.version) // each song's lines start at their own top
                    .frame(width: w, height: Self.lyricsHeight - b - 10, alignment: .topLeading)
                    .offset(y: b + 10)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                            removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
            // The art itself flies over everything (`flyingIcons`); this is its spot, and opens the player.
            spot(.media, size: artSize)
                .contentShape(Rectangle())
                .onTapGesture { m.openPlayer() }
                .help("Open \(m.appName)")
            VStack(alignment: .leading, spacing: 1) {
                Marquee(text: m.songTitle, font: .system(size: 15, weight: .semibold), color: .white)
                Marquee(text: m.artistLine, font: .system(size: 12.5), color: .white.opacity(0.6))
            }
            .frame(width: titleWidth, alignment: .leading)
            .offset(x: textX)
            EqualizerBars(playing: m.playing && !on, color: tint) // hidden on the lyrics face: resting, not animating
                .frame(width: w - textX, alignment: .trailing)
                .offset(x: textX, y: 2)
                .opacity(on ? 0 : 1)
            if m.duration > 0 {
                PlayerTimeline(m: m)
                    .frame(width: w - textX, height: 14)
                    .offset(x: textX, y: (35 + big - b) / 2 - 7) // centred between the song and the buttons
                    .opacity(on ? 0 : 1)
                    .allowsHitTesting(!on)
            }
            HStack(spacing: gap) {
                RoundButton(symbol: "backward.fill", tint: nil, size: b) { m.previous() }
                RoundButton(symbol: m.playing ? "pause.fill" : "play.fill", tint: .pink, size: b) { m.playPause() }
                RoundButton(symbol: "forward.fill", tint: nil, size: b) { m.next() }
            }
            .offset(x: trioX, y: rowY)
            if Lyrics.shared.hasLines { lyricsButton.offset(x: w - b, y: rowY) }
        }
        .frame(width: w, height: on ? Self.lyricsHeight : big, alignment: .topLeading)
        .animation(islandSpring, value: on)
    }

    private var lyricsButton: some View {
        let on = model.lyricsFace
        return RoundButton(symbol: on ? "quote.bubble.fill" : "quote.bubble", tint: on ? .white : nil, size: Self.rowButton,
                           breathing: NowPlaying.shared.playing && !on) { // the face it opens is already up
            withAnimation(islandSpring) {
                if model.lyricsOverride != nil { model.lyricsOverride?.toggle() } else { Store.shared.settings.notchLyricsOpen.toggle() }
            }
        }
        .help(on ? "Hide Lyrics" : "Show Lyrics")
    }

    /// The open player's art, as tall as the song, time and controls beside it.
    static let artBig: CGFloat = 92
    /// The lyrics face, taller than the player so the line being sung (wrapped if it's long) and the next ones fit.
    static let lyricsHeight: CGFloat = 148

    static func songClock(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The next event: its title, time and calendar, with Join (when it has a call link) and dismiss.
    @ViewBuilder private var eventDetail: some View {
        let c = CalendarEvents.shared
        if let e = c.upcoming {
            HStack(spacing: 12) {
                spot(.event, size: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: e.color)).frame(width: 7, height: 7)
                        Text(e.timeRange + " · " + (e.start > c.now ? "in " : "") + e.countdown(c.now)).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if e.link != nil { RoundButton(symbol: "video.fill", tint: .green) { c.join(e) }.help("Join") }
                // Offered, never automatic: notes for this event (its title and attendees).
                if !model.meeting.isRunning, model.meeting.phase != .summarizing {
                    RoundButton(symbol: "record.circle", tint: .red) {
                        model.meeting.reset()
                        model.meeting.start(event: e)
                    }
                    .help("Take notes")
                }
                RoundButton(symbol: "xmark", tint: nil) { c.dismiss(e) }.help("Dismiss")
            }
        }
    }

    private var toastDetail: some View {
        HStack(spacing: 12) {
            if let t = model.toast {
                spot(.toast, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    if !t.detail.isEmpty { Text(t.detail).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(2) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The 32 pt round buttons everywhere in the open notch except the first thing's own big ones.
    static let rowButton: CGFloat = 32
    /// A tile's inset: the same on every side ((tile height − button) / 2).
    static let rowPad: CGFloat = (IslandGeometry.tileHeight - rowButton) / 2
    /// Tiles and the camera: concentric with the round buttons `rowPad` in from the edge.
    static let cardRadius: CGFloat = rowButton / 2 + rowPad

    /// A tile beside the first thing: its icon, its time (and what it is), and its one control.
    private func tile(_ slot: IslandModel.Slot) -> some View {
        HStack(spacing: 8) {
            // In a button-sized slot, so the icon sits as far in as the button on the other side.
            spot(slot, size: 20).frame(width: Self.rowButton, height: Self.rowButton)
            tileText(slot).frame(maxWidth: .infinity, alignment: .leading)
            tileButton(slot)
        }
        .padding(.horizontal, Self.rowPad)
        .frame(width: IslandGeometry.tileWidth, height: IslandGeometry.tileHeight)
        .background(RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    /// A tile's value (a time, the song) over what it is, when that says more than the icon.
    @ViewBuilder private func tileText(_ slot: IslandModel.Slot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch slot {
            case .timer(let id):
                let t = Timers.shared
                if let n = t.list.first(where: { $0.id == id }) {
                    let clock = Pomodoro.clock(n.remaining(t.now))
                    Text(clock).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(n.paused ? 0.6 : 1)).rolling(clock, down: true)
                    caption(n.name)
                }
            case .stopwatch(let id):
                let s = Stopwatches.shared
                if let w = s.list.first(where: { $0.id == id }) {
                    let clock = Stopwatch.format(w.elapsed(s.now), hundredths: false)
                    Text(clock).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white).rolling(clock)
                }
            case .pomodoro:
                trailing(.pomodoro)
                caption(model.pomodoro.status)
            case .event:
                trailing(.event)
                caption(CalendarEvents.shared.upcoming?.title ?? "")
            case .media:
                let m = NowPlaying.shared
                Marquee(text: m.songTitle, font: .system(size: 12.5, weight: .semibold), color: .white)
                caption(m.artistLine)
            case .dictation:
                Text("Listening").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            case .toast:
                trailing(.toast)
                caption(model.toast?.detail ?? "")
            case .alarm: trailing(.alarm)
            case .meeting: trailing(.meeting)
            }
        }
    }

    @ViewBuilder private func caption(_ s: String) -> some View {
        if !s.isEmpty { Text(s).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1) }
    }

    /// A tile's one control (the rest are a tap away, with the tile at the front).
    @ViewBuilder private func tileButton(_ slot: IslandModel.Slot) -> some View {
        let b = Self.rowButton
        switch slot {
        case .timer(let id):
            let t = Timers.shared
            if let n = t.list.first(where: { $0.id == id }) { RoundButton(symbol: n.paused ? "play.fill" : "pause.fill", tint: nil, size: b) { t.toggle(n) } }
        case .stopwatch(let id):
            let s = Stopwatches.shared
            if let w = s.list.first(where: { $0.id == id }) { RoundButton(symbol: w.running ? "pause.fill" : "play.fill", tint: nil, size: b) { s.toggle(w) } }
        case .pomodoro:
            RoundButton(symbol: model.pomodoro.paused ? "play.fill" : "pause.fill", tint: nil, size: b) { model.pomodoro.toggle() }
        case .meeting:
            RoundButton(symbol: "stop.fill", tint: .red, size: b) { model.meeting.stop() }
        case .media:
            RoundButton(symbol: NowPlaying.shared.playing ? "pause.fill" : "play.fill", tint: nil, size: b) { NowPlaying.shared.playPause() }
        case .event:
            let c = CalendarEvents.shared
            if let e = c.upcoming {
                if e.link != nil { RoundButton(symbol: "video.fill", tint: .green, size: b) { c.join(e) }.help("Join") }
                else { RoundButton(symbol: "xmark", tint: nil, size: b) { c.dismiss(e) }.help("Dismiss") }
            }
        case .alarm:
            RoundButton(symbol: "stop.fill", tint: .orange, size: b) { Alarms.shared.dismiss() }
        case .toast, .dictation:
            EmptyView()
        }
    }

    private func bar(_ progress: Double, _ color: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(color).frame(width: max(4, proxy.size.width * progress))
            }
        }
        .frame(height: 4)
    }
}

/// One line that scrolls sideways when it's too long to fit (pausing at the start of each pass), with soft edges.
struct Marquee: View {
    let text: String
    let font: Font
    var color: Color = .primary
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var start = Date()

    private static let gap: CGFloat = 36
    private static let speed: CGFloat = 28 // points a second
    private static let pause = 1.6

    var body: some View {
        let overflow = textWidth > boxWidth + 1
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .background {
                Text(text).font(font).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !overflow)) { ctx in
                    let cycle = textWidth + Self.gap
                    let period = Double(cycle / Self.speed) + Self.pause
                    let t = ctx.date.timeIntervalSince(start).truncatingRemainder(dividingBy: max(period, 0.1))
                    let x = overflow && t > Self.pause ? -CGFloat(t - Self.pause) * Self.speed : 0
                    HStack(spacing: Self.gap) {
                        Text(text).font(font).foregroundStyle(color).fixedSize()
                        if overflow { Text(text).font(font).foregroundStyle(color).fixedSize() }
                    }
                    .offset(x: x)
                    .frame(width: boxWidth, alignment: .leading)
                    .clipped()
                    .mask {
                        // The far edge fades while there's more to come; the near one only once it's moving.
                        if overflow {
                            LinearGradient(stops: [.init(color: x < 0 ? .clear : .black, location: 0), .init(color: .black, location: 0.06),
                                                   .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                           startPoint: .leading, endPoint: .trailing)
                        } else {
                            Color.black
                        }
                    }
                }
                .frame(width: boxWidth, alignment: .leading)
            }
            .onChange(of: text) { _, _ in start = Date() }
    }
}

/// Album art as a square, whatever shape the picture is (it's cropped to fill), its corners in step with its size so it
/// can grow from the closed notch into the player. A new cover fades in over the last one with a slight settle; the
/// note shows only for a song known to have none.
private struct AlbumArt: View {
    let image: NSImage?
    var missing = true
    /// The cover being replaced, held under the new one until it has faded in.
    @State private var under: NSImage?

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let shape = RoundedRectangle(cornerRadius: min(12, side / 4), style: .continuous)
            ZStack {
                shape.fill(Color.white.opacity(image == nil ? 0.12 : 0))
                if let under { picture(under, side) }
                if let image {
                    picture(image, side)
                        .id(ObjectIdentifier(image))
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.08)), removal: .opacity))
                } else if missing {
                    Image(systemName: "music.note").font(.system(size: side * 0.36, weight: .bold)).foregroundStyle(.pink)
                        .transition(.opacity)
                }
            }
            .frame(width: side, height: side)
            .clipShape(shape)
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.easeInOut(duration: 0.45), value: image)
        .onChange(of: image) { old, new in
            guard let old, new != nil else { return }
            under = old
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if under === old { under = nil } }
        }
    }

    private func picture(_ i: NSImage, _ side: CGFloat) -> some View {
        Image(nsImage: i).resizable().scaledToFill().frame(width: side, height: side)
    }
}

/// The open player's time: elapsed, the bar, and what's left. Click or drag the bar to go anywhere in the song; it
/// moves at once and the player follows.
private struct PlayerTimeline: View {
    let m: NowPlaying
    /// Where the bar is being held (0…1) while dragging.
    @State private var held: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let at = held.map { $0 * m.duration } ?? min(m.livePosition, m.duration)
            HStack(spacing: 8) {
                Text(IslandView.songClock(at)).frame(width: 34, alignment: .leading)
                GeometryReader { g in
                    let p = m.duration > 0 ? at / m.duration : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule().fill(Color.white.opacity(held == nil ? 0.85 : 1)).frame(width: max(4, g.size.width * p))
                    }
                    .frame(height: held == nil ? 4 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in held = min(1, max(0, v.location.x / max(1, g.size.width))) }
                        .onEnded { v in
                            m.seek(to: min(1, max(0, v.location.x / max(1, g.size.width))) * m.duration)
                            held = nil
                        })
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: held == nil)
                }
                Text("-" + IslandView.songClock(m.duration - at)).frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// A little equalizer beside the notch while music plays, in the album art's colour; resting while paused. Core
/// Animation moves the bars (a made-up level five times a second, eased, on an 8 s loop), so the app does no work per
/// frame for it.
private struct EqualizerBars: NSViewRepresentable {
    let playing: Bool
    var color: Color = .pink

    func makeNSView(context: Context) -> Bars { Bars() }
    func updateNSView(_ view: Bars, context: Context) { view.show(playing: playing, color: NSColor(color).cgColor) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Bars, context: Context) -> CGSize? { CGSize(width: IslandModel.artSize, height: 18) }

    final class Bars: NSView {
        private let bars = (0..<4).map { _ in CALayer() }
        private var playing: Bool?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for b in bars {
                b.cornerRadius = 1.5
                layer?.addSublayer(b)
            }
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, b) in bars.enumerated() { b.position = CGPoint(x: bounds.midX + (CGFloat(i) - 1.5) * 5.5, y: bounds.midY) }
            CATransaction.commit()
        }

        func show(playing: Bool, color: CGColor) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.45) // in step with the cover fading to the next song's
            for b in bars {
                b.backgroundColor = color
                b.opacity = playing ? 1 : 0.5
            }
            CATransaction.commit()
            guard playing != self.playing else { return }
            self.playing = playing
            for (i, b) in bars.enumerated() {
                b.removeAnimation(forKey: "level")
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.4)
                b.bounds = CGRect(x: 0, y: 0, width: 3, height: playing ? Self.height(i, 0) : 3)
                CATransaction.commit()
                guard playing else { continue }
                let a = CAKeyframeAnimation(keyPath: "bounds.size.height")
                a.values = (0...40).map { Self.height(i, $0 % 40) }
                a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 40)
                a.duration = 8
                a.repeatCount = .infinity
                a.beginTime = CACurrentMediaTime() + 0.4
                b.add(a, forKey: "level")
            }
        }

        /// A made-up height for a bar at a tick, never the same twice in a row by much: the middle bars run higher.
        private static func height(_ bar: Int, _ tick: Int) -> CGFloat {
            var h = UInt64(truncatingIfNeeded: tick &* 4 &+ bar) &* 0x9E37_79B9_7F4A_7C15
            h ^= h >> 29
            let r = CGFloat(h % 1000) / 1000
            return 4 + 12 * ((bar == 1 || bar == 2 ? 0.35 : 0.15) + r * (bar == 1 || bar == 2 ? 0.65 : 0.6))
        }
    }
}

/// The album art's colour for the visualizer: its colourful, bright parts count most, lifted so it reads on black.
/// Grey art gets near-white bars, and no art the music pink.
@MainActor enum ArtTint {
    private static var last: (art: ObjectIdentifier, color: Color)?

    static func color(_ image: NSImage?) -> Color {
        guard let image else { return .pink }
        if let last, last.art == ObjectIdentifier(image) { return last.color }
        let c = average(image) ?? .pink
        last = (ObjectIdentifier(image), c)
        return c
    }

    private static func average(_ image: NSImage) -> Color? {
        let n = 12
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: n * n * 4) else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in 0..<(n * n) {
            let pr = Double(data[i * 4]) / 255, pg = Double(data[i * 4 + 1]) / 255, pb = Double(data[i * 4 + 2]) / 255
            let hi = max(pr, pg, pb), lo = min(pr, pg, pb)
            let w = 0.1 + (hi > 0 ? (hi - lo) / hi : 0) * hi
            r += pr * w; g += pg * w; b += pb * w; total += w
        }
        guard total > 0, let c = NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1).usingColorSpace(.sRGB) else { return nil }
        if c.saturationComponent < 0.12 { return Color(white: 0.85) }
        return Color(hue: c.hueComponent, saturation: min(0.85, max(0.45, c.saturationComponent)), brightness: max(0.85, c.brightnessComponent))
    }
}

private extension View {
    /// Digits roll to their new value instead of swapping.
    func rolling(_ value: String, down: Bool = false) -> some View {
        contentTransition(.numericText(countsDown: down)).animation(.spring(response: 0.35, dampingFraction: 0.85), value: value)
    }
}

/// Five bars that fit beside the notch.
/// Polishing: a bright arc chasing round.
private struct PolishSpinner: View {
    var size: CGFloat = 20
    var line: CGFloat = 2.5

    var body: some View {
        TimelineView(.animation) { ctx in
            let turn = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(AngularGradient(colors: [.white.opacity(0), .white], center: .center, startAngle: .degrees(0), endAngle: .degrees(260)),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: size, height: size)
    }
}

private struct MiniWave: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let l = levels.isEmpty ? 0 : levels[max(0, levels.count - 1 - i * 2)]
                Capsule().fill(.white).frame(width: 2, height: 3 + CGFloat(l) * 12) // five bars and their gaps fill the 18 pt icon slot
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.08), value: levels)
    }
}
