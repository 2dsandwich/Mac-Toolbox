import AppKit
import SQLite3

// What Claude Code and Codex leave on disk: session names and processes, Codex's threads (its own SQLite stores, as
// most of the logs they point to are gone), and the day's tokens. Files are read on `Agents.io` only, a tail at a time
// or from where the last read stopped; results go back to the main thread as plain values.

final class AgentFiles: @unchecked Sendable {
    static let shared = AgentFiles()
    static let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: Claude Code

    struct ClaudeProcess { let pid: Int32; let name: String? }

    /// The session's process, from ~/.claude/sessions/<pid>.json: its pid, and its name when the user gave it one.
    static func claudeProcess(_ session: String) -> ClaudeProcess? {
        let dir = home.appendingPathComponent(".claude/sessions")
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
            guard let j = (try? Data(contentsOf: f)).flatMap(json), j["sessionId"] as? String == session,
                  let pid = (j["pid"] as? NSNumber)?.int32Value else { continue }
            let name = j["nameSource"] as? String == "derived" ? nil : (j["name"] as? String).map(trim).flatMap { $0.isEmpty ? nil : $0 }
            return ClaudeProcess(pid: pid, name: name)
        }
        return nil
    }

    /// The newest title in the transcript's last 512 KB: one set with /rename, else Claude Code's own, else an old summary.
    static func claudeTitle(_ path: String) -> String? {
        var found: [String: String] = [:]
        forEachLine(path, from: tail(path, 524_288)) { line in
            guard line.range(of: Data("Title\"".utf8)) != nil || line.range(of: Data("\"summary\"".utf8)) != nil, let j = json(line) else { return }
            switch j["type"] as? String {
            case "custom-title": found["custom"] = j["customTitle"] as? String
            case "ai-title": found["ai"] = j["aiTitle"] as? String
            case "summary": found["summary"] = j["summary"] as? String
            default: break
            }
        }
        return [found["custom"], found["ai"], found["summary"]].compactMap { $0.map(trim) }.first { !$0.isEmpty }
    }

    /// The terminal a process runs in ("/dev/ttys003"), to find its tab.
    static func tty(_ pid: Int32) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "tty=", "-p", "\(pid)"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let t = trim(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        p.waitUntilExit()
        return t.isEmpty || t.hasPrefix("?") ? nil : "/dev/" + t
    }

    private var claudeDay = Date.distantPast
    private var claudeOffsets: [String: UInt64] = [:]
    private var claudeSeen: Set<String> = []
    private var claudeTokens = 0

    /// Today's Claude Code tokens: input, cache writes and output (cache reads are the same context read again), each
    /// request once (its lines repeat the usage), from every transcript and subagent transcript written today.
    func claudeToday() -> Int {
        let day = Calendar.current.startOfDay(for: Date())
        if day != claudeDay { claudeDay = day; claudeOffsets = [:]; claudeSeen = []; claudeTokens = 0 }
        let e = FileManager.default.enumerator(at: Self.home.appendingPathComponent(".claude/projects"), includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
        while let f = e?.nextObject() as? URL {
            if f.lastPathComponent == "tool-results" { e?.skipDescendants(); continue }
            // A session's folder (its subagents) only when its own transcript was written today: subagents write
            // only while it runs, and it is written as each one ends.
            if f.pathExtension.isEmpty, let m = Self.modified(f.path + ".jsonl"), m < day { e?.skipDescendants(); continue }
            guard f.pathExtension == "jsonl", let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m >= day else { continue }
            claudeOffsets[f.path] = Self.forEachLine(f.path, from: claudeOffsets[f.path] ?? 0) { line in
                guard line.range(of: Data("\"usage\"".utf8)) != nil, let j = Self.json(line), j["type"] as? String == "assistant",
                      let m = j["message"] as? [String: Any], let u = m["usage"] as? [String: Any],
                      let t = (j["timestamp"] as? String).flatMap(Self.date), t >= day,
                      claudeSeen.insert("\(m["id"] ?? "")|\(j["requestId"] ?? "")").inserted else { return }
                claudeTokens += ["input_tokens", "cache_creation_input_tokens", "output_tokens"].reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) }
            }
        }
        return claudeTokens
    }

    // MARK: Focusing a session

    /// The app a process runs under (Ghostty for a claude in one of its tabs): its nearest ancestor that is an app.
    static func hostApp(_ pid: Int32) -> String? {
        var p = pid
        for _ in 0..<12 {
            if let id = NSRunningApplication(processIdentifier: p)?.bundleIdentifier { return id }
            let ps = Process(), out = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "ppid=", "-p", "\(p)"]
            ps.standardOutput = out
            ps.standardError = FileHandle.nullDevice
            guard (try? ps.run()) != nil else { return nil }
            let parent = Int32(trim(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))) ?? 0
            ps.waitUntilExit()
            guard parent > 1 else { return nil }
            p = parent
        }
        return nil
    }

    /// Brings a session's own tab or pane to the front: Ghostty, Terminal and iTerm2 by its terminal, VS Code and the
    /// Codex app by link; anything else just comes to the front.
    @MainActor static func focus(app: String?, session: String, claude: Bool, tty: String?) {
        let link: String? = switch app {
        case "com.microsoft.VSCode" where claude: "vscode://anthropic.claude-code/open?session=\(session)"
        case "com.openai.codex" where !claude: "codex://threads/\(session)"
        default: nil
        }
        if let link, let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        if let tty, let source = focusScript(app: app, tty: tty) {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if error == nil { return }
            // -1743: Automation for this app was turned off in System Settings › Privacy & Security.
            Log.write("agents: focusing a tab in \(app ?? "?") failed (\(error?[NSAppleScript.errorNumber] ?? "?"))")
        }
        guard let app, let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first else {
            return Log.write("agents: no running app \(app ?? "nil") for a \(claude ? "Claude" : "Codex") session (tty \(tty == nil ? "unknown" : "found"))")
        }
        running.activate()
    }

    /// The AppleScript that selects the tab (or pane) on a terminal.
    static func focusScript(app: String?, tty: String) -> String? {
        switch app {
        case "com.mitchellh.ghostty":
            return """
            tell application id "com.mitchellh.ghostty"
              activate
              focus (first terminal whose tty is "\(tty)")
            end tell
            """
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return
                  end if
                end repeat
              end repeat
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      select t
                      select s
                      activate
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        default: return nil
        }
    }

    // MARK: Codex

    struct CodexThread: Sendable {
        var id: String
        var cwd: String
        var title: String
        /// The thread that spawned it, for a subagent.
        var parent: String?
        var nickname: String?
        var role = ""
        var desktop = false
        var working = false
        var activity = ""
        var started: Date?
        var updated: Date
        var context: Double?
    }
    struct Codex: Sendable {
        var threads: [CodexThread] = []
        var five: Agents.Limit?
        var week: Agents.Limit?
        var seen = Date.distantPast
        var today = 0
    }

    private var codexDay = Date.distantPast
    private var tokenOffsets: [String: UInt64] = [:]
    private var tokenLast: [String: Int] = [:]
    private var last = Codex()
    /// When everything the last pass read was last written (with its day and window), and the logs it read.
    private var stamp: [Date] = []
    private var logs: [String] = []

    static let codexDir = home.appendingPathComponent(".codex")

    /// Threads touched in the last half hour (from state_5.sqlite, else the last two days' logs), each one's state
    /// and step from its log's tail (or the turn history when the log is gone), and from every log written today the
    /// limits and the day's tokens.
    func codex(window: TimeInterval = 1800) -> Codex {
        let now = Date(), day = Calendar.current.startOfDay(for: now)
        if day != codexDay { codexDay = day; tokenOffsets = [:]; tokenLast = [:]; last.today = 0 }
        // Nothing Codex keeps has been written since the last pass: only the clock moves its threads on.
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let files = ["state_5.sqlite", "state_5.sqlite-wal", "thread_history_1.sqlite", "thread_history_1.sqlite-wal", "session_index.jsonl",
                     String(format: "sessions/%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)].map { Self.codexDir.appendingPathComponent($0).path }
        let stamp = [day, Date(timeIntervalSinceReferenceDate: window)] + (files + logs).map { Self.modified($0) ?? .distantPast }
        if stamp == self.stamp {
            var out = last
            out.threads = last.threads.filter { now.timeIntervalSince($0.updated) < window }
            for i in out.threads.indices where now.timeIntervalSince(out.threads[i].updated) > 1700 { out.threads[i].working = false }
            return out
        }
        var out = Codex(five: last.five, week: last.week, seen: last.seen, today: last.today)
        var read: Set<String> = []
        let rows = Self.threadRows(since: min(day, now.addingTimeInterval(-max(window, 7 * 86_400))))
        let names = Self.sessionIndex()
        for r in rows {
            let exists = FileManager.default.fileExists(atPath: r.path)
            // Logs written today for the tokens; with no limits yet, the newest log there is (Codex unused today).
            if exists, r.updated >= day || out.seen == .distantPast { readTokens(r.path, day, &out); read.insert(r.path) }
            guard now.timeIntervalSince(r.updated) < window else { continue }
            var t = r.thread
            t.title = names[t.id] ?? t.title
            if exists { Self.rollout(r.path, into: &t); read.insert(r.path) } else { Self.history(into: &t) }
            // A turn that stopped writing half an hour ago crashed or was closed.
            if now.timeIntervalSince(t.updated) > 1700 { t.working = false }
            out.threads.append(t)
        }
        last = out
        // Stamped as they were before reading, so anything written meanwhile is read next time; other logs this time
        // means the next pass reads again and stamps those.
        if read == Set(logs) { self.stamp = stamp } else { logs = Array(read); self.stamp = [] }
        return out
    }

    private struct Row { var thread: CodexThread; var path: String; var updated: Date }

    /// Codex's threads updated since a time, newest first.
    private static func threadRows(since: Date) -> [Row] {
        let sql = """
            select id, rollout_path, cwd, coalesce(nullif(name, ''), nullif(title, ''), preview), source, agent_nickname, agent_path, updated_at_ms, coalesce(originator, '')
            from threads where archived = 0 and updated_at_ms > \(Int(since.timeIntervalSince1970 * 1000)) order by updated_at_ms desc limit 200
            """
        if let rows = query(codexDir.appendingPathComponent("state_5.sqlite").path, sql) {
            return rows.compactMap { c in
                guard let id = c[0], let path = c[1], let ms = c[7].flatMap(Double.init) else { return nil }
                let spawn = ((c[4].flatMap { json(Data($0.utf8)) }?["subagent"] as? [String: Any])?["thread_spawn"]) as? [String: Any]
                let updated = Date(timeIntervalSince1970: ms / 1000)
                var t = CodexThread(id: id, cwd: c[2] ?? "", title: line(c[3] ?? ""), parent: spawn?["parent_thread_id"] as? String, nickname: c[5],
                               desktop: c[8]?.contains("desktop") ?? false, updated: updated)
                t.role = ((c[6] ?? "") as NSString).lastPathComponent.replacingOccurrences(of: "_", with: " ")
                return Row(thread: t, path: path, updated: updated)
            }
        }
        // No database (an older Codex): its logs from today and yesterday.
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        return [Date(), Date().addingTimeInterval(-86_400)].flatMap { d in
            let dir = codexDir.appendingPathComponent("sessions/" + f.string(from: d))
            return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).compactMap { u -> Row? in
                guard u.pathExtension == "jsonl", let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > since else { return nil }
                var meta: [String: Any]?
                forEachLine(u.path, from: 0, limit: 1) { meta = json($0)?["payload"] as? [String: Any] }
                guard let meta, let id = meta["id"] as? String else { return nil }
                return Row(thread: CodexThread(id: id, cwd: meta["cwd"] as? String ?? "", title: "", desktop: (meta["originator"] as? String ?? "").contains("desktop"), updated: m), path: u.path, updated: m)
            }
        }
    }

    /// Thread names from ~/.codex/session_index.jsonl (the last line for a thread wins).
    private static func sessionIndex() -> [String: String] {
        var names: [String: String] = [:]
        let path = codexDir.appendingPathComponent("session_index.jsonl").path
        forEachLine(path, from: tail(path, 262_144)) { l in
            guard let j = json(l), let id = j["id"] as? String, let n = (j["thread_name"] as? String).map(trim), !n.isEmpty else { return }
            names[id] = line(n)
        }
        return names
    }

    /// A thread's state from its log's last 256 KB: working or done, the step it's on (its reasoning's bold title, or the
    /// command it ran), and how full its context is.
    private static func rollout(_ path: String, into t: inout CodexThread) {
        forEachLine(path, from: tail(path, 262_144)) { l in
            guard let j = json(l), let p = j["payload"] as? [String: Any] else { return }
            switch p["type"] as? String {
            case "task_started":
                t.working = true
                t.started = (p["started_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? (j["timestamp"] as? String).flatMap(date)
                t.activity = "Working"
            case "task_complete":
                t.working = false
                t.activity = line(p["last_agent_message"] as? String ?? "").isEmpty ? "Done" : line(p["last_agent_message"] as? String ?? "")
            case "reasoning" where j["type"] as? String == "response_item":
                if let s = step(p["summary"]) { t.activity = s }
            case "item_completed":
                let item = p["item"] as? [String: Any]
                if item?["type"] as? String == "CommandExecution", let c = command(item?["parsed_cmd"]) { t.activity = c }
            case "token_count":
                let info = p["info"] as? [String: Any]
                if let used = ((info?["last_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber)?.doubleValue,
                   let window = (info?["model_context_window"] as? NSNumber)?.doubleValue, window > 0 {
                    t.context = min(100, used / window * 100)
                }
            default: break
            }
        }
    }

    /// A thread whose log is gone: its last turn and step from ~/.codex/thread_history_1.sqlite.
    private static func history(into t: inout CodexThread) {
        let file = codexDir.appendingPathComponent("thread_history_1.sqlite").path
        let id = t.id.replacingOccurrences(of: "'", with: "")
        if let turn = query(file, "select status, started_at from thread_turns where thread_id = '\(id)' order by rollout_ordinal desc limit 1")?.first {
            t.working = turn[0] == "inProgress"
            t.started = turn[1].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
            t.activity = t.working ? "Working" : "Done"
        }
        let sql = "select item_json from thread_items where thread_id = '\(id)' and item_type in ('reasoning', 'commandExecution') order by rollout_ordinal desc limit 1"
        if let item = query(file, sql)?.first?[0].flatMap({ json(Data($0.utf8)) }), let s = step(item["summary"]) ?? command(item["commandActions"]) {
            t.activity = s
        }
    }

    /// Adds a log's new token counts that happened today, and takes its newest limits.
    private func readTokens(_ path: String, _ day: Date, _ out: inout Codex) {
        tokenOffsets[path] = Self.forEachLine(path, from: tokenOffsets[path] ?? 0) { l in
            guard l.range(of: Data("token_count".utf8)) != nil, let j = Self.json(l), let p = j["payload"] as? [String: Any], p["type"] as? String == "token_count" else { return }
            let at = (j["timestamp"] as? String).flatMap(Self.date) ?? .distantPast
            if let u = (p["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] {
                func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                let fresh = n("input_tokens") - n("cached_input_tokens") + n("output_tokens")
                if at >= day { out.today += max(0, fresh - (tokenLast[path] ?? 0)) }
                tokenLast[path] = fresh
            }
            if let r = p["rate_limits"] as? [String: Any], at > out.seen {
                func limit(_ k: String) -> Agents.Limit? {
                    guard let w = r[k] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                    return Agents.Limit(used: used, resets: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                                        window: ((w["window_minutes"] as? NSNumber)?.doubleValue ?? 300) * 60)
                }
                out.five = limit("primary"); out.week = limit("secondary"); out.seen = at
            }
        }
    }

    /// The step a reasoning summary starts with: its "**Title**" line.
    private static func step(_ summary: Any?) -> String? {
        let texts = (summary as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["text"] as? String ?? $0 as? String }
        guard let t = texts.last, t.hasPrefix("**"), let end = t.dropFirst(2).range(of: "**") else { return nil }
        let title = trim(String(t.dropFirst(2)[..<end.lowerBound]))
        return title.isEmpty ? nil : line(title)
    }

    /// A command Codex ran, in words: what it read or searched for, else the command.
    private static func command(_ parsed: Any?) -> String? {
        guard let c = (parsed as? [[String: Any]])?.last else { return nil }
        let name = (c["name"] as? String) ?? ((c["path"] as? String).map { ($0 as NSString).lastPathComponent })
        switch c["type"] as? String {
        case "read": return name.map { "Reading " + $0 }
        case "search": return (c["query"] as? String).map { "Searching for " + line($0) }
        case "list_files", "listFiles": return "Listing " + (name ?? "files")
        default: return (c["cmd"] as? String ?? c["command"] as? String).map { "Running " + line($0, max: 60) }
        }
    }

    // MARK: Helpers

    /// Rows of a Codex database, opened read-only (Codex keeps writing it); nil when there's no such database.
    static func query(_ file: String, _ sql: String) -> [[String?]]? {
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(file, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 250)
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        var rows: [[String?]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(st)).map { sqlite3_column_text(st, $0).map { String(cString: $0) } })
        }
        return rows
    }

    /// Calls `body` with each whole line from `offset` on, 4 MB at a time, and returns where the last whole line ended
    /// (a line still being written is read next time). A file that got shorter is read from the start.
    @discardableResult static func forEachLine(_ path: String, from offset: UInt64, limit: Int = .max, _ body: (Data) -> Void) -> UInt64 {
        guard let h = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var pos = offset > size ? 0 : offset, count = 0
        try? h.seek(toOffset: pos)
        var carry = Data()
        while count < limit, let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty {
            carry.append(chunk)
            var start = carry.startIndex
            while count < limit, let nl = carry[start...].firstIndex(of: 10) {
                body(carry[start..<nl])
                start = nl + 1
                count += 1
            }
            pos += UInt64(start - carry.startIndex)
            carry = Data(carry[start...])
        }
        return pos
    }

    /// When a file (or folder) was last written.
    static func modified(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }

    /// Where the last `bytes` of a file start.
    static func tail(_ path: String, _ bytes: UInt64) -> UInt64 {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        return size > bytes ? size - bytes : 0
    }

    static func json(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func line(_ s: String, max: Int = 120) -> String { Agents.line(s, max: max) }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func date(_ s: String) -> Date? { iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) }
}
