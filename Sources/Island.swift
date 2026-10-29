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

    /// Room for up to four activities side by side (compact) or stacked (expanded).
    var panelSize: CGSize { CGSize(width: max(expandedSize.width, compactSize.width + 460) + 48, height: expandedSize.height + CGFloat(IslandGeometry.maxRows) * IslandGeometry.rowHeight + topInset + 24) }
    static let rowHeight: CGFloat = 52
    static let maxRows = 5
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
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return IslandGeometry(hasNotch: false, notchHeight: 32, screenFrame: frame, centerX: frame.midX, topInset: 5,
                              seedSize: CGSize(width: 64, height: 32), compactSize: CGSize(width: 190, height: 32),
                              expandedSize: CGSize(width: 380, height: 124))
    }
}

let islandSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)
/// For shrinking: no overshoot, so the shape never dips below the physical notch and bounces back.
let islandSettle = Animation.spring(response: 0.38, dampingFraction: 1)

@MainActor @Observable final class IslandModel {
    enum Activity: Equatable { case alarm, dictation, toast, meeting, pomodoro, timer, stopwatch, media }

    var stage = IslandStage.hidden { didSet { if stage != oldValue { onStage?(stage) } } }
    var contentVisible = false
    var hovering = false
    var geometry = IslandGeometry.current()
    /// A passing message. A `note` shows its words in the closed notch too (otherwise it's just its icon there).
    var toast: (title: String, detail: String, symbol: String, color: Color, note: Bool)?
    /// Everything happening now, most urgent first. The notch widens for each one.
    var activities: [Activity] = []
    var activity: Activity? { activities.first }

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

    static func kind(_ a: Activity) -> NotchKind? {
        switch a {
        case .media: .media
        case .timer: .timer
        case .meeting: .meeting
        case .pomodoro: .focus
        case .stopwatch: .stopwatch
        case .toast: .message
        case .alarm, .dictation: nil
        }
    }

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
        }
    }

    /// Moves something to the front of the closed notch (and remembers it for this mix of activities).
    func promote(_ slot: Slot) {
        var order = compactOrder
        order.removeAll { $0 == slot }
        order.insert(slot, at: 0)
        saveArrangement(order)
    }

    /// Remembers the order of what's in the notch for this mix of activities (say music and two timers), so the
    /// same mix comes back the same way.
    func saveArrangement(_ order: [Slot]) {
        Store.shared.settings.notchArrangements[comboKey] = order.map(token)
        refresh()
    }

    /// Whether this mix has an order you dragged into place.
    var hasArrangement: Bool { Store.shared.settings.notchArrangements[comboKey] != nil }

    /// Back to the default order for this mix.
    func resetArrangement() {
        Store.shared.settings.notchArrangements[comboKey] = nil
        refresh()
    }

    /// A name for a slot that holds while it runs: timers and stopwatches by their place (soonest timer first).
    func token(_ slot: Slot) -> String {
        switch slot {
        case .timer(let id):
            let t = Timers.shared
            return "timer#\(t.running.sorted { $0.remaining(t.now) < $1.remaining(t.now) }.firstIndex { $0.id == id } ?? 0)"
        case .stopwatch(let id): return "stopwatch#\(Stopwatches.shared.running.firstIndex { $0.id == id } ?? 0)"
        default: return slot.key
        }
    }

    /// Which mix of activities is going on.
    private var comboKey: String { compactCandidates.map(token).sorted().joined(separator: ",") }

    /// Everything that could sit in the closed notch: alarms and dictation first, then the order from Settings ›
    /// Notch (what's playing first by default), each running timer (soonest first) and stopwatch on its own.
    private var compactCandidates: [Slot] {
        let order = Store.shared.settings.notchPriority
        var out: [Slot] = []
        for a in activities.sorted(by: { rank($0, order) < rank($1, order) }) {
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

    private func rank(_ a: Activity, _ order: [NotchKind]) -> Int {
        switch a {
        case .alarm: return 0
        case .dictation: return 1
        default: return 2 + (Self.kind(a).flatMap { order.firstIndex(of: $0) } ?? 99)
        }
    }

    /// Everything in the notch, in the order the closed notch reads left to right: the order you dragged it into for
    /// this mix, else the default. Alarms and dictation always lead.
    var compactOrder: [Slot] {
        let all = compactCandidates
        guard let saved = Store.shared.settings.notchArrangements[comboKey] else { return all }
        let pinned = all.filter { $0 == .alarm || $0 == .dictation }
        let rest = all.filter { $0 != .alarm && $0 != .dictation }.enumerated()
            .sorted { (saved.firstIndex(of: token($0.element)) ?? 99, $0.offset) < (saved.firstIndex(of: token($1.element)) ?? 99, $1.offset) }
            .map(\.element)
        return pinned + rest
    }

    /// Closed, at most three.
    var compactShown: [Slot] { Array(compactOrder.prefix(Self.compactMax)) }

    /// One thing in the notch: each running timer and stopwatch gets its own.
    enum Slot: Hashable {
        case alarm, dictation, toast, meeting, pomodoro, timer(UUID), stopwatch(UUID), media
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
        case .timer: Timers.shared.next.map { .timer($0.id) } ?? .toast
        case .stopwatch: Stopwatches.shared.running.first.map { .stopwatch($0.id) } ?? .toast
        }
    }

    /// Expanded: playback on top, then everything else in the closed notch's order, every running timer and
    /// stopwatch on its own row.
    var slots: [Slot] {
        var out: [Slot] = activities.contains(.media) ? [.media] : []
        out += compactOrder.filter { $0 != .media && $0 != .dictation }
        // Dictation sits in the strip beside the notch; it only fills the notch when it's all there is.
        if out.isEmpty, activities.contains(.dictation) { out = [.dictation] }
        return Array(out.prefix(IslandGeometry.maxRows + 1))
    }

    /// The live words in the open notch: as tall as they need, up to five lines (then they scroll).
    var dictationTextHeight: CGFloat {
        let w = geometry.expandedSize.width - 2 * (Self.expandedInset + (geometry.hasNotch ? 12 : 0))
        let h = (dictation.preview as NSString).boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude),
                                                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                            attributes: [.font: NSFont.systemFont(ofSize: 14)]).height
        return min(ceil(h) + 2, 92)
    }

    /// Dictation shown in the top strip (beside the notch) of the expanded notch.
    var dictationInStrip: Bool {
        if case .failed = dictation.phase { return slots.first != .dictation }
        return activities.contains(.dictation)
    }

    /// Height of the first item's detail in the expanded notch.
    var detailHeight: CGFloat {
        switch slots.first {
        case .media: NowPlaying.shared.duration > 0 ? 60 : 46
        case .timer: 56
        case .stopwatch: 56
        case .pomodoro: 80
        case .meeting: 90
        case .alarm: 48
        case .toast: 42
        case .dictation:
            if case .failed = dictation.phase { 48 } else { dictation.preview.isEmpty ? 0 : dictationTextHeight }
        case nil: 42
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
        L.text = shown.first { [.timer, .stopwatch, .pomodoro, .meeting].contains(activity(for: $0)) && slotTextWidth($0) > 0 }
            ?? (slotTextWidth(shown[0]) > 0 ? shown[0] : nil)
        L.textWidth = L.text.map(slotTextWidth) ?? 0
        if shown.count == 1 {
            L.left = shown
            L.textApart = L.text != nil
            L.side = max(pad + Self.iconWidth(shown[0]) + gap, L.textApart ? gap + L.textWidth + pad : 0)
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
            // As tall as what it shows: the first item's controls, then a row for each other one.
            let top: CGFloat = geometry.hasNotch ? geometry.notchHeight + 6 : 16 + (dictationInStrip ? 28 : 0)
            let rows = CGFloat(max(0, slots.count - 1)) * IslandGeometry.rowHeight
            return CGSize(width: geometry.expandedSize.width, height: top + detailHeight + rows + Self.expandedInset)
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
        if !s.notchEnabled { list.removeAll() }
        // Alarms and dictation first, then the order from Settings › Notch.
        let order = s.notchPriority
        list.sort { rank($0, order) < rank($1, order) }
        if NowPlaying.shared.playing, Store.shared.settings.mediaInNotch { list.append(.media) }
        if list != activities {
            withAnimation(list.count < activities.count ? islandSettle : islandSpring) { activities = list }
        }
        let next = list.first
        guard next != nil else { return hide() }
        show()
        // Dictation expands on its own once there are words to show; a failure expands to explain itself.
        // Polishing happens in the closed notch: an open one closes when it starts.
        let polishing = dictation.phase == .processing
        if polishing, !wasPolishing { collapse() }
        wasPolishing = polishing
        if next == .dictation, !polishing {
            let wantsRoom: Bool = {
                if case .failed = dictation.phase { return true }
                let listening = [.starting, .listening].contains(dictation.phase)
                return listening && (dictation.handsFree || !dictation.preview.isEmpty)
            }()
            if wantsRoom { expand(haptic: false) } else if stage == .expanded, !hovering { collapse() }
        }
    }

    /// Content starts this far in from the shape's edge (past the 12 pt ears that meet the screen edge).
    static let compactPad: CGFloat = 22
    static let compactMax = 3

    /// Closed, only times (and a few live marks) show as text; everything else is just its icon.
    func compactTrailingWidth(_ a: Activity) -> CGFloat {
        switch a {
        case .pomodoro, .meeting, .timer, .stopwatch, .media: return trailingWidth(a)
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
        case .media: return 18
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

    func show() {
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
        generation += 1
        let current = generation
        guard stage != .hidden else { return }
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
            self.stage = .hidden
        }
    }

    func expand(haptic: Bool = true) {
        guard stage == .compact || stage == .seed else { return }
        if haptic { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        lastInteraction = Date()
        withAnimation(islandSpring) {
            hovering = false
            stage = .expanded
            contentVisible = true
        }
    }

    func collapse() {
        guard stage == .expanded else { return }
        withAnimation(islandSettle) { stage = .compact }
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
}

@MainActor final class IslandController {
    let model: IslandModel
    private let panel: IslandPanel
    private var tracker: Timer?
    private var clickMonitor: Any?
    private var hoverSince: Date?

    init(model: IslandModel, openMeeting: @escaping () -> Void) {
        self.model = model
        panel = IslandPanel(contentRect: model.geometry.panelFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // On every Space but not stationary, so it slides along with the desktop when you swipe between Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
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
    }

    func setSharing(_ hidden: Bool) { panel.sharingType = hidden ? .none : .readOnly }

    private func layout() {
        let g = IslandGeometry.current()
        if g != model.geometry { model.geometry = g }
        panel.setFrame(g.panelFrame, display: true)
    }

    private func stageChanged(_ stage: IslandStage) {
        if stage == .hidden {
            tracker?.invalidate()
            tracker = nil
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        } else if !panel.isVisible {
            layout()
            panel.orderFrontRegardless()
            let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.track() }
            }
            RunLoop.main.add(t, forMode: .common)
            tracker = t
        }
    }

    /// Clicks only land on the island itself; hovering it for a moment expands it.
    private func track() {
        let g = model.geometry
        let size = model.shapeSize
        let k: CGFloat = model.hovering ? 1.05 : 1
        let rect = NSRect(x: g.centerX - size.width * k / 2, y: g.screenFrame.maxY - g.topInset - size.height * k,
                          width: size.width * k, height: size.height * k + g.topInset + 1)
        let interactive = model.stage == .compact || model.stage == .expanded
        let inside = interactive && model.contentVisible && rect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
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
            if inside {
                model.lastInteraction = Date()
            } else if Date().timeIntervalSince(model.lastInteraction) > s.notchCollapseDelay, model.activity != .dictation {
                model.collapse()
            }
        }
    }
}

// MARK: - Views

/// One side of the closed notch, beside the physical notch: the ear curving out along the top of the screen, down the
/// outer edge, round the bottom corner, and straight up where the notch begins. Drawn in a rect the width of the
/// whole closed notch.
struct NotchHalf: Shape {
    enum Side: Hashable { case left, right }
    var side: Side
    var sideWidth: CGFloat
    var ear: CGFloat
    var bottom: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        let e = max(0, min(ear, sideWidth / 3, r.height / 2)), b = max(0, min(bottom, sideWidth / 3, r.height / 2))
        let k: CGFloat = 0.58
        var p = Path()
        func corner(_ from: CGPoint, _ apex: CGPoint, _ to: CGPoint) {
            p.addCurve(to: to, control1: CGPoint(x: from.x + (apex.x - from.x) * k, y: from.y + (apex.y - from.y) * k),
                       control2: CGPoint(x: to.x + (apex.x - to.x) * k, y: to.y + (apex.y - to.y) * k))
        }
        switch side {
        case .left:
            let outer = r.minX, edge = rect.minX + sideWidth
            p.move(to: CGPoint(x: outer, y: r.minY))
            corner(CGPoint(x: outer, y: r.minY), CGPoint(x: outer + e, y: r.minY), CGPoint(x: outer + e, y: r.minY + e))
            p.addLine(to: CGPoint(x: outer + e, y: r.maxY - b))
            corner(CGPoint(x: outer + e, y: r.maxY - b), CGPoint(x: outer + e, y: r.maxY), CGPoint(x: outer + e + b, y: r.maxY))
            p.addLine(to: CGPoint(x: edge, y: r.maxY))
            p.addLine(to: CGPoint(x: edge, y: r.minY))
        case .right:
            let outer = r.maxX, edge = rect.maxX - sideWidth
            p.move(to: CGPoint(x: edge, y: r.minY))
            p.addLine(to: CGPoint(x: edge, y: r.maxY))
            p.addLine(to: CGPoint(x: outer - e - b, y: r.maxY))
            corner(CGPoint(x: outer - e - b, y: r.maxY), CGPoint(x: outer - e, y: r.maxY), CGPoint(x: outer - e, y: r.maxY - b))
            p.addLine(to: CGPoint(x: outer - e, y: r.minY + e))
            corner(CGPoint(x: outer - e, y: r.minY + e), CGPoint(x: outer - e, y: r.minY), CGPoint(x: outer, y: r.minY))
        }
        p.closeSubpath()
        return p
    }
}

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
    var size: CGFloat = 40
    var action: () -> Void

    var body: some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.375, weight: .bold))
                .foregroundStyle(tint ?? .white)
                .contentTransition(.symbolEffect(.replace))
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
    @Namespace private var closedNS
    @Namespace private var previewNS

    private var shape: IslandShape {
        let g = model.geometry
        if g.hasNotch {
            switch model.stage {
            // The bottom corners match the ears where it meets the screen edge, and don't change when it opens.
            case .expanded: return IslandShape(ear: 12, top: 0, bottom: 12)
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
                .frame(width: size.width, height: size.height)
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
                                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)).animation(islandSpring.delay(0.04)),
                                                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)).animation(.easeOut(duration: 0.16))))
                        }
                    }
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .opacity(model.contentVisible ? 1 : 0)
                    .clipShape(shape)
                }
                .contentShape(shape)
                // Size and position follow what's inside: a spring when it opens, no bounce otherwise.
                .animation(model.stage == .expanded ? islandSpring : islandSettle, value: size)
                .onTapGesture { model.expand() }
                .scaleEffect(model.hovering ? 1.05 : 1, anchor: .top)
                .opacity(model.stage == .hidden ? 0 : 1)
                .padding(.top, model.geometry.topInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Compact: something on each side of the notch

    private var compact: some View {
        let g = model.geometry
        return closedContent(model.compactLayout, glide: true)
            .frame(height: g.compactSize.height)
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(islandSettle, value: model.compactLayout.keys)
    }

    /// The closed notch's contents: each side's things read left to right, a time just after its icon. Both
    /// sides are the same width so the notch stays centred. `glide` lets the icons fly to their places in the
    /// open notch; `hole` leaves an empty spot (where a dragged thing would land), `faded` dims one.
    private func closedContent(_ L: IslandModel.CompactLayout, glide: Bool, hole: IslandModel.Slot? = nil, faded: IslandModel.Slot? = nil) -> some View {
        let g = model.geometry
        let pad = g.hasNotch ? IslandModel.compactPad : 10
        return HStack(spacing: 0) {
            HStack(spacing: IslandModel.compactGap) {
                ForEach(L.left, id: \.self) { s in closedItem(s, L, glide: glide, hole: hole, faded: faded) }
            }
            .padding(.leading, pad + (L.left.first == .media ? IslandModel.artInset : 0))
            .frame(width: L.side, alignment: .leading)
            Color.clear.frame(width: g.seedSize.width)
            HStack(spacing: IslandModel.compactGap) {
                if L.textApart, let t = L.text {
                    slotText(t).lineLimit(1).truncationMode(.tail).frame(width: L.textWidth, alignment: .trailing)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
                ForEach(L.right, id: \.self) { s in closedItem(s, L, glide: glide, hole: hole, faded: faded) }
            }
            .padding(.trailing, pad + (L.right.last == .media ? IslandModel.artInset : 0))
            .frame(width: L.side, alignment: .trailing)
        }
    }

    @ViewBuilder private func closedItem(_ s: IslandModel.Slot, _ L: IslandModel.CompactLayout, glide: Bool, hole: IslandModel.Slot?, faded: IslandModel.Slot?) -> some View {
        let w = IslandModel.iconWidth(s)
        HStack(spacing: IslandModel.compactGap) {
            Group {
                if glide { icon(s, size: w) } else { slotIcon(s).frame(width: w, height: w) }
            }
            // The carried icon is about to land in the hole; its time already shows, as it will.
            .opacity(s == hole ? 0 : 1)
            if s == L.text, !L.textApart {
                slotText(s).lineLimit(1).truncationMode(.tail).frame(width: L.textWidth, alignment: .leading)
            }
        }
        .opacity(s == faded ? 0.3 : 1)
        .matchedGeometryEffect(id: s.key, in: glide ? closedNS : previewNS, properties: .position, isSource: true)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    /// A slot's time in the closed notch: each timer and stopwatch its own.
    @ViewBuilder private func slotText(_ s: IslandModel.Slot) -> some View {
        switch s {
        case .timer(let id):
            let t = Timers.shared
            Text(Pomodoro.clock(t.list.first { $0.id == id }?.remaining(t.now) ?? 0))
                .font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        case .stopwatch(let id):
            let w = Stopwatches.shared
            Text(Stopwatch.format(w.list.first { $0.id == id }?.elapsed(w.now) ?? 0, hundredths: false))
                .font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        default: compactTrailing(model.activity(for: s))
        }
    }

    /// A slot's icon. The expanded notch uses the same one, so it glides into place when the notch opens.
    private func icon(_ slot: IslandModel.Slot, size: CGFloat = IslandModel.iconSize) -> some View {
        slotIcon(slot)
            .frame(width: size, height: size)
            .matchedGeometryEffect(id: slot.key, in: ns)
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
            default: MiniWave(levels: model.dictation.levels)
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
            AlbumArt(image: NowPlaying.shared.artwork, corner: 3, note: 11)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func compactTrailing(_ a: IslandModel.Activity?) -> some View {
        switch a {
        case .pomodoro, .meeting, .timer, .stopwatch, .media: trailing(a)
        case .dictation:
            switch model.dictation.phase {
            case .processing: PolishSpinner(size: 14, line: 2).frame(width: 16, height: 16)
            case .starting, .listening:
                Image(systemName: model.dictation.handsFree ? "lock.fill" : model.dictation.mode == .command ? "wand.and.stars" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
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
                .contentTransition(.numericText(countsDown: true))
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: p.clock)
        case .meeting:
            Text(model.meeting.clock).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
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
            Text(Stopwatch.format(s.running.first?.elapsed(s.now) ?? 0, hundredths: false)).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        case .timer:
            let t = Timers.shared
            Text(t.next.map { Pomodoro.clock($0.remaining(t.now)) } ?? "").font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        case .media:
            EqualizerBars(playing: NowPlaying.shared.playing)
        case nil:
            EmptyView()
        }
    }

    // MARK: Expanded: details and controls

    @ViewBuilder private var expanded: some View {
        let g = model.geometry
        let slots = model.slots
        let rows = Array(slots.dropFirst())
        VStack(spacing: 10) {
            if let first = slots.first { detail(first).contextMenu { promoteMenu(first) } }
            // A row carried up toward the preview of the closed notch shrinks, step by step, into its closed-notch
            // icon; near the preview the icons there make room and it glides into the gap, and letting go settles it
            // there (that order is kept for this mix). Let go anywhere else and it slides back into its row.
            ForEach(rows, id: \.self) { slot in
                let dragged = drag?.slot == slot
                ZStack(alignment: .leading) {
                    row(slot).opacity(dragged ? 0 : 1)
                    if dragged, let d = drag, let f = rowFrames[slot.key] { carried(slot, d, f) }
                }
                .zIndex(dragged ? 1 : 0)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames[slot.key] = $0 }
                .contextMenu { promoteMenu(slot) }
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { v in
                        model.lastInteraction = Date()
                        if drag == nil {
                            drag = RowDrag(slot: slot, start: v.startLocation, point: v.location)
                        } else if drag?.settling == false {
                            drag?.point = v.location
                        }
                    }
                    .onEnded { _ in finishDrag() })
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .animation(islandSpring, value: slots)
        .padding(.horizontal, IslandModel.expandedInset + (g.hasNotch ? 12 : 0))
        .padding(.top, g.hasNotch ? g.notchHeight + 6 : 16 + (model.dictationInStrip ? 28 : 0))
        .padding(.bottom, IslandModel.expandedInset)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            if let d = drag, let plan = arrangement() {
                closedPreview(model.layout(for: Array(plan.order.prefix(IslandModel.compactMax))), hole: plan.near ? d.slot : nil, faded: plan.near ? nil : d.slot)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            } else if model.dictationInStrip {
                dictationStrip
            }
        }
        .animation(.spring(duration: 0.25), value: drag == nil)
        .onAppear {
            // `--island-snapshot … --drag`: a row held up by the preview, for the picture.
            guard CommandLine.arguments.contains("--drag") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard let s = model.slots.dropFirst().first, let f = rowFrames[s.key] else { return }
                drag = RowDrag(slot: s, start: CGPoint(x: f.midX, y: f.midY), point: CGPoint(x: f.minX + 30, y: 22))
            }
        }
    }

    /// The closed notch as it would be, drawn where it sits (beside the notch, at menu-bar height), with an
    /// outline on each side of the notch.
    private func closedPreview(_ L: IslandModel.CompactLayout, hole: IslandModel.Slot?, faded: IslandModel.Slot?) -> some View {
        let g = model.geometry
        let height = g.compactSize.height
        return closedContent(L, glide: false, hole: hole, faded: faded)
            .frame(width: g.seedSize.width + L.side * 2, height: height)
            .background {
                // Each side traced exactly as the closed notch will be there: its curved ear at the top of the screen,
                // its rounded bottom corner, straight up the edge of the notch.
                ZStack {
                    ForEach([NotchHalf.Side.left, .right], id: \.self) { side in
                        let half = NotchHalf(side: side, sideWidth: L.side, ear: 12, bottom: 12)
                        half.fill(Color.white.opacity(0.07))
                        half.stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
            }
            .animation(islandSpring, value: L.keys)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { previewFrame = $0 }
            .padding(.top, g.hasNotch ? 0 : 6)
    }

    private struct RowDrag {
        var slot: IslandModel.Slot
        /// Where it was picked up, and where the pointer is now.
        var start: CGPoint
        var point: CGPoint
        /// Let go: on its way into its spot (or back to its row).
        var settling = false
        var landed = false
    }

    /// 0 while it's at its row, 1 at the preview of the closed notch (by height).
    private func progress(_ d: RowDrag, _ f: CGRect) -> CGFloat {
        if d.landed { return 1 }
        guard previewFrame != .zero else { return 0 }
        let t = min(1, max(0, (f.midY - d.point.y) / max(1, f.midY - previewFrame.midY)))
        return t * t * (3 - 2 * t)
    }

    /// The centre of the gap it would fill in the preview.
    private func landing(_ d: RowDrag) -> CGPoint? {
        guard let plan = arrangement(), plan.near else { return nil }
        let L = model.layout(for: Array(plan.order.prefix(IslandModel.compactMax)))
        guard let c = model.centers(L)[d.slot] else { return nil }
        return CGPoint(x: previewFrame.midX - (model.geometry.seedSize.width + L.side * 2) / 2 + c, y: previewFrame.midY)
    }

    /// The row being carried: the row itself, shrinking into its closed-notch icon as it nears the preview.
    private func carried(_ slot: IslandModel.Slot, _ d: RowDrag, _ f: CGRect) -> some View {
        let p = progress(d, f)
        func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        let iconW = IslandModel.iconWidth(slot)
        let w = mix(f.width, iconW, p), h = mix(f.height, iconW, p)
        // From where it was grabbed onto the pointer, then pulled into its gap as it gets close.
        let grabbed = CGPoint(x: f.midX + d.point.x - d.start.x, y: f.midY + d.point.y - d.start.y)
        var c = CGPoint(x: mix(grabbed.x, d.point.x, p), y: mix(grabbed.y, d.point.y, p))
        if let t = landing(d) {
            let pull = d.landed ? 1 : min(1, max(0, (p - 0.55) / 0.45))
            c = CGPoint(x: mix(c.x, t.x, pull), y: mix(c.y, t.y, pull))
        }
        return ZStack(alignment: .leading) {
            row(slot).frame(width: f.width, height: f.height).opacity(Double(max(0, 1 - p * 1.8)))
            slotIcon(slot).frame(width: iconW, height: iconW)
                .frame(width: w, height: h)
                .opacity(Double(min(1, max(0, p * 2.2 - 0.5))))
        }
        .frame(width: w, height: h, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: mix(12, h / 2, p), style: .continuous))
        .shadow(color: .black.opacity(Double(0.5 * (1 - p))), radius: 10, y: 4)
        .offset(x: c.x - f.minX - w / 2, y: c.y - f.midY)
        .allowsHitTesting(false)
    }

    /// The row being carried, and where the pointer is (screen-window coordinates).
    @State private var drag: RowDrag?
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var previewFrame: CGRect = .zero

    /// While carrying a row: the order there'd be if it were let go now. Near the preview, it goes in the spot
    /// closest to the pointer; elsewhere nothing changes.
    private func arrangement() -> (order: [IslandModel.Slot], near: Bool)? {
        guard let d = drag else { return nil }
        let current = model.compactOrder
        guard previewFrame != .zero, d.point.y < previewFrame.maxY + 36 else { return (current, false) }
        let pinned = current.prefix { $0 == .alarm || $0 == .dictation }.count
        var base = current
        base.removeAll { $0 == d.slot }
        let last = min(base.count, IslandModel.compactMax - 1)
        guard pinned <= last else { return (current, false) }
        var best: (order: [IslandModel.Slot], distance: CGFloat)?
        for t in pinned...last {
            var order = base
            order.insert(d.slot, at: t)
            let L = model.layout(for: Array(order.prefix(IslandModel.compactMax)))
            guard let c = model.centers(L)[d.slot] else { continue }
            let x = previewFrame.midX - (model.geometry.seedSize.width + L.side * 2) / 2 + c
            if best == nil || abs(x - d.point.x) < best!.distance { best = (order, abs(x - d.point.x)) }
        }
        return (best?.order ?? current, true)
    }

    private func finishDrag() {
        guard let d = drag, !d.settling else { return }
        let plan = arrangement()
        let near = plan?.near ?? false
        // Into its gap in the preview, or back into its row; then the order is kept.
        withAnimation(islandSpring) {
            drag?.settling = true
            if near, let t = landing(d) {
                drag?.point = t
                drag?.landed = true
            } else {
                drag?.point = d.start
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (near ? 0.32 : 0.28)) {
            withAnimation(islandSpring) {
                drag = nil
                if let plan, near, plan.order != model.compactOrder { model.saveArrangement(plan.order) }
            }
        }
    }

    @ViewBuilder private func promoteMenu(_ slot: IslandModel.Slot) -> some View {
        if slot != .alarm, slot != .dictation {
            Button { withAnimation(islandSpring) { model.promote(slot) } } label: { Label("Show First When Closed", systemImage: "arrow.up.to.line") }
        }
        if model.hasArrangement {
            Button { withAnimation(islandSpring) { model.resetArrangement() } } label: { Label("Reset Order", systemImage: "arrow.counterclockwise") }
        }
    }

    /// Dictation in the band beside the notch (at menu-bar height) while the notch is open: the waveform (a spinner
    /// while it polishes) left of the notch, its controls right. The words go underneath.
    private var dictationStrip: some View {
        let g = model.geometry
        let d = model.dictation
        let polishing = d.phase == .processing
        return HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                if polishing {
                    PolishSpinner().transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Waveform(levels: Array(d.levels.suffix(14)), active: d.phase == .listening)
                        .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                }
            }
            Spacer(minLength: g.hasNotch ? g.seedSize.width : 0)
            if d.handsFree || polishing {
                stripButton("xmark", tint: nil) { d.cancel() }
            }
            if d.handsFree, !polishing {
                stripButton("stop.fill", tint: focusColor) { d.stop() }.transition(.scale.combined(with: .opacity))
            } else if !polishing {
                Image(systemName: d.mode == .command ? "wand.and.stars" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: polishing)
        .animation(.spring(duration: 0.3), value: d.handsFree)
        .padding(.horizontal, IslandModel.expandedInset + (g.hasNotch ? 12 : 0))
        .frame(height: g.hasNotch ? g.notchHeight : 28)
        .padding(.top, g.hasNotch ? 0 : 8)
    }

    private func stripButton(_ symbol: String, tint: Color?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint ?? .white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.map { $0.opacity(0.24) } ?? Color.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func detail(_ slot: IslandModel.Slot) -> some View {
        switch slot {
        case .media: mediaDetail
        case .timer(let id): timerDetail(id)
        case .stopwatch(let id): stopwatchDetail(id)
        case .alarm: alarmDetail
        case .toast: toastDetail
        case .dictation: dictationDetail
        case .pomodoro: HStack(alignment: .top, spacing: 12) { icon(slot, size: 24).padding(.top, 2); pomodoroDetail }
        case .meeting: HStack(alignment: .top, spacing: 12) { icon(slot, size: 24).padding(.top, 2); meetingDetail }
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
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: p.clock)
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
                    Text(m.clock).font(.system(size: 40, weight: .semibold).monospacedDigit()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
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

    private var dictationDetail: some View {
        let d = model.dictation
        let polishing = d.phase == .processing
        // The waveform and controls are in the band beside the notch; here, only the words.
        return VStack(alignment: .leading, spacing: 10) {
            if case .failed(let msg) = d.phase {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(msg).font(.system(size: 13)).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                }
            }
            if !d.preview.isEmpty {
                let words = Text(d.preview).font(.system(size: 14))
                // Every word, scrolling; it stays on the newest ones as they come in.
                ScrollView(.vertical) {
                    words
                        .foregroundStyle(.white.opacity(polishing ? 0.6 : 0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay { if polishing { Shine().mask(words.frame(maxWidth: .infinity, alignment: .leading)) } }
                        .animation(.easeOut(duration: 0.25), value: polishing)
                }
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.never)
                .frame(height: model.dictationTextHeight)
                .mask {
                    // The top edge fades once there's more than fits.
                    LinearGradient(stops: [.init(color: model.dictationTextHeight >= 92 ? .clear : .black, location: 0), .init(color: .black, location: 0.18)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
        }
    }

    private var alarmDetail: some View {
        let a = Alarms.shared
        return HStack(spacing: 12) {
            icon(.alarm, size: 28)
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
                icon(.stopwatch(id), size: 24)
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
                    icon(.timer(id), size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(n.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange).lineLimit(1)
                        Text(Pomodoro.clock(n.remaining(t.now))).font(.system(size: 34, weight: .semibold).monospacedDigit()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
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

    private var mediaDetail: some View {
        let m = NowPlaying.shared
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                AlbumArt(image: m.artwork, corner: 6, note: 20)
                    .frame(width: 46, height: 46)
                .matchedGeometryEffect(id: IslandModel.Slot.media.key, in: ns)
                .onTapGesture { m.openPlayer() }
                .help("Open \(m.appName)")
                VStack(alignment: .leading, spacing: 2) {
                    Marquee(text: m.songTitle, font: .system(size: 14, weight: .semibold), color: .white)
                    Marquee(text: m.artistLine, font: .system(size: 12), color: .white.opacity(0.6))
                }
                Spacer(minLength: 0)
                RoundButton(symbol: "backward.fill", tint: nil) { m.previous() }
                RoundButton(symbol: m.playing ? "pause.fill" : "play.fill", tint: .pink) { m.playPause() }
                RoundButton(symbol: "forward.fill", tint: nil) { m.next() }
            }
            if m.duration > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { _ in bar(m.livePosition / max(1, m.duration), .white.opacity(0.8)) }
            }
        }
    }

    private var toastDetail: some View {
        HStack(spacing: 10) {
            if let t = model.toast {
                icon(.toast, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    if !t.detail.isEmpty { Text(t.detail).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(2) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// A one-line row for each slot after the first (expanded notch).
    /// The buttons on a row: their real size (not shrunk), so they line up with the ones above.
    static let rowButton: CGFloat = 32

    @ViewBuilder private func row(_ slot: IslandModel.Slot) -> some View {
        HStack(spacing: 10) {
            icon(slot, size: 20)
            switch slot {
            case .timer(let id):
                let t = Timers.shared
                if let n = t.list.first(where: { $0.id == id }) {
                    Spacer(minLength: 0)
                    Text(Pomodoro.clock(n.remaining(t.now))).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    RoundButton(symbol: n.paused ? "play.fill" : "pause.fill", tint: nil, size: Self.rowButton) { t.toggle(n) }
                    RoundButton(symbol: "xmark", tint: nil, size: Self.rowButton) { t.remove(n) }
                }
            case .stopwatch(let id):
                let s = Stopwatches.shared
                if let w = s.list.first(where: { $0.id == id }) {
                    Spacer(minLength: 0)
                    Text(Stopwatch.format(w.elapsed(s.now), hundredths: false)).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    RoundButton(symbol: w.running ? "pause.fill" : "play.fill", tint: nil, size: Self.rowButton) { s.toggle(w) }
                    RoundButton(symbol: "flag.fill", tint: nil, size: Self.rowButton) { s.lap(w) }
                }
            case .alarm: rowContent(.alarm)
            case .dictation: rowContent(.dictation)
            case .toast: rowContent(.toast)
            case .meeting: rowContent(.meeting)
            case .pomodoro: rowContent(.pomodoro)
            case .media: rowContent(.media)
            }
        }
        .frame(height: IslandGeometry.rowHeight - 10)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    /// A one-line row for each activity after the first (expanded notch).
    @ViewBuilder private func rowContent(_ a: IslandModel.Activity) -> some View {
            switch a {
            case .pomodoro:
                Spacer(minLength: 0)
                trailing(a)
                RoundButton(symbol: model.pomodoro.paused ? "play.fill" : "pause.fill", tint: nil, size: Self.rowButton) { model.pomodoro.toggle() }
                RoundButton(symbol: "xmark", tint: nil, size: Self.rowButton) { model.pomodoro.stop() }
            case .meeting:
                Spacer(minLength: 0)
                trailing(a)
                RoundButton(symbol: "text.alignleft", tint: nil, size: Self.rowButton) { openMeeting() }
                RoundButton(symbol: "stop.fill", tint: .red, size: Self.rowButton) { model.meeting.stop() }
            case .dictation:
                Text(model.dictation.preview.isEmpty ? "Listening" : model.dictation.preview)
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            case .toast:
                trailing(a)
                if let t = model.toast, !t.detail.isEmpty { Text(t.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1) }
                Spacer(minLength: 0)
            case .alarm:
                trailing(a)
                Spacer(minLength: 0)
                RoundButton(symbol: "zzz", tint: nil, size: Self.rowButton) { Alarms.shared.snooze() }
                RoundButton(symbol: "stop.fill", tint: .orange, size: Self.rowButton) { Alarms.shared.dismiss() }
            case .stopwatch:
                Spacer(minLength: 0)
                trailing(a)
                if let w = Stopwatches.shared.running.first {
                    RoundButton(symbol: "pause.fill", tint: nil, size: Self.rowButton) { Stopwatches.shared.toggle(w) }
                    RoundButton(symbol: "flag.fill", tint: nil, size: Self.rowButton) { Stopwatches.shared.lap(w) }
                }
            case .timer:
                Spacer(minLength: 0)
                trailing(a)
                if let n = Timers.shared.next {
                    RoundButton(symbol: "pause.fill", tint: nil, size: Self.rowButton) { Timers.shared.toggle(n) }
                    RoundButton(symbol: "xmark", tint: nil, size: Self.rowButton) { Timers.shared.remove(n) }
                }
            case .media:
                Marquee(text: NowPlaying.shared.songTitle, font: .system(size: 12.5, weight: .medium), color: .white.opacity(0.85))
                Spacer(minLength: 0)
                RoundButton(symbol: NowPlaying.shared.playing ? "pause.fill" : "play.fill", tint: nil, size: Self.rowButton) { NowPlaying.shared.playPause() }
                RoundButton(symbol: "forward.fill", tint: nil, size: Self.rowButton) { NowPlaying.shared.next() }
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

/// Album art as a square, whatever shape the picture is (it's cropped to fill).
private struct AlbumArt: View {
    let image: NSImage?
    let corner: CGFloat
    let note: CGFloat

    var body: some View {
        Color.white.opacity(image == nil ? 0.12 : 0)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.system(size: note, weight: .bold)).foregroundStyle(.pink)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// A little equalizer beside the notch while music plays.
private struct EqualizerBars: View {
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let h = playing ? 4 + 9 * abs(sin(t * (2.1 + Double(i) * 0.7) + Double(i))) : 3
                    Capsule().fill(Color.pink).frame(width: 2.5, height: h)
                }
            }
            .frame(height: 16)
        }
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

/// A soft highlight sweeping left to right, over and over (the words while they're polished).
private struct Shine: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
            GeometryReader { g in
                let band = max(80, g.size.width * 0.35)
                LinearGradient(colors: [.white.opacity(0), .white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    .offset(x: -band + (g.size.width + band) * t)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MiniWave: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let l = levels.isEmpty ? 0 : levels[max(0, levels.count - 1 - i * 2)]
                Capsule().fill(.white).frame(width: 2.5, height: 3 + CGFloat(l) * 12)
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.08), value: levels)
    }
}
