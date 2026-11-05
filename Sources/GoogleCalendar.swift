import AppKit

// Events from the Google calendars you show (all-day ones, colours, people, places, Meet links), kept on disk so the
// notch and the Calendar mode start at once and work offline. CalendarEvents reads from here while you're signed in.

@MainActor final class GoogleCalendar {
    static let shared = GoogleCalendar()

    struct Cal: Codable, Equatable {
        var id: String
        var name: String
        var color: String
        var primary = false
    }

    /// An event as cached (colours as hex, so it can go to disk).
    struct Stored: Codable, Equatable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var color: String
        var link: String?
        var web: String?
        var allDay = false
        var calendar = ""
        var calendarId = ""
        var location: String?
        var notes: String?
        var attendees: [String] = []

        var event: CalendarEvent {
            CalendarEvent(id: id, title: title, start: start, end: end, color: NSColor(hex: color) ?? .systemBlue, link: link.flatMap(URL.init(string:)),
                          allDay: allDay, calendar: calendar, location: location, notes: notes, attendees: attendees, web: web.flatMap(URL.init(string:)))
        }
    }

    /// The parts of Google's event JSON that MONEY! uses.
    struct GEvent: Decodable {
        struct When: Decodable { var dateTime: String?; var date: String? }
        struct Person: Decodable {
            var email: String?
            var displayName: String?
            var isSelf: Bool?
            var resource: Bool?
            var responseStatus: String?
            enum CodingKeys: String, CodingKey { case email, displayName, isSelf = "self", resource, responseStatus }
        }
        struct Conference: Decodable {
            struct Entry: Decodable { var entryPointType: String?; var uri: String? }
            var entryPoints: [Entry]?
        }
        var id: String
        var summary: String?
        var status: String?
        var eventType: String?
        var htmlLink: String?
        var hangoutLink: String?
        var location: String?
        var description: String?
        var colorId: String?
        var start: When?
        var end: When?
        var attendees: [Person]?
        var conferenceData: Conference?
    }

    private struct Span: Codable { var from: Date; var to: Date; var at: Date }
    private struct Cache: Codable { var calendars: [Cal]; var events: [Stored]; var spans: [Span] }

    private(set) var calendars: [Cal] = []
    private var events: [Stored] = []
    private var spans: [Span] = []
    private var loading: Set<String> = []
    private var listedAt = Date.distantPast
    private var saveWork: DispatchWorkItem?

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MONEY/google-calendar.json")
    }

    private init() {
        guard Google.shared.ready, !Google.shared.demo,
              let data = try? Data(contentsOf: Self.file), let c = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        calendars = c.calendars
        events = c.events
        spans = c.spans
    }

    /// Signed in or out: nothing kept from the last account.
    func reset() {
        calendars = []
        events = []
        spans = []
        listedAt = .distantPast
        try? FileManager.default.removeItem(at: Self.file)
    }

    /// The events overlapping from..<to in the calendars switched on, from memory; fetched again in the background
    /// when that range is older than `maxAge` seconds.
    func events(from: Date, to: Date, maxAge: TimeInterval) -> [CalendarEvent] {
        ensure(from, to, maxAge)
        let off = Set(Store.shared.settings.eventCalendarsOff)
        return events.filter { $0.start < to && $0.end > from && !off.contains($0.calendarId) }.map(\.event)
    }

    /// Fetches from..<to now unless that range is fresh, for callers that can't wait for a redraw (Ask).
    func load(from: Date, to: Date, maxAge: TimeInterval = 120) async {
        guard Google.shared.ready, !Google.shared.demo,
              !spans.contains(where: { $0.from <= from && $0.to >= to && Date().timeIntervalSince($0.at) < maxAge }) else { return }
        await fetch(from, to)
    }

    private func ensure(_ from: Date, _ to: Date, _ maxAge: TimeInterval) {
        guard Google.shared.ready, !Google.shared.demo else { return }
        let fresh = spans.contains { $0.from <= from && $0.to >= to && Date().timeIntervalSince($0.at) < maxAge }
        let key = "\(from.timeIntervalSince1970)-\(to.timeIntervalSince1970)"
        guard !fresh, !loading.contains(key) else { return }
        loading.insert(key)
        Task {
            await fetch(from, to)
            loading.remove(key)
        }
    }

    private func fetch(_ from: Date, _ to: Date) async {
        do {
            if calendars.isEmpty || Date().timeIntervalSince(listedAt) > 600 { try await listCalendars() }
        } catch {
            if calendars.isEmpty { return }
        }
        let shown = calendars
        let results = await withTaskGroup(of: [Stored]?.self) { group in
            for c in shown { group.addTask { await Self.list(c, from, to) } }
            var all: [[Stored]?] = []
            for await r in group { all.append(r) }
            return all
        }
        // Offline (nothing came back): keep what's cached.
        guard results.contains(where: { $0 != nil }) else { return }
        let found = results.compactMap { $0 }.flatMap { $0 }
        events.removeAll { $0.start < to && $0.end > from }
        events += found
        spans.removeAll { $0.from >= from && $0.to <= to }
        spans.append(Span(from: from, to: to, at: Date()))
        save()
        CalendarEvents.shared.reload()
        CalendarBoard.shared.load(force: true)
    }

    private func listCalendars() async throws {
        let json = try await Google.shared.json(URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader&maxResults=250")!)
        calendars = Self.calendars(json)
        listedAt = Date()
    }

    /// The calendars ticked in Google Calendar (and the main one), as listed by calendarList.
    static func calendars(_ json: [String: Any]) -> [Cal] {
        (json["items"] as? [[String: Any]] ?? []).compactMap { c -> Cal? in
            guard let id = c["id"] as? String, c["selected"] as? Bool == true || c["primary"] as? Bool == true, c["hidden"] as? Bool != true else { return nil }
            return Cal(id: id, name: (c["summaryOverride"] as? String) ?? (c["summary"] as? String) ?? id,
                       color: c["backgroundColor"] as? String ?? "#4285F4", primary: c["primary"] as? Bool == true)
        }
        .prefix(25).map { $0 }
    }

    /// One calendar's events in the range, every page (nil when it failed).
    private static func list(_ c: Cal, _ from: Date, _ to: Date) async -> [Stored]? {
        var out: [Stored] = []
        var page = ""
        let iso = ISO8601DateFormatter()
        repeat {
            var u = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(c.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/@#"))) ?? c.id)/events")!
            u.queryItems = [.init(name: "timeMin", value: iso.string(from: from)), .init(name: "timeMax", value: iso.string(from: to)),
                            .init(name: "singleEvents", value: "true"), .init(name: "orderBy", value: "startTime"), .init(name: "maxResults", value: "250")]
            if !page.isEmpty { u.queryItems?.append(.init(name: "pageToken", value: page)) }
            guard let url = u.url, let data = try? await Google.shared.call(url), let r = try? JSONDecoder().decode(Page.self, from: data) else { return nil }
            out += r.items.compactMap { map($0, c) }
            page = r.nextPageToken ?? ""
        } while !page.isEmpty && out.count < 2000
        return out
    }

    private struct Page: Decodable { var items: [GEvent] = []; var nextPageToken: String? }

    /// Google's event → MONEY!'s. Skips cancelled and declined ones and working-location markers.
    static func map(_ e: GEvent, _ c: Cal) -> Stored? {
        guard e.status != "cancelled", e.eventType != "workingLocation",
              e.attendees?.first(where: { $0.isSelf == true })?.responseStatus != "declined",
              let start = e.start.flatMap(date), let endRaw = e.end.flatMap(date) else { return nil }
        let allDay = e.start?.dateTime == nil
        let notes = e.description.map(plainText).flatMap { $0.isEmpty ? nil : $0 }
        let location = e.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let video = e.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
        let link = e.hangoutLink.flatMap(URL.init(string:)) ?? video.flatMap(URL.init(string:)) ?? CalendarEvent.meetingLink([location, notes])
        return Stored(id: e.id, title: e.summary?.isEmpty == false ? e.summary! : "(No title)", start: start,
                      // All-day ends are the next midnight; EventKit's end a second before, which the views expect.
                      end: allDay ? endRaw.addingTimeInterval(-1) : endRaw,
                      color: e.colorId.flatMap { eventColors[$0] } ?? c.color, link: link?.absoluteString, web: e.htmlLink, allDay: allDay,
                      calendar: c.name, calendarId: c.id, location: location?.isEmpty == false ? location : nil, notes: notes,
                      attendees: (e.attendees ?? []).filter { $0.isSelf != true && $0.resource != true }.compactMap { $0.displayName ?? $0.email })
    }

    /// Google's fixed event palette (colorId → colour).
    static let eventColors = ["1": "#7986CB", "2": "#33B679", "3": "#8E24AA", "4": "#E67C73", "5": "#F6BF26", "6": "#F4511E",
                              "7": "#039BE5", "8": "#616161", "9": "#3F51B5", "10": "#0B8043", "11": "#D50000"]

    /// "2026-11-05T10:00:00+09:00" or an all-day "2026-11-05" (local midnight).
    static func date(_ w: GEvent.When) -> Date? {
        if let t = w.dateTime {
            let f = ISO8601DateFormatter()
            if let d = f.date(from: t) { return d }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: t)
        }
        guard let parts = w.date?.split(separator: "-").compactMap({ Int($0) }), parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Descriptions come as HTML from the web app.
    static func plainText(_ html: String) -> String {
        var s = html
        for (pattern, with) in [(#"<br\s*/?>"#, "\n"), (#"</(p|div|li)>"#, "\n"), (#"<[^>]+>"#, "")] {
            s = s.replacingOccurrences(of: pattern, with: with, options: [.regularExpression, .caseInsensitive])
        }
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// To disk a moment after the last change: the calendars and the months around today.
    private func save() {
        saveWork?.cancel()
        let today = Date()
        let keep = Cache(calendars: calendars, events: events.filter { $0.end > today.addingTimeInterval(-62 * 86_400) && $0.start < today.addingTimeInterval(93 * 86_400) },
                         spans: spans)
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(keep) else { return }
            try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.file, options: .atomic)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
