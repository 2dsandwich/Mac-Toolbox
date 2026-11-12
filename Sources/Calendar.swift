import AppKit
import EventKit
import Observation

// Upcoming calendar events: the next one shows in the notch a little before it starts (with a Join button for
// Zoom, Meet, Teams and Webex links), and "calendar" in the search bar lists what's left of today.
// Signed in to Google, the events come from Google Calendar (GoogleCalendar.swift); otherwise from EventKit.

struct CalendarEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var color: NSColor
    var link: URL?
    var allDay = false
    var calendar = ""
    var location: String?
    var notes: String?
    /// The other people invited (names, else addresses).
    var attendees: [String] = []
    /// The event on the web (Google Calendar).
    var web: URL?

    /// Repeating events share an identifier, so each occurrence is told apart by its start.
    var key: String { "\(id)@\(Int(start.timeIntervalSince1970))" }

    /// Until it starts: "12m", "1h 5m", then "Now".
    func countdown(_ now: Date) -> String {
        let m = Int(ceil(start.timeIntervalSince(now) / 60))
        if m <= 0 { return "Now" }
        return m < 60 ? "\(m)m" : m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    /// "10:00 – 10:30".
    var timeRange: String {
        if allDay { return "All day" }
        return start.formatted(date: .omitted, time: .shortened) + " – " + end.formatted(date: .omitted, time: .shortened)
    }

    /// A video-call link in the event's URL, location or notes (in that order).
    static func meetingLink(_ texts: [String?]) -> URL? {
        let pattern = #"https?://(?:[a-z0-9-]+\.)*(?:zoom\.us|zoomgov\.com|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com)/[^\s<>"'()\[\]]+"#
        for t in texts.compactMap({ $0 }) {
            guard let r = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            // A link at the end of a sentence keeps its full stop otherwise.
            let s = String(t[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if let url = URL(string: s) { return url }
        }
        return nil
    }
}

@MainActor @Observable final class CalendarEvents {
    static let shared = CalendarEvents()

    struct Info: Identifiable, Equatable {
        var id: String
        var title: String
        var source: String
        var color: NSColor
    }

    /// What's left of today (under way or still to come) and the next hour, soonest first: not all-day, not declined.
    private(set) var events: [CalendarEvent] = []
    /// The clock the countdowns read; it moves on once a minute.
    private(set) var now = Date()
    private(set) var access = EKEventStore.authorizationStatus(for: .event)
    /// Every calendar, for Settings.
    private(set) var calendars: [Info] = []
    /// Closed from the notch (until it's gone anyway).
    private(set) var dismissed: Set<String> = []

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var asking = false
    @ObservationIgnored private var demo = false
    @ObservationIgnored private var fetched = Date.distantPast
    /// Events added while showing made-up ones (snapshots and tests).
    @ObservationIgnored private var added: [CalendarEvent] = []

    private var eventStore: EKEventStore {
        if let store { return store }
        let s = EKEventStore()
        store = s
        return s
    }

    /// Reading Google Calendar instead of EventKit.
    var google: Bool { !demo && Google.shared.ready }
    var authorized: Bool { demo || google || access == .fullAccess }
    /// Not asked yet (the system will ask once).
    var undecided: Bool { access == .notDetermined }

    /// The one for the notch: starting within the lead time from Settings, or started under five minutes ago.
    var upcoming: CalendarEvent? {
        let lead = Double(Store.shared.settings.notchEventLead) * 60
        return events.first { e in
            !dismissed.contains(e.key) && e.start.timeIntervalSince(now) <= lead && now.timeIntervalSince(e.start) < 300
        }
    }

    /// The rest of today, for the search bar (fetched fresh unless it just was).
    func remainingToday() -> [CalendarEvent] {
        if !demo, authorized, Date().timeIntervalSince(fetched) > 20 { reload() }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        return events.filter { $0.start < tomorrow }
    }

    /// Follows the calendar while the notch shows events; asks for access only then.
    func apply(_ s: Settings) {
        guard !demo else { return }
        if s.notchEvents { start() } else { stop() }
    }

    func dismiss(_ e: CalendarEvent) {
        dismissed.insert(e.key)
        onChange?()
    }

    func join(_ e: CalendarEvent) {
        guard let url = e.link else { return }
        NSWorkspace.shared.open(url)
        dismiss(e)
    }

    /// Asks for calendar access (the system asks once; after that, only System Settings can change it).
    func requestAccess() {
        guard !asking, access != .fullAccess else { return }
        guard access == .notDetermined else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
            return
        }
        asking = true
        eventStore.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let c = CalendarEvents.shared
                    c.asking = false
                    // A fresh store sees the calendars it's now allowed to.
                    c.store = nil
                    c.access = EKEventStore.authorizationStatus(for: .event)
                    if Store.shared.settings.notchEvents { c.start() } else { c.reload() }
                }
            }
        }
    }

    private func start() {
        if google {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            startTicker()
            return reload()
        }
        access = EKEventStore.authorizationStatus(for: .event)
        if access == .notDetermined { return requestAccess() }
        guard access == .fullAccess else { return stop() }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CalendarEvents.shared.reload() }
            }
        }
        startTicker()
        reload()
    }

    private func startTicker() {
        if ticker == nil {
            // On the minute (plus a moment), so "Now" shows as the event starts.
            let next = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / 60).rounded(.up) * 60 + 0.5)
            let t = Timer(fire: next, interval: 60, repeats: true) { _ in MainActor.assumeIsolated { CalendarEvents.shared.reload() } }
            t.tolerance = 2
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        }
    }

    /// Display asleep or screen locked: no minute ticks until it's back, then a catch-up and ticks on the minute again.
    func pause(_ on: Bool) {
        guard let t = ticker else { return }
        if on { return t.fireDate = .distantFuture }
        t.invalidate()
        ticker = nil
        startTicker()
        reload()
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if !events.isEmpty { events = [] }
        onChange?()
    }

    /// Reads the rest of today from EventKit (one query; cheap), then tells the notch.
    func reload() {
        now = Date()
        access = EKEventStore.authorizationStatus(for: .event)
        if google {
            let g = GoogleCalendar.shared
            // Each calendar's account only once there's more than one.
            let many = Google.shared.emails.count > 1
            let list = g.calendars.map { Info(id: $0.id, title: $0.name, source: many ? $0.account ?? "" : "", color: NSColor(hex: $0.color) ?? .systemBlue) }
            if list != calendars { calendars = list }
            let today = Calendar.current.startOfDay(for: now)
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? now
            // Today and tomorrow in one cached range, refreshed every five minutes.
            let found = g.events(from: today, to: Calendar.current.date(byAdding: .day, value: 2, to: today) ?? now, maxAge: 300)
                .filter { !$0.allDay && $0.end > now && $0.start < max(tomorrow, now.addingTimeInterval(3600)) }
                .sorted { $0.start < $1.start }
            settle(found)
        } else if !demo, access == .fullAccess {
            let s = Store.shared.settings
            let all = eventStore.calendars(for: .event)
            let list = all.map { Info(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "", color: $0.color) }
            if list != calendars { calendars = list }
            let shown = all.filter { !s.eventCalendarsOff.contains($0.calendarIdentifier) }
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
            var found: [CalendarEvent] = []
            if !shown.isEmpty {
                // Overlapping the range, so what's under way now comes too; the extra hour covers late evenings.
                let p = eventStore.predicateForEvents(withStart: now, end: max(tomorrow, now.addingTimeInterval(3600)), calendars: shown)
                found = eventStore.events(matching: p)
                    .filter { e in
                        !e.isAllDay && e.status != .canceled && e.endDate > now
                            && e.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
                    }
                    .sorted { $0.startDate < $1.startDate }
                    .map(Self.make)
            }
            settle(found)
        }
        onChange?()
    }

    private func settle(_ found: [CalendarEvent]) {
        if found != events { events = found }
        fetched = Date()
        // Forget dismissals once their events have passed.
        let live = Set(found.map(\.key))
        if !dismissed.isSubset(of: live) { dismissed.formIntersection(live) }
    }

    private static func make(_ e: EKEvent) -> CalendarEvent {
        CalendarEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title?.isEmpty == false ? e.title! : "Event",
                      start: e.startDate, end: e.endDate, color: e.calendar?.color ?? .systemRed,
                      link: CalendarEvent.meetingLink([e.url?.absoluteString, e.location, e.notes]),
                      allDay: e.isAllDay, calendar: e.calendar?.title ?? "", location: e.location?.isEmpty == false ? e.location : nil,
                      notes: e.notes?.isEmpty == false ? e.notes : nil,
                      attendees: (e.attendees ?? []).filter { !$0.isCurrentUser }.map { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") })
    }

    /// The event a meeting starting now belongs to: under way or starting within ten minutes, a call before anything else.
    func current() -> CalendarEvent? {
        if !demo, authorized, Date().timeIntervalSince(fetched) > 20 { reload() }
        let now = Date()
        let on = events.filter { !$0.allDay && $0.start.timeIntervalSince(now) < 600 && $0.end > now }
        return on.first { $0.link != nil } ?? on.first
    }

    /// Every event overlapping from..<to (all-day ones too) in the calendars switched on, for the Calendar mode.
    func range(from: Date, to: Date) -> [CalendarEvent] {
        if demo {
            return (Self.demoRange(from: from, to: to) + added.filter { $0.start < to && $0.end > from })
                .sorted { ($0.start, $0.allDay ? 0 : 1) < ($1.start, $1.allDay ? 0 : 1) }
        }
        if google {
            return GoogleCalendar.shared.events(from: from, to: to, maxAge: 120)
                .sorted { ($0.start, $0.allDay ? 0 : 1) < ($1.start, $1.allDay ? 0 : 1) }
        }
        access = EKEventStore.authorizationStatus(for: .event)
        guard access == .fullAccess else { return [] }
        let off = Store.shared.settings.eventCalendarsOff
        let shown = eventStore.calendars(for: .event).filter { !off.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { return [] }
        return eventStore.events(matching: eventStore.predicateForEvents(withStart: from, end: to, calendars: shown))
            .filter { $0.status != .canceled && $0.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined }
            .map(Self.make)
            .sorted { ($0.start, $0.allDay ? 0 : 1) < ($1.start, $1.allDay ? 0 : 1) }
    }

    /// A made-up month for the snapshots: the same pattern every month, and a busy today.
    static func demoRange(from: Date, to: Date) -> [CalendarEvent] {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        var list: [CalendarEvent] = []
        func add(_ day: Date, _ title: String, _ h: Double, _ minutes: Double, _ color: NSColor, link: String? = nil, place: String? = nil,
                 notes: String? = nil, days: Int = 0) {
            let start = days > 0 ? day : day.addingTimeInterval(h * 3600)
            let end = days > 0 ? cal.date(byAdding: .day, value: days, to: day)!.addingTimeInterval(-1) : start.addingTimeInterval(minutes * 60)
            list.append(CalendarEvent(id: "demo-\(title)-\(Int(day.timeIntervalSince1970))", title: title, start: start, end: end, color: color,
                                      link: link.flatMap(URL.init(string:)), allDay: days > 0, calendar: days > 0 ? "Personal" : "Work",
                                      location: place, notes: notes))
        }
        var day = from
        while day < to {
            let n = cal.component(.day, from: day), w = cal.component(.weekday, from: day)
            if n == 12 { add(day, "Tokyo Game Show", 0, 0, .systemOrange, place: "Makuhari Messe", days: 3) }
            if n == 20 { add(day, "Mom’s birthday", 0, 0, .systemPink, days: 1) }
            if [2, 4, 6].contains(w) { add(day, "Standup", 9.5, 15, .systemBlue, link: "https://meet.google.com/abc-defg-hij") }
            if n == 3 { add(day, "Dentist", 16, 60, .systemGreen, place: "Shibuya Dental Clinic") }
            if n % 7 == 2 || day == today {
                add(day, "Design review", 13, 60, .systemPurple, link: "https://meet.google.com/xyz-abcd-efg",
                    notes: "Walk through the new calendar view and the notch timings.")
            }
            if n % 5 == 0, w != 1, w != 7 { add(day, "Gym", 19, 60, .systemTeal) }
            if n == 25 { add(day, "Sponsor sync", 11, 30, .systemOrange, link: "https://us02web.zoom.us/j/81234567890") }
            if day == today {
                add(day, "Team lunch", 12.5, 60, .systemGreen, place: "Ebisu")
                add(day, "Venue walkthrough", 15, 60, .systemRed, place: "Zepp Shinjuku")
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return list.sorted { ($0.start, $0.allDay ? 0 : 1) < ($1.start, $1.allDay ? 0 : 1) }
    }

    // MARK: Adding

    /// Where a new event goes: the first Google account's main calendar, else the Mac's default one.
    var newEventCalendar: String? {
        if demo { return "Work" }
        if google { return GoogleCalendar.shared.home?.name }
        return access == .fullAccess ? eventStore.defaultCalendarForNewEvents?.title : nil
    }

    /// Adds a timed event (only ever from a click or an Ask request). Without Google, the Mac's calendar asks for
    /// access here the first time, never before.
    func add(title: String, start: Date, minutes: Int, allDay: Bool = false) async throws -> CalendarEvent {
        // All day: the whole of that day (its end is the day's last second, as events read back from calendars have).
        let day = Calendar.current.startOfDay(for: start), nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let start = allDay ? day : start
        let end = allDay ? nextDay.addingTimeInterval(-1) : start.addingTimeInterval(Double(max(5, minutes)) * 60)
        if demo {
            let e = CalendarEvent(id: "demo-new-\(UUID().uuidString)", title: title, start: start, end: end, color: .systemBlue, allDay: allDay, calendar: "Work")
            added.append(e)
            if e.end > now, e.start < now.addingTimeInterval(86_400) { events = (events + [e]).sorted { $0.start < $1.start } }
            CalendarBoard.shared.load(force: true)
            return e
        }
        if google { return try await GoogleCalendar.shared.add(title, start: start, end: end, allDay: allDay) }
        if access == .notDetermined {
            _ = try? await eventStore.requestFullAccessToEvents()
            store = nil
            access = EKEventStore.authorizationStatus(for: .event)
        }
        guard access == .fullAccess || access == .writeOnly else {
            throw AskTools.Problem("MONEY! can't add to the calendar (System Settings › Privacy & Security › Calendars, or sign in to Google in Settings).")
        }
        let e = EKEvent(eventStore: eventStore)
        e.title = title
        e.startDate = start
        e.endDate = end
        e.isAllDay = allDay
        e.calendar = eventStore.defaultCalendarForNewEvents
        try eventStore.save(e, span: .thisEvent)
        reload()
        CalendarBoard.shared.load(force: true)
        return Self.make(e)
    }

    /// Takes an added event back off (Ask's Undo).
    func remove(_ e: CalendarEvent) {
        if demo {
            added.removeAll { $0.id == e.id }
            events.removeAll { $0.id == e.id }
            CalendarBoard.shared.load(force: true)
        } else if google {
            Task { await GoogleCalendar.shared.remove(e.id) }
        } else if let ek = eventStore.event(withIdentifier: e.id) {
            try? eventStore.remove(ek, span: .thisEvent)
            reload()
            CalendarBoard.shared.load(force: true)
        }
    }

    /// Made-up events in place of EventKit, for the off-screen snapshots.
    func useDemo(_ list: [CalendarEvent]) {
        demo = true
        stop()
        now = Date()
        events = list
        calendars = [Info(id: "demo-work", title: "Work", source: "ben@example.com", color: .systemBlue),
                     Info(id: "demo-personal", title: "Personal", source: "ben@example.com", color: .systemGreen),
                     Info(id: "demo-festival", title: "Festival crew", source: "ben@festival.example", color: .systemOrange)]
        onChange?()
    }

    /// The snapshots' clock (to see "Now").
    func setNowForDemo(_ date: Date) { if demo { now = date; onChange?() } }

    static func demoEvents(_ now: Date = Date()) -> [CalendarEvent] {
        let m = 60.0
        let base = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        let at = { (min: Double) in Date(timeIntervalSinceReferenceDate: base + min * m) }
        return [
            CalendarEvent(id: "demo-1", title: "Design review", start: at(12), end: at(42), color: .systemBlue,
                          link: URL(string: "https://meet.google.com/abc-defg-hij"), attendees: ["Fumi Kato", "Gaku Ono"]),
            CalendarEvent(id: "demo-2", title: "Sponsor sync", start: at(90), end: at(120), color: .systemOrange,
                          link: URL(string: "https://us02web.zoom.us/j/81234567890")),
            CalendarEvent(id: "demo-3", title: "Venue walkthrough", start: at(180), end: at(240), color: .systemGreen, link: nil),
        ]
    }

    /// The search bar's answer: a card with what's left of today. ↩ joins the call that's on now or about to
    /// start; otherwise it opens the Calendar mode.
    func answer() -> Answer {
        let header = "Today’s events"
        if !demo { access = EKEventStore.authorizationStatus(for: .event) }
        guard authorized else {
            return Answer(title: header, subtitle: "Not signed in to Google", symbol: "calendar", color: .systemRed,
                          action: .run(keepOpen: true) { Google.shared.signInOrSettings() }, hint: "Sign in ↩")
        }
        let list = remainingToday()
        let lead = Double(Store.shared.settings.notchEventLead) * 60
        let soon = list.first { $0.link != nil && $0.start.timeIntervalSince(now) <= lead && $0.end > now }
        return Answer(title: header, subtitle: list.isEmpty ? "Nothing left today" : "\(list.count) left today", symbol: "calendar", color: .systemRed,
                      action: soon?.link.map { .open($0) } ?? .run(keepOpen: true) { Tools.enterScope(.calendar, "") },
                      hint: soon != nil ? "Join ↩" : "Calendar ↩", card: .events(list, now: now))
    }
}
