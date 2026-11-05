import AppKit
import EventKit
import SwiftUI

// MARK: Calendar mode: Moneybag's month grid, week and day timelines, and the chip → detail morph, on EventKit.

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.firstWeekday = 1
    return c
}()
private let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
private let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
private let tertiary = Color.primary.opacity(0.35)
private let hairline = Color.primary.opacity(0.1)
private let nowRed = Color(red: 1, green: 69 / 255, blue: 58 / 255)

private func day(_ d: Date) -> Date { cal.startOfDay(for: d) }
private func add(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: d)! }
private func monthStart(_ d: Date) -> Date { cal.date(from: cal.dateComponents([.year, .month], from: d))! }
private func weekStart(_ d: Date) -> Date { add(day(d), 1 - cal.component(.weekday, from: d)) }
private func clock(_ d: Date) -> String { let c = cal.dateComponents([.hour, .minute], from: d); return String(format: "%d:%02d", c.hour!, c.minute!) }
private func longDate(_ d: Date) -> String {
    let c = cal.dateComponents([.weekday, .month, .day], from: d)
    return "\(weekdays[c.weekday! - 1]), \(months[c.month! - 1].prefix(3)) \(c.day!)"
}

extension CalendarEvent {
    /// Each day it touches (an all-day one ends just before midnight).
    var days: [Date] {
        let last = day(max(start, end.addingTimeInterval(-1)))
        var list: [Date] = []
        var d = day(start)
        while d <= last, list.count < 42 { list.append(d); d = add(d, 1) }
        return list
    }

    var timeText: String {
        if allDay {
            let d = days
            return d.count > 1 ? "\(longDate(d[0])) – \(longDate(d[d.count - 1])) · All day" : "\(longDate(start)) · All day"
        }
        return day(start) == day(end.addingTimeInterval(-1)) ? "\(longDate(start)) · \(clock(start)) – \(clock(end))"
            : "\(longDate(start)) \(clock(start)) – \(longDate(end)) \(clock(end))"
    }

    /// Dark text on light calendar colours, white on the rest.
    var ink: Color {
        guard let c = color.usingColorSpace(.sRGB) else { return .white }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.6 ? Color(white: 0.11) : .white
    }

    func openInCalendar() {
        let id = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        NSWorkspace.shared.open(URL(string: "ical://ekevent/\(id)?method=show&options=more") ?? URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}

enum CalendarSpan: String, CaseIterable { case day, week, month }

@MainActor @Observable final class CalendarBoard {
    static let shared = CalendarBoard()

    enum Focus: Equatable { case event(CalendarEvent), day(Date) }

    var span = CalendarSpan.month
    var anchor = day(Date())
    private(set) var byDay: [Date: [CalendarEvent]] = [:]
    private(set) var events: [CalendarEvent] = []
    /// What's open over the grid, the chip it grew from, and whether it's at full size.
    private(set) var focus: Focus?
    private(set) var from = CGRect.zero
    private(set) var expanded = false
    var measured: CGFloat?
    /// The new period slides in from the side it came from.
    private(set) var slide: CGFloat = 0
    private(set) var entered = true
    @ObservationIgnored var area = CGSize.zero
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored private var leaving = false
    @ObservationIgnored private var loaded: Date?
    @ObservationIgnored private var swipeMonitor: Any?
    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    @ObservationIgnored private var swipeSum: CGFloat = 0
    @ObservationIgnored private var swiped = false

    var gridStart: Date { weekStart(monthStart(anchor)) }
    var month: Int { cal.component(.month, from: anchor) }

    var periodStart: Date {
        switch span {
        case .month: monthStart(anchor)
        case .week: weekStart(anchor)
        case .day: anchor
        }
    }

    var shownDays: [Date] { span == .week ? (0..<7).map { add(periodStart, $0) } : [anchor] }

    var title: (String, Int) {
        let year = cal.component(.year, from: anchor)
        switch span {
        case .month: return (months[month - 1], year)
        case .day: return ("\(months[month - 1]) \(cal.component(.day, from: anchor))", year)
        case .week:
            let a = cal.component(.month, from: periodStart), b = cal.component(.month, from: add(periodStart, 6))
            return (a == b ? months[a - 1] : "\(months[a - 1].prefix(3)) – \(months[b - 1].prefix(3))", cal.component(.year, from: add(periodStart, 6)))
        }
    }

    /// The visible six weeks, from EventKit (again when forced: on opening and when the store changes).
    func load(force: Bool = false) {
        let start = gridStart
        guard force || loaded != start else { return }
        loaded = start
        events = CalendarEvents.shared.range(from: start, to: add(start, 42))
        var map: [Date: [CalendarEvent]] = [:]
        for e in events { for d in e.days { map[d, default: []].append(e) } }
        byDay = map
    }

    /// Each time the mode opens: today, nothing focused, the last span kept (as in Moneybag).
    func appear() {
        anchor = day(Date())
        focus = nil
        expanded = false
        load(force: true)
        if storeObserver == nil {
            storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CalendarBoard.shared.load(force: true) }
            }
        }
        if swipeMonitor == nil {
            swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                MainActor.assumeIsolated { CalendarBoard.shared.scrolled(e) }
                return e
            }
        }
    }

    func disappear() {
        if let m = swipeMonitor { NSEvent.removeMonitor(m) }
        swipeMonitor = nil
        if let o = storeObserver { NotificationCenter.default.removeObserver(o) }
        storeObserver = nil
        focus = nil
        expanded = false
    }

    // MARK: Moving

    func shift(_ delta: Int) {
        guard focus == nil else { return }
        switch span {
        case .day: anchor = add(anchor, delta)
        case .week: anchor = add(anchor, delta * 7)
        case .month:
            let first = cal.date(byAdding: .month, value: delta, to: monthStart(anchor))!
            anchor = monthStart(Date()) == first ? day(Date()) : first
        }
        slideIn(CGFloat(delta))
    }

    func goToday() {
        guard focus == nil else { return }
        let before = periodStart
        anchor = day(Date())
        slideIn(periodStart > before ? 1 : periodStart < before ? -1 : 0)
    }

    func pick(_ s: CalendarSpan) {
        guard focus == nil, s != span else { return }
        span = s
        slideIn(0)
    }

    private func slideIn(_ direction: CGFloat) {
        load()
        guard direction != 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            slide = direction * 56
            entered = false
        }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.24)) {
                self.slide = 0
                self.entered = true
            }
        }
    }

    private func scrolled(_ e: NSEvent) {
        guard e.hasPreciseScrollingDeltas, e.window is LauncherPanel else { return }
        if e.phase == .began { swipeSum = 0; swiped = false }
        guard e.phase == .began || e.phase == .changed, !swiped, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
        swipeSum += e.scrollingDeltaX
        guard abs(swipeSum) >= 48 else { return }
        swiped = true
        shift(swipeSum > 0 ? -1 : 1)
    }

    // MARK: Focus

    func open(_ f: Focus, from rect: CGRect) {
        leaving = false
        measured = nil
        expanded = false
        from = rect
        focus = f
    }

    /// Once the card knows its height, it springs out of the chip.
    func grow() {
        guard focus != nil, !expanded, !leaving else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { expanded = true; return }
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 360, damping: 34)) { expanded = true }
    }

    func close() {
        guard focus != nil, !leaving else { return }
        leaving = true
        withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.22)) {
            expanded = false
        } completion: {
            guard self.leaving else { return }
            self.focus = nil
            self.leaving = false
        }
    }

    private func openNext() {
        let now = Date()
        guard let next = events.filter({ $0.end > now }).min(by: { $0.start < $1.start }) else { return }
        open(.event(next), from: CGRect(x: area.width / 2 - 20, y: area.height / 2 - 10, width: 40, height: 20))
    }

    /// The bar's keys: ↩ opens the next event (or joins / shows the open one), Esc closes it, Page Up/Down and ←→ move,
    /// Tab goes Day → Week → Month.
    func handle(_ sel: Selector, typing: Bool) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)) where focus != nil: close()
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)): return focus != nil
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): shift(-1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): shift(1)
        case #selector(NSResponder.moveLeft(_:)) where !typing && focus == nil: shift(-1)
        case #selector(NSResponder.moveRight(_:)) where !typing && focus == nil: shift(1)
        case #selector(NSResponder.insertTab(_:)) where focus == nil:
            let all = CalendarSpan.allCases
            pick(all[(all.firstIndex(of: span)! + 1) % all.count])
        case #selector(NSResponder.insertNewline(_:)):
            if case .event(let e)? = focus {
                if let link = e.link { NSWorkspace.shared.open(link) } else { e.openInCalendar() }
            } else if focus == nil {
                openNext()
            }
        default: return false
        }
        return true
    }
}

// MARK: The panel

struct CalendarPanel: View {
    let board: CalendarBoard
    let query: String
    let radius: CGFloat
    @State private var events = CalendarEvents.shared

    static let header: CGFloat = 32
    static let headerGap: CGFloat = 6
    static let weekdayRow: CGFloat = 17
    static let cell: CGFloat = 80
    static var grid: CGFloat { weekdayRow + cell * 6 }
    static var height: CGFloat { PanelLayout.vertical + header + headerGap + grid }
    static let space = "calendar"

    var body: some View {
        let blocked = !events.authorized
        VStack(alignment: .leading, spacing: 0) {
            if blocked { AccessBanner(undecided: events.undecided).padding(.bottom, Self.headerGap) }
            CalendarHeader(board: board).frame(height: Self.header).padding(.bottom, Self.headerGap)
            GeometryReader { g in
                Group {
                    if board.span == .month {
                        MonthGrid(board: board, query: query, width: g.size.width, cell: (g.size.height - Self.weekdayRow) / 6)
                    } else {
                        CalendarTimeline(board: board, query: query, width: g.size.width, height: g.size.height)
                    }
                }
                .offset(x: board.slide)
                .opacity(board.entered ? 1 : 0)
            }
            .frame(height: Self.grid - (blocked ? 40 : 0))
        }
        .padding(PanelLayout.edges)
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { board.area = $0 }
        .overlay { if board.focus != nil { FocusCard(board: board, radius: radius) } }
        .onAppear { board.appear() }
        .onDisappear { board.disappear() }
        .onChange(of: events.access) { board.load(force: true) }
    }
}

private struct AccessBanner: View {
    let undecided: Bool
    private let coral = Color(red: 1, green: 106 / 255, blue: 85 / 255)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.open").font(.system(size: 10)).foregroundStyle(coral)
            Text("Allow MONEY! to read your calendars").font(.system(size: 12.5))
            Spacer(minLength: 0)
            Button { CalendarEvents.shared.requestAccess() } label: { Pill(text: undecided ? "Allow" : "Open Settings") }.buttonStyle(Press())
        }
        .padding(.leading, 12).padding(.trailing, 1)
        .frame(height: 34)
        .background(Capsule().fill(coral.opacity(0.14)))
    }
}

private struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.7 : 1) }
}

/// A capsule button the height of the round ones.
private struct Pill: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
            .contentShape(Capsule())
    }
}

private struct CalendarHeader: View {
    let board: CalendarBoard

    var body: some View {
        let (title, year) = board.title
        HStack(spacing: 4) {
            Text("\(Text(title).font(.system(size: 15, weight: .semibold))) \(Text(String(year)).font(.system(size: 15)).foregroundStyle(tertiary))")
                .lineLimit(1)
                .padding(.leading, 7)
            Spacer(minLength: 0)
            SpanSwitch(board: board).padding(.trailing, 4)
            Button { board.goToday() } label: { Pill(text: "Today") }.buttonStyle(Press())
            ClockButton(symbol: "chevron.left", help: "Previous") { board.shift(-1) }
            ClockButton(symbol: "chevron.right", help: "Next") { board.shift(1) }
        }
    }
}

/// Day · Week · Month, with the selected one on a sliding pill.
private struct SpanSwitch: View {
    let board: CalendarBoard
    private let segment: CGFloat = 54
    private let inset: CGFloat = 4

    var body: some View {
        let index = CGFloat(CalendarSpan.allCases.firstIndex(of: board.span)!)
        HStack(spacing: 0) {
            ForEach(CalendarSpan.allCases, id: \.self) { s in
                let on = s == board.span
                Button { board.pick(s) } label: {
                    Text(s.rawValue.capitalized).font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .frame(width: segment, height: 32 - inset * 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Press())
            }
        }
        .background(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.15)).frame(width: segment).offset(x: index * segment)
                .animation(.interpolatingSpring(mass: 1, stiffness: 420, damping: 36), value: index)
        }
        .padding(inset)
        .background(Capsule().fill(Color.primary.opacity(0.1)))
    }
}

// MARK: Month

private struct DayBadge: View {
    let date: Date
    var body: some View {
        let today = date == day(Date())
        Text("\(cal.component(.day, from: date))")
            .font(.system(size: 11, weight: today ? .bold : .medium))
            .foregroundStyle(today ? Color.black : Color.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(Capsule().fill(today ? Color.white : .clear))
    }
}

private func matching(_ list: [CalendarEvent], _ q: String) -> [CalendarEvent] {
    let q = q.trimmingCharacters(in: .whitespaces)
    return q.isEmpty ? list : list.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.location ?? "").localizedCaseInsensitiveContains(q) }
}

private struct MonthGrid: View {
    let board: CalendarBoard
    let query: String
    let width: CGFloat
    let cell: CGFloat

    var body: some View {
        let column = width / 7
        let start = board.gridStart
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { d in
                    Text(d).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tertiary).frame(width: column)
                }
            }
            .frame(height: CalendarPanel.weekdayRow, alignment: .top)
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let date = add(start, row * 7 + col)
                        DayCell(board: board, date: date, items: matching(board.byDay[date] ?? [], query), inMonth: cal.component(.month, from: date) == board.month)
                            .frame(width: column, height: cell, alignment: .topLeading)
                    }
                }
            }
        }
    }
}

private struct DayCell: View {
    let board: CalendarBoard
    let date: Date
    let items: [CalendarEvent]
    let inMonth: Bool

    var body: some View {
        // Three chips fit; with more, two and a "+N more" so it's never cut off.
        let shown = items.count > 3 ? 2 : items.count
        let lines = items.count <= 1 ? 3 : items.count == 2 ? 2 : 1
        VStack(alignment: .leading, spacing: 2) {
            DayBadge(date: date)
            ForEach(items.prefix(shown), id: \.key) { e in
                Chip(event: e, lines: lines, key: "m\(e.key)\(date.timeIntervalSince1970)", board: board) { board.open(.event(e), from: $0) }
            }
            if items.count > shown {
                More(count: items.count - shown, key: "more\(date.timeIntervalSince1970)", board: board) { board.open(.day(date), from: $0) }
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .top) { hairline.frame(height: 0.5) }
        .opacity(inMonth ? 1 : 0.55)
    }
}

/// Remembers where it sits, so the detail card can grow out of it.
private struct Tracked: ViewModifier {
    let key: String
    let board: CalendarBoard
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CalendarPanel.space)) } action: { board.frames[key] = $0 }
    }
}

private struct Chip: View {
    let event: CalendarEvent
    let lines: Int
    let key: String
    let board: CalendarBoard
    let onPick: (CGRect) -> Void

    var body: some View {
        let color = Color(nsColor: event.color)
        Button { onPick(board.frames[key] ?? .zero) } label: {
            HStack(alignment: .top, spacing: 3) {
                if !event.allDay { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 9.5).padding(.top, 1.5) }
                Text(event.allDay ? event.title : "\(clock(event.start)) \(event.title)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(event.allDay ? event.ink : Color.primary)
                    .lineLimit(lines)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1.75)
            .frame(minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(event.allDay ? color : color.opacity(0.25)))
            .contentShape(Rectangle())
            .modifier(Tracked(key: key, board: board))
        }
        .buttonStyle(Press())
        .help(event.allDay ? event.title : "\(clock(event.start)) \(event.title)")
    }
}

private struct More: View {
    let count: Int
    let key: String
    let board: CalendarBoard
    let onPick: (CGRect) -> Void

    var body: some View {
        Button { onPick(board.frames[key] ?? .zero) } label: {
            Text("+\(count) more").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 4).frame(height: 14)
                .contentShape(Rectangle())
                .modifier(Tracked(key: key, board: board))
        }
        .buttonStyle(Press())
    }
}

// MARK: Week and day

private struct TimeBlock: Identifiable {
    let event: CalendarEvent
    var top: CGFloat
    var height: CGFloat
    var column = 0
    var columns = 1
    var id: String { event.key }
}

private struct CalendarTimeline: View {
    let board: CalendarBoard
    let query: String
    let width: CGFloat
    let height: CGFloat

    static let hour: CGFloat = 40
    static let gutter: CGFloat = 38
    static let top: CGFloat = 6

    static func y(_ minute: Double) -> CGFloat { top + CGFloat(minute / 60) * hour }

    static func minute(_ t: Date, in d: Date) -> Double {
        if t <= d { return 0 }
        if t >= add(d, 1) { return 1440 }
        let c = cal.dateComponents([.hour, .minute], from: t)
        return Double(c.hour! * 60 + c.minute!)
    }

    /// Overlapping events share their cluster's width side by side (Moneybag's layout).
    static func layout(_ d: Date, _ events: [CalendarEvent]) -> [TimeBlock] {
        var blocks: [TimeBlock] = events.map { e in
            let from: Double = minute(e.start, in: d)
            let length = CGFloat((minute(e.end, in: d) - from) / 60) * hour
            return TimeBlock(event: e, top: y(from), height: max(18, length))
        }
        blocks.sort { $0.top != $1.top ? $0.top < $1.top : $0.height > $1.height }
        var cluster: [Int] = [], ends: [CGFloat] = [], bottom = -CGFloat.infinity
        func settle() { for i in cluster { blocks[i].columns = ends.count } }
        for i in blocks.indices {
            if blocks[i].top >= bottom { settle(); cluster = []; ends = [] }
            let free = ends.firstIndex { $0 <= blocks[i].top }
            blocks[i].column = free ?? ends.count
            if let free { ends[free] = blocks[i].top + blocks[i].height } else { ends.append(blocks[i].top + blocks[i].height) }
            cluster.append(i)
            bottom = max(bottom, blocks[i].top + blocks[i].height)
        }
        settle()
        return blocks
    }

    var body: some View {
        let days = board.shownDays
        let column = (width - Self.gutter) / CGFloat(days.count)
        let columns = days.map { d in
            let items = matching(board.byDay[d] ?? [], query)
            return (day: d, allDay: items.filter(\.allDay), blocks: Self.layout(d, items.filter { !$0.allDay }))
        }
        let tops = columns.flatMap { $0.blocks.map(\.top) }
        let first = tops.min().map { Int(($0 - Self.top) / Self.hour) } ?? 8
        let startHour = min(first >= 8 && first < 17 ? 8 : first, 15)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { d in
                    HStack(spacing: 3) {
                        Text(weekdays[cal.component(.weekday, from: d) - 1]).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tertiary)
                        DayBadge(date: d)
                    }
                    .frame(width: column)
                }
            }
            .padding(.leading, Self.gutter)
            .padding(.bottom, 4)
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(.system(size: 9.5)).foregroundStyle(tertiary)
                    .frame(width: Self.gutter - 6, alignment: .trailing).padding(.trailing, 6).padding(.top, 2)
                ForEach(columns, id: \.day) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(c.allDay.prefix(2), id: \.key) { e in
                            Chip(event: e, lines: 1, key: "a\(e.key)\(c.day.timeIntervalSince1970)", board: board) { board.open(.event(e), from: $0) }
                        }
                        if c.allDay.count > 2 {
                            More(count: c.allDay.count - 2, key: "amore\(c.day.timeIntervalSince1970)", board: board) { board.open(.day(c.day), from: $0) }
                        }
                    }
                    .padding(.horizontal, 1)
                    .frame(width: column, alignment: .topLeading)
                }
            }
            .padding(.vertical, 3)
            .frame(minHeight: 24, alignment: .top)
            .overlay(alignment: .top) { hairline.frame(height: 0.5) }
            .overlay(alignment: .bottom) { hairline.frame(height: 0.5) }
            GeometryReader { g in
                ScrollView(.vertical, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<25, id: \.self) { h in
                            Color.primary.opacity(0.08).frame(height: 0.5).padding(.leading, Self.gutter).offset(y: Self.y(Double(h * 60)))
                        }
                        ForEach(1..<24, id: \.self) { h in
                            Text("\(h):00").font(.system(size: 9.5)).foregroundStyle(tertiary)
                                .frame(width: Self.gutter - 6, height: 12, alignment: .trailing)
                                .offset(y: Self.y(Double(h * 60)) - 6)
                        }
                        ForEach(Array(columns.enumerated()), id: \.element.day) { i, c in
                            ZStack(alignment: .topLeading) {
                                Color.primary.opacity(0.06).frame(width: 0.5)
                                ForEach(c.blocks) { b in
                                    EventBlock(block: b, board: board)
                                        .frame(width: column / CGFloat(b.columns) - 2, height: b.height)
                                        .offset(x: CGFloat(b.column) * column / CGFloat(b.columns) + 1, y: b.top)
                                }
                            }
                            .frame(width: column, height: Self.y(1440) + Self.top, alignment: .topLeading)
                            .offset(x: Self.gutter + CGFloat(i) * column)
                        }
                        if let i = days.firstIndex(of: day(Date())) {
                            TimelineView(.everyMinute) { t in
                                HStack(spacing: 0) {
                                    Circle().fill(nowRed).frame(width: 7, height: 7)
                                    nowRed.frame(height: 1.5)
                                }
                                .frame(width: column + 3.5, height: 7)
                                .offset(x: Self.gutter + CGFloat(i) * column - 3.5, y: Self.y(Self.minute(t.date, in: day(t.date))) - 3.5)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: width, height: Self.y(1440) + Self.top, alignment: .topLeading)
                }
                // Opens at 8:00, or earlier when something starts earlier (Moneybag's rule), on each new period.
                .defaultScrollAnchor(UnitPoint(x: 0, y: (Self.y(Double(startHour * 60)) - Self.top * 2) / max(1, Self.y(1440) + Self.top - g.size.height)),
                                     for: .initialOffset)
                .id("\(board.span)\(board.periodStart)")
            }
        }
        .frame(width: width, height: height, alignment: .top)
    }
}

private struct EventBlock: View {
    let block: TimeBlock
    let board: CalendarBoard

    var body: some View {
        let e = block.event
        let color = Color(nsColor: e.color)
        let compact = block.height < 13 * 2 + 4
        Button { board.open(.event(e), from: board.frames["b\(block.id)"] ?? .zero) } label: {
            VStack(alignment: .leading, spacing: 0) {
                if compact {
                    Text("\(Text(e.title).font(.system(size: 10.5, weight: .semibold))) \(Text(clock(e.start)).font(.system(size: 10)).foregroundStyle(.secondary))")
                        .lineLimit(1)
                } else {
                    Text(e.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(max(1, Int((block.height - 4) / 13) - 1))
                    Text("\(clock(e.start)) – \(clock(e.end))").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, 2.5 + 3 + 3)
            .padding(.trailing, 3)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3).padding(.vertical, 2.5).padding(.leading, 2.5)
            }
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
            .modifier(Tracked(key: "b\(block.id)", board: board))
        }
        .buttonStyle(Press())
        .help("\(clock(e.start)) – \(clock(e.end)) \(e.title)")
    }
}

// MARK: Detail

/// The event (or the day's list) on a card that grows out of the chip that was clicked, over a dimmed grid.
private struct FocusCard: View {
    let board: CalendarBoard
    let radius: CGFloat

    var body: some View {
        let area = board.area
        let width = min(380, area.width - 24)
        let height = min(board.measured ?? area.height, area.height - 24)
        let to = CGRect(x: (area.width - width) / 2, y: max(12, (area.height - height) / 2), width: width, height: height)
        let rect = board.expanded ? to : board.from
        let open = board.expanded
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom).frame(height: 56)
                Color.black.opacity(0.5)
            }
            .contentShape(Rectangle())
            .onTapGesture { board.close() }
            .opacity(open ? 1 : 0)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
                    .opacity(open ? 1 : 0)
                    .animation(open ? .easeOut(duration: 0.07) : .easeIn(duration: 0.07).delay(0.15), value: open)
                ScrollView(.vertical, showsIndicators: false) {
                    detail
                        .frame(width: width, alignment: .topLeading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                            board.measured = h
                            board.grow()
                        }
                }
                .frame(width: width, height: height)
                .opacity(open ? 1 : 0)
                .animation(open ? .easeOut(duration: 0.12).delay(0.1) : .linear(duration: 0.08), value: open)
            }
            .frame(width: max(1, rect.width), height: max(1, rect.height), alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: open ? radius : 4, style: .continuous))
            .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
    }

    @ViewBuilder private var detail: some View {
        switch board.focus {
        case .event(let e)?: EventDetail(event: e, radius: radius)
        case .day(let d)?: DayDetail(date: d, items: board.byDay[d] ?? [], radius: radius, board: board)
        case nil: EmptyView()
        }
    }
}

private struct EventDetail: View {
    let event: CalendarEvent
    let radius: CGFloat

    var body: some View {
        let pad = PanelLayout.inset
        let actions = event.link == nil ? 1 : 2
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: event.color)).frame(width: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).font(.system(size: 15.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(event.timeText).font(.system(size: 12)).foregroundStyle(.secondary)
                    if !event.calendar.isEmpty { Text(event.calendar).font(.system(size: 11.5)).foregroundStyle(tertiary) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, CGFloat(actions) * 36 + radius - 16 - pad)
            if let place = event.location {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                    Text(place).font(.system(size: 13)).textSelection(.enabled)
                }
            }
            if let notes = event.notes {
                Text(notes).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                if let link = event.link {
                    Button { NSWorkspace.shared.open(link) } label: {
                        Image(systemName: "video.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                            .frame(width: 32, height: 32).background(Circle().fill(Color.white))
                    }
                    .buttonStyle(Press()).help("Join")
                }
                ClockButton(symbol: "arrow.up.right.square", help: "Open in Calendar") { event.openInCalendar() }
            }
            .padding(radius - 16)
        }
    }
}

private struct DayDetail: View {
    let date: Date
    let items: [CalendarEvent]
    let radius: CGFloat
    let board: CalendarBoard

    var body: some View {
        let pad: CGFloat = 12
        VStack(alignment: .leading, spacing: 2) {
            Text(longDate(date)).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 4).padding(.bottom, 6)
            ForEach(items, id: \.key) { e in
                Button { board.open(.event(e), from: board.from) } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.color)).frame(width: 3, height: 16)
                        Text(e.allDay ? "All day" : "\(clock(e.start)) – \(clock(e.end))").font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(width: 82, alignment: .leading)
                        Text(e.title).font(.system(size: 13.5)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowPress(radius: PanelLayout.inner(radius, by: pad)))
            }
        }
        .padding(pad)
    }
}

private struct RowPress: ButtonStyle {
    let radius: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(configuration.isPressed ? selectedFill : .clear))
    }
}
