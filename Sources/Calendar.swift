import AppKit
import EventKit
import Observation

// Upcoming calendar events: the next one shows in the notch a little before it starts (with a Join button for
// Zoom, Meet, Teams and Webex links), and "calendar" in the search bar lists what's left of today.

struct CalendarEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var color: NSColor
    var link: URL?

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
        start.formatted(date: .omitted, time: .shortened) + " – " + end.formatted(date: .omitted, time: .shortened)
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

    private var eventStore: EKEventStore {
        if let store { return store }
        let s = EKEventStore()
        store = s
        return s
    }

    var authorized: Bool { demo || access == .fullAccess }
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
        access = EKEventStore.authorizationStatus(for: .event)
        if access == .notDetermined { return requestAccess() }
        guard access == .fullAccess else { return stop() }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CalendarEvents.shared.reload() }
            }
        }
        if ticker == nil {
            // On the minute (plus a moment), so "Now" shows as the event starts.
            let next = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / 60).rounded(.up) * 60 + 0.5)
            let t = Timer(fire: next, interval: 60, repeats: true) { _ in MainActor.assumeIsolated { CalendarEvents.shared.reload() } }
            t.tolerance = 2
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        }
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
        if !demo, access == .fullAccess {
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
                    .map { e in
                        CalendarEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title?.isEmpty == false ? e.title! : "Event",
                                      start: e.startDate, end: e.endDate, color: e.calendar?.color ?? .systemRed,
                                      link: CalendarEvent.meetingLink([e.url?.absoluteString, e.location, e.notes]))
                    }
            }
            if found != events { events = found }
            fetched = Date()
            // Forget dismissals once their events have passed.
            let live = Set(found.map(\.key))
            if !dismissed.isSubset(of: live) { dismissed.formIntersection(live) }
        }
        onChange?()
    }

    /// Made-up events in place of EventKit, for the off-screen snapshots.
    func useDemo(_ list: [CalendarEvent]) {
        demo = true
        stop()
        now = Date()
        events = list
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
                          link: URL(string: "https://meet.google.com/abc-defg-hij")),
            CalendarEvent(id: "demo-2", title: "Sponsor sync", start: at(90), end: at(120), color: .systemOrange,
                          link: URL(string: "https://us02web.zoom.us/j/81234567890")),
            CalendarEvent(id: "demo-3", title: "Venue walkthrough", start: at(180), end: at(240), color: .systemGreen, link: nil),
        ]
    }

    /// The search bar's answer: a card with what's left of today. ↩ joins the call that's on now or about to
    /// start; otherwise it opens Calendar (so "calendar ↩" still does what it used to).
    func answer() -> Answer {
        let header = "Today’s events"
        if !demo { access = EKEventStore.authorizationStatus(for: .event) }
        guard authorized else {
            return Answer(title: header, subtitle: access == .notDetermined ? "No calendar access yet" : "No calendar access",
                          symbol: "calendar", color: .systemRed, action: .run(keepOpen: true) { CalendarEvents.shared.requestAccess() },
                          hint: access == .notDetermined ? "Allow ↩" : "Open Settings ↩")
        }
        let list = remainingToday()
        let lead = Double(Store.shared.settings.notchEventLead) * 60
        let soon = list.first { $0.link != nil && $0.start.timeIntervalSince(now) <= lead && $0.end > now }
        let app = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        return Answer(title: header, subtitle: list.isEmpty ? "Nothing left today" : "\(list.count) left today", symbol: "calendar", color: .systemRed,
                      action: soon?.link.map { .open($0) } ?? .open(app), hint: soon != nil ? "Join ↩" : "Open Calendar ↩",
                      card: .events(list, now: now))
    }
}
