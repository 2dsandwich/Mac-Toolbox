import Foundation
import Observation

// Google Tasks, as in Moneybag: every list of every account, add / complete / edit / delete with the change shown at once and undone if
// Google refuses it, subtasks under their parent, and the recently completed ones. Cached on disk for a quick start.

struct TaskList: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    /// The account it belongs to (nil in caches from before there were several: the first account).
    var account: String?
}

struct TaskItem: Codable, Equatable, Identifiable {
    var id: String
    var list: String
    var title: String
    var notes: String?
    /// The day it's due (Google keeps no time).
    var due: Date?
    var done = false
    var completed: Date?
    var parent: String?
    var position = ""

    /// Not yet saved at Google.
    var local: Bool { id.hasPrefix("local-") }
}

@MainActor @Observable final class GoogleTasks {
    static let shared = GoogleTasks()

    private(set) var lists: [TaskList] = []
    private(set) var tasks: [TaskItem] = []
    private(set) var loaded = false
    private(set) var loading = false
    var error: String?

    @ObservationIgnored private var refreshedAt = Date.distantPast
    @ObservationIgnored private var writes = 0
    @ObservationIgnored private var demo = false
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    private static let api = "https://tasks.googleapis.com/tasks/v1"
    private struct Cache: Codable { var lists: [TaskList]; var tasks: [TaskItem] }
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MONEY/google-tasks.json")
    }

    /// Seconds since the last refresh.
    var age: TimeInterval { Date().timeIntervalSince(refreshedAt) }

    private init() {
        guard Google.shared.ready, !Google.shared.demo,
              let data = try? Data(contentsOf: Self.file), let c = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        lists = c.lists
        tasks = c.tasks
        loaded = true
    }

    func reset() {
        lists = []
        tasks = []
        loaded = false
        error = nil
        refreshedAt = .distantPast
        try? FileManager.default.removeItem(at: Self.file)
    }

    // MARK: Reading

    /// The lists switched on in Settings › Google.
    var shownLists: [TaskList] {
        let off = Store.shared.settings.taskListsOff
        return lists.filter { !off.contains($0.id) }
    }

    /// The account a list belongs to, for writing to it.
    private func account(_ list: String) -> String? { lists.first { $0.id == list }?.account }

    /// A list's open tasks in Google's order, each parent followed by its subtasks.
    func open(in list: String) -> [TaskItem] {
        let mine = tasks.filter { $0.list == list && !$0.done }
        let ids = Set(mine.map(\.id))
        let byPosition = { (a: TaskItem, b: TaskItem) in a.position < b.position }
        // New ones (no position yet) first, as Google puts them.
        let top = mine.filter { $0.parent == nil || !ids.contains($0.parent!) }.sorted { ($0.position.isEmpty ? 0 : 1, $0.position) < ($1.position.isEmpty ? 0 : 1, $1.position) }
        return top.flatMap { t in [t] + mine.filter { $0.parent == t.id }.sorted(by: byPosition) }
    }

    /// Done in the last 30 days, newest first.
    var completed: [TaskItem] {
        tasks.filter(\.done).sorted { ($0.completed ?? .distantPast) > ($1.completed ?? .distantPast) }
    }

    func refresh() async {
        guard Google.shared.ready, !demo, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            var all: [TaskList] = []
            for email in Google.shared.emails {
                let json = try await Google.shared.json(URL(string: "\(Self.api)/users/@me/lists?maxResults=100")!, account: email)
                all += (json["items"] as? [[String: Any]] ?? []).compactMap { l in
                    (l["id"] as? String).map { TaskList(id: $0, title: l["title"] as? String ?? "Tasks", account: email) }
                }
            }
            var found: [TaskItem] = []
            for l in all {
                found += try await fetch(l, done: false)
                found += try await fetch(l, done: true)
            }
            // A change still on its way would be undone by this older copy.
            guard writes == 0 else { return }
            lists = all
            tasks = found
            loaded = true
            error = nil
            refreshedAt = Date()
            save()
        } catch {
            self.error = error.localizedDescription
            if !loaded, !Google.shared.ready { loaded = false }
        }
    }

    private func fetch(_ l: TaskList, done: Bool) async throws -> [TaskItem] {
        let list = l.id
        var out: [TaskItem] = []
        var page = ""
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 86_400))
        repeat {
            var u = URLComponents(string: "\(Self.api)/lists/\(list)/tasks")!
            u.queryItems = done
                ? [.init(name: "showCompleted", value: "true"), .init(name: "showHidden", value: "true"), .init(name: "completedMin", value: since),
                   .init(name: "maxResults", value: "100")]
                : [.init(name: "showCompleted", value: "false"), .init(name: "maxResults", value: "100")]
            if !page.isEmpty { u.queryItems?.append(.init(name: "pageToken", value: page)) }
            let json = (try JSONSerialization.jsonObject(with: try await Google.shared.call(u.url!, account: l.account))) as? [String: Any] ?? [:]
            out += (json["items"] as? [[String: Any]] ?? []).compactMap { Self.task($0, list: list) }.filter { $0.done == done }
            page = json["nextPageToken"] as? String ?? ""
        } while !page.isEmpty && !done && out.count < 1000
        return out
    }

    /// Google's task JSON → TaskItem (nil for deleted or untitled ones).
    static func task(_ t: [String: Any], list: String) -> TaskItem? {
        guard let id = t["id"] as? String, t["deleted"] as? Bool != true,
              let title = (t["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let notes = (t["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskItem(id: id, list: list, title: title, notes: notes?.isEmpty == false ? notes : nil, due: (t["due"] as? String).flatMap(day),
                        done: t["status"] as? String == "completed", completed: (t["completed"] as? String).flatMap(time),
                        parent: t["parent"] as? String, position: t["position"] as? String ?? "")
    }

    /// "2026-11-12T00:00:00.000Z" → that day at local midnight (Google stores the date only).
    static func day(_ s: String) -> Date? {
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    static func dueString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02dT00:00:00.000Z", c.year!, c.month!, c.day!)
    }

    private static func time(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: Writing (shown at once, undone if Google refuses)

    /// Adds from what was typed: the list it names, else `list`, else the first.
    func add(_ text: String, list: String?) {
        let names = lists.map(\.title)
        Task {
            let p = await QuickAdd.final(text, groups: names)
            guard let target = lists.first(where: { $0.title == p.group })?.id ?? list ?? shownLists.first?.id ?? lists.first?.id else { return }
            let temp = TaskItem(id: "local-" + UUID().uuidString, list: target, title: p.title, notes: p.note, due: p.day)
            tasks.insert(temp, at: 0)
            var body: [String: Any] = ["title": temp.title]
            if let n = temp.notes { body["notes"] = n }
            if let d = temp.due { body["due"] = Self.dueString(d) }
            await write(undo: { $0.tasks.removeAll { $0.id == temp.id } }) {
                let data = try await Google.shared.call(URL(string: "\(Self.api)/lists/\(target)/tasks")!, method: "POST", body: body, account: self.account(target))
                if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let made = Self.task(json, list: target),
                   let i = self.tasks.firstIndex(where: { $0.id == temp.id }) {
                    self.tasks[i] = made
                }
            }
        }
    }

    /// Adds one task exactly as given (Ask) and waits for Google, so it comes back with its real id; nil if refused.
    func add(title: String, notes: String?, due: Date?, list: String?) async -> TaskItem? {
        guard let target = list ?? lists.first?.id else { return nil }
        let temp = TaskItem(id: (demo ? "demo-" : "local-") + UUID().uuidString, list: target, title: title, notes: notes, due: due)
        tasks.insert(temp, at: 0)
        var made: TaskItem? = demo ? temp : nil
        var body: [String: Any] = ["title": title]
        if let notes { body["notes"] = notes }
        if let due { body["due"] = Self.dueString(due) }
        await write(undo: { $0.tasks.removeAll { $0.id == temp.id } }) {
            let data = try await Google.shared.call(URL(string: "\(Self.api)/lists/\(target)/tasks")!, method: "POST", body: body, account: self.account(target))
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let t = Self.task(json, list: target),
               let i = self.tasks.firstIndex(where: { $0.id == temp.id }) {
                self.tasks[i] = t
                made = t
            }
        }
        return made
    }

    func setDone(_ t: TaskItem, _ done: Bool) {
        guard !t.local, let i = tasks.firstIndex(where: { $0.id == t.id }) else { return }
        tasks[i].done = done
        tasks[i].completed = done ? Date() : nil
        patch(t, done ? ["status": "completed"] : ["status": "needsAction", "completed": NSNull()])
    }

    /// Title, notes and due date together (nil clears).
    func edit(_ t: TaskItem, title: String, notes: String?, due: Date?) {
        guard !t.local, let i = tasks.firstIndex(where: { $0.id == t.id }) else { return }
        tasks[i].title = title
        tasks[i].notes = notes
        tasks[i].due = due
        patch(t, ["title": title, "notes": notes ?? NSNull(), "due": due.map(Self.dueString) ?? NSNull()])
    }

    func delete(_ t: TaskItem) {
        guard !t.local, let i = tasks.firstIndex(where: { $0.id == t.id }) else { return }
        tasks.remove(at: i)
        Task {
            await write(undo: { $0.tasks.insert(t, at: min(i, $0.tasks.count)) }) {
                _ = try await Google.shared.call(URL(string: "\(Self.api)/lists/\(t.list)/tasks/\(t.id)")!, method: "DELETE", account: self.account(t.list))
            }
        }
    }

    private func patch(_ before: TaskItem, _ body: [String: Any]) {
        Task {
            await write(undo: { m in if let i = m.tasks.firstIndex(where: { $0.id == before.id }) { m.tasks[i] = before } }) {
                _ = try await Google.shared.call(URL(string: "\(Self.api)/lists/\(before.list)/tasks/\(before.id)")!, method: "PATCH", body: body,
                                                 account: self.account(before.list))
            }
        }
    }

    private func write(undo: (GoogleTasks) -> Void, _ run: () async throws -> Void) async {
        save()
        guard !demo else { return }
        writes += 1
        defer { writes -= 1 }
        do {
            try await run()
            error = nil
        } catch {
            undo(self)
            self.error = error.localizedDescription
        }
        save()
    }

    private func save() {
        guard !demo else { return }
        saveWork?.cancel()
        let keep = Cache(lists: lists, tasks: tasks.filter { !$0.local })
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(keep) else { return }
            try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.file, options: .atomic)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: Snapshots

    func useDemo(empty: Bool = false) {
        demo = true
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let day = { (n: Int) in cal.date(byAdding: .day, value: n, to: today)! }
        lists = [TaskList(id: "l1", title: "My Tasks", account: "ben@example.com"), TaskList(id: "l2", title: "Festival", account: "ben@festival.example")]
        tasks = [
            TaskItem(id: "t1", list: "l1", title: "Call Ben about the contract", notes: "Ask about the second stage", due: day(0), position: "1"),
            TaskItem(id: "t2", list: "l1", title: "Renew passport", due: day(-2), position: "2"),
            TaskItem(id: "t3", list: "l1", title: "Book dentist", position: "3"),
            TaskItem(id: "t4", list: "l2", title: "Sponsor deck", due: day(1), position: "1"),
            TaskItem(id: "t5", list: "l2", title: "Logo on the cover", parent: "t4", position: "1"),
            TaskItem(id: "t6", list: "l2", title: "Pricing page", parent: "t4", position: "2"),
            TaskItem(id: "t7", list: "l2", title: "Venue walkthrough", due: day(5), position: "2"),
            TaskItem(id: "t8", list: "l2", title: "Artist contracts", position: "3"),
            TaskItem(id: "t11", list: "l1", title: "Write the thank-you notes for everyone who helped with the spring festival", due: day(3), position: "4"),
            TaskItem(id: "t9", list: "l1", title: "Pay the electricity bill", done: true, completed: Date().addingTimeInterval(-3600)),
            TaskItem(id: "t10", list: "l2", title: "Send the stage plan", done: true, completed: Date().addingTimeInterval(-86_400)),
        ]
        if empty { tasks = [] }
        loaded = true
    }
}
