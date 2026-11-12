import AppKit
import SwiftUI

// Class timetable (ported from the owner's iOS app Jikanwari): terms of days × periods, which class is next and where,
// in the notch, the search bar and Ask. Kept as JSON in Application Support. The UI calls a term a schedule: each
// applies over its own dates, and where two cover a day the shorter one is used (an exam week inside a term).

/// One period of the school day, "9:00" to "10:30". One that ends before it starts runs past midnight.
struct ClassPeriod: Codable, Hashable {
    var start: String
    var end: String
}

/// Which weeks a class meets. Week 1 is the week the term starts (or the ISO week when the term has no start date).
struct ClassWeeks: Codable, Hashable {
    /// 1 odd weeks, 2 even weeks.
    var parity: Int?
    var from: String?
    var to: String?
    /// Only these weeks, or every week but these (their Mondays, yyyy-MM-dd): Jikanwari's B' weeks.
    var only: [String]?
    var skip: [String]?

    var label: String {
        if parity == 1 { return "Odd weeks" }
        if parity == 2 { return "Even weeks" }
        if only != nil || skip != nil { return "Some weeks" }
        if from != nil || to != nil { return "\(from.map(TimetableTerm.short) ?? "") – \(to.map(TimetableTerm.short) ?? "")" }
        return "Every week"
    }
}

/// A class in one cell of the week.
struct ClassItem: Codable, Hashable, Identifiable {
    var id = UUID()
    /// 0 Monday … 6 Sunday.
    var day: Int
    /// Index into the term's periods.
    var period: Int
    var name: String
    var room = ""
    var teacher = ""
    /// "#RRGGBB"; nil takes a colour from the name.
    var color: String?
    var note = ""
    /// An online class's meeting link.
    var link = ""
    var weeks: ClassWeeks?
    /// Split from the same class in the period before: drawn and counted on its own.
    var apart = false

    init(day: Int, period: Int, name: String, room: String = "", teacher: String = "", color: String? = nil, note: String = "",
         link: String = "", weeks: ClassWeeks? = nil, apart: Bool = false) {
        (self.day, self.period, self.name, self.room, self.teacher) = (day, period, name, room, teacher)
        (self.color, self.note, self.link, self.weeks, self.apart) = (color, note, link, weeks, apart)
    }

    /// Lenient, so hand-written and older files load (only day, period and name are needed).
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        day = try c.decode(Int.self, forKey: .day)
        period = try c.decode(Int.self, forKey: .period)
        name = try c.decode(String.self, forKey: .name)
        room = (try? c.decode(String.self, forKey: .room)) ?? ""
        teacher = (try? c.decode(String.self, forKey: .teacher)) ?? ""
        color = try? c.decode(String.self, forKey: .color)
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        link = (try? c.decode(String.self, forKey: .link)) ?? ""
        weeks = try? c.decode(ClassWeeks.self, forKey: .weeks)
        apart = (try? c.decode(Bool.self, forKey: .apart)) ?? false
    }

    var tint: Color { Color(nsColor: nsTint) }
    var nsTint: NSColor { color.flatMap(NSColor.init(hex:)) ?? NSColor(hex: TimetableTerm.palette[TimetableTerm.paletteIndex(name)])! }
}

/// A schedule (a term, an exam week, a holiday…): its dates, school days, periods and classes.
struct TimetableTerm: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// A label of the user's ("Exam period"); "" for none.
    var kind = ""
    /// School days, 0 Monday … 6 Sunday.
    var days: [Int] = [0, 1, 2, 3, 4]
    var periods: [ClassPeriod]
    var classes: [ClassItem] = []
    /// First and last day, yyyy-MM-dd ("" when open).
    var start = ""
    var end = ""

    init(name: String, days: [Int] = [0, 1, 2, 3, 4], periods: [ClassPeriod], classes: [ClassItem] = [], start: String = "", end: String = "") {
        (self.name, self.days, self.periods, self.classes, self.start, self.end) = (name, days, periods, classes, start, end)
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Timetable"
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        days = (try? c.decode([Int].self, forKey: .days)) ?? [0, 1, 2, 3, 4]
        periods = try c.decode([ClassPeriod].self, forKey: .periods)
        classes = (try? c.decode([ClassItem].self, forKey: .classes)) ?? []
        start = (try? c.decode(String.self, forKey: .start)) ?? ""
        end = (try? c.decode(String.self, forKey: .end)) ?? ""
    }

    static func blank(_ name: String = "Timetable") -> TimetableTerm {
        TimetableTerm(name: name, periods: [("9:00", "10:30"), ("10:40", "12:10"), ("13:00", "14:30"), ("14:40", "16:10"), ("16:20", "17:50")]
            .map { ClassPeriod(start: $0.0, end: $0.1) })
    }

    func classes(day: Int, period: Int) -> [ClassItem] { classes.filter { $0.day == day && $0.period == period } }

    /// Does its date range take in this day (yyyy-MM-dd)?
    func covers(_ d: String) -> Bool { (start.isEmpty || d >= start) && (end.isEmpty || d <= end) }

    /// Days in its range; an open end is longest.
    var length: Int {
        guard let s = TimetableTerm.parse(start), let e = TimetableTerm.parse(end) else { return .max }
        return Calendar.current.dateComponents([.day], from: s, to: e).day ?? .max
    }

    /// "Sep 21 – Jan 29", "From Apr 5", "Any date".
    var range: String { TimetableTerm.range(start, end) }

    static func range(_ s: String, _ e: String) -> String {
        s.isEmpty ? e.isEmpty ? "Any date" : "Until \(short(e))" : e.isEmpty ? "From \(short(s))" : "\(short(s)) – \(short(e))"
    }

    /// Alone in its cell and the same class (name and room) as the one alone in the period before: one block with it.
    func joinsAbove(_ c: ClassItem) -> Bool {
        guard !c.apart, c.period > 0, !c.name.isEmpty, classes(day: c.day, period: c.period).count == 1 else { return false }
        let above = classes(day: c.day, period: c.period - 1)
        return above.count == 1 && above[0].name == c.name && above[0].room == c.room
    }

    /// The class and the same class in the periods next to it, top first (the grid draws them as one cell).
    func block(of id: UUID) -> [ClassItem] {
        guard var top = classes.first(where: { $0.id == id }) else { return [] }
        while joinsAbove(top), let up = classes(day: top.day, period: top.period - 1).first { top = up }
        var out = [top]
        while let below = classes(day: top.day, period: out.last!.period + 1).first, joinsAbove(below) { out.append(below) }
        return out
    }
}

/// A class on a real day: consecutive periods of the same class in the same room count as one (Jikanwari's rule).
struct ClassOccurrence: Equatable {
    var item: ClassItem
    var first: Int
    var last: Int
    var start: Date
    var end: Date

    var key: String { "\(item.id)-\(Int(start.timeIntervalSince1970))" }
    /// "3rd period", "3rd–4th periods".
    var periodsLabel: String {
        first == last ? "\(TimetableTerm.ordinal(first + 1)) period" : "\(TimetableTerm.ordinal(first + 1))–\(TimetableTerm.ordinal(last + 1)) periods"
    }
    var timeRange: String { start.formatted(date: .omitted, time: .shortened) + "–" + end.formatted(date: .omitted, time: .shortened) }
}

extension TimetableTerm {
    /// Each period's start and end in minutes from the school day's midnight; a period earlier than the one before
    /// it, or ending before it starts, has gone past midnight.
    var spans: [(start: Int, end: Int)] {
        var out: [(Int, Int)] = []
        var base = 0, prev = -1
        for p in periods {
            var s = (TimetableTerm.minutes(p.start) ?? 0) + base
            if s < prev { base += 1440; s += 1440 }
            var e = (TimetableTerm.minutes(p.end) ?? 0) + base
            if e <= s { e += 1440 }
            out.append((s, e))
            prev = s
        }
        return out
    }

    /// 30 minutes or more since the period before (lunch): the same class either side is two classes.
    func longBreak(before i: Int, _ sp: [(start: Int, end: Int)]) -> Bool { i > 0 && i < sp.count && sp[i].start - sp[i - 1].end >= 30 }

    /// Does the class meet on this day (weekday, the term's dates, its weeks)?
    func meets(_ c: ClassItem, on day: Date, _ cal: Calendar) -> Bool {
        guard TimetableTerm.weekday(day, cal) == c.day, days.contains(c.day), c.period < periods.count else { return false }
        let d = TimetableTerm.dayString(day, cal)
        if !start.isEmpty, d < start { return false }
        if !end.isEmpty, d > end { return false }
        guard let w = c.weeks else { return true }
        if let f = w.from, d < f { return false }
        if let t = w.to, d > t { return false }
        let monday = TimetableTerm.dayString(TimetableTerm.monday(day, cal), cal)
        if let only = w.only, !only.contains(monday) { return false }
        if let skip = w.skip, skip.contains(monday) { return false }
        if let p = w.parity { return week(of: day, cal) % 2 == (p == 1 ? 1 : 0) }
        return true
    }

    /// Week 1 is the term's first week (or the ISO week number without a start date).
    func week(of day: Date, _ cal: Calendar) -> Int {
        guard let s = TimetableTerm.parse(start, cal) else { return Calendar(identifier: .iso8601).component(.weekOfYear, from: day) }
        let days = cal.dateComponents([.day], from: TimetableTerm.monday(s, cal), to: TimetableTerm.monday(day, cal)).day ?? 0
        return Int((Double(days) / 7).rounded(.down)) + 1
    }

    /// The day's classes in order, consecutive periods of one class joined.
    func occurrences(on day: Date, _ cal: Calendar = .current) -> [ClassOccurrence] {
        let midnight = cal.startOfDay(for: day), sp = spans
        var out: [ClassOccurrence] = []
        for c in classes.filter({ meets($0, on: midnight, cal) }).sorted(by: { ($0.period, $0.name) < ($1.period, $1.name) }) {
            if !c.apart, let k = out.lastIndex(where: { $0.item.name == c.name && $0.item.room == c.room && $0.last == c.period - 1 }), !longBreak(before: c.period, sp) {
                out[k].last = c.period
                out[k].end = cal.date(byAdding: .minute, value: sp[c.period].end, to: midnight)!
                continue
            }
            out.append(ClassOccurrence(item: c, first: c.period, last: c.period,
                                       start: cal.date(byAdding: .minute, value: sp[c.period].start, to: midnight)!,
                                       end: cal.date(byAdding: .minute, value: sp[c.period].end, to: midnight)!))
        }
        return out.sorted { $0.start < $1.start }
    }

    func current(at now: Date, _ cal: Calendar = .current) -> ClassOccurrence? { [self].current(at: now, cal) }
    func next(after now: Date, _ cal: Calendar = .current) -> ClassOccurrence? { [self].next(after: now, cal) }
}

/// All the schedules: each day's classes come from the schedule in effect that day.
extension Array where Element == TimetableTerm {
    /// The schedule whose dates cover the day; where several do, the shortest range, then the later start, then the first.
    func inEffect(on day: Date, _ cal: Calendar = .current) -> TimetableTerm? { inEffect(TimetableTerm.dayString(day, cal)) }

    func inEffect(_ d: String) -> TimetableTerm? {
        filter { $0.covers(d) }.enumerated().min { a, b in (a.element.length, b.element.start, a.offset) < (b.element.length, a.element.start, b.offset) }?.element
    }

    func occurrences(on day: Date, _ cal: Calendar = .current) -> [ClassOccurrence] { inEffect(on: day, cal)?.occurrences(on: day, cal) ?? [] }

    /// The class under way (yesterday's too, when its last period runs past midnight).
    func current(at now: Date, _ cal: Calendar = .current) -> ClassOccurrence? {
        let today = cal.startOfDay(for: now)
        for offset in [-1, 0] {
            let day = cal.date(byAdding: .day, value: offset, to: today)!
            if let o = occurrences(on: day, cal).first(where: { $0.start <= now && now < $0.end }) { return o }
        }
        return nil
    }

    /// The next class to start, looking two weeks ahead (from yesterday, for periods past midnight), each day in its own schedule.
    func next(after now: Date, _ cal: Calendar = .current) -> ClassOccurrence? {
        let today = cal.startOfDay(for: now)
        for offset in -1..<15 {
            let day = cal.date(byAdding: .day, value: offset, to: today)!
            if let o = occurrences(on: day, cal).first(where: { $0.start > now }) { return o }
        }
        return nil
    }

    /// One plain line for each two dated schedules that overlap: which one is used there, and when.
    var overlapNotes: [String] {
        var out: [String] = []
        for i in indices { for j in indices where j > i {
            let s = Swift.max(self[i].start, self[j].start), e = [self[i].end, self[j].end].filter { !$0.isEmpty }.min() ?? ""
            guard e.isEmpty || s <= e, self[i].covers(s), self[j].covers(s), let win = [self[i], self[j]].inEffect(s) else { continue }
            let lose = win.id == self[i].id ? self[j] : self[i]
            if lose.start.isEmpty, lose.end.isEmpty { continue } // one with no dates fills in where nothing else is: no news
            out.append("\(win.name) is used over \(lose.name) (\(TimetableTerm.range(s, e))).")
        } }
        return out
    }
}

/// The saved timetables, the clock the notch reads, and undo.
@MainActor @Observable final class Timetables {
    static let shared = Timetables()

    struct Saved: Codable {
        var terms: [TimetableTerm]
        /// Older files: the term picked by hand. Read once (it goes first, so it wins a tie); no longer written.
        var active: UUID?
        var look: TimetableLook?
    }

    private(set) var terms: [TimetableTerm] = []
    /// The schedule open in the editor (not saved: it starts on today's).
    private(set) var editingID: UUID?
    var look = TimetableLook() { didSet { if look != oldValue { save() } } }
    /// The clock the notch's countdowns read; it moves on once a minute.
    private(set) var now = Date()
    /// Closed from the notch (each alert and each class under way on its own).
    private(set) var dismissed: Set<String> = []
    private(set) var canUndo = false
    private(set) var canRedo = false

    @ObservationIgnored private var undoStack: [Saved] = []
    @ObservationIgnored private var redoStack: [Saved] = []
    @ObservationIgnored private var lastUndoKey: String?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var flashed: Set<String> = []
    /// Snapshots and tests: made-up terms, a fixed clock, nothing saved.
    @ObservationIgnored private(set) var demo = false

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MONEY/timetable.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let s = Self.decode(data) {
            terms = s.terms
            look = s.look ?? TimetableLook()
        }
        startTicker()
    }

    /// The saved file, with an older file's hand-picked term moved first.
    static func decode(_ data: Data) -> Saved? {
        guard var s = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        if let i = s.terms.firstIndex(where: { $0.id == s.active }) { s.terms.insert(s.terms.remove(at: i), at: 0) }
        return s
    }

    /// The schedule in effect today.
    var today: TimetableTerm? { terms.inEffect(on: now) }
    var editing: TimetableTerm? { terms.first { $0.id == editingID } ?? today ?? terms.first }

    // MARK: Changes

    private var snapshot: Saved { Saved(terms: terms, active: editingID, look: nil) }

    /// Every change goes through here: one undo step each (typing in one field is one step).
    func edit(_ undoKey: String? = nil, _ change: (inout TimetableTerm) -> Void) {
        if editing == nil { terms = [.blank()]; editingID = terms[0].id }
        guard let i = terms.firstIndex(where: { $0.id == editing?.id }) else { return }
        var t = terms[i]
        change(&t)
        guard t != terms[i] else { return }
        pushUndo(undoKey)
        terms[i] = t
        changed()
    }

    func addTerm(_ t: TimetableTerm) {
        pushUndo(nil)
        terms.append(t)
        editingID = t.id
        changed()
    }

    /// A copy with its classes, after it in the list.
    func duplicate(_ t: TimetableTerm) {
        var c = t
        c.id = UUID()
        c.name = t.name + " copy"
        c.classes = t.classes.map { var x = $0; x.id = UUID(); return x }
        addTerm(c)
    }

    /// An import's days, periods and classes into a schedule; its name, kind and dates stay.
    func replace(_ id: UUID, with t: TimetableTerm) {
        guard let i = terms.firstIndex(where: { $0.id == id }) else { return addTerm(t) }
        pushUndo(nil)
        (terms[i].days, terms[i].periods, terms[i].classes) = (t.days, t.periods, t.classes)
        editingID = id
        changed()
    }

    func select(_ id: UUID) { editingID = id }

    func deleteTerm(_ id: UUID) {
        pushUndo(nil)
        terms.removeAll { $0.id == id }
        if editingID == id { editingID = nil }
        changed()
    }

    private func pushUndo(_ key: String?) {
        defer { lastUndoKey = key }
        if key != nil, key == lastUndoKey { return }
        undoStack.append(snapshot)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack = []
    }

    func undo() { step(&undoStack, &redoStack) }
    func redo() { step(&redoStack, &undoStack) }

    private func step(_ from: inout [Saved], _ to: inout [Saved]) {
        guard let s = from.popLast() else { return }
        to.append(snapshot)
        terms = s.terms
        editingID = s.active
        lastUndoKey = nil
        changed()
    }

    private func changed() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        save()
        notify()
    }

    private func save() {
        guard !demo else { return }
        let s = Saved(terms: terms, active: nil, look: look)
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: Self.file, options: .atomic) }
    }

    // MARK: The notch

    /// What the notch shows: the next class from the lead time before it starts (`live` false), else the class
    /// under way (`live` true). Each can be dismissed.
    var alert: (occ: ClassOccurrence, live: Bool)? {
        let s = Store.shared.settings
        guard s.notchClasses, !terms.isEmpty else { return nil }
        let t = terms
        if let n = t.next(after: now), n.start.timeIntervalSince(now) <= Double(s.notchClassLead) * 60, !dismissed.contains(n.key + "-soon") {
            return (n, false)
        }
        if s.notchClassLive, let c = t.current(at: now), !dismissed.contains(c.key + "-live") { return (c, true) }
        return nil
    }

    func dismiss() {
        guard let a = alert else { return }
        dismissed.insert(a.occ.key + (a.live ? "-live" : "-soon"))
        notify()
    }

    /// "8m" until it starts, or what's left of it.
    func countdown(_ a: (occ: ClassOccurrence, live: Bool)) -> String {
        let m = max(0, Int(ceil((a.live ? a.occ.end : a.occ.start).timeIntervalSince(now) / 60)))
        if !a.live, m == 0 { return "Now" }
        return m < 60 ? "\(m)m" : m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    /// The next class if it's still today (the idle notch's line).
    var nextToday: ClassOccurrence? {
        guard let n = terms.next(after: now), Calendar.current.isDate(n.start, inSameDayAs: now) else { return nil }
        return n
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let next = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / 60).rounded(.up) * 60 + 0.5)
        let t = Timer(fire: next, interval: 60, repeats: true) { _ in MainActor.assumeIsolated { Timetables.shared.tick() } }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard !demo, !terms.isEmpty else { return }
        now = Date()
        notify()
    }

    /// Tells the notch; a new "class soon" says its name and room for a moment in the closed notch.
    private func notify() {
        guard let island = (NSApp.delegate as? AppDelegate)?.island else { return }
        island.refresh()
        if let a = alert, !a.live, !flashed.contains(a.occ.key), !demo {
            flashed.insert(a.occ.key)
            if island.stage != .expanded {
                island.flash(a.occ.item.name + (a.occ.item.room.isEmpty ? "" : " · " + a.occ.item.room), "Next class",
                             symbol: "graduationcap.fill", color: a.occ.item.tint, seconds: 6, note: true, alone: true)
            }
        }
    }

    // MARK: Search bar and Ask

    /// "next class" (or 次の授業) typed in the search bar: the next class and its room, ↩ opens the timetable.
    func answer(_ q: String) -> Answer? {
        let l = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard ["next class", "next lecture", "next lesson", "my next class", "what's my next class", "次の授業", "つぎの授業", "次の講義"].contains(l),
              !terms.isEmpty else { return nil }
        // In class: that one, unless the next starts within 15 minutes.
        let cur = terms.current(at: now), nxt = terms.next(after: now)
        guard let n = cur.map({ c in nxt.flatMap { $0.start.timeIntervalSince(now) <= 900 ? $0 : nil } ?? c }) ?? nxt else {
            let open = Answer.Action.run(keepOpen: true) { Tools.enterScope(.timetable, "") }
            return Answer(title: "No classes coming up", subtitle: today?.name ?? "No schedule covers today", symbol: "graduationcap.fill", color: .systemTeal, action: open, hint: "Timetable ↩")
        }
        let live = n.start <= now
        let day = Calendar.current.isDate(n.start, inSameDayAs: now) ? "" : n.start.formatted(.dateTime.weekday(.wide)) + " "
        let m = Int(ceil((live ? n.end : n.start).timeIntervalSince(now) / 60))
        let wait = m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
        let when = live ? "Now, \(wait) left" : day.isEmpty ? "In \(wait)" : day.trimmingCharacters(in: .whitespaces)
        // ↩ opens the class itself (its room is the first thing to fix).
        let open = Answer.Action.run(keepOpen: true) { Tools.enterScope(.timetable, ""); Timetables.shared.open(n) }
        return Answer(title: n.item.name + (n.item.room.isEmpty ? "" : " · " + n.item.room),
                      subtitle: "\(when) · \(n.timeRange) · \(n.periodsLabel)" + (n.item.teacher.isEmpty ? "" : " · " + n.item.teacher),
                      symbol: "graduationcap.fill", color: n.item.nsTint, action: open, hint: "Timetable ↩")
    }

    /// The class's schedule in the editor, the class picked.
    func open(_ o: ClassOccurrence) {
        guard let t = terms.first(where: { $0.classes.contains { $0.id == o.item.id } }) else { return }
        select(t.id)
        TimetableBoard.shared.select(o.item)
    }

    /// Ask's `timetable` tool: the class now and next, a day's classes, and the week of the schedule in effect that day.
    func askResult(date: String?) -> Any {
        guard !terms.isEmpty else { return "No timetable is set up. It can be added with \"timetable\" in the search bar." }
        let cal = Calendar.current
        let day = date.flatMap { AskTools.date($0) }
        let hm = { (d: Date) in d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()) }
        func one(_ o: ClassOccurrence) -> [String: Any] {
            var d: [String: Any] = ["name": o.item.name, "day": TimetableTerm.dayNames[TimetableTerm.weekday(o.start, cal)], "date": TimetableTerm.dayString(o.start, cal),
                                    "period": o.first == o.last ? "\(o.first + 1)" : "\(o.first + 1)-\(o.last + 1)", "start": hm(o.start), "end": hm(o.end)]
            for (k, v) in [("room", o.item.room), ("teacher", o.item.teacher), ("link", o.item.link), ("note", o.item.note)] where !v.isEmpty { d[k] = v }
            return d
        }
        var out: [String: Any] = ["schedules": terms.map { [$0.name, $0.kind, $0.range].filter { !$0.isEmpty }.joined(separator: ", ") }]
        if let c = terms.current(at: now) { out["now"] = one(c) }
        if let n = terms.next(after: now) { out["next"] = one(n) }
        if let d = day { out["on_date"] = terms.occurrences(on: d, cal).map(one) }
        guard let t = terms.inEffect(on: day ?? now, cal) else {
            out["schedule"] = "No schedule covers \(day == nil ? "today" : "that day")."
            return out
        }
        out["schedule"] = t.name
        out["periods"] = t.periods.enumerated().map { "\($0.offset + 1): \($0.element.start)-\($0.element.end)" }
        var week: [String: [String]] = [:]
        for d in t.days {
            let list = t.classes.filter { $0.day == d && $0.period < t.periods.count }.sorted { $0.period < $1.period }.map { (c: ClassItem) -> String in
                "period \(c.period + 1) (\(t.periods[c.period].start)-\(t.periods[c.period].end)): " + [c.name, c.room, c.teacher].filter { !$0.isEmpty }.joined(separator: ", ")
                    + (c.weeks == nil ? "" : " [\(c.weeks!.label)]")
            }
            if !list.isEmpty { week[TimetableTerm.dayNames[d]] = list }
        }
        out["week"] = week
        return out
    }

    // MARK: Demo

    /// Made-up schedules (Fall with an exam week inside it, an open-ended spring) and a fixed clock; nothing is read or saved.
    func useDemo(now: Date, long: Bool = false, empty: Bool = false) {
        demo = true
        ticker?.invalidate()
        ticker = nil
        self.now = now
        var spring = TimetableTerm(name: "Spring 2027", periods: Self.demoTerm().periods, start: "2027-04-05")
        spring.kind = "Regular"
        terms = empty ? [] : [Self.demoTerm(long: long), Self.demoExams(), spring]
        editingID = nil
        look = TimetableLook()
        undoStack = []
        redoStack = []
        canUndo = false
        canRedo = false
    }

    func setNowForDemo(_ d: Date) { now = d; notify() }

    static func demoTerm(long: Bool = false) -> TimetableTerm {
        let periods = [("9:00", "10:30"), ("10:40", "12:10"), ("13:00", "14:30"), ("14:40", "16:10"), ("16:20", "17:50"), ("18:00", "19:30")]
            .map { ClassPeriod(start: $0.0, end: $0.1) }
        var c: [ClassItem] = [
            ClassItem(day: 0, period: 0, name: "Linear Algebra", room: "B-204", teacher: "Prof. Sato"),
            ClassItem(day: 0, period: 2, name: "English Discussion", room: "4-301", teacher: "Ms. Hall"),
            ClassItem(day: 0, period: 3, name: "Economics I", room: "Hall 1", teacher: "Prof. Mori"),
            ClassItem(day: 1, period: 1, name: "Programming", room: "PC Lab 2", teacher: "Dr. Ito"),
            ClassItem(day: 1, period: 2, name: "Programming", room: "PC Lab 2", teacher: "Dr. Ito"),
            ClassItem(day: 1, period: 4, name: "French", room: "7-112", teacher: "Mme Laurent", weeks: ClassWeeks(parity: 1)),
            ClassItem(day: 1, period: 4, name: "Lab Report", room: "Online", link: "https://zoom.us/j/123", weeks: ClassWeeks(parity: 2)),
            ClassItem(day: 2, period: 0, name: "Linear Algebra", room: "B-204", teacher: "Prof. Sato"),
            ClassItem(day: 2, period: 1, name: "Statistics", room: "Hall 3", teacher: "Prof. Kim", note: "Quiz every other week"),
            ClassItem(day: 2, period: 3, name: "Seminar", room: "11-605", teacher: "Prof. Mori"),
            ClassItem(day: 3, period: 1, name: "Economics I", room: "Hall 1", teacher: "Prof. Mori"),
            ClassItem(day: 3, period: 2, name: "Physics", room: "Science 101", teacher: "Dr. Clark"),
            ClassItem(day: 3, period: 5, name: "Film Studies", room: "AV Room", teacher: "Mr. Ono"),
            ClassItem(day: 4, period: 0, name: "Statistics", room: "Hall 3", teacher: "Prof. Kim"),
            ClassItem(day: 4, period: 2, name: "English Discussion", room: "4-301", teacher: "Ms. Hall"),
            ClassItem(day: 4, period: 3, name: "PE", room: "Gym", teacher: "Coach Lee"),
        ]
        if long {
            c[3].name = "Introduction to Computational Thinking and Programming in Python"
            c[4].name = c[3].name
            c[3].room = "Engineering Building 3, Computer Lab 4F-412"
            c[4].room = c[3].room
            c[11].name = "量子力学と統計物理学の基礎演習"
            c[11].room = "理学部2号館 大講義室"
        }
        var t = TimetableTerm(name: "Fall 2026", periods: periods, classes: c, start: "2026-09-21", end: "2027-01-29")
        t.kind = "Regular"
        return t
    }

    /// Mid-term exams, Nov 16 – 20 2026: two longer slots a day.
    static func demoExams() -> TimetableTerm {
        var t = TimetableTerm(name: "Exam week", periods: [ClassPeriod(start: "9:30", end: "11:00"), ClassPeriod(start: "13:00", end: "14:30")], classes: [
            ClassItem(day: 0, period: 0, name: "Linear Algebra exam", room: "Hall 1"),
            ClassItem(day: 1, period: 0, name: "Programming exam", room: "PC Lab 2"),
            ClassItem(day: 2, period: 1, name: "Statistics exam", room: "Hall 3"),
            ClassItem(day: 3, period: 0, name: "Physics exam", room: "Science 101"),
            ClassItem(day: 4, period: 0, name: "Economics I exam", room: "Hall 1"),
        ], start: "2026-11-16", end: "2026-11-20")
        t.kind = "Exam period"
        return t
    }
}

/// Clock and calendar helpers (not tied to the main thread, so the model and tests can use them).
extension TimetableTerm {
    static let palette = ["#0A84FF", "#40C8E0", "#30D158", "#63E6BE", "#FFD60A", "#FF9F0A", "#FF453A", "#FF375F", "#BF5AF2", "#5E5CE6", "#AC8E68", "#8E8E93"]

    /// The same name always gets the same colour.
    static func paletteIndex(_ name: String) -> Int {
        var h: UInt32 = 5381
        for b in name.utf8 { h = h &* 33 &+ UInt32(b) }
        return Int(h % UInt32(palette.count - 1)) // grey only when picked
    }

    static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
        return p[0] * 60 + p[1]
    }

    static func weekday(_ d: Date, _ cal: Calendar) -> Int { (cal.component(.weekday, from: d) + 5) % 7 }

    static func monday(_ d: Date, _ cal: Calendar) -> Date {
        cal.date(byAdding: .day, value: -weekday(d, cal), to: cal.startOfDay(for: d))!
    }

    static func dayString(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func parse(_ s: String, _ cal: Calendar = .current) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// "2026-11-09" → "Nov 9".
    static func short(_ s: String) -> String { parse(s)?.formatted(.dateTime.month(.abbreviated).day()) ?? s }

    static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }

    static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    static let dayShort = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
}
