import AppKit
import Observation
import SwiftUI

enum Scope: Equatable {
    case apps, switcher, clipboard, text, meeting, web, pomodoro, library, calculator, timer, mixer, translate, notes, weather

    var title: String {
        switch self {
        case .apps: "Apps"
        case .switcher: "Switch"
        case .clipboard: "Clipboard"
        case .text: "Text"
        case .meeting: "Meeting"
        case .web: "Web"
        case .pomodoro: "Clock"
        case .library: "All Apps"
        case .calculator: "Calculator"
        case .timer: "Timer"
        case .mixer: "Volume"
        case .translate: "Translate"
        case .notes: "Notes"
        case .weather: "Weather"
        }
    }

    var symbol: String {
        switch self {
        case .apps: "square.grid.2x2"
        case .switcher: "rectangle.stack"
        case .clipboard: "doc.on.clipboard"
        case .text: "text.viewfinder"
        case .meeting: "waveform"
        case .web: "globe"
        case .pomodoro: "clock.fill"
        case .library: "square.grid.3x3.fill"
        case .calculator: "plus.forwardslash.minus"
        case .timer: "timer"
        case .mixer: "slider.vertical.3"
        case .translate: "character.bubble.fill"
        case .notes: "note.text"
        case .weather: "cloud.sun.fill"
        }
    }

    /// Modes with their own body instead of a result list.
    var isPanel: Bool { [.text, .meeting, .pomodoro, .calculator, .timer, .mixer, .translate, .notes].contains(self) }
}

enum Builtin: String, CaseIterable {
    case clipboard, switcher, pomodoro, calculator, timer, stopwatch, alarm, mixer, translate, notes, weather, meeting, screenText,
         allApps, settings, quit

    var title: String {
        switch self {
        case .clipboard: "Clipboard History"
        case .switcher: "Switch Apps"
        case .pomodoro: "Clock"
        case .calculator: "Calculator"
        case .timer: "Timer"
        case .stopwatch: "Stopwatch"
        case .alarm: "Alarms"
        case .mixer: "Volume Mixer"
        case .translate: "Translate"
        case .notes: "Sticky Notes"
        case .weather: "Weather Anywhere"
        case .meeting: "Meetings"
        case .screenText: "Text from Screen"
        case .allApps: "All Apps"
        case .settings: "MONEY! Settings"
        case .quit: "Quit MONEY!"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .switcher: "rectangle.stack"
        case .pomodoro: "timer"
        case .calculator: "plus.forwardslash.minus"
        case .timer: "timer"
        case .stopwatch: "stopwatch"
        case .alarm: "alarm"
        case .mixer: "slider.vertical.3"
        case .translate: "character.bubble.fill"
        case .notes: "note.text"
        case .weather: "cloud.sun.fill"
        case .meeting: "waveform"
        case .screenText: "text.viewfinder"
        case .allApps: "square.grid.3x3.fill"
        case .settings: "gearshape"
        case .quit: "power"
        }
    }

    var scope: Scope? {
        switch self {
        case .clipboard: .clipboard
        case .switcher: .switcher
        case .pomodoro: .pomodoro
        case .calculator: .calculator
        case .timer, .stopwatch, .alarm: .pomodoro
        case .mixer: .mixer
        case .translate: .translate
        case .notes: .notes
        case .weather: .weather
        case .meeting: .meeting
        case .screenText: .text
        case .allApps: .library
        default: nil
        }
    }

    /// Which tab of ⌘5 Clock it opens.
    var clockMode: ClockMode? {
        switch self {
        case .pomodoro: .focus
        case .timer: .timer
        case .stopwatch: .stopwatch
        case .alarm: .alarms
        default: nil
        }
    }
}

struct ResultItem: Identifiable {
    enum Kind {
        case app(AppEntry)
        case running(NSRunningApplication)
        case builtin(Builtin)
        case clip(Clip)
        case site(SiteHome)
        case setting(SettingsPane)
        case meetingFile(MeetingRecorder.Past)
        /// An instant answer (calculator, weather, units…).
        case answer(Answer)
    }

    let id: String
    let title: String
    var subtitle: String?
    let kind: Kind
    var isRunning = false
    /// The app's shortcut words from Settings › Shortcuts, shown on its row.
    var keyword: String?
    /// A site's favicon from the browser.
    var image: NSImage?
}

/// Row geometry shared by the views and the controller (Moneybag numbers: 2.5pt gaps, 6pt inset).
enum Metrics {
    static let rowGap: CGFloat = 2.5
    /// Content sits this far from the card's left, right and bottom edges: the same gap the mode chip keeps in the bar.
    static let listInset: CGFloat = 16
    /// Transparent room around the card inside the window, for its shadow.
    static let margin: CGFloat = 40

    static func slot(_ s: Settings) -> CGFloat { s.rowHeight + rowGap * 2 }
    static func clipboardList(_ s: Settings) -> CGFloat { CGFloat(max(s.maxRows, 6)) * slot(s) + listInset - rowGap }
    /// Largest picture area for ⌘3 text.
    static let textMax = CGSize(width: 900, height: 540)

    /// All Apps grid: icon tiles, as many columns as fit.
    static let libraryCell = CGSize(width: 96, height: 104)
    static let libraryRows = 4
    static func libraryColumns(_ width: CGFloat) -> Int { max(3, Int((width - listInset * 2) / libraryCell.width)) }
}

@MainActor @Observable final class LauncherModel {
    var query = ""
    var scope = Scope.apps { didSet { if scope != .notes { controlFrames["board"] = nil } } }
    var items: [ResultItem] = []
    var selection = 0
    var hovered: Int?
    var ghost = ""
    /// Drives the open/close animation of the card.
    var presented = false
    /// The mode buttons beside the bar: shown while the pointer is on the bar or on them.
    var tabsShown = false
    @ObservationIgnored private var hoverSources = Set<String>()
    @ObservationIgnored private var hideTabsWork: DispatchWorkItem?
    /// ⌘3: the captured text, the highlighted words, and a status line while capturing.
    var screenText: ScreenTextResult?
    var textSelection: ClosedRange<Int>?
    var textStatus: String?
    var textToast: String?
    /// Web mode: the browser whose sites are suggested (Tab on a browser in the results).
    var browser: AppEntry?
    @ObservationIgnored var sites: [SiteHome] = []
    @ObservationIgnored var favicons: [String: Data] = [:]
    @ObservationIgnored private var faviconImages: [String: NSImage] = [:]
    @ObservationIgnored private var webCompletion = ""

    @ObservationIgnored weak var field: NSTextField?
    /// Buttons in the bar, in hosting-view coordinates (top-left origin), so clicks on them skip drag tracking.
    @ObservationIgnored var controlFrames: [String: CGRect] = [:]
    @ObservationIgnored var meeting: MeetingRecorder?
    /// The chat about the meeting being recorded (or just ended).
    @ObservationIgnored var meetingCopilot: MeetingCopilot?
    @ObservationIgnored var pomodoro: Pomodoro?
    /// ⌘4 with no meeting running: the saved meeting being read (nil = the list).
    var openedMeeting: MeetingRecorder.Past?
    /// Chat about the saved meeting being read.
    var pastChat: MeetingCopilot?
    @ObservationIgnored private var pastCache: [MeetingRecorder.Past] = []

    /// The meeting view shows the list of saved meetings unless one is recording or just ended.
    var meetingListMode: Bool {
        guard let m = meeting else { return false }
        return !m.isRunning && m.phase != .summarizing && m.phase != .done
    }

    func reloadPastMeetings() { pastCache = meeting?.pastMeetings() ?? [] }
    @ObservationIgnored let store: Store
    @ObservationIgnored let index: AppIndex
    @ObservationIgnored let switcher: Switcher
    @ObservationIgnored let clipboard: ClipboardStore

    init(store: Store, index: AppIndex, switcher: Switcher, clipboard: ClipboardStore) {
        self.store = store
        self.index = index
        self.switcher = switcher
        self.clipboard = clipboard
    }

    var selected: ResultItem? { items.indices.contains(selection) ? items[selection] : nil }

    /// Bar and buttons share one hover; a short grace period lets the pointer cross the gap between them.
    func hoverTabs(_ source: String, _ inside: Bool) {
        if inside { hoverSources.insert(source) } else { hoverSources.remove(source) }
        hideTabsWork?.cancel()
        if !hoverSources.isEmpty {
            if !tabsShown { withAnimation(.spring(duration: 0.45, bounce: 0.3)) { tabsShown = true } }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hoverSources.isEmpty else { return }
                withAnimation(.easeIn(duration: 0.18)) { self.tabsShown = false }
            }
        }
        hideTabsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func resetTabHover() {
        hoverSources = []
        hideTabsWork?.cancel()
        tabsShown = false
    }

    func width(_ s: Settings) -> CGFloat {
        switch scope {
        case .clipboard, .meeting: return CGFloat(max(s.clipboardWidth, s.width))
        case .text:
            guard screenText != nil else { return CGFloat(s.width) }
            return max(CGFloat(s.width), textDisplaySize.width + Metrics.listInset * 2)
        default: return CGFloat(s.width)
        }
    }

    /// The captured picture's size in the card: natural size, shrunk to fit, enlarged up to 1.5× when tiny.
    var textDisplaySize: CGSize {
        guard let r = screenText, r.size.width > 0, r.size.height > 0 else { return .zero }
        let maxW = Metrics.textMax.width - Metrics.listInset * 2
        let k = min(maxW / r.size.width, Metrics.textMax.height / r.size.height, 1.5)
        return CGSize(width: (r.size.width * k).rounded(), height: (r.size.height * k).rounded())
    }

    func listHeight(_ s: Settings) -> CGFloat {
        if scope == .meeting, meetingListMode, openedMeeting == nil {
            let rows = max(1, min(items.count, s.maxRows))
            return CGFloat(rows) * Metrics.slot(s) + Metrics.listInset - Metrics.rowGap
        }
        if scope == .clipboard || scope == .meeting { return Metrics.clipboardList(s) }
        if scope == .pomodoro { return ClockHub.height(self) }
        if scope == .calculator { return CalculatorView.height }
        if scope == .translate { return TranslateView.height }
        if scope == .notes { return NoteBoardView.height }
        if scope == .mixer { return MixerView.height(AudioMixer.shared.apps.count) }
        if scope == .library {
            guard !items.isEmpty else { return 44 }
            let rows = (items.count + libraryColumns - 1) / libraryColumns
            return CGFloat(min(rows, Metrics.libraryRows)) * Metrics.libraryCell.height + Metrics.listInset * 2
        }
        if scope == .text {
            if screenText != nil { return textDisplaySize.height + Metrics.listInset }
            return textStatus == nil ? 0 : 44
        }
        guard !items.isEmpty else { return 0 }
        return visibleListHeight(s) + Metrics.listInset - Metrics.rowGap
    }

    /// Rows are one height; answer cards are taller. Shows as many as fit in maxRows rows (a card always shows).
    func visibleListHeight(_ s: Settings) -> CGFloat {
        let budget = CGFloat(s.maxRows) * Metrics.slot(s)
        var h: CGFloat = 0
        for (n, item) in items.enumerated() {
            var ih = Metrics.slot(s)
            if case .answer(let a) = item.kind, let card = a.card { ih = card.height + Metrics.rowGap * 2 }
            if n > 0, h + ih > budget + 1 { break }
            h += ih
        }
        return h
    }

    func cardHeight(_ s: Settings) -> CGFloat { s.barHeight + listHeight(s) }

    func placeholder(_ s: Settings) -> String {
        switch scope {
        case .apps: s.placeholder
        case .switcher: "Switch to…"
        case .clipboard: "Search clipboard"
        case .text: screenText == nil ? "Text from the screen" : "Find in text"
        case .meeting: meetingListMode ? (openedMeeting == nil ? "Search past meetings" : "Search this meeting") : "Search transcript"
        case .web: "Search or type a site"
        case .pomodoro:
            switch clockMode {
            case .focus: "25/5, 1h, until 3pm…"
            case .timer: "5m, 1h 30m, 90s tea…"
            case .stopwatch: "Stopwatch"
            case .alarms: "7:30, 6am wake up, 7時半…"
            }
        case .library: "Search all apps"
        case .calculator: "Type or tap: 12×8, (3+4)^2…"
        case .timer: "5m, 1h 30m, 90s tea…"
        case .mixer: "Volume for each app"
        case .translate: "Type to translate"
        case .notes: "New note…"
        case .weather: "City or place…"
        }
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }

    var libraryColumns: Int { Metrics.libraryColumns(width(store.settings)) }

    // MARK: ⌘5 Clock

    var clockMode = ClockMode.focus

    func setClockMode(_ m: ClockMode) {
        guard m != clockMode else { return }
        withAnimation(.smooth(duration: 0.25)) {
            clockMode = m
            setQuery("")
        }
    }

    /// Timers: the "new timer" panel is open (it always is when there are none).
    var timerComposer = false
    /// Alarms: the one being added or edited, and which part of its time ↑↓ change (0 hour, 1 minute, 2 AM/PM).
    var alarmDraft: AlarmDraft?
    var alarmSegment = 0

    func newAlarm() {
        withAnimation(.smooth(duration: 0.25)) {
            alarmDraft = .new()
            alarmSegment = 0
            setQuery("")
        }
    }

    func editAlarm(_ a: Alarm) {
        withAnimation(.smooth(duration: 0.25)) {
            alarmDraft = AlarmDraft(a)
            alarmSegment = 0
            setQuery("")
        }
    }

    func updateDraft(_ change: (inout AlarmDraft) -> Void) {
        guard var d = alarmDraft else { return }
        change(&d)
        alarmDraft = d
    }

    func nudgeAlarm(_ delta: Int) {
        let seg = alarmSegment
        updateDraft { d in
            switch seg {
            case 0: d.hour = (d.hour + delta + 24) % 24
            case 1: d.minute = (d.minute + delta + 60) % 60
            default: d.hour = (d.hour + 12) % 24
            }
        }
    }

    func saveAlarmDraft() {
        guard let d = alarmDraft else { return }
        let a = Alarms.shared.save(d)
        withAnimation(.smooth(duration: 0.25)) {
            alarmDraft = nil
            setQuery("")
        }
        Tools.flash("Alarm set for \(a.time)", RelativeDateTimeFormatter().localizedString(for: a.next, relativeTo: Date()), "alarm.fill")
    }

    /// The old Timer view now lives in ⌘5 Clock.
    func resolve(_ s: Scope) -> Scope {
        guard s == .timer else { return s }
        clockMode = .timer
        return .pomodoro
    }

    // MARK: Calculator

    /// Finished sums, newest first ("12×8 = 96").
    var calcHistory: [String] = []

    func calcPress(_ key: String) {
        var q = query
        switch key {
        case "AC": q = ""
        case "⌫": if !q.isEmpty { q.removeLast() }
        case "=": return calcEquals()
        case "( )":
            let open = q.filter { $0 == "(" }.count - q.filter { $0 == ")" }.count
            let last = q.last
            q += open > 0 && last.map { $0.isNumber || $0 == ")" || $0 == "%" } == true ? ")" : "("
        case "±":
            if q.hasPrefix("-(") && q.hasSuffix(")") { q = String(q.dropFirst(2).dropLast()) } else if !q.isEmpty { q = "-(\(q))" }
        default:
            // A fresh number after a result starts a new sum; an operator continues it.
            if justEvaluated, key.first?.isNumber == true || key == "." { q = "" }
            q += key
        }
        justEvaluated = false
        setQuery(q)
    }

    @ObservationIgnored private var justEvaluated = false

    func calcEquals() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let v = Tools.evaluate(q) else { return }
        Stats.shared.add(.calculations)
        let result = Tools.plain(v)
        if q != result { calcHistory.insert("\(q) = \(Tools.fmt(v, digits: 10))", at: 0) }
        calcHistory = Array(calcHistory.prefix(3))
        setQuery(result)
        justEvaluated = true
    }

    /// Up and down in the All Apps grid jump a whole row, stopping at the edges.
    func moveRow(_ delta: Int) {
        guard !items.isEmpty else { return }
        let next = selection + delta * libraryColumns
        if items.indices.contains(next) {
            selection = next
        } else if delta > 0, (selection / libraryColumns) < (items.count - 1) / libraryColumns {
            selection = items.count - 1
        }
    }

    func setQuery(_ q: String) {
        query = q
        if field?.stringValue != q { field?.stringValue = q }
        recompute()
    }

    func recompute() {
        let s = store.settings
        let q = query.trimmingCharacters(in: .whitespaces)
        switch scope {
        case .apps:
            if q.isEmpty {
                switch s.emptyState {
                case .nothing: items = []
                case .recents: items = index.recents(limit: s.maxRows).map { appItem($0, running: runningPaths()) }
                case .running: items = switcher.apps().map(runningItem)
                }
            } else {
                let answers = s.instantAnswers ? Tools.answers(q, s).enumerated().map { answerItem($1, $0) } : []
                items = answers + searchApps(q, s)
            }
        case .library:
            let running = runningPaths()
            let excluded = Set(s.excludedApps)
            let apps = index.apps.filter { !excluded.contains($0.path) && !excluded.contains($0.bundleID ?? "\u{0}") && $0.path != AppIndex.appsLauncherPath }
            if q.isEmpty {
                items = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { appItem($0, running: running) }
            } else {
                items = apps.map { a in (a, max(matchScore(a.name, q), a.altName.map { matchScore($0, q) - 30 } ?? 0)) }.filter { $0.1 > 0 }
                    .sorted { $0.1 > $1.1 }.map { appItem($0.0, running: running) }
            }
        case .switcher:
            let apps = switcher.apps()
            if q.isEmpty {
                items = apps.map(runningItem)
            } else {
                items = apps.map { ($0, matchScore($0.localizedName ?? "", q)) }.filter { $0.1 > 0 }
                    .sorted { $0.1 > $1.1 }.map { runningItem($0.0) }
            }
        case .clipboard:
            items = clipboard.search(q).map(clipItem)
        case .meeting where meetingListMode && openedMeeting == nil:
            items = pastCache.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.text.localizedCaseInsensitiveContains(q) }
                .map { p in
                    let f = DateFormatter()
                    f.dateFormat = "MMM d, HH:mm"
                    return ResultItem(id: p.url.path, title: p.title, subtitle: f.string(from: p.date) + (p.snippet.isEmpty ? "" : " · " + p.snippet),
                                      kind: .meetingFile(p))
                }
        case .pomodoro:
            items = []
            // Typing a time while adding an alarm sets it ("7:30", "6am gym").
            if clockMode == .alarms, alarmDraft != nil, let t = Alarms.parse(q) {
                updateDraft { d in
                    d.hour = t.hour
                    d.minute = t.minute
                    if !t.label.isEmpty { d.label = t.label }
                }
            }
        case .translate:
            items = []
            Translator.shared.request(query)
        case .weather:
            // A place's weather as you type it (here, or your default city, when it's empty).
            items = LiveData.shared.weather(place: q, kind: .full, s).enumerated().map { answerItem($1, $0) }
        case .text, .meeting, .calculator, .timer, .mixer, .notes:
            items = []
        case .web:
            let r = BrowserSites.suggest(query, in: sites, limit: max(s.maxRows, 6))
            items = r.items.map(siteItem)
            webCompletion = query.isEmpty ? "" : r.completion
        }
        selection = 0
        hovered = nil
        updateGhost()
        applyHighlights()
    }

    /// Colors the understood parts of the typed text (times, places, the command…) without changing the text.
    func applyHighlights() {
        // After the field editor has the new text.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let editor = self.field?.currentEditor() as? NSTextView, let lm = editor.layoutManager else { return }
                let full = NSRange(location: 0, length: (editor.string as NSString).length)
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
                guard self.store.settings.colorTypedText, !editor.hasMarkedText(), editor.string == self.query else { return } // leave Japanese input being composed alone
                for (r, color) in Highlighter.spans(self.query, self) where NSMaxRange(r) <= full.length {
                    lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: r)
                }
            }
        }
    }

    /// A live answer arrived (weather, rates…): redraw, keeping the same row selected.
    func refreshAnswers() {
        guard scope == .weather || (scope == .apps && !query.isEmpty) else { return }
        let id = selected?.id
        recompute()
        if let id, let i = items.firstIndex(where: { $0.id == id }) { selection = i }
    }

    private func answerItem(_ a: Answer, _ i: Int) -> ResultItem {
        ResultItem(id: "ans-\(i)", title: a.title, subtitle: a.subtitle, kind: .answer(a), image: a.image)
    }

    func updateGhost() {
        ghost = ""
        if scope == .web {
            if store.settings.ghostCompletion { ghost = webCompletion }
            return
        }
        guard scope == .apps, store.settings.ghostCompletion, !query.isEmpty, let top = items.first else { return }
        if case .answer = top.kind { return }
        guard top.title.lowercased().hasPrefix(query.lowercased()), top.title.count > query.count else { return }
        ghost = String(top.title.dropFirst(query.count))
    }

    private func runningPaths() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
    }

    private func searchApps(_ q: String, _ s: Settings) -> [ResultItem] {
        var scored: [(ResultItem, Int)] = []
        let running = runningPaths()
        let excluded = Set(s.excludedApps)
        let lower = q.lowercased()
        let words = keywordMap(s)
        for a in index.apps where !excluded.contains(a.path) && !excluded.contains(a.bundleID ?? "\u{0}") {
            var sc = matchScore(a.name, q)
            if let alt = a.altName { sc = max(sc, matchScore(alt, q) - 30) }
            // Your own words win: exact → top of the list, start of the word → near it.
            for w in words[a.path] ?? [] {
                if w == lower { sc = max(sc, 5000) } else if w.hasPrefix(lower) { sc = max(sc, 1000) }
            }
            if sc > 0 { scored.append((appItem(a, running: running), sc + index.boost(a.path))) }
        }
        if s.searchSettingsPages, lower.count >= 2 {
            for p in SettingsPane.all {
                var sc = matchScore(p.name, q)
                for kw in p.keywords {
                    if kw == lower { sc = max(sc, 1100) } else if kw.hasPrefix(lower) { sc = max(sc, 900) }
                }
                if sc > 0 {
                    scored.append((ResultItem(id: "set-\(p.target)", title: p.name, subtitle: "System Settings", kind: .setting(p)), sc - 40))
                }
            }
        }
        if s.builtinsInResults {
            for b in Builtin.allCases {
                var sc = matchScore(b.title, q)
                for kw in keywords(b, s) where !kw.isEmpty {
                    if kw == lower { sc = max(sc, 1150) } else if lower.count >= 2, kw.hasPrefix(lower) { sc = max(sc, 940) }
                }
                if sc > 0 { scored.append((ResultItem(id: "b-\(b.rawValue)", title: b.title, kind: .builtin(b)), sc - 20)) }
            }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(40).map(\.0)
    }

    func keywords(_ b: Builtin, _ s: Settings) -> [String] {
        switch b {
        case .clipboard: [s.clipboardKeyword.lowercased(), "clipboard", "history", "paste"]
        case .switcher: [s.switcherKeyword.lowercased(), "running", "switch"]
        case .pomodoro: ["clock", "clocks", "pomodoro", "pomo", "focus", "時計", "ポモドーロ", "集中"]
        case .calculator: ["calc", "calculator", "keypad", "電卓", "計算機"]
        case .timer: ["timer", "countdown", "タイマー"]
        case .stopwatch: ["stopwatch", "stop watch", "lap", "ストップウォッチ"]
        case .alarm: ["alarm", "alarms", "wake me", "アラーム", "目覚まし"]
        case .mixer: ["mixer", "volume mixer", "app volume", "sound mixer", "ミキサー", "音量ミキサー"]
        case .translate: ["translate", "translator", "翻訳"]
        case .notes: ["notes", "sticky", "sticky notes", "memo", "board", "付箋", "メモ"]
        case .weather: ["weather", "forecast", "天気", "天気予報"]
        case .meeting: ["meeting", "meetings", "record meeting", "会議", "議事録"]
        case .screenText: ["text from screen", "scan", "ocr", "screen text", "qr scan", "文字認識"]
        case .allApps: ["all apps", "library", "launchpad", "アプリ一覧"]
        case .settings: ["settings", "preferences", "money"]
        case .quit: ["quit money", "quit"]
        }
    }

    /// app path → its shortcut words, lowercased.
    private func keywordMap(_ s: Settings) -> [String: [String]] {
        s.appKeywords.mapValues { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }
    }

    private func keywordLabel(_ path: String?) -> String? {
        guard let path, let w = store.settings.appKeywords[path]?.trimmingCharacters(in: .whitespaces), !w.isEmpty else { return nil }
        return w
    }

    private func appItem(_ a: AppEntry, running: Set<String>) -> ResultItem {
        ResultItem(id: a.path, title: a.name, kind: .app(a), isRunning: running.contains(a.path), keyword: keywordLabel(a.path))
    }

    private func runningItem(_ r: NSRunningApplication) -> ResultItem {
        ResultItem(id: "pid-\(r.processIdentifier)", title: r.localizedName ?? "App", subtitle: r.isHidden ? "Hidden" : nil,
                   kind: .running(r), isRunning: true, keyword: keywordLabel(r.bundleURL?.path))
    }

    private func siteItem(_ site: SiteHome) -> ResultItem {
        var item = ResultItem(id: "site-\(site.host)", title: site.host, kind: .site(site))
        if let img = faviconImages[site.host] {
            item.image = img
        } else if let data = favicons[site.host], let img = NSImage(data: data) {
            faviconImages[site.host] = img
            item.image = img
        }
        return item
    }

    func resetSites() {
        sites = []
        favicons = [:]
        faviconImages = [:]
    }

    private func clipItem(_ c: Clip) -> ResultItem {
        ResultItem(id: c.id.uuidString, title: c.title, kind: .clip(c))
    }
}

// MARK: - Controller

@MainActor final class LauncherController: NSObject, NSWindowDelegate {
    let store: Store
    let clipboard: ClipboardStore
    let index = AppIndex()
    let switcher = Switcher()
    let model: LauncherModel
    let panel: LauncherPanel
    var openSettings: () -> Void = {}

    private var hosting: NSHostingView<LauncherRoot>!
    private var keyMonitor: Any?
    private var holdTimer: Timer?
    private var holding = false
    /// Whether the switcher selection was moved while the modifier was held.
    private var navigated = false
    /// The card's top centre on screen.
    private var anchor = (centerX: CGFloat(0), top: CGFloat(0))
    weak var island: IslandModel?
    private(set) var isShown = false { didSet { if isShown != oldValue { onVisibilityChange?() } } }
    var onVisibilityChange: (() -> Void)?

    init(store: Store, clipboard: ClipboardStore) {
        self.store = store
        self.clipboard = clipboard
        model = LauncherModel(store: store, index: index, switcher: switcher, clipboard: clipboard)
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the card draws its own shadow
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onDragEnded = { [weak self] in self?.savePosition() }
        panel.onOutsideClick = { [weak self] in self?.hide() }
        panel.cardRect = { [weak self] in self?.cardRect() ?? .zero }
        panel.isControl = { [weak self] p in
            guard let self, let content = self.panel.contentView else { return false }
            let q = NSPoint(x: p.x, y: content.bounds.height - p.y)
            return self.model.controlFrames.values.contains { $0.insetBy(dx: -2, dy: -2).contains(q) }
        }

        // The window keeps one size; only the card inside animates. SwiftUI must not resize the window.
        hosting = NSHostingView(rootView: LauncherRoot(model: model, store: store, clipboard: clipboard,
                                                       onActivate: { [weak self] i in self?.activate(index: i) },
                                                       onTab: { [weak self] scope in self?.tab(scope) },
                                                       clipActions: ClipActions(
                                                           paste: { [weak self] id in self?.clipAction(id) { self?.activate($0) } },
                                                           copy: { [weak self] id in self?.clipAction(id) { self?.activate($0, flags: .command) } },
                                                           pin: { [weak self] id in self?.togglePin(id) },
                                                           delete: { [weak self] id in self?.deleteClip(id) }),
                                                       textActions: TextActions(
                                                           copySelection: { [weak self] in self?.copyText() },
                                                           copyAll: { [weak self] in
                                                               self?.model.textSelection = nil
                                                               self?.copyText()
                                                           },
                                                           retake: { [weak self] in self?.startScreenText() },
                                                           code: { [weak self] c in self?.useCode(c) }),
                                                       onPomodoro: { [weak self] plan in self?.startPomodoro(plan) },
                                                       onAnswerAction: { [weak self] action in self?.runAnswer(Answer(title: "", action: action), flags: []) },
                                                       onTimerStart: { [weak self] in self?.startTimer() },
                                                       meetingActions: MeetingActions(new: { [weak self] in self?.newMeeting() },
                                                                                      back: { [weak self] in self?.closeOpenedMeeting() },
                                                                                      rename: { [weak self] name in self?.renameOpenedMeeting(name) })))
        hosting.sizingOptions = []
        panel.contentView = hosting
        index.onUpdate = { [weak self] in
            guard let self, self.isShown, self.model.scope == .apps, !self.model.query.isEmpty else { return }
            self.model.recompute()
        }
        index.refresh(folders: store.settings.searchFolders)
        Tools.flash = { [weak self] title, detail, symbol in self?.island?.flash(title, detail, symbol: symbol) }
        Tools.openSettings = { [weak self] in
            self?.hide(animated: false)
            self?.openSettings()
        }
        LiveData.shared.onUpdate = { [weak self] in self?.model.refreshAnswers() }
        Tools.translate = { [weak self] text, target in
            Translator.shared.target = target ?? "Auto"
            self?.enter(.translate)
            self?.model.setQuery(text)
        }
        Tools.enterScope = { [weak self] scope, query in
            self?.enter(scope)
            self?.model.setQuery(query)
        }
        applySettings()
    }

    private var animate: Bool {
        store.settings.animations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Showing

    func toggle(_ scope: Scope) {
        if isShown, model.scope == scope { hide() } else { show(scope) }
    }

    func show(_ requested: Scope, prepared: Bool = false) {
        let scope = model.resolve(requested)
        let wasShown = isShown
        // While hidden, the card still has its last size. Switch to the new state without animation, and lay it
        // out before the window appears, so it never visibly shrinks or grows from the old size on open.
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(wasShown ? Transaction() : quiet) {
            if !prepared {
                index.refreshIfStale(folders: store.settings.searchFolders)
                model.scope = scope
                model.setQuery("")
            }
            if !wasShown {
                model.resetTabHover()
                Tools.reset()
            }
        }
        if !wasShown {
            isShown = true
            anchor = restingAnchor()
            layoutPanel()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            panel.makeKeyAndOrderFront(nil)
            installKeyMonitor()
            // Esc taken system-wide while the popup is open, so it never reaches the app underneath.
            if escToken == nil {
                escToken = HotKeyCenter.shared.registerTransient(.escape) { [weak self] in
                    MainActor.assumeIsolated { self?.escapePressed() }
                }
            }
            if animate {
                withAnimation(.spring(duration: 0.32, bounce: 0.18)) { model.presented = true }
            } else {
                model.presented = true
            }
        }
        panel.makeFirstResponder(model.field)
        model.field?.currentEditor()?.selectedRange = NSRange(location: model.query.utf16.count, length: 0)
    }

    private var escToken: UInt32?

    /// Esc: cancels Japanese input being composed, then clears the text, then backs out of a mode, then closes.
    private func escapePressed() {
        guard isShown else { return }
        if let editor = model.field?.currentEditor() as? NSTextView, editor.hasMarkedText() {
            editor.inputContext?.discardMarkedText()
            editor.unmarkText()
            return
        }
        if model.scope == .pomodoro, model.alarmDraft != nil {
            withAnimation(.smooth(duration: 0.2)) { model.alarmDraft = nil }
            return
        }
        _ = handle(#selector(NSResponder.cancelOperation(_:)))
    }

    func hide(animated: Bool = true) {
        stopHold()
        guard isShown else { return }
        isShown = false
        removeKeyMonitor()
        HotKeyCenter.shared.remove(escToken)
        escToken = nil
        if animated && animate {
            withAnimation(.easeIn(duration: 0.13)) { model.presented = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isShown else { return }
                    self.panel.orderOut(nil)
                }
            }
        } else {
            model.presented = false
            panel.orderOut(nil)
        }
    }

    /// The hover buttons / ⌘1–⌘4.
    func tab(_ scope: Scope) {
        switch scope {
        case .text: startScreenText()
        case .meeting: openMeeting()
        case .pomodoro: if isShown { enter(.pomodoro) } else { show(.pomodoro) }
        default: enter(scope)
        }
    }

    func enter(_ requested: Scope) {
        let scope = model.resolve(requested)
        panel.makeFirstResponder(model.field)
        guard scope != model.scope || !model.query.isEmpty else { return }
        let change = {
            self.model.scope = scope
            self.model.setQuery("")
        }
        if animate { withAnimation(.smooth(duration: 0.3)) { change() } } else { change() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if isShown, !panel.dragging { hide() }
    }

    // MARK: App switcher

    /// ⌥Tab shows the switcher with the previous app selected. While the modifier is held,
    /// more taps move down (⇧ up) and letting go switches; let go without moving and it stays open.
    func switcherPressed(backward: Bool) {
        if isShown, model.scope == .switcher {
            model.move(backward ? -1 : 1)
            if holding { navigated = true }
            return
        }
        model.scope = .switcher
        model.setQuery("")
        if !model.items.isEmpty { model.selection = backward ? model.items.count - 1 : min(1, model.items.count - 1) }
        show(.switcher, prepared: true)
        let required = store.settings.switcherHotKey.cocoaModifiers.subtracting(.shift)
        guard store.settings.holdToSwitch, !required.isEmpty else { return }
        holding = true
        navigated = false
        let t = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !NSEvent.modifierFlags.contains(required) { self.releaseHold() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        holdTimer = t
    }

    private func releaseHold() {
        let switchNow = navigated
        stopHold()
        if switchNow, let item = model.selected { activate(item) }
    }

    private func stopHold() {
        holding = false
        navigated = false
        holdTimer?.invalidate()
        holdTimer = nil
    }

    // MARK: Keys

    /// Commands the text field forwards (arrows, Tab, Return, Esc, delete).
    func handle(_ sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)) where model.scope == .pomodoro && model.clockMode == .alarms && model.alarmDraft != nil:
            model.nudgeAlarm(1)
        case #selector(NSResponder.moveDown(_:)) where model.scope == .pomodoro && model.clockMode == .alarms && model.alarmDraft != nil:
            model.nudgeAlarm(-1)
        case #selector(NSResponder.moveLeft(_:)) where model.scope == .pomodoro && model.clockMode == .alarms && model.alarmDraft != nil && model.query.isEmpty:
            model.alarmSegment = max(0, model.alarmSegment - 1)
        case #selector(NSResponder.moveRight(_:)) where model.scope == .pomodoro && model.clockMode == .alarms && model.alarmDraft != nil && model.query.isEmpty:
            model.alarmSegment = min(TimePickerInfo.segments - 1, model.alarmSegment + 1)
        case #selector(NSResponder.moveUp(_:)) where model.scope == .library:
            model.moveRow(-1)
        case #selector(NSResponder.moveDown(_:)) where model.scope == .library:
            model.moveRow(1)
        case #selector(NSResponder.moveLeft(_:)) where model.scope == .library && model.query.isEmpty:
            model.selection = max(0, model.selection - 1)
        case #selector(NSResponder.moveRight(_:)) where model.scope == .library && model.query.isEmpty:
            model.selection = min(max(0, model.items.count - 1), model.selection + 1)
        case #selector(NSResponder.moveUp(_:)):
            model.move(-1)
            if holding { navigated = true }
        case #selector(NSResponder.moveDown(_:)):
            model.move(1)
            if holding { navigated = true }
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            model.selection = max(0, model.selection - store.settings.maxRows)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            model.selection = min(max(0, model.items.count - 1), model.selection + store.settings.maxRows)
        case #selector(NSResponder.insertTab(_:)): tab()
        case #selector(NSResponder.insertBacktab(_:)): model.move(-1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            if model.scope == .calculator {
                model.calcEquals()
            } else if model.scope == .mixer {
                return true
            } else if model.scope == .notes {
                // ↩ pins what you typed as a new note (or an empty one to write on).
                NoteBoard.shared.add(model.query.trimmingCharacters(in: .whitespaces))
                model.setQuery("")
            } else if model.scope == .translate {
                if let r = Translator.shared.result { copyTranslation(r) }
            } else if model.scope == .pomodoro {
                switch model.clockMode {
                case .focus: startPomodoro(Pomodoro.parse(model.query))
                case .timer:
                    if TimersView.composing(model) { startTimer() } else if let t = Timers.shared.list.first { Timers.shared.toggle(t) }
                case .stopwatch:
                    if let w = Stopwatches.shared.list.first { Stopwatches.shared.toggle(w) }
                case .alarms:
                    if model.alarmDraft != nil { model.saveAlarmDraft() } else if Alarms.parse(model.query) != nil { addAlarm() } else { model.newAlarm() }
                }
            } else if model.scope == .text {
                copyText(matchesOnly: !model.query.isEmpty)
            } else if model.scope == .web, model.selected == nil {
                // Not a known site: an address if it looks like one, otherwise a web search.
                if let url = BrowserSites.url(for: model.query) { open(url, in: model.browser) }
            } else if let item = model.selected {
                activate(item, flags: NSApp.currentEvent?.modifierFlags ?? [])
            }
        case #selector(NSResponder.cancelOperation(_:)):
            if !model.query.isEmpty { model.setQuery("") } else { hide() }
        case #selector(NSResponder.deleteBackward(_:)):
            guard model.query.isEmpty, model.scope != .apps else { return false }
            if model.scope == .meeting, model.openedMeeting != nil { closeOpenedMeeting() } else { enter(.apps) }
        default:
            return false
        }
        return true
    }

    private func tab() {
        if model.scope == .apps, case .app(let a)? = model.selected?.kind, BrowserSites.browserPaths.contains(a.path) {
            enterBrowser(a)
            return
        }
        if model.scope == .apps, case .app(let a)? = model.selected?.kind, a.path == AppIndex.appsLauncherPath {
            enter(.library)
            return
        }
        if model.scope == .library {
            model.move(1)
            return
        }
        if model.scope == .pomodoro {
            // Tab moves through Focus, Timer, Stopwatch and Alarms.
            let all = ClockMode.allCases
            model.setClockMode(all[((all.firstIndex(of: model.clockMode) ?? 0) + 1) % all.count])
            return
        }
        let lower = model.query.lowercased()
        // "weather tokyo" + Tab → the Weather tab, already showing Tokyo ("translate hello" likewise).
        if model.scope == .apps, let (scope, rest) = Self.modeWithText(model.query) {
            enter(scope)
            if !rest.isEmpty { model.setQuery(rest) }
            return
        }
        if model.scope == .apps, let b = modeToEnter(lower), let scope = b.scope {
            // "cl" + Tab → Clipboard, "wea" + Tab → Weather (like site scopes in the browser bar), even when an app
            // with the same name sits above it.
            if let m = b.clockMode { model.clockMode = m }
            tab(scope)
        } else if !model.ghost.isEmpty {
            model.setQuery(model.query + model.ghost)
        } else {
            model.move(1)
        }
    }

    /// The mode Tab opens: the selected row if it's one, otherwise the first listed mode whose word starts with
    /// what's typed.
    private func modeToEnter(_ lower: String) -> Builtin? {
        func mode(_ item: ResultItem?) -> Builtin? {
            if case .builtin(let b)? = item?.kind, b.scope != nil { b } else { nil }
        }
        let matches = { (b: Builtin) in !lower.isEmpty && self.model.keywords(b, self.store.settings).contains { $0.hasPrefix(lower) } }
        if let b = mode(model.selected), matches(b) || model.ghost.isEmpty { return b }
        if let b = model.items.lazy.compactMap(mode).first(where: matches) { return b }
        // Modes left out of the results still open by their whole word.
        return Builtin.allCases.first { $0.scope != nil && model.keywords($0, store.settings).contains(lower) }
    }

    /// A mode's word at the start of what's typed, and the rest ("weather in tokyo" → Weather, "tokyo").
    static func modeWithText(_ q: String) -> (Scope, String)? {
        let modes: [(Scope, String)] = [(.weather, #"weather|forecast|天気予報|天気"#), (.translate, #"translate|翻訳"#)]
        for (scope, words) in modes {
            guard let r = q.range(of: #"^\s*(?:"# + words + #")(?:\s+(?:in|for|at|の)\b)?\s*"#, options: [.regularExpression, .caseInsensitive]) else { continue }
            let rest = String(q[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            // Only a whole word ("weathering" isn't one).
            if let next = q[r.upperBound...].first, next.isLetter, q[..<r.upperBound].last?.isWhitespace == false, !q[..<r.upperBound].unicodeScalars.contains(where: { $0.value > 0x2FFF }) { continue }
            return (scope, rest)
        }
        return nil
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, e.window === self.panel else { return e }
                return self.keyEquivalent(e) ? nil : e
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func keyEquivalent(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == .command else { return false }
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (key, e.keyCode) {
        case ("1", _): tab(.apps)
        case ("2", _), ("3", _), ("4", _), ("5", _):
            // Whatever Settings › Appearance puts in those places.
            let modes = store.settings.quickModes
            let i = Int(key)! - 2
            guard modes.indices.contains(i) else { return false }
            switch modes[i] {
            case .mode(let m): tab(m.scope)
            case .app(let path): openQuickApp(path)
            }
        case (",", _): hide(animated: false); openSettings()
        case ("w", _): hide()
        case (_, 36), (_, 76): // ⌘↩: copy only
            if let item = model.selected { activate(item, flags: .command) }
        case (_, 51): // ⌘⌫
            guard case .clip(let c)? = model.selected?.kind else { return false }
            deleteClip(c.id)
        case ("p", _):
            guard case .clip(let c)? = model.selected?.kind else { return false }
            togglePin(c.id)
        case ("c", _):
            guard case .clip? = model.selected?.kind, (model.field?.currentEditor()?.selectedRange.length ?? 0) == 0,
                  let item = model.selected else { return false }
            activate(item, flags: .command)
        case ("q", _):
            guard let app = runningApp(model.selected) else { return false }
            app.terminate()
            refreshSoon(0.4)
        case ("h", _):
            guard let app = runningApp(model.selected) else { return false }
            app.hide()
            refreshSoon(0.2)
        default:
            return false
        }
        return true
    }

    // MARK: Web mode (Tab on a browser)

    /// Like the Moneybag bar: type a site, get its home page from your history, Return opens it in that browser.
    func enterBrowser(_ app: AppEntry) {
        let change = {
            self.model.resetSites()
            self.model.browser = app
            self.model.scope = .web
            self.model.setQuery("")
        }
        if animate { withAnimation(.smooth(duration: 0.3)) { change() } } else { change() }
        let id = app.bundleID
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { BrowserSites.load(bundleID: id) }.value
            guard self.model.scope == .web, self.model.browser?.path == app.path else { return }
            self.model.sites = loaded.sites
            self.model.favicons = loaded.favicons
            withAnimation(.smooth(duration: 0.24)) { self.model.recompute() }
        }
    }

    private func open(_ url: URL, in browser: AppEntry?) {
        hide()
        guard let browser else { NSWorkspace.shared.open(url); return }
        index.recordLaunch(browser.path)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: browser.path), configuration: cfg)
    }

    // MARK: ⌘3 Text from the screen

    private let picker = RegionPicker()

    /// The bar turns into "Text", steps aside while you drag over the screen, then comes back holding the words.
    func startScreenText() {
        Stats.shared.add(.textScans)
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            withAnimation(.smooth(duration: 0.3)) {
                model.scope = .text
                model.screenText = nil
                model.textStatus = "Allow Screen & System Audio Recording for MONEY! in System Settings › Privacy & Security, then press ⌘3 again."
                model.setQuery("")
            }
            if !isShown { show(.text, prepared: true) }
            return
        }
        withAnimation(.smooth(duration: 0.25)) {
            model.scope = .text
            model.screenText = nil
            model.textSelection = nil
            model.textStatus = nil
            model.setQuery("")
        }
        let wasShown = isShown
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasShown ? 0.22 : 0)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hide(animated: wasShown)
                DispatchQueue.main.asyncAfter(deadline: .now() + (wasShown ? 0.17 : 0)) {
                    MainActor.assumeIsolated { self.pickRegion() }
                }
            }
        }
    }

    private func pickRegion() {
        picker.pick { [weak self] rect in
            guard let self else { return }
            guard let rect else { return } // Esc: just close
            self.model.textStatus = "Reading text…"
            self.show(.text, prepared: true)
            Task {
                do {
                    let image = try await ScreenText.capture(rect)
                    let result = await ScreenText.recognize(image, pointSize: rect.size, codes: self.store.settings.scanQR)
                    withAnimation(.smooth(duration: 0.38)) {
                        self.model.screenText = result
                        self.model.textStatus = result.tokens.isEmpty && result.codes.isEmpty ? "No text or QR code in that area." : nil
                    }
                } catch {
                    self.model.textStatus = "Couldn't capture the screen: \(error.localizedDescription)"
                }
            }
        }
    }

    /// A scanned QR code: links open in the browser (and are copied); anything else is copied.
    func useCode(_ c: ScreenTextResult.Code) {
        clipboard.copy(text: c.payload, source: "QR code")
        if let url = c.url {
            hide()
            NSWorkspace.shared.open(url)
            island?.flash("Opened QR link", url.host ?? "", symbol: "qrcode")
        } else {
            withAnimation(.smooth(duration: 0.2)) { model.textToast = "Copied the QR code" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                MainActor.assumeIsolated { withAnimation(.smooth(duration: 0.2)) { self?.model.textToast = nil } }
            }
        }
    }

    /// Copies the highlighted words (called when a drag ends) or everything / the matching lines.
    func copyText(matchesOnly: Bool = false) {
        guard let r = model.screenText, !r.tokens.isEmpty else { return }
        var text: String
        var label: String
        if let sel = model.textSelection, !matchesOnly {
            text = r.text(sel)
            label = sel.count == 1 ? "Copied “\(text.prefix(24))”" : "Copied \(sel.count) words"
        } else if matchesOnly {
            let q = model.query.lowercased()
            let lines = Set(r.tokens.filter { $0.text.lowercased().contains(q) }.map(\.line))
            text = Dictionary(grouping: r.tokens.indices.filter { lines.contains(r.tokens[$0].line) }, by: { r.tokens[$0].line })
                .sorted { $0.key < $1.key }.map { r.text($0.value.min()!...$0.value.max()!) }.joined(separator: "\n")
            label = "Copied \(lines.count) matching line\(lines.count == 1 ? "" : "s")"
        } else {
            text = r.fullText
            label = "Copied all text"
        }
        guard !text.isEmpty else { return }
        clipboard.copy(text: text, source: "Screen Text")
        withAnimation(.smooth(duration: 0.2)) { model.textToast = label }
        let toast = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.textToast == toast else { return }
                withAnimation(.smooth(duration: 0.3)) { self.model.textToast = nil }
            }
        }
    }

    /// An app button beside the bar (or its ⌘2–⌘5).
    func openQuickApp(_ path: String) {
        hide()
        openApp(path: path)
    }

    // MARK: Translate

    func copyTranslation(_ text: String) {
        Stats.shared.add(.translations)
        clipboard.copy(text: text, source: "Translate")
        hide()
    }

    // MARK: Alarms

    /// ↩ in Alarms: adds the typed time ("7:30 gym").
    func addAlarm() {
        guard let t = Alarms.parse(model.query) else {
            if !model.query.isEmpty { island?.flash("Not a time", "Try 7:30, 6am or 7時半", symbol: "alarm", color: .orange) }
            return
        }
        let a = Alarms.shared.add(hour: t.hour, minute: t.minute, label: t.label)
        model.setQuery("")
        island?.flash("Alarm set for \(a.time)", RelativeDateTimeFormatter().localizedString(for: a.next, relativeTo: Date()), symbol: "alarm.fill", color: .orange)
    }

    // MARK: Timer view

    /// Starts the typed timer (5 minutes when nothing is typed) and lets it lift into the notch.
    func startTimer() {
        let parts = TimersView.parts(model.query)
        if parts.isEmpty { Timers.shared.add(minutes: TimersView.defaultMinutes) }
        for p in parts.reversed() { Timers.shared.add(minutes: p.minutes, label: p.label) } // newest first, so keep the typed order
        withAnimation(.smooth(duration: 0.25)) {
            model.timerComposer = false
            model.setQuery("")
        }
    }

    // MARK: ⌘5 Pomodoro

    /// Return in the Focus view: start the typed plan, or pause/resume the running timer.
    /// Starting closes the popup so the timer lifts into the notch.
    func startPomodoro(_ plan: Pomodoro.Plan?) {
        guard let p = model.pomodoro else { return }
        if let plan {
            p.start(plan)
            hide()
        } else if p.active {
            p.toggle()
        } else {
            p.start(p.plan)
            hide()
        }
    }

    // MARK: ⌘4 Meeting

    var meeting: MeetingRecorder? { model.meeting }

    /// ⌘4: the running meeting if there is one, otherwise the saved meetings and "New Meeting".
    func openMeeting() {
        guard let meeting = model.meeting else { return }
        if !meeting.isRunning, meeting.phase != .summarizing { meeting.reset() }
        model.openedMeeting = nil
        model.reloadPastMeetings()
        if isShown { enter(.meeting) } else { show(.meeting) }
        model.recompute()
    }

    func newMeeting() {
        guard let meeting = model.meeting else { return }
        withAnimation(.smooth(duration: 0.3)) {
            model.openedMeeting = nil
            meeting.reset()
            meeting.start()
            model.setQuery("")
        }
    }

    func renameOpenedMeeting(_ name: String) {
        guard let past = model.openedMeeting, let renamed = model.meeting?.rename(past, to: name) else { return }
        model.openedMeeting = renamed
        model.reloadPastMeetings()
    }

    func closeOpenedMeeting() {
        withAnimation(.smooth(duration: 0.28)) {
            model.openedMeeting = nil
            model.setQuery("")
        }
    }

    // MARK: Clipboard actions

    private func clipAction(_ id: UUID, _ run: (ResultItem) -> Void) {
        guard let i = model.items.firstIndex(where: { $0.id == id.uuidString }) else { return }
        model.selection = i
        run(model.items[i])
    }

    func deleteClip(_ id: UUID) {
        let keep = model.items.firstIndex { $0.id == id.uuidString } ?? model.selection
        let change = {
            self.clipboard.delete(id)
            self.model.recompute()
            self.model.selection = min(keep, max(0, self.model.items.count - 1))
        }
        if animate { withAnimation(.smooth(duration: 0.22)) { change() } } else { change() }
    }

    func togglePin(_ id: UUID) {
        clipboard.togglePin(id)
        model.recompute()
        if let i = model.items.firstIndex(where: { $0.id == id.uuidString }) { model.selection = i }
    }

    private func refreshSoon(_ delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let keep = self.model.selection
                self.model.recompute()
                self.model.selection = min(keep, max(0, self.model.items.count - 1))
            }
        }
    }

    private func runningApp(_ item: ResultItem?) -> NSRunningApplication? {
        switch item?.kind {
        case .running(let r): return r
        case .app(let a): return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == a.path }
        default: return nil
        }
    }

    // MARK: Actions

    func activate(index i: Int) {
        guard model.items.indices.contains(i) else { return }
        model.selection = i
        activate(model.items[i], flags: NSEvent.modifierFlags)
    }

    func activate(_ item: ResultItem, flags: NSEvent.ModifierFlags = []) {
        switch item.kind {
        case .app(let a) where a.path == AppIndex.appsLauncherPath:
            // macOS's Apps opens Spotlight; ours is the All Apps grid.
            enter(.library)
        case .app(let a):
            hide()
            Stats.shared.add(.appsOpened)
            openApp(path: a.path)
        case .answer(let a):
            Stats.shared.add(.answers)
            runAnswer(a, flags: flags)
        case .running(let r):
            hide()
            Stats.shared.add(.appsOpened)
            if r.isHidden { r.unhide() }
            if let url = r.bundleURL { openApp(path: url.path) } else { r.activate() }
        case .builtin(let b):
            switch b {
            case .clipboard: enter(.clipboard)
            case .switcher: enter(.switcher)
            case .pomodoro, .timer, .stopwatch, .alarm:
                if let m = b.clockMode { model.clockMode = m }
                enter(.pomodoro)
            case .calculator: enter(.calculator)
            case .mixer: enter(.mixer)
            case .translate: enter(.translate)
            case .notes: enter(.notes)
            case .weather: enter(.weather)
            case .meeting, .screenText, .allApps: if let scope = b.scope { tab(scope) }
            case .settings: hide(animated: false); openSettings()
            case .quit: NSApp.terminate(nil)
            }
        case .site(let site):
            if let url = URL(string: site.home) { open(url, in: model.browser) }
        case .setting(let pane):
            hide()
            if let url = pane.url { NSWorkspace.shared.open(url) }
        case .meetingFile(let past):
            withAnimation(.smooth(duration: 0.3)) {
                model.openedMeeting = past
                model.pastChat = MeetingCopilot(store: store, savedMeeting: past.text)
                model.setQuery("")
            }
        case .clip(let c):
            let copyOnly = flags.contains(.command) || !store.settings.pasteOnEnter
            clipboard.write(c, plain: flags.contains(.shift))
            hide(animated: false)
            guard !copyOnly else { return }
            if Paster.trusted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Paster.pressCommandV() }
            } else {
                Paster.requestAccess()
            }
        }
    }

    private func runAnswer(_ a: Answer, flags: NSEvent.ModifierFlags) {
        let pb = NSPasteboard.general
        if flags.contains(.command), case .paste(let t) = a.action {
            clipboard.copy(text: t, source: "MONEY!")
            return hide()
        }
        switch a.action {
        case .copy(let t):
            clipboard.copy(text: t, source: "MONEY!")
            hide()
        case .copySecret(let t):
            // Marked transient so no clipboard history (ours included) keeps it.
            let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            pb.clearContents()
            pb.declareTypes([.string, transient, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
            pb.setString(t, forType: .string)
            pb.setData(Data(), forType: transient)
            hide()
        case .paste(let t):
            hide(animated: false)
            if Paster.trusted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Paster.pasteText(t) }
            } else {
                clipboard.copy(text: t, source: "MONEY!")
                Paster.requestAccess()
            }
        case .fill(let t):
            model.setQuery(t)
        case .open(let url):
            hide()
            NSWorkspace.shared.open(url)
        case .copyImage(let img):
            pb.clearContents()
            pb.writeObjects([img])
            hide()
        case .run(let keepOpen, let f):
            if !keepOpen { hide() }
            f()
        case .none:
            break
        }
    }

    /// Opens or brings forward an app (also used by the per-app hotkeys).
    func openApp(path: String) {
        if path == AppIndex.appsLauncherPath {
            show(.library)
            return
        }
        index.recordLaunch(path)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg)
    }

    // MARK: Layout

    func applySettings() {
        // The popup always keeps its dark look with white text, in Light Mode too.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.barHeight = store.settings.barHeight
        if isShown {
            anchor = restingAnchor()
            layoutPanel()
        }
    }

    private func windowSize(_ s: Settings) -> NSSize {
        NSSize(width: max(s.width, s.clipboardWidth, Metrics.textMax.width) + Metrics.margin * 2,
               height: s.barHeight + max(Metrics.clipboardList(s), Metrics.textMax.height + Metrics.listInset) + Metrics.margin * 2)
    }

    private func layoutPanel() {
        let size = windowSize(store.settings)
        let frame = NSRect(x: round(anchor.centerX - size.width / 2), y: round(anchor.top + Metrics.margin - size.height),
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// The card in window coordinates (origin bottom left).
    private func cardRect() -> NSRect {
        let s = store.settings
        let size = panel.frame.size
        let w = model.width(s), h = model.cardHeight(s)
        return NSRect(x: (size.width - w) / 2, y: size.height - Metrics.margin - h, width: w, height: h)
    }

    private func targetScreen() -> NSScreen {
        if store.settings.screen == .mouse {
            let p = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) { return s }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func restingAnchor() -> (centerX: CGFloat, top: CGFloat) {
        let s = store.settings
        let vf = targetScreen().visibleFrame
        let pos = s.position ?? [0.5, 0.4]
        let w = model.width(s)
        let bar = CGFloat(s.barHeight)
        var cx = vf.minX + CGFloat(pos[0]) * vf.width
        cx = min(max(cx, vf.minX + w / 2), vf.maxX - w / 2)
        var top = vf.maxY - CGFloat(pos[1]) * vf.height + bar / 2
        top = min(max(top, vf.minY + bar), vf.maxY)
        return (cx, top)
    }

    private func savePosition() {
        let f = panel.frame
        let cx = f.midX, top = f.maxY - Metrics.margin
        let bar = CGFloat(store.settings.barHeight)
        let screen = NSScreen.screens.first { NSMouseInRect(NSPoint(x: cx, y: top - bar / 2), $0.frame, false) } ?? panel.screen
        guard let vf = screen?.visibleFrame else { return }
        anchor = (cx, top)
        store.settings.position = [Double((cx - vf.minX) / vf.width), Double((vf.maxY - (top - bar / 2)) / vf.height)]
    }

    func resetPosition() {
        store.settings.position = nil
    }

    // MARK: Snapshot (off-screen render for checking layout; glass can't render off screen)

    func snapshot(scope: Scope, query: String, dark: Bool, to path: String) {
        index.refresh(folders: store.settings.searchFolders)
        let deadline = Date().addingTimeInterval(5)
        while index.apps.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        model.scope = model.resolve(scope)
        model.query = query
        if scope != .text { model.recompute() }
        if CommandLine.arguments.contains("--tab") {
            tab()
            print("tab →", model.scope, "query:", model.query)
        }
        if model.scope == .weather || (model.scope == .apps && !model.query.isEmpty) {
            // Let network answers (weather: place, then forecast) arrive.
            for _ in 0..<3 {
                RunLoop.main.run(until: Date().addingTimeInterval(2.5))
                model.recompute()
            }
        }
        if scope == .translate, !query.isEmpty {
            let until = Date().addingTimeInterval(10)
            while Translator.shared.result == nil, Translator.shared.error == nil, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        model.presented = true
        let root = LauncherRoot(model: model, store: store, clipboard: clipboard, onActivate: { _ in }, onTab: { _ in }, opaque: true)
        let hv = NSHostingView(rootView: root)
        let size = windowSize(store.settings)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hv
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hv.layoutSubtreeIfNeeded()
        guard let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) else { return }
        hv.cacheDisplay(in: hv.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Panel

/// Borderless, non-activating panel (the app you came from stays frontmost, so paste lands there).
/// Its window is bigger than the card; clicks outside the card close it. The bar can be dragged
/// anywhere and snaps to the screen centre and 24pt edge lines.
final class LauncherPanel: NSPanel {
    var barHeight: Double = 76
    var onDragEnded: (() -> Void)?
    var onOutsideClick: (() -> Void)?
    var cardRect: () -> NSRect = { .zero }
    /// Points (window coordinates) over buttons in the bar, which must get plain clicks.
    var isControl: (NSPoint) -> Bool = { _ in false }
    private(set) var dragging = false
    private let guides = SnapGuides()

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc from a text box other than the search field (e.g. a meeting chat) closes the popup properly.
    override func cancelOperation(_ sender: Any?) { onOutsideClick?() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            let card = cardRect()
            let p = event.locationInWindow
            if !card.contains(p), !isControl(p) {
                onOutsideClick?()
                return
            }
            if p.y >= card.maxY - CGFloat(barHeight), !isControl(p), trackDrag(card) { return }
        }
        super.sendEvent(event)
    }

    /// Returns true if the press became a drag; otherwise replays it as a normal click.
    private func trackDrag(_ card: NSRect) -> Bool {
        let start = NSEvent.mouseLocation
        let origin = frame.origin
        let bar = CGFloat(barHeight)
        let barOffset = NSPoint(x: card.minX, y: card.maxY - bar) // bar's corner within the window
        while let e = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let m = NSEvent.mouseLocation
            if e.type == .leftMouseUp {
                if dragging {
                    dragging = false
                    guides.hide()
                    onDragEnded?()
                    return true
                }
                NSApp.postEvent(e, atStart: true)
                return false
            }
            let dx = m.x - start.x, dy = m.y - start.y
            if !dragging {
                guard hypot(dx, dy) >= 4 else { continue }
                dragging = true
            }
            let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? self.screen ?? NSScreen.screens[0]
            let proposed = NSPoint(x: origin.x + dx + barOffset.x, y: origin.y + dy + barOffset.y)
            let (snapped, active) = guides.snap(proposed, size: NSSize(width: card.width, height: bar), bar: bar, in: screen.visibleFrame)
            guides.show(on: screen, active: active, below: self)
            setFrameOrigin(NSPoint(x: snapped.x - barOffset.x, y: snapped.y - barOffset.y))
        }
        return false
    }
}

final class SnapGuides {
    struct Line: Equatable { let vertical: Bool; let at: CGFloat }
    private var window: NSWindow?
    private let view = GuideView()
    private static let distance: CGFloat = 8
    private static let margin: CGFloat = 24

    func snap(_ p: NSPoint, size: NSSize, bar: CGFloat, in vf: NSRect) -> (NSPoint, [Line]) {
        var out = p
        var active: [Line] = []
        // x: popup centre ↔ screen centre, left edge ↔ left margin, right edge ↔ right margin
        let xs: [(CGFloat, CGFloat)] = [(vf.midX, size.width / 2), (vf.minX + Self.margin, 0), (vf.maxX - Self.margin, size.width)]
        if let best = xs.map({ ($0.0, $0.0 - $0.1) }).min(by: { abs($0.1 - p.x) < abs($1.1 - p.x) }), abs(best.1 - p.x) <= Self.distance {
            out.x = best.1
            active.append(Line(vertical: true, at: best.0))
        }
        // y (bottom-left origin): bar centre ↔ screen centre, top ↔ top margin, bar bottom ↔ bottom margin
        let top = p.y + size.height
        let ys: [(CGFloat, CGFloat)] = [(vf.midY, -bar / 2), (vf.maxY - Self.margin, 0), (vf.minY + Self.margin, -bar)]
        if let best = ys.map({ ($0.0, $0.0 - $0.1) }).min(by: { abs($0.1 - top) < abs($1.1 - top) }), abs(best.1 - top) <= Self.distance {
            out.y = best.1 - size.height
            active.append(Line(vertical: false, at: best.0))
        }
        return (out, active)
    }

    func show(on screen: NSScreen, active: [Line], below panel: NSWindow) {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            w.contentView = view
            window = w
        }
        guard let w = window else { return }
        w.level = NSWindow.Level(panel.level.rawValue - 1)
        if w.frame != screen.frame { w.setFrame(screen.frame, display: false) }
        let vf = screen.visibleFrame
        let o = screen.frame.origin
        let all = [Line(vertical: true, at: vf.midX), Line(vertical: true, at: vf.minX + Self.margin), Line(vertical: true, at: vf.maxX - Self.margin),
                   Line(vertical: false, at: vf.midY), Line(vertical: false, at: vf.maxY - Self.margin), Line(vertical: false, at: vf.minY + Self.margin)]
        view.lines = all.map { (Line(vertical: $0.vertical, at: $0.at - ($0.vertical ? o.x : o.y)), active.contains($0)) }
        view.span = NSRect(x: vf.minX - o.x, y: vf.minY - o.y, width: vf.width, height: vf.height)
        view.needsDisplay = true
        if !w.isVisible { w.orderFront(nil) }
    }

    func hide() { window?.orderOut(nil) }
}

final class GuideView: NSView {
    var lines: [(SnapGuides.Line, Bool)] = []
    var span = NSRect.zero

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for (line, on) in lines {
            (dark ? NSColor.white : NSColor.black).withAlphaComponent(on ? 0.7 : 0.14).setFill()
            let r = line.vertical
                ? NSRect(x: round(line.at) - 0.5, y: span.minY, width: 1, height: span.height)
                : NSRect(x: span.minX, y: round(line.at) - 0.5, width: span.width, height: 1)
            r.fill()
        }
    }
}
