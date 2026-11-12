import AppKit
import Network
import Observation
import SwiftUI

// Coding agents in the notch and the search bar: what each session is doing, the question one asks with its options as
// buttons, and the provider's 5-hour and weekly limits. Claude Code reports through HTTP hooks and its status line to
// 127.0.0.1 (Settings › Notch connects them); Codex through the files it writes anyway (`AgentFiles`). The views are
// in AgentsViews.swift.

@MainActor @Observable final class Agents {
    static let shared = Agents()
    static let port: UInt16 = 47474
    static let hookURL = "http://127.0.0.1:\(port)/claude/hook"
    static let statusCommand = "curl -s -m 1 --data-binary @- http://127.0.0.1:\(port)/claude/status"
    /// Reading the agents' files happens here, never on the main thread.
    nonisolated static let io = DispatchQueue(label: "money.agents.files", qos: .utility)

    enum Provider: String { case claude = "Claude Code", codex = "Codex" }
    enum State { case working, needsYou, idle }
    /// A subagent a session started (an Agent call, or a Codex thread it spawned).
    struct Sub: Identifiable, Equatable {
        let id: String
        /// Claude Code's own id for it, once SubagentStart names it (its tools' hooks carry it).
        var agent: String?
        var name: String
        var kind: String
        var state: State
        var activity: String
        var started: Date
    }
    struct Todo: Equatable { var done: Int; var total: Int; var current: String }
    struct Session: Identifiable, Equatable {
        let id: String
        var provider: Provider
        var project: String
        var state: State
        /// What it's doing right now, or how it finished.
        var detail: String
        /// When the current turn started.
        var started: Date
        var updated: Date
        /// The app it runs in (Ghostty, an editor…), to bring to the front.
        var app: String?
        /// Its short name: the one it was given, else the one the agent gave it (the folder's until then).
        var title = ""
        var todo: Todo?
        /// How full its context window is, in percent.
        var context: Double?
        var added = 0
        var removed = 0
        var subs: [Sub] = []
        /// Claude Code's tasks (TaskCreated, TaskCompleted) by id: done or not.
        var tasks: [String: Bool] = [:]
        var name: String { title.isEmpty ? project : title }
        /// The name cut to its first few words, for the closed notch: "Agents view in the notch" → "Agents view".
        var short: String {
            var out = ""
            for w in name.split(separator: " ") {
                let next = out.isEmpty ? String(w) : out + " " + w
                if next.count > 14, !out.isEmpty { break }
                out = next
            }
            return out.count > 16 ? String(out.prefix(15)) + "…" : out
        }
        /// Its turn ended but a subagent it started is still running: not finished yet.
        var waitingOnSubs: Bool { state == .idle && subs.contains { $0.state == .working } }
        /// The state to show: working while any of its subagents is.
        var shown: State { waitingOnSubs ? .working : state }
    }
    struct Limit: Equatable {
        var used: Double
        var resets: Date?
        /// The window's length (5 hours, a week).
        var window: TimeInterval
    }
    struct Limits: Equatable { var provider: Provider; var fiveHour: Limit?; var week: Limit?; var seen: Date }
    struct Option: Hashable { let label: String; let detail: String }
    struct Ask { let question: String; let options: [Option]; let multi: Bool }
    /// An edit waiting for permission: the file, and the lines it takes out and puts in.
    struct Diff { let file: String; let removed: [String]; let added: [String] }
    struct Question: Identifiable {
        let id = UUID()
        let session: String
        let project: String
        let asks: [Ask]
        /// A permission prompt: the tool and what it would do.
        let permission: (tool: String, summary: String)?
        var diff: Diff?
        /// ExitPlanMode's plan, to approve.
        var plan: String?
        /// Claude Code's own "don't ask again" rules for this prompt, sent back for Always Allow.
        var suggestions: [[String: Any]] = []
        /// The tool's input, echoed back with the answers.
        let input: [String: Any]
        let conn: NWConnection?
    }

    private(set) var sessions: [Session] = []
    private(set) var limits: [Provider: Limits] = [:]
    /// Today's tokens per provider (`AgentFiles`).
    private(set) var tokens: [Provider: Int] = [:]
    private(set) var questions: [Question] = []
    /// Sessions whose subagents show under them.
    var expanded: Set<String> = []
    /// The front question's answers so far (multi-part questions go one at a time) and a multi-select's picks.
    var step = 0
    var answers: [String: String] = [:]
    var picks: Set<String> = []
    /// The search bar's agents view at its natural height (measured, as rows wrap).
    var panelHeight: CGFloat = 0

    @ObservationIgnored var onChange: (() -> Void)?
    /// A session just finished: its turn ended and none of its subagents is still running (the closed notch says so).
    @ObservationIgnored var onFinish: ((Session) -> Void)?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var filesTimer: Timer?
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var reads = 0
    /// When each Claude session's name was last looked up.
    @ObservationIgnored private var looked: [String: Date] = [:]

    /// Sessions worth showing: working or waiting on you, and ones that finished in the last 15 minutes.
    var visible: [Session] {
        sessions.filter { $0.shown != .idle || -$0.updated.timeIntervalSinceNow < 900 }
            .sorted { ($0.state.rank, $1.updated) < ($1.state.rank, $0.updated) }
    }
    var live: [Session] { sessions.filter { $0.shown != .idle } }
    var asking: Bool { !questions.isEmpty }
    /// In the closed notch only when an agent needs you (working sessions wait behind the agents button).
    var showsInNotch: Bool { asking || sessions.contains { $0.state == .needsYou } }
    /// Whose input is needed: its folder, short enough for the closed notch.
    var needy: String {
        let id = questions.first?.session
        return sessions.first { id == nil ? $0.state == .needsYou : $0.id == id }?.project ?? ""
    }
    /// Anything ever heard from (the notch's agents button shows then).
    var known: Bool { !sessions.isEmpty || !limits.isEmpty }
    func run(_ on: Bool) {
        if on { startServer(); startFiles() } else {
            listener?.cancel(); listener = nil
            filesTimer?.invalidate(); filesTimer = nil
            for q in questions { reply(q, nil) }
            questions = []; sessions = []; limits = [:]; tokens = [:]
            changed()
        }
    }

    private func changed() { onChange?() }

    private func upsert(_ id: String, _ provider: Provider, cwd: String?, app: String?, at t: Date = Date(), _ edit: (inout Session) -> Void) {
        var s = sessions.first { $0.id == id }
            ?? Session(id: id, provider: provider, project: "", state: .idle, detail: "", started: t, updated: t)
        if let cwd, !cwd.isEmpty { s.project = (cwd as NSString).lastPathComponent }
        if let app, !app.isEmpty { s.app = app }
        let was = s.state, began = s.started, wasShown = s.shown
        edit(&s)
        s.updated = t
        if s.state == .working, was != .working, s.started == began { s.started = t }
        let known = sessions.contains { $0.id == id }
        if let k = sessions.firstIndex(where: { $0.id == id }) { sessions[k] = s } else { sessions.append(s) }
        // Only a finish happening now: catching up on an old log at launch replays finishes long past.
        if known, wasShown == .working, s.shown == .idle, Date().timeIntervalSince(t) < 60 { onFinish?(s) }
    }

    /// Brings the session's own tab, pane or thread to the front (`AgentFiles.focus`), else its app.
    func open(_ s: Session) {
        let (id, app, claude) = (s.id, s.app, s.provider == .claude)
        Self.io.async {
            let pid = claude ? AgentFiles.claudeProcess(id)?.pid : nil
            let tty = pid.flatMap(AgentFiles.tty)
            // The terminal actually running it first: what a hook reported can be missing (a session found from its
            // files) or name no running app.
            let host = pid.flatMap(AgentFiles.hostApp) ?? app
            DispatchQueue.main.async { MainActor.assumeIsolated { AgentFiles.focus(app: host, session: id, claude: claude, tty: tty) } }
        }
    }

    func toggleSubs(_ s: Session) {
        if expanded.contains(s.id) { expanded.remove(s.id) } else { expanded.insert(s.id) }
    }

    // MARK: Answering

    /// Picks an option of the front question's current part (toggles it on a multi-select).
    func choose(_ option: String) {
        guard let q = questions.first, step < q.asks.count else { return }
        let ask = q.asks[step]
        if ask.multi {
            if picks.contains(option) { picks.remove(option) } else { picks.insert(option) }
            return
        }
        answers[ask.question] = option
        next(q)
    }

    /// A multi-select's picks are in.
    func confirm() {
        guard let q = questions.first, step < q.asks.count, !picks.isEmpty else { return }
        let ask = q.asks[step]
        answers[ask.question] = ask.options.map(\.label).filter(picks.contains).joined(separator: ", ")
        next(q)
    }

    private func next(_ q: Question) {
        picks = []
        step += 1
        guard step >= q.asks.count else { return }
        var input = q.input
        input["answers"] = answers
        send(q, ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input]])
    }

    func allow(_ ok: Bool, always: Bool = false) {
        guard let q = questions.first else { return }
        send(q, Self.decision(q, ok, always: always))
    }

    /// The PermissionRequest answer. Always Allow sends back Claude Code's first suggestion, as its own prompt would.
    static func decision(_ q: Question, _ ok: Bool, always: Bool) -> [String: Any] {
        var d: [String: Any] = ok ? ["behavior": "allow"] : ["behavior": "deny", "message": "Declined from the notch."]
        if ok, always, let s = q.suggestions.first { d["updatedPermissions"] = [s] }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
    }

    /// Leaves the front question to the terminal (it shows its own prompt there).
    func toTerminal() {
        guard let q = questions.first else { return }
        if let s = sessions.first(where: { $0.id == q.session }) { open(s) }
        finish(q, nil)
    }

    private func send(_ q: Question, _ json: [String: Any]) {
        finish(q, try? JSONSerialization.data(withJSONObject: json))
    }

    private func finish(_ q: Question, _ body: Data?) {
        reply(q, body)
        drop(q.id)
        upsert(q.session, .claude, cwd: nil, app: nil) { $0.state = .working }
        changed()
    }

    private func reply(_ q: Question, _ body: Data?) {
        guard let c = q.conn else { return }
        Self.respond(c, body ?? Data(), type: "application/json")
    }

    private func drop(_ id: UUID) {
        let front = questions.first?.id == id
        questions.removeAll { $0.id == id }
        if front { step = 0; answers = [:]; picks = [] }
    }

    // MARK: Claude Code (HTTP hooks and the status line)

    private func startServer() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { c in
            c.start(queue: .main)
            MainActor.assumeIsolated { Agents.shared.read(c, Data()) }
        }
        l.start(queue: .main)
        listener = l
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, error in
            MainActor.assumeIsolated {
                var buf = buf
                if let data { buf.append(data) }
                guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                    if done || error != nil || buf.count > 1 << 20 { c.cancel() } else { Agents.shared.read(c, buf) }
                    return
                }
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n").map(String.init)
                func header(_ name: String) -> String? {
                    head.dropFirst().first { $0.lowercased().hasPrefix(name + ":") }.map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(header("content-length") ?? "") ?? 0
                let body = Data(buf[end.upperBound...])
                if body.count < length, !done, error == nil { return Agents.shared.read(c, buf) }
                let path = head.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                Agents.shared.route(path, body, app: header("x-money-app"), c)
            }
        }
    }

    private func route(_ path: String, _ body: Data, app: String?, _ c: NWConnection) {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return Self.respond(c, Data(), type: "text/plain")
        }
        switch path {
        case "/claude/status": Self.respond(c, Data(status(json).utf8), type: "text/plain")
        case "/claude/hook":
            if !hook(json, app: app, c) { Self.respond(c, Data(), type: "application/json") }
            changed()
        default: Self.respond(c, Data(), type: "text/plain")
        }
    }

    /// One Claude Code hook event. True when it holds the connection for an answer from the notch.
    @discardableResult func hook(_ j: [String: Any], app: String?, _ c: NWConnection?) -> Bool {
        guard let id = j["session_id"] as? String else { return false }
        let cwd = j["cwd"] as? String
        let event = j["hook_event_name"] as? String ?? ""
        let tool = j["tool_name"] as? String ?? ""
        let input = j["tool_input"] as? [String: Any] ?? [:]
        let agent = (j["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let call = j["tool_use_id"] as? String ?? UUID().uuidString
        func set(_ state: State, _ detail: String? = nil, _ more: (inout Session) -> Void = { _ in }) {
            upsert(id, .claude, cwd: cwd, app: app) { s in
                s.state = state
                if let detail { s.detail = detail }
                more(&s)
            }
        }
        if ["SessionStart", "UserPromptSubmit", "Stop"].contains(event) { lookUp(id, j["transcript_path"] as? String) }
        // A subagent's own tool calls: its row says what it's doing; the session's line stays the parent's.
        if let agent, event == "PreToolUse" || event == "PostToolUse", tool != "AskUserQuestion" {
            set(.working) { s in
                let k = s.subs.firstIndex { $0.agent == agent } ?? {
                    s.subs.append(Sub(id: agent, agent: agent, name: j["agent_type"] as? String ?? "Agent", kind: "", state: .working, activity: "", started: Date()))
                    return s.subs.count - 1
                }()
                s.subs[k].state = .working
                if event == "PreToolUse" { s.subs[k].activity = Self.activity(tool, input) }
            }
            return false
        }
        switch event {
        case "SessionStart": set(.idle, "Ready")
        case "UserPromptSubmit":
            set(.working, Self.line(j["prompt"] as? String ?? "")) { s in s.subs.removeAll { $0.state == .idle } }
        case "PreToolUse" where tool == "AskUserQuestion":
            let asks = (input["questions"] as? [[String: Any]] ?? []).compactMap { q -> Ask? in
                guard let text = q["question"] as? String else { return nil }
                let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o in
                    (o["label"] as? String).map { Option(label: $0, detail: o["description"] as? String ?? "") }
                }
                return Ask(question: text, options: options, multi: q["multiSelect"] as? Bool ?? false)
            }
            guard !asks.isEmpty else { return false }
            set(.needsYou, asks[0].question)
            hold(Question(session: id, project: name(id), asks: asks, permission: nil, input: input, conn: c))
            return c != nil
        case "PermissionRequest":
            set(.needsYou, tool == "ExitPlanMode" ? "Plan ready" : "Wants to use \(tool)")
            var q = Question(session: id, project: name(id), asks: [], permission: (tool, Self.summary(tool, input)), input: input, conn: c)
            q.diff = Self.diff(tool, input)
            q.plan = tool == "ExitPlanMode" ? input["plan"] as? String : nil
            q.suggestions = j["permission_suggestions"] as? [[String: Any]] ?? []
            hold(q)
            return c != nil
        case "PreToolUse":
            set(.working, Self.activity(tool, input)) { s in
                if ["Agent", "Task"].contains(tool) {
                    s.subs.append(Sub(id: call, name: Self.line(input["description"] as? String ?? "Agent"), kind: input["subagent_type"] as? String ?? "general-purpose",
                                      state: .working, activity: "Starting", started: Date()))
                }
                if tool == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
                    let done = todos.filter { $0["status"] as? String == "completed" }.count
                    let now = todos.first { $0["status"] as? String == "in_progress" }
                    s.todo = Todo(done: done, total: todos.count, current: Self.line(now?["activeForm"] as? String ?? now?["content"] as? String ?? ""))
                }
                if tool == "TaskUpdate", let t = input["taskId"] as? String {
                    if input["status"] as? String == "completed" { s.tasks[t] = true }
                    if input["status"] as? String == "in_progress", let f = input["activeForm"] as? String { s.todo?.current = Self.line(f) }
                    s.retally()
                }
            }
        case "PostToolUse":
            set(.working) { s in
                guard ["Agent", "Task"].contains(tool), let k = s.subs.firstIndex(where: { $0.id == call }) else { return }
                let r = j["tool_response"] as? [String: Any]
                if let a = r?["agentId"] as? String { s.subs[k].agent = a }
                // Started in the background, it keeps going until SubagentStop.
                if r?["status"] as? String != "async_launched" { s.subs[k].state = .idle; s.subs[k].activity = "Done" }
            }
        case "SubagentStart":
            guard let agent, let kind = j["agent_type"] as? String, !kind.isEmpty else { break } // empty: Claude Code's own helpers
            set(.working) { s in
                // The oldest Agent call of this kind still waiting for its id is this one.
                if let k = s.subs.firstIndex(where: { $0.agent == nil && $0.kind == kind }) { s.subs[k].agent = agent } else if !s.subs.contains(where: { $0.agent == agent }) {
                    s.subs.append(Sub(id: agent, agent: agent, name: kind, kind: kind, state: .working, activity: "Starting", started: Date()))
                }
            }
        case "SubagentStop":
            guard let agent, let k = sessions.firstIndex(where: { $0.id == id }), let n = sessions[k].subs.firstIndex(where: { $0.agent == agent }) else { break }
            let wasShown = sessions[k].shown
            sessions[k].subs[n].state = .idle
            sessions[k].subs[n].activity = Self.line(j["last_assistant_message"] as? String ?? "").nonEmpty ?? "Done"
            if wasShown == .working, sessions[k].shown == .idle { onFinish?(sessions[k]) }
        case "TaskCreated", "TaskCompleted":
            guard let t = j["task_id"] as? String else { break }
            set(.working) { s in
                s.tasks[t] = event == "TaskCompleted"
                s.retally()
                if event == "TaskCreated", s.todo?.current.isEmpty ?? true { s.todo?.current = Self.line(j["task_subject"] as? String ?? "") }
            }
        case "Notification":
            switch j["notification_type"] as? String {
            case "permission_prompt", "elicitation_dialog", "agent_needs_input": set(.needsYou, Self.line(j["message"] as? String ?? ""))
            default: break
            }
        case "Stop":
            set(.idle, Self.line(j["last_assistant_message"] as? String ?? "").nonEmpty ?? "Done")
        case "SessionEnd":
            for q in questions where q.session == id { reply(q, nil); drop(q.id) }
            sessions.removeAll { $0.id == id }
        default: break
        }
        return false
    }

    private func name(_ id: String) -> String { sessions.first { $0.id == id }?.name ?? "" }

    /// Looks up a Claude session's name (and so its title) off the main thread, at most every 20 seconds.
    private func lookUp(_ id: String, _ transcript: String?) {
        guard Date().timeIntervalSince(looked[id] ?? .distantPast) > 20 else { return }
        looked[id] = Date()
        Self.io.async {
            let title = AgentFiles.claudeProcess(id)?.name ?? transcript.flatMap(AgentFiles.claudeTitle)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let a = Agents.shared
                    guard let title, let k = a.sessions.firstIndex(where: { $0.id == id }), a.sessions[k].title != title else { return }
                    a.sessions[k].title = title
                    a.changed()
                }
            }
        }
    }

    private func hold(_ q: Question) {
        questions.append(q)
        // The hook gives up after five minutes; so does the notch, a moment sooner (the terminal asks then).
        let id = q.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 290) {
            MainActor.assumeIsolated {
                let a = Agents.shared
                guard let q = a.questions.first(where: { $0.id == id }) else { return }
                a.reply(q, nil); a.drop(id); a.changed()
            }
        }
        // Answered in the terminal or cancelled there: Claude Code closes the connection.
        q.conn?.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, done, error in
            guard done || error != nil else { return }
            MainActor.assumeIsolated {
                let a = Agents.shared
                guard a.questions.contains(where: { $0.id == id }) else { return }
                a.drop(id); a.changed()
            }
        }
    }

    /// The status line's numbers (limits, model, context, lines changed, its name), and the line Claude Code shows
    /// under its prompt.
    func status(_ j: [String: Any]) -> String {
        func limit(_ k: String, _ window: TimeInterval) -> Limit? {
            guard let w = (j["rate_limits"] as? [String: Any])?[k] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return Limit(used: used, resets: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }, window: window)
        }
        let five = limit("five_hour", 5 * 3600), week = limit("seven_day", 7 * 86_400)
        if five != nil || week != nil { limits[.claude] = Limits(provider: .claude, fiveHour: five, week: week, seen: Date()) }
        let context = ((j["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue
        if let id = j["session_id"] as? String {
            let cost = j["cost"] as? [String: Any]
            let known = sessions.contains { $0.id == id }
            let named = (j["session_name"] as? String)?.nonEmpty
            upsert(id, .claude, cwd: j["cwd"] as? String, app: nil, at: sessions.first { $0.id == id }?.updated ?? Date()) { s in
                if !known { s.detail = "Ready" }
                s.context = context ?? s.context
                s.added = (cost?["total_lines_added"] as? NSNumber)?.intValue ?? s.added
                s.removed = (cost?["total_lines_removed"] as? NSNumber)?.intValue ?? s.removed
                if let named { s.title = named }
            }
            if named == nil { lookUp(id, j["transcript_path"] as? String) }
        }
        changed()
        let model = (j["model"] as? [String: Any])?["display_name"] as? String
        return [model, context.map { "context \(Int($0))%" }, five.map { "5h \(Int($0.used))%" }, week.map { "week \(Int($0.used))%" }].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Codex and the day's tokens (read off the main thread)

    private func startFiles() {
        guard filesTimer == nil else { return }
        readFiles()
        filesTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in MainActor.assumeIsolated { Agents.shared.readFiles() } }
    }

    /// Display asleep or screen locked: no reading the files until it's back, then a read at once.
    func pause(_ on: Bool) { filesTimer?.fireDate = on ? .distantFuture : Date() }

    /// Codex's threads every 4 seconds; Claude Code's tokens for the day every 30.
    func readFiles() {
        guard !reading else { return }
        reading = true
        let claude = reads % 8 == 0
        reads += 1
        Self.io.async {
            let codex = AgentFiles.shared.codex()
            let today = claude ? AgentFiles.shared.claudeToday() : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let a = Agents.shared
                    a.reading = false
                    a.apply(codex, claudeToday: today)
                }
            }
        }
    }

    private func apply(_ c: AgentFiles.Codex, claudeToday: Int?) {
        let before = (sessions, limits, tokens)
        for t in c.threads where t.parent == nil {
            upsert(t.id, .codex, cwd: t.cwd, app: t.desktop ? "com.openai.codex" : nil, at: t.updated) { s in
                s.title = t.title
                s.state = t.working ? .working : .idle
                s.detail = t.activity
                if let st = t.started { s.started = st }
                s.context = t.context
                s.subs = c.threads.filter { $0.parent == t.id }.map {
                    Sub(id: $0.id, name: $0.nickname ?? $0.title, kind: $0.role, state: $0.working ? .working : .idle, activity: $0.activity, started: $0.started ?? $0.updated)
                }
            }
        }
        if c.five != nil || c.week != nil { limits[.codex] = Limits(provider: .codex, fiveHour: c.five, week: c.week, seen: c.seen) }
        if c.today > 0 { tokens[.codex] = c.today }
        if let claudeToday, claudeToday > 0 { tokens[.claude] = claudeToday }
        if before != (sessions, limits, tokens) { changed() }
    }

    // MARK: Connecting Claude Code

    nonisolated static let settingsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Notification", "Stop", "SessionEnd",
                         "SubagentStart", "SubagentStop", "TaskCreated", "TaskCompleted"]

    static func claudeConnected(_ file: URL = settingsFile) -> Bool {
        guard let data = try? Data(contentsOf: file), let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("127.0.0.1:\(port)/claude/hook")
    }

    /// Connected before this version listened for some events (subagents, tasks): Settings offers Update.
    static func claudeOutdated(_ file: URL = settingsFile) -> Bool {
        guard claudeConnected(file), let data = try? Data(contentsOf: file),
              let hooks = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["hooks"] as? [String: Any] else { return false }
        return events.contains { "\(hooks[$0] ?? "")".contains(hookURL) == false }
    }

    /// Adds (or takes out) the hooks and, when there's none of the user's own, the status line. Everything else in
    /// the file stays; a copy of it from before the first change is kept beside it.
    static func connectClaude(_ on: Bool, file: URL = settingsFile) throws {
        let data = (try? Data(contentsOf: file)) ?? Data("{}".utf8)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        let backup = file.appendingPathExtension("money-backup")
        if FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: file, to: backup)
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let ours = { (group: Any) in (group as? [String: Any])?["hooks"].map { "\($0)".contains(hookURL) } ?? false }
        for e in events {
            var groups = (hooks[e] as? [Any] ?? []).filter { !ours($0) }
            if on {
                groups.append(["hooks": [["type": "http", "url": hookURL, "timeout": 300,
                                          "headers": ["X-Money-App": "$__CFBundleIdentifier"], "allowedEnvVars": ["__CFBundleIdentifier"]]]])
            }
            hooks[e] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        let line = (root["statusLine"] as? [String: Any])?["command"] as? String
        if on, root["statusLine"] == nil { root["statusLine"] = ["type": "command", "command": statusCommand] }
        if !on, line == statusCommand { root["statusLine"] = nil }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: file, options: .atomic)
    }

    // MARK: Helpers

    nonisolated static func respond(_ c: NWConnection, _ body: Data, type: String) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    /// The first line of some text, short.
    nonisolated static func line(_ s: String, max: Int = 120) -> String {
        let first = s.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return first.count > max ? String(first.prefix(max - 1)) + "…" : first
    }

    /// What a tool call does, in a few words: the command, or the file's name.
    static func summary(_ tool: String, _ input: [String: Any]) -> String {
        if let c = input["command"] as? String { return line(c) }
        if let p = input["file_path"] as? String ?? input["path"] as? String { return "\(tool) \((p as NSString).lastPathComponent)" }
        if let u = input["url"] as? String { return "\(tool) \(URL(string: u)?.host ?? u)" }
        if let q = input["pattern"] as? String ?? input["query"] as? String ?? input["description"] as? String { return "\(tool) \(line(q))" }
        return tool
    }

    /// What the agent is doing, as a person would say it: "Editing Island.swift", the command's own description.
    static func activity(_ tool: String, _ i: [String: Any]) -> String {
        let file = ((i["file_path"] as? String ?? i["notebook_path"] as? String ?? i["path"] as? String ?? "") as NSString).lastPathComponent
        let text: String? = switch tool {
        case "Bash": i["description"] as? String ?? (i["command"] as? String).map { "Running " + $0 }
        case "Edit", "MultiEdit", "Write", "NotebookEdit": file.isEmpty ? nil : "Editing " + file
        case "Read": file.isEmpty ? nil : "Reading " + file
        case "Grep", "Glob": (i["pattern"] as? String).map { "Searching for " + $0 }
        case "Agent", "Task": i["description"] as? String
        case "WebFetch": (i["url"] as? String).flatMap { URL(string: $0)?.host }.map { "Reading " + $0 }
        case "WebSearch": (i["query"] as? String).map { "Searching the web for " + $0 }
        case "TaskCreate", "TaskUpdate": i["activeForm"] as? String
        case "TodoWrite": (i["todos"] as? [[String: Any]])?.first { $0["status"] as? String == "in_progress" }?["activeForm"] as? String
        case "ExitPlanMode": "Finishing the plan"
        default: nil
        }
        return line(text ?? summary(tool, i), max: 90)
    }

    /// An edit's lines: only the ones that change (what both versions share at the start and end is left out).
    static func diff(_ tool: String, _ i: [String: Any]) -> Diff? {
        guard let path = i["file_path"] as? String else { return nil }
        let pairs: [(String, String)] = switch tool {
        case "Edit": [(i["old_string"] as? String ?? "", i["new_string"] as? String ?? "")]
        case "MultiEdit": (i["edits"] as? [[String: Any]] ?? []).map { ($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "") }
        case "Write": [("", i["content"] as? String ?? "")]
        default: []
        }
        guard !pairs.isEmpty else { return nil }
        var removed: [String] = [], added: [String] = []
        for (old, new) in pairs {
            var a = old.isEmpty ? [] : old.components(separatedBy: "\n"), b = new.isEmpty ? [] : new.components(separatedBy: "\n")
            while let x = a.first, x == b.first { a.removeFirst(); b.removeFirst() }
            while let x = a.last, x == b.last { a.removeLast(); b.removeLast() }
            removed += a; added += b
        }
        return Diff(file: (path as NSString).lastPathComponent, removed: removed, added: added)
    }

    /// `--agents-demo`, `--agents <kind>`: made-up sessions, limits and (with a kind) something asked. Kinds: `question`,
    /// `options` (five), `long`, `permission`, `diff`, `plan`, `many` (eight sessions), `claude` (only Claude's stats), `none` (limits but no sessions).
    func useDemo(_ ask: String?) {
        let t = Date()
        let notch = Session(id: "a", provider: .claude, project: "notch-app", state: ask == nil || ask == "many" || ask == "claude" ? .working : .needsYou,
                            detail: "Editing AgentsViews.swift", started: t.addingTimeInterval(-252), updated: t, app: "com.mitchellh.ghostty",
                            title: "Agents view in the notch", todo: Todo(done: 3, total: 7, current: "Drawing the stats column"), context: 42, added: 120, removed: 8,
                            subs: [Sub(id: "a1", name: "Survey the hook payloads", kind: "Explore", state: .working, activity: "Reading hooks.md", started: t.addingTimeInterval(-40)),
                                   Sub(id: "a2", name: "Check the render sizes", kind: "general-purpose", state: .idle, activity: "All six states fit", started: t.addingTimeInterval(-200))])
        sessions = [
            notch,
            Session(id: "b", provider: .codex, project: "photo-board", state: .working, detail: "Checking image sizes on the index page", started: t.addingTimeInterval(-61),
                    updated: t.addingTimeInterval(-5), app: "com.openai.codex", title: "Bilingual gallery pages", context: 18,
                    subs: [Sub(id: "b1", name: "Hooke", kind: "page layout", state: .working, activity: "Running the image test", started: t.addingTimeInterval(-30))]),
            Session(id: "c", provider: .claude, project: "habit-log", state: .idle, detail: "Fixed the score chart's last week", started: t.addingTimeInterval(-900),
                    updated: t.addingTimeInterval(-240), title: "Score chart fix", context: 63, added: 14, removed: 3),
        ]
        if ask == "many" {
            sessions += [
                Session(id: "d", provider: .claude, project: "recipe-box", state: .working, detail: "Searching for parseIngredients", started: t.addingTimeInterval(-75), updated: t.addingTimeInterval(-2),
                        title: "Move the ingredient parser into its own module and keep the old import working for the share sheet", context: 71, added: 210, removed: 96),
                Session(id: "e", provider: .codex, project: "weather-cli", state: .idle, detail: "Done", started: t.addingTimeInterval(-500), updated: t.addingTimeInterval(-420), title: "Hourly forecast flag"),
                Session(id: "f", provider: .claude, project: "photo-sorter", state: .working, detail: "Running the import tests", started: t.addingTimeInterval(-1300), updated: t.addingTimeInterval(-9),
                        title: "Duplicate detection", todo: Todo(done: 5, total: 6, current: "Running the import tests"), context: 88, added: 40, removed: 12),
                Session(id: "g", provider: .claude, project: "blog", state: .idle, detail: "Published the draft list page", started: t.addingTimeInterval(-800), updated: t.addingTimeInterval(-600), context: 22, added: 6),
                Session(id: "h", provider: .codex, project: "budget-sheet", state: .working, detail: "Reading totals.ts", started: t.addingTimeInterval(-15), updated: t, title: "Monthly totals"),
            ]
        }
        expanded = ["a"]
        limits[.claude] = Limits(provider: .claude, fiveHour: Limit(used: 38, resets: t.addingTimeInterval(7_400), window: 5 * 3600),
                                 week: Limit(used: 81, resets: t.addingTimeInterval(200_000), window: 7 * 86_400), seen: t)
        tokens[.claude] = 1_284_000
        if ask != "claude" {
            limits[.codex] = Limits(provider: .codex, fiveHour: Limit(used: 64, resets: t.addingTimeInterval(9_000), window: 5 * 3600),
                                    week: Limit(used: 12, resets: t.addingTimeInterval(500_000), window: 7 * 86_400), seen: t.addingTimeInterval(-60))
            tokens[.codex] = 342_000
        } else {
            sessions.removeAll { $0.provider == .codex }
        }
        func question(_ text: String, _ options: [Option], multi: Bool = false) {
            questions = [Question(session: "a", project: notch.name, asks: [Ask(question: text, options: options, multi: multi)], permission: nil, input: [:], conn: nil)]
        }
        switch ask {
        case "long":
            question("The settings window and the open notch both list the agents now. Should the notch keep its own short list of the three most recent sessions, or show every session with a scroll, the way the search bar does, so nothing is ever hidden?",
                     [Option(label: "Three recent", detail: "Older ones stay in the search bar"), Option(label: "Every session", detail: "The list scrolls past six"), Option(label: "Ask me later", detail: "")])
        case "question":
            question("Where should the agents button go in the open notch?", [Option(label: "Beside settings", detail: ""), Option(label: "Left of the notch", detail: "")])
        case "options":
            question("Which states should the demo cover?", ["Questions", "Permissions", "Plans", "Subagents", "Limits"].map { Option(label: $0, detail: "") }, multi: true)
            picks = ["Questions", "Plans"]
        case "permission":
            var q = Question(session: "a", project: notch.name, asks: [], permission: ("Bash", "./scripts/build.sh"), input: ["command": "./scripts/build.sh", "description": "Build the app"], conn: nil)
            q.suggestions = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "./scripts/build.sh"]], "behavior": "allow", "destination": "localSettings"]]
            questions = [q]
        case "diff":
            let input: [String: Any] = ["file_path": "/tmp/notch-app/Sources/AgentsViews.swift",
                                        "old_string": "struct Row: View {\n    let s: Session\n    var body: some View { Text(s.project) }\n}",
                                        "new_string": "struct Row: View {\n    let s: Session\n    var body: some View {\n        Text(s.name).lineLimit(2)\n        Text(s.detail).foregroundStyle(.secondary)\n    }\n}"]
            var q = Question(session: "a", project: notch.name, asks: [], permission: ("Edit", Self.summary("Edit", input)), input: input, conn: nil)
            q.diff = Self.diff("Edit", input)
            q.suggestions = [["type": "setMode", "mode": "acceptEdits", "destination": "session"]]
            questions = [q]
        case "plan":
            var q = Question(session: "a", project: notch.name, asks: [], permission: ("ExitPlanMode", "ExitPlanMode"), input: [:], conn: nil)
            q.plan = "## Agents view\n1. Sessions on the left, two lines each: the title, then what it is doing now.\n2. Each provider's limits in its own block on the right, with the pace and when it runs out.\n3. Subagents fold out under their session.\n4. Questions put the answers in a column on the right.\n5. Render every state off screen and check nothing is cut off."
            questions = [q]
        case "none": sessions = []
        default: break
        }
        changed()
    }
}

extension Agents.State {
    var rank: Int { switch self { case .needsYou: 0; case .working: 1; case .idle: 2 } }
}

extension Agents.Provider {
    var color: Color { self == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.55, green: 0.65, blue: 1) }
    var short: String { self == .claude ? "Claude" : "Codex" }
}

extension Agents.Session {
    /// The todo count from Claude Code's tasks, once it has some.
    mutating func retally() {
        guard !tasks.isEmpty else { return }
        todo = Agents.Todo(done: tasks.values.filter { $0 }.count, total: tasks.count, current: todo?.current ?? "")
    }
}

extension Agents.Limit {
    /// How far through its window it is (0 to 1), when the reset time is known.
    func elapsed(_ now: Date) -> Double? { resets.map { min(1, max(0, 1 - $0.timeIntervalSince(now) / window)) } }

    /// When it runs out if use keeps its pace so far; nil when it lasts to the reset (or there's too little to tell).
    func runsOut(_ now: Date) -> Date? {
        guard let resets, let f = elapsed(now), f > 0.02, used > 0 else { return nil }
        if used >= 100 { return now }
        let out = now.addingTimeInterval((100 - used) / (used / (f * window)))
        return out < resets ? out : nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
