import AppKit
import ApplicationServices
import Observation
import SwiftUI

/// What Ask may look up on this Mac. Each one is a switch in Settings › AI; one that's off is never offered to the
/// model, so nothing from it is sent.
enum AskSource: String, CaseIterable, Identifiable {
    case location, calendar, tasks, meetings, notes, nowPlaying, clipboard, selection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .location: "Location"
        case .calendar: "Calendar"
        case .tasks: "Tasks"
        case .meetings: "Meetings"
        case .notes: "Sticky notes"
        case .nowPlaying: "What’s playing"
        case .clipboard: "Clipboard history"
        case .selection: "Selected text"
        }
    }

    /// The clipboard can hold anything, so it waits to be switched on.
    var defaultOn: Bool { self != .clipboard }

    func on(_ s: Settings) -> Bool { (Self.testSources ?? s.askSources)[rawValue] ?? defaultOn }

    /// Tests: switches in place of the saved ones, so a test never changes the user's settings.
    nonisolated(unsafe) static var testSources: [String: Bool]?
}

/// A change Ask made (a task, a timer, an alarm), shown under its answer with Undo.
struct AskReceipt: Identifiable {
    let id = UUID()
    let symbol: String
    let color: NSColor
    let title: String
    var detail: String?
    var undo: (@MainActor () -> Void)?
    var undone = false
}

/// Ask's own tools: Claude calls them when a question is about the user's things (calendar, tasks, meetings…),
/// the app runs them here and sends the results back. Reads only fetch what the question needs; writes happen at
/// once and leave a receipt with Undo.
@MainActor @Observable final class AskTools {
    static let shared = AskTools()

    /// Receipts by the turn they belong to.
    private(set) var receipts: [UUID: [AskReceipt]] = [:]

    /// Tests: timers, alarms and opening things are only pretended (tasks use GoogleTasks' demo).
    @ObservationIgnored static var sandbox = false
    /// Tests: clipboard history in place of the real one.
    @ObservationIgnored static var fakeClips: [Clip]?
    /// Every tool called since launch, by name (for the dev hooks).
    @ObservationIgnored private(set) var calls: [String] = []

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private struct Tool {
        let name: String
        let source: AskSource?
        let status: String
        let symbol: String
        let description: String
        var properties: [String: Any] = [:]
        var required: [String] = []

        var json: [String: Any] {
            ["name": name, "description": description,
             "input_schema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
        }
    }

    private static func text(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static let day = "Local date YYYY-MM-DD or date and time YYYY-MM-DDTHH:mm"

    private static let tools: [Tool] = [
        Tool(name: "get_location", source: .location, status: "Finding where you are", symbol: "location.fill",
             description: "The user's approximate location now: town, neighbourhood, country, coordinates and time zone. For \"near me\", \"here\", local weather and local times."),
        Tool(name: "calendar_events", source: .calendar, status: "Checking your calendar", symbol: "calendar",
             description: "Events in the user's calendars from one time to another, optionally only those whose title, place, notes or guests contain the query.",
             properties: ["from": text(day), "to": text(day + " (a date alone includes that whole day)"), "query": text("Words to match")], required: ["from", "to"]),
        Tool(name: "tasks_list", source: .tasks, status: "Checking your tasks", symbol: "checklist",
             description: "The user's to-dos (Google Tasks) by list, with the ids complete_task needs.",
             properties: ["list": text("A list's name; all lists if left out"), "include_completed": ["type": "boolean"]]),
        Tool(name: "add_task", source: .tasks, status: "Adding the task", symbol: "plus.circle",
             description: "Adds a to-do. Use for \"remind me to…\" and \"add … to my list\".",
             properties: ["title": text("Short, starting with a verb"), "due": text("YYYY-MM-DD"), "notes": text("Details, if any"), "list": text("A list's name; the first list if left out")],
             required: ["title"]),
        Tool(name: "complete_task", source: .tasks, status: "Ticking it off", symbol: "checkmark.circle",
             description: "Marks a to-do as done, by its id from tasks_list.", properties: ["id": text("The task's id")], required: ["id"]),
        Tool(name: "create_timer", source: nil, status: "Starting a timer", symbol: "timer",
             description: "Starts a countdown timer on this Mac.",
             properties: ["minutes": ["type": "number"], "label": text("What it's for")], required: ["minutes"]),
        Tool(name: "set_alarm", source: nil, status: "Setting an alarm", symbol: "alarm",
             description: "Sets an alarm that rings on this Mac at a time of day (the next time it comes round, unless it repeats).",
             properties: ["time": text("24-hour HH:mm"), "label": text("What it's for"),
                          "repeat": ["type": "string", "enum": ["once", "daily", "weekdays", "weekends"]]], required: ["time"]),
        Tool(name: "now_playing", source: .nowPlaying, status: "Checking what’s playing", symbol: "music.note",
             description: "The song playing in Music or Spotify."),
        Tool(name: "search_clipboard", source: .clipboard, status: "Searching your clipboard", symbol: "doc.on.clipboard",
             description: "Text the user copied recently, newest first, optionally only what contains the query.",
             properties: ["query": text("Words to match"), "limit": ["type": "integer"]]),
        Tool(name: "search_meetings", source: .meetings, status: "Searching your meetings", symbol: "waveform",
             description: "The user's recorded meetings, newest first, with a summary and the id meeting_notes needs. Filter by words (title, people, what was said) and dates.",
             properties: ["query": text("Words to match"), "from": text(day), "to": text(day)]),
        Tool(name: "meeting_notes", source: .meetings, status: "Reading the meeting", symbol: "doc.text",
             description: "One meeting's notes and full transcript, by its id from search_meetings. Use it for who said what.",
             properties: ["id": text("The meeting's id")], required: ["id"]),
        Tool(name: "search_notes", source: .notes, status: "Reading your notes", symbol: "note.text",
             description: "The user's sticky notes, newest first.", properties: ["query": text("Words to match")]),
        Tool(name: "system_status", source: nil, status: "Checking your Mac", symbol: "laptopcomputer",
             description: "This Mac's battery, storage, memory, uptime and macOS version."),
        Tool(name: "selected_text", source: .selection, status: "Reading your selection", symbol: "text.cursor",
             description: "The text selected in the app in front, with the app's name and window title. For \"this\": explain this, translate this, reply to this."),
        Tool(name: "open", source: nil, status: "Opening", symbol: "arrow.up.forward.app",
             description: "Opens a web page or an app. Only when the user asks to open something.",
             properties: ["url": text("An http or https address"), "app": text("An app's name")]),
    ]

    // MARK: For the request

    /// The tools on offer: those whose source is switched on, plus any already used in this thread (the history
    /// has to match the tools sent with it).
    static func definitions(_ s: Settings, history: [[String: Any]]) -> [[String: Any]] {
        var used = Set<String>()
        for m in history {
            for case let b as [String: Any] in m["content"] as? [Any] ?? [] where b["type"] as? String == "tool_use" {
                if let n = b["name"] as? String { used.insert(n) }
            }
        }
        return tools.filter { $0.source?.on(s) ?? true || used.contains($0.name) }.map(\.json)
    }

    /// Ask's line about them in the system prompt.
    static func prompt(_ s: Settings) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        let secs = TimeZone.current.secondsFromGMT()
        let offset = String(format: "UTC%@%02d:%02d", secs < 0 ? "-" : "+", abs(secs) / 3600, abs(secs) % 3600 / 60)
        let off = AskSource.allCases.filter { !$0.on(s) }.map(\.title)
        return """
        Your other tools reach the user's own things on this Mac. Use them for personal questions (what's on tomorrow, remind me to…, \
        what did Ben say in yesterday's meeting, what's this song, explain this) instead of guessing or searching the web; don't use them for general questions. \
        "Remind me to…" adds a task, due on the day named; a reminder at a time of day sets an alarm labelled with it. \
        A task, timer or alarm is made at once and the app shows it under your answer with Undo, so confirm it in a few words. \
        Ask before anything that can't be undone. Dates and times you send and get back are the user's local time: it is now \(f.string(from: Date())) (\(offset)).\
        \(off.isEmpty ? "" : " Switched off by the user: \(off.joined(separator: ", ")). If a question needs one, say it can be turned on in Settings › AI.")
        """
    }

    /// The web search's idea of where the user is: the time zone, and the town once Location has found it.
    static func searchLocation(_ s: Settings) -> [String: Any] {
        var l: [String: Any] = ["type": "approximate", "timezone": TimeZone.current.identifier]
        if AskSource.location.on(s), let f = Location.shared.fix {
            if let c = f.city { l["city"] = c }
            if let r = f.region { l["region"] = r }
            if let c = f.countryCode { l["country"] = c }
        }
        return l
    }

    /// The status line while a tool runs.
    static func status(_ block: [String: Any]) -> Assistant.Status {
        guard let t = tools.first(where: { $0.name == block["name"] as? String }) else { return .thinking }
        return .using(t.status, t.symbol)
    }

    // MARK: Running

    /// Runs every tool call in an answer and returns the results, in one user message's content.
    func run(_ blocks: [[String: Any]], turn: UUID) async -> [[String: Any]] {
        var out: [[String: Any]] = []
        for b in blocks where b["type"] as? String == "tool_use" {
            let id = b["id"] as? String ?? ""
            let input = AskJSON(v: b["input"] as? [String: Any] ?? [:])
            calls.append(b["name"] as? String ?? "")
            do {
                let r = try await call(b["name"] as? String ?? "", input, turn)
                out.append(["type": "tool_result", "tool_use_id": id, "content": Self.encode(r)])
            } catch {
                out.append(["type": "tool_result", "tool_use_id": id, "content": error.localizedDescription, "is_error": true])
            }
        }
        return out
    }

    func undo(_ r: AskReceipt, in turn: UUID) {
        guard let i = receipts[turn]?.firstIndex(where: { $0.id == r.id }), receipts[turn]?[i].undone == false else { return }
        r.undo?()
        receipts[turn]?[i].undone = true
    }

    /// Snapshots: receipts for a made-up turn.
    func demoReceipts(_ list: [AskReceipt], turn: UUID) { receipts[turn] = list }

    private func receipt(_ turn: UUID, _ r: AskReceipt) { receipts[turn, default: []].append(r) }

    private static func encode(_ r: Any) -> String {
        if let s = r as? String { return s }
        guard JSONSerialization.isValidJSONObject(r),
              let d = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(r)" }
        return String(decoding: d, as: UTF8.self)
    }

    private func call(_ name: String, _ j: AskJSON, _ turn: UUID) async throws -> Any {
        guard let t = Self.tools.first(where: { $0.name == name }) else { throw Problem("There's no tool called \(name).") }
        let s = Store.shared.settings
        if let src = t.source, !src.on(s) { throw Problem("\(src.title) is switched off in Settings › AI.") }
        switch name {
        case "get_location": return try await location(s)
        case "calendar_events": return try await calendar(j)
        case "tasks_list": return try await tasks(j)
        case "add_task": return try await addTask(j, turn)
        case "complete_task": return try await completeTask(j, turn)
        case "create_timer": return try timer(j, turn)
        case "set_alarm": return try alarm(j, turn)
        case "now_playing": return await nowPlaying()
        case "search_clipboard": return clipboard(j)
        case "search_meetings": return meetings(j)
        case "meeting_notes": return try meeting(j)
        case "search_notes": return notes(j)
        case "system_status": return system(s)
        case "selected_text": return try selection()
        case "open": return try open(j)
        default: throw Problem("There's no tool called \(name).")
        }
    }

    // MARK: Dates

    /// "2026-11-06" (that day's start, or with `end` the next day's), "2026-11-06T09:00", or ISO 8601 with a zone.
    static func date(_ raw: String, end: Bool = false) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(s.prefix(10))) else { return nil }
        return end ? Calendar.current.date(byAdding: .day, value: 1, to: d) : d
    }

    /// "Thu 2026-11-06 09:00" in the user's time zone (the date alone for all-day things).
    static func show(_ d: Date, time: Bool = true) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = time ? "EEE yyyy-MM-dd HH:mm" : "EEE yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func matches(_ query: String?, _ fields: [String?]) -> Bool {
        guard let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return true }
        let hay = fields.compactMap { $0 }.joined(separator: "\n")
        return q.split(separator: " ").allSatisfy { hay.localizedCaseInsensitiveContains($0) }
    }

    // MARK: Reads

    private func location(_ s: Settings) async throws -> Any {
        let loc = Location.shared
        if let f = await loc.current() {
            var d: [String: Any] = ["latitude": NSDecimalNumber(string: String(format: "%.3f", f.lat)), "longitude": NSDecimalNumber(string: String(format: "%.3f", f.lon)),
                                    "time_zone": (f.zone ?? .current).identifier]
            for (k, v) in [("town", f.city), ("neighbourhood", f.area), ("region", f.region), ("country", f.country)] { if let v { d[k] = v } }
            return d
        }
        let city = s.weatherCity.trimmingCharacters(in: .whitespaces)
        if !city.isEmpty { return ["town": city, "time_zone": TimeZone.current.identifier, "note": "The city set in Settings; the Mac's own location isn't available."] }
        throw Problem(loc.denied ? "Location is off for MONEY! (System Settings › Privacy & Security › Location Services)." : "Couldn't find where the Mac is right now.")
    }

    private func calendar(_ j: AskJSON) async throws -> Any {
        let cal = Calendar.current
        let from = j.s("from").flatMap { Self.date($0) } ?? cal.startOfDay(for: Date())
        var to = j.s("to").flatMap { Self.date($0, end: true) } ?? cal.date(byAdding: .day, value: 1, to: from)!
        if to <= from { to = from.addingTimeInterval(86_400) }
        to = min(to, from.addingTimeInterval(366 * 86_400))
        let c = CalendarEvents.shared
        if !c.authorized, c.undecided {
            c.requestAccess()
            var waited = 0
            while c.undecided, waited < 600 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
        }
        guard c.authorized else { throw Problem("MONEY! can't read the calendar (System Settings › Privacy & Security › Calendars, or sign in to Google in Settings).") }
        if c.google { await GoogleCalendar.shared.load(from: from, to: to) }
        let q = j.s("query")
        let found = c.range(from: from, to: to).filter { e in Self.matches(q, [e.title, e.location, e.notes, e.calendar] + e.attendees) }
        return ["from": Self.show(from), "to": Self.show(to), "count": found.count, "events": found.prefix(60).map { e -> [String: Any] in
            var d: [String: Any] = ["title": e.title, "calendar": e.calendar]
            if e.allDay {
                d["all_day"] = true
                d["date"] = Self.show(e.start, time: false)
            } else {
                d["start"] = Self.show(e.start)
                d["end"] = Self.show(e.end)
            }
            if let l = e.location { d["place"] = l }
            if !e.attendees.isEmpty { d["guests"] = e.attendees }
            if e.link != nil { d["video_call"] = true }
            if let n = e.notes { d["notes"] = String(n.prefix(300)) }
            return d
        }]
    }

    private func tasksReady() async throws -> GoogleTasks {
        guard Google.shared.ready else { throw Problem("Tasks need a Google account (Settings › Google).") }
        let g = GoogleTasks.shared
        if !g.loaded || g.age > 60 { await g.refresh() }
        guard !g.lists.isEmpty else { throw Problem(g.error ?? "Couldn't load the task lists.") }
        return g
    }

    private static func task(_ t: TaskItem, _ g: GoogleTasks) -> [String: Any] {
        var d: [String: Any] = ["id": t.id, "title": t.title]
        if let due = t.due { d["due"] = show(due, time: false) }
        if let n = t.notes { d["notes"] = String(n.prefix(300)) }
        if t.done { d["done"] = true }
        if let p = t.parent, let parent = g.tasks.first(where: { $0.id == p }) { d["subtask_of"] = parent.title }
        return d
    }

    private func list(_ name: String?, _ g: GoogleTasks) throws -> TaskList? {
        guard let name else { return nil }
        if let l = g.lists.first(where: { $0.id == name || $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return l }
        throw Problem("No list called \(name). The lists are: \(g.lists.map(\.title).joined(separator: ", ")).")
    }

    private func tasks(_ j: AskJSON) async throws -> Any {
        let g = try await tasksReady()
        let lists = try list(j.s("list"), g).map { [$0] } ?? g.lists
        let done = j.b("include_completed") == true
        return ["lists": lists.map { l -> [String: Any] in
            let open = g.open(in: l.id).prefix(80).map { Self.task($0, g) }
            let finished = done ? g.completed.filter { $0.list == l.id }.prefix(20).map { Self.task($0, g) } : []
            return ["list": l.title, "tasks": open + finished]
        }]
    }

    private func nowPlaying() async -> Any {
        let n = NowPlaying.shared
        if !n.available {
            n.refresh()
            try? await Task.sleep(for: .seconds(1.2))
        }
        guard n.available else { return "Nothing is playing in Music or Spotify." }
        func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
        var d: [String: Any] = ["title": n.songTitle, "artist": n.artistLine, "app": n.appName, "playing": n.playing]
        if !n.album.isEmpty { d["album"] = n.album }
        if n.duration > 0 { d["position"] = "\(clock(n.livePosition)) of \(clock(n.duration))" }
        return d
    }

    private func clipboard(_ j: AskJSON) -> Any {
        let all = Self.fakeClips ?? (NSApp.delegate as? AppDelegate)?.clipboard?.ordered ?? []
        let q = j.s("query")
        let limit = max(1, min(Int(j.d("limit") ?? 10), 30))
        // Never anything that looks like a key, token or password, whatever the clipboard setting.
        let found = all.filter { c in
            guard c.kind == .text, let t = c.text, !t.isEmpty, !ClipboardStore.looksSecret(t) else { return false }
            return Self.matches(q, [t, c.sourceName])
        }
        return found.prefix(limit).map { c -> [String: Any] in
            var d: [String: Any] = ["text": String((c.text ?? "").prefix(1500)), "copied": Self.show(c.date)]
            if let app = c.sourceName { d["from"] = app }
            if c.pinned { d["pinned"] = true }
            return d
        }
    }

    private func meetingDocs() -> [MeetingDoc] {
        let files = (try? FileManager.default.contentsOfDirectory(at: MeetingDoc.folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap(MeetingDoc.load).sorted { $0.date > $1.date }
    }

    private func meetings(_ j: AskJSON) -> Any {
        let from = j.s("from").flatMap { Self.date($0) } ?? .distantPast
        let to = j.s("to").flatMap { Self.date($0, end: true) } ?? .distantFuture
        let q = j.s("query")
        let found = meetingDocs().filter { d in
            d.date >= from && d.date < to && Self.matches(q, [d.title, d.attendees.joined(separator: ", "), d.notes, d.myNotes, d.transcript])
        }
        if found.isEmpty { return "No meetings found." }
        return found.prefix(12).map { d -> [String: Any] in
            var o: [String: Any] = ["id": d.url.deletingPathExtension().lastPathComponent, "title": d.displayTitle, "date": Self.show(d.date),
                                    "minutes": Int((d.duration / 60).rounded())]
            if !d.attendees.isEmpty { o["people"] = d.attendees }
            let summary = d.notes.isEmpty ? d.myNotes : d.notes
            if !summary.isEmpty { o["summary"] = String(summary.prefix(500)) }
            return o
        }
    }

    private func meeting(_ j: AskJSON) throws -> Any {
        guard let id = j.s("id"), !id.contains("/"), !id.hasPrefix("."),
              let d = MeetingDoc.load(MeetingDoc.folder.appendingPathComponent(id + ".md")) else {
            throw Problem("No meeting with that id; get one from search_meetings.")
        }
        let transcript = d.transcript
        var o: [String: Any] = ["title": d.displayTitle, "date": Self.show(d.date), "minutes": Int((d.duration / 60).rounded())]
        if !d.attendees.isEmpty { o["people"] = d.attendees }
        if !d.notes.isEmpty { o["notes"] = d.notes }
        if !d.myNotes.isEmpty { o["my_notes"] = d.myNotes }
        if !transcript.isEmpty { o["transcript"] = transcript.count > 60_000 ? String(transcript.prefix(60_000)) + "\n[cut short]" : transcript }
        return o
    }

    private func notes(_ j: AskJSON) -> Any {
        let q = j.s("query")
        let found = NoteBoard.shared.notes.filter { !$0.text.isEmpty && Self.matches(q, [$0.text]) }.sorted { $0.updated > $1.updated }
        if found.isEmpty { return "No sticky notes found." }
        return found.prefix(30).map { ["text": String($0.text.prefix(1000)), "updated": Self.show($0.updated)] }
    }

    private func system(_ s: Settings) -> Any {
        func line(_ k: String) -> String? {
            SystemTools.answers(k, k, s).first.map { [$0.title, $0.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
        }
        var d: [String: Any] = ["macOS": ProcessInfo.processInfo.operatingSystemVersionString]
        for (key, word) in [("battery", "battery"), ("storage", "disk"), ("memory", "memory"), ("uptime", "uptime")] {
            if let v = line(word) { d[key] = v }
        }
        return d
    }

    private func selection() throws -> Any {
        guard AXIsProcessTrusted() else {
            throw Problem("MONEY! needs Accessibility access to read the selection (System Settings › Privacy & Security › Accessibility).")
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let ws = NSWorkspace.shared
        guard let app = [ws.frontmostApplication, ws.menuBarOwningApplication].compactMap({ $0 }).first(where: { $0.processIdentifier != me }) else {
            throw Problem("No app is in front.")
        }
        func value(_ e: AXUIElement, _ key: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success ? v : nil
        }
        func element(_ o: AnyObject?) -> AXUIElement? {
            guard let o, CFGetTypeID(o) == AXUIElementGetTypeID() else { return nil }
            return (o as! AXUIElement)
        }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let text = element(value(ax, kAXFocusedUIElementAttribute)).flatMap { value($0, kAXSelectedTextAttribute) as? String } ?? ""
        var d: [String: Any] = ["app": app.localizedName ?? "", "selection": String(text.prefix(20_000))]
        if let w = element(value(ax, kAXFocusedWindowAttribute)), let title = value(w, kAXTitleAttribute) as? String, !title.isEmpty { d["window"] = title }
        if text.isEmpty { d["note"] = "Nothing is selected." }
        return d
    }

    // MARK: Writes (each leaves a receipt with Undo)

    private func addTask(_ j: AskJSON, _ turn: UUID) async throws -> Any {
        guard let title = j.s("title") else { throw Problem("A task needs a title.") }
        let g = try await tasksReady()
        let l = try list(j.s("list"), g) ?? g.lists.first
        let due = j.s("due").flatMap { Self.date($0) }.map { Calendar.current.startOfDay(for: $0) }
        guard let t = await g.add(title: title, notes: j.s("notes"), due: due, list: l?.id) else {
            throw Problem("Google didn't save the task" + (g.error.map { ": \($0)" } ?? "."))
        }
        let when = due.map { " · due " + $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? ""
        receipt(turn, AskReceipt(symbol: "checklist", color: .systemBlue, title: title, detail: "Added to \(l?.title ?? "Tasks")" + when) {
            GoogleTasks.shared.delete(t)
        })
        return ["added": Self.task(t, g), "list": l?.title ?? ""]
    }

    private func completeTask(_ j: AskJSON, _ turn: UUID) async throws -> Any {
        let g = try await tasksReady()
        guard let id = j.s("id"), let t = g.tasks.first(where: { $0.id == id }) else { throw Problem("No task with that id; get one from tasks_list.") }
        guard !t.done else { return "Already done." }
        g.setDone(t, true)
        receipt(turn, AskReceipt(symbol: "checkmark.circle.fill", color: .systemGreen, title: t.title, detail: "Marked as done") {
            if let now = GoogleTasks.shared.tasks.first(where: { $0.id == t.id }) { GoogleTasks.shared.setDone(now, false) }
        })
        return ["done": t.title]
    }

    private func timer(_ j: AskJSON, _ turn: UUID) throws -> Any {
        guard let minutes = j.d("minutes"), minutes > 0, minutes <= 24 * 60 else { throw Problem("A timer needs between 1 second and 24 hours.") }
        let label = j.s("label") ?? ""
        let length = SystemTools.span(minutes)
        var undo: @MainActor () -> Void = {}
        if !Self.sandbox {
            let t = Timers.shared.add(minutes: minutes, label: label)
            undo = { Timers.shared.remove(t) }
        }
        receipt(turn, AskReceipt(symbol: "timer", color: .systemOrange, title: label.isEmpty ? "\(length) timer" : label,
                                 detail: "Timer started · \(length)", undo: undo))
        return ["started": length, "label": label, "rings": Self.show(Date().addingTimeInterval(minutes * 60))]
    }

    private func alarm(_ j: AskJSON, _ turn: UUID) throws -> Any {
        let raw = j.s("time") ?? ""
        let hm: (Int, Int)? = Tools.rx(#"^(\d{1,2}):(\d{2})"#, raw).flatMap { m in Int(m[1]).flatMap { h in Int(m[2]).map { (h, $0) } } }
            ?? Alarms.parse(raw).map { ($0.hour, $0.minute) }
        guard let (h, m) = hm, (0..<24).contains(h), (0..<60).contains(m) else { throw Problem("Give the time as HH:mm.") }
        let days: Set<Int> = switch j.s("repeat") {
        case "daily": Set(1...7)
        case "weekdays": Set(2...6)
        case "weekends": [1, 7]
        default: []
        }
        let label = j.s("label") ?? ""
        var a = Alarm(hour: h, minute: m, label: label, weekdays: days)
        var undo: @MainActor () -> Void = {}
        if !Self.sandbox {
            a = Alarms.shared.add(hour: h, minute: m, label: label, weekdays: days)
            let id = a.id
            undo = { Alarms.shared.remove(id) }
        }
        receipt(turn, AskReceipt(symbol: "alarm.fill", color: .systemOrange, title: label.isEmpty ? "Alarm" : label,
                                 detail: "Alarm set · \(a.time) · \(a.repeatText)", undo: undo))
        return ["set": a.time, "repeats": a.repeatText, "next": Self.show(a.next)]
    }

    private func open(_ j: AskJSON) throws -> Any {
        if let raw = j.s("url") {
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw Problem("Only web addresses can be opened.") }
            if !Self.sandbox { AskCards.open(url) }
            return "Opened \(url.host ?? raw)."
        }
        guard let name = j.s("app") else { throw Problem("Say what to open: a url or an app.") }
        let apps = (NSApp.delegate as? AppDelegate)?.launcher?.model.index.apps ?? []
        let pick = apps.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame || $0.altName?.localizedCaseInsensitiveCompare(name) == .orderedSame }
            ?? apps.first { $0.name.localizedCaseInsensitiveContains(name) }
        guard let app = pick else { throw Problem("No app called \(name).") }
        if !Self.sandbox {
            (NSApp.delegate as? AppDelegate)?.launcher.hide()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
        }
        return "Opened \(app.name)."
    }
}

// MARK: Views

/// The changes an answer made, one line each with Undo.
struct AskReceipts: View {
    let turn: UUID

    var body: some View {
        let list = AskTools.shared.receipts[turn] ?? []
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: PanelLayout.gap) {
                ForEach(list) { ReceiptRow(receipt: $0, turn: turn) }
            }
            .transition(.opacity)
        }
    }
}

private struct ReceiptRow: View {
    let receipt: AskReceipt
    let turn: UUID
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(Color(nsColor: receipt.color).gradient)
                .frame(width: 18, height: 18)
                .overlay(Image(systemName: receipt.symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white))
                .opacity(receipt.undone ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(receipt.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                    .strikethrough(receipt.undone)
                    .foregroundStyle(receipt.undone ? .secondary : .primary)
                if let d = receipt.detail {
                    Text(receipt.undone ? "Undone" : d).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if receipt.undo != nil, !receipt.undone {
                Button { AskTools.shared.undo(receipt, in: turn) } label: {
                    Text("Undo").font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Capsule().fill(Color.primary.opacity(hover ? 0.16 : 0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
            }
        }
        .padding(.horizontal, cardPadding)
        .padding(.vertical, PanelLayout.gap)
        .frame(minHeight: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(AskCards.outline)
        .animation(.easeOut(duration: 0.2), value: receipt.undone)
    }
}

/// Settings › AI: which of the user's things Ask may look up, and the permissions they need.
struct AskSourcesSection: View {
    @Bindable var store: Store
    private let location = Location.shared
    private let calendar = CalendarEvents.shared

    var body: some View {
        Section("What Ask can use") {
            ForEach(AskSource.allCases) { src in
                Toggle(src.title, isOn: Binding(get: { src.on(store.settings) }, set: { store.settings.askSources[src.rawValue] = $0 }))
            }
            LabeledContent("Location access") {
                if location.allowed {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if location.undecided {
                    Button("Allow…") { location.requestPermission() }
                } else {
                    Button("Open Settings…") { open("Privacy_LocationServices") }
                }
            }
            LabeledContent("Calendar access") {
                if calendar.authorized {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button(calendar.undecided ? "Allow…" : "Open Settings…") { calendar.requestAccess() }
                }
            }
        }
    }

    private func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
