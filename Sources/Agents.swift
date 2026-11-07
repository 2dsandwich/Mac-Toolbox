import AppKit
import Network
import Observation
import SwiftUI

// Coding agents in the notch and the search bar: what each session is doing, the question one asks with its options as
// buttons, and the provider's 5-hour and weekly limits. Claude Code reports through HTTP hooks and its status line to
// 127.0.0.1 (Settings › Notch connects them); Codex through the session logs it writes anyway.

@MainActor @Observable final class Agents {
    static let shared = Agents()
    static let port: UInt16 = 47474
    static let hookURL = "http://127.0.0.1:\(port)/claude/hook"
    static let statusCommand = "curl -s -m 1 --data-binary @- http://127.0.0.1:\(port)/claude/status"

    enum Provider: String { case claude = "Claude Code", codex = "Codex" }
    enum State { case working, needsYou, idle }
    struct Session: Identifiable, Equatable {
        let id: String
        var provider: Provider
        var project: String
        var state: State
        /// The prompt it's on, what it's doing, or how it finished.
        var detail: String
        /// When the current turn started.
        var started: Date
        var updated: Date
        /// The app it runs in (Ghostty, an editor…), to bring to the front.
        var app: String?
    }
    struct Limit: Equatable { var used: Double; var resets: Date? }
    struct Limits: Equatable { var provider: Provider; var fiveHour: Limit?; var week: Limit?; var seen: Date }
    struct Ask { let question: String; let options: [String]; let multi: Bool }
    struct Question: Identifiable {
        let id = UUID()
        let session: String
        let project: String
        let asks: [Ask]
        /// A permission prompt: the tool and what it would do.
        let permission: (tool: String, summary: String)?
        /// The tool's input, echoed back with the answers.
        let input: [String: Any]
        let conn: NWConnection?
    }

    private(set) var sessions: [Session] = []
    private(set) var limits: [Provider: Limits] = [:]
    private(set) var questions: [Question] = []
    /// The front question's answers so far (multi-part questions go one at a time) and a multi-select's picks.
    var step = 0
    var answers: [String: String] = [:]
    var picks: Set<String> = []
    /// Ticks once a second while something is working (for the elapsed times).
    private(set) var now = Date()

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var codexTimer: Timer?
    @ObservationIgnored private var codexSeen: [String: (mtime: Date, cwd: String, app: String?)] = [:]

    /// Sessions worth showing: working or waiting on you, and ones that finished in the last 15 minutes.
    var visible: [Session] {
        sessions.filter { $0.state != .idle || now.timeIntervalSince($0.updated) < 900 }
            .sorted { ($0.state.rank, $1.updated) < ($1.state.rank, $0.updated) }
    }
    var live: [Session] { sessions.filter { $0.state != .idle } }
    var asking: Bool { !questions.isEmpty }
    /// In the closed notch only when an agent needs you (working sessions wait behind the agents button).
    var showsInNotch: Bool { asking || sessions.contains { $0.state == .needsYou } }
    /// Whose input is needed.
    var needy: String { questions.first?.project ?? sessions.first { $0.state == .needsYou }?.project ?? "" }
    /// Anything ever heard from (the notch's agents button shows then).
    var known: Bool { !sessions.isEmpty || !limits.isEmpty }
    /// The limits to show: the provider used last.
    var frontLimits: Limits? {
        if let p = sessions.max(by: { $0.updated < $1.updated })?.provider, let l = limits[p] { return l }
        return limits.values.max { $0.seen < $1.seen }
    }

    func run(_ on: Bool) {
        if on { startServer(); startCodex() } else {
            listener?.cancel(); listener = nil
            codexTimer?.invalidate(); codexTimer = nil
            for q in questions { reply(q, nil) }
            questions = []; sessions = []; limits = [:]
            changed()
        }
    }

    private func changed() {
        let working = sessions.contains { $0.state == .working }
        if working, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { Agents.shared.now = Date() } }
        } else if !working { ticker?.invalidate(); ticker = nil }
        now = Date()
        onChange?()
    }

    private func upsert(_ id: String, _ provider: Provider, cwd: String?, app: String?, _ edit: (inout Session) -> Void) {
        let t = Date()
        var s = sessions.first { $0.id == id }
            ?? Session(id: id, provider: provider, project: "", state: .idle, detail: "", started: t, updated: t)
        if let cwd, !cwd.isEmpty { s.project = (cwd as NSString).lastPathComponent }
        if let app, !app.isEmpty { s.app = app }
        let was = s.state
        edit(&s)
        s.updated = t
        if s.state == .working, was != .working { s.started = t }
        if let k = sessions.firstIndex(where: { $0.id == id }) { sessions[k] = s } else { sessions.append(s) }
    }

    /// Terminals and editors (and any app a session reported from): hovering the notch over one opens the agents view.
    static let codingApps: Set<String> = ["com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
                                          "io.alacritty", "com.github.wez.wezterm", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
                                          "dev.zed.Zed", "com.apple.dt.Xcode", "com.openai.codex"]
    var codingInFront: Bool {
        guard known, let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.codingApps.contains(id) || sessions.contains { $0.app == id }
    }

    /// Brings the session's app to the front.
    func open(_ s: Session) {
        guard let id = s.app, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        app.activate()
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
        answers[ask.question] = ask.options.filter(picks.contains).joined(separator: ", ")
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

    func allow(_ ok: Bool) {
        guard let q = questions.first else { return }
        send(q, ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                        "decision": ok ? ["behavior": "allow"] : ["behavior": "deny", "message": "Declined from the notch."]]])
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
        func set(_ state: State, _ detail: String? = nil) {
            upsert(id, .claude, cwd: cwd, app: app) { s in
                s.state = state
                if let detail { s.detail = detail }
            }
        }
        switch event {
        case "SessionStart": set(.idle, "Ready")
        case "UserPromptSubmit": set(.working, Self.line(j["prompt"] as? String ?? ""))
        case "PreToolUse" where tool == "AskUserQuestion":
            let asks = (input["questions"] as? [[String: Any]] ?? []).compactMap { q -> Ask? in
                guard let text = q["question"] as? String else { return nil }
                let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                return Ask(question: text, options: options, multi: q["multiSelect"] as? Bool ?? false)
            }
            guard !asks.isEmpty else { return false }
            set(.needsYou, asks[0].question)
            hold(Question(session: id, project: project(id), asks: asks, permission: nil, input: input, conn: c))
            return c != nil
        case "PermissionRequest":
            set(.needsYou, "Wants to use \(tool)")
            hold(Question(session: id, project: project(id), asks: [], permission: (tool, Self.summary(tool, input)), input: input, conn: c))
            return c != nil
        case "PreToolUse": set(.working, Self.summary(tool, input))
        case "PostToolUse": set(.working)
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

    private func project(_ id: String) -> String { sessions.first { $0.id == id }?.project ?? "" }

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

    /// The status line's numbers (limits, model, context), and the line Claude Code shows under its prompt.
    func status(_ j: [String: Any]) -> String {
        func limit(_ k: String) -> Limit? {
            guard let w = (j["rate_limits"] as? [String: Any])?[k] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return Limit(used: used, resets: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        let five = limit("five_hour"), week = limit("seven_day")
        if five != nil || week != nil { limits[.claude] = Limits(provider: .claude, fiveHour: five, week: week, seen: Date()) }
        if let id = j["session_id"] as? String, sessions.contains(where: { $0.id == id }) == false {
            upsert(id, .claude, cwd: j["cwd"] as? String, app: nil) { $0.detail = "Ready" }
        }
        changed()
        let model = (j["model"] as? [String: Any])?["display_name"] as? String
        let context = ((j["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber).map { "context \($0.intValue)%" }
        return [model, context, five.map { "5h \(Int($0.used))%" }, week.map { "week \(Int($0.used))%" }].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Codex (its session logs)

    private func startCodex() {
        guard codexTimer == nil else { return }
        readCodex()
        codexTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in MainActor.assumeIsolated { Agents.shared.readCodex() } }
    }

    /// Today's and yesterday's logs touched in the last half hour: the last turn started or finished, and the limits.
    func readCodex(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")) {
        let fm = FileManager.default, day = DateFormatter()
        day.dateFormat = "yyyy/MM/dd"
        var touched = false
        for d in [Date(), Date().addingTimeInterval(-86_400)] {
            let dir = root.appendingPathComponent(day.string(from: d))
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
                guard let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      Date().timeIntervalSince(m) < 1800, codexSeen[f.path]?.mtime != m else { continue }
                touched = true
                codexFile(f, mtime: m)
            }
        }
        if touched { changed() }
    }

    private func codexFile(_ f: URL, mtime: Date) {
        guard let h = try? FileHandle(forReadingFrom: f) else { return }
        defer { try? h.close() }
        var meta = codexSeen[f.path].map { ($0.cwd, $0.app) }
        if meta == nil, let first = try? h.read(upToCount: 65_536).flatMap({ String(decoding: $0, as: UTF8.self).split(separator: "\n").first }),
           let p = (Self.json(first)?["payload"] as? [String: Any]) {
            let desktop = (p["originator"] as? String ?? "").contains("desktop")
            meta = (p["cwd"] as? String ?? "", desktop ? "com.openai.codex" : nil)
        }
        guard let (cwd, app) = meta else { return }
        codexSeen[f.path] = (mtime, cwd, app)
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let lines = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self).split(separator: "\n")
        let id = f.deletingPathExtension().lastPathComponent
        for line in lines {
            guard let p = Self.json(line)?["payload"] as? [String: Any] else { continue }
            switch p["type"] as? String {
            case "task_started": upsert(id, .codex, cwd: cwd, app: app) { $0.state = .working; $0.detail = "Working" }
            case "task_complete":
                upsert(id, .codex, cwd: cwd, app: app) { $0.state = .idle; $0.detail = Self.line(p["last_agent_message"] as? String ?? "").nonEmpty ?? "Done" }
            case "token_count":
                guard let r = p["rate_limits"] as? [String: Any] else { continue }
                func limit(_ k: String) -> Limit? {
                    guard let w = r[k] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                    return Limit(used: used, resets: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
                }
                limits[.codex] = Limits(provider: .codex, fiveHour: limit("primary"), week: limit("secondary"), seen: mtime)
            default: continue
            }
        }
        // A session's logs keep their dates: a stale "working" (it crashed or was closed) settles after half an hour.
        if Date().timeIntervalSince(mtime) > 1700, let k = sessions.firstIndex(where: { $0.id == id && $0.state == .working }) { sessions[k].state = .idle }
    }

    // MARK: Connecting Claude Code

    nonisolated static let settingsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    static func claudeConnected(_ file: URL = settingsFile) -> Bool {
        guard let data = try? Data(contentsOf: file), let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("127.0.0.1:\(port)/claude/hook")
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

    private static func json(_ s: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    /// The first line of some text, short.
    static func line(_ s: String) -> String {
        let first = s.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return first.count > 120 ? String(first.prefix(119)) + "…" : first
    }

    /// What a tool call does, in a few words: the command, or the file's name.
    static func summary(_ tool: String, _ input: [String: Any]) -> String {
        if let c = input["command"] as? String { return line(c) }
        if let p = input["file_path"] as? String ?? input["path"] as? String { return "\(tool) \((p as NSString).lastPathComponent)" }
        if let u = input["url"] as? String { return "\(tool) \(URL(string: u)?.host ?? u)" }
        if let q = input["pattern"] as? String ?? input["query"] as? String ?? input["description"] as? String { return "\(tool) \(line(q))" }
        return tool
    }

    /// `--agents-demo`: made-up sessions, limits and (with `question`/`permission`) something asked.
    func useDemo(_ ask: String?) {
        let t = Date()
        sessions = [
            Session(id: "a", provider: .claude, project: "notch-app", state: ask == nil ? .working : .needsYou, detail: "Add a coding agents face to the notch",
                    started: t.addingTimeInterval(-252), updated: t, app: "com.mitchellh.ghostty"),
            Session(id: "b", provider: .codex, project: "gallery-site", state: .working, detail: "Working", started: t.addingTimeInterval(-61), updated: t.addingTimeInterval(-5)),
            Session(id: "c", provider: .claude, project: "study-tracker", state: .idle, detail: "Fixed the score chart's last week", started: t.addingTimeInterval(-900), updated: t.addingTimeInterval(-240)),
        ]
        limits[.claude] = Limits(provider: .claude, fiveHour: Limit(used: 38, resets: t.addingTimeInterval(7_400)), week: Limit(used: 81, resets: t.addingTimeInterval(200_000)), seen: t)
        limits[.codex] = Limits(provider: .codex, fiveHour: Limit(used: 3, resets: nil), week: Limit(used: 12, resets: nil), seen: t.addingTimeInterval(-60))
        if ask == "question" {
            questions = [Question(session: "a", project: "notch-app", asks: [Ask(question: "Where should the agents button go in the open notch?", options: ["Beside settings", "Left of the notch", "In the idle home"], multi: false)],
                                  permission: nil, input: [:], conn: nil)]
        } else if ask == "permission" {
            questions = [Question(session: "a", project: "notch-app", asks: [], permission: ("Bash", "./scripts/build.sh --install"), input: [:], conn: nil)]
        }
        changed()
    }
}

extension Agents.State {
    var rank: Int { switch self { case .needsYou: 0; case .working: 1; case .idle: 2 } }
}

extension Agents.Provider {
    var color: Color { self == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.55, green: 0.65, blue: 1) }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: Views (the notch and the search bar share them)

/// The 5-hour and weekly limits as two short bars, white, orange from 75%, red from 90%.
struct AgentLimitGauges: View {
    let limits: Agents.Limits

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let l = limits.fiveHour { row("5h", l) }
            if let l = limits.week { row("Wk", l) }
        }
        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
        .help(limits.provider.rawValue)
    }

    private func row(_ label: String, _ l: Agents.Limit) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.white.opacity(0.55)).frame(width: 16, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(Self.color(l.used)).frame(width: max(3, 36 * min(100, l.used) / 100))
            }
            .frame(width: 36, height: 4)
            Text("\(Int(l.used.rounded()))%").foregroundStyle(.white).frame(width: 28, alignment: .trailing)
        }
        .help(l.resets.map { "Resets \($0.formatted(.relative(presentation: .named)))" } ?? "")
    }

    static let width: CGFloat = 16 + 5 + 36 + 5 + 28
    static func color(_ used: Double) -> Color { used >= 90 ? .red : used >= 75 ? .orange : .white }
}

/// What a session is doing: a spinner while it works, orange when it waits on you, a tick when it's done.
struct AgentStateIcon: View {
    let state: Agents.State
    var size: CGFloat = 14

    var body: some View {
        switch state {
        case .working: PolishSpinner(size: size, line: 2)
        case .needsYou: Image(systemName: "questionmark.bubble.fill").font(.system(size: size * 0.9, weight: .semibold)).foregroundStyle(.orange)
        case .idle: Image(systemName: "checkmark.circle.fill").font(.system(size: size * 0.9, weight: .semibold)).foregroundStyle(.green)
        }
    }
}

/// The open notch's face (and the search bar's): the question being asked, or the sessions.
struct AgentsFace: View {
    var agents = Agents.shared
    var rows = 3
    var asks = true

    var body: some View {
        if asks, let q = agents.questions.first { question(q) } else { list }
    }

    private var list: some View {
        let shown = Array(agents.visible.prefix(rows))
        return VStack(alignment: .leading, spacing: 4) {
            if shown.isEmpty {
                Text("No coding sessions").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(shown) { s in
                Button { agents.open(s) } label: { row(s) }.buttonStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ s: Agents.Session) -> some View {
        HStack(spacing: 10) {
            AgentStateIcon(state: s.state).frame(width: 18)
            Text(s.project).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1).layoutPriority(1)
            Text(s.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            Spacer(minLength: 0)
            Text(s.state == .working ? Pomodoro.clock(agents.now.timeIntervalSince(s.started)) : s.updated.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
        }
        .frame(height: 26)
        .contentShape(Rectangle())
    }

    private func question(_ q: Agents.Question) -> some View {
        let ask = agents.step < q.asks.count ? q.asks[agents.step] : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AgentStateIcon(state: .needsYou, size: 13)
                Text(q.project + (q.permission == nil ? " asks" : " wants to use \(q.permission!.tool)"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                Spacer(minLength: 0)
                if q.asks.count > 1 { Text("\(agents.step + 1) of \(q.asks.count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.5)) }
            }
            .lineLimit(1)
            Group {
                if let p = q.permission { Text(p.summary).font(.system(size: 13, design: .monospaced)) } else { Text(ask?.question ?? "").font(.system(size: 13.5, weight: .medium)) }
            }
            .foregroundStyle(.white).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if q.permission != nil {
                        chip("Allow", tint: .green) { agents.allow(true) }
                        chip("Deny") { agents.allow(false) }
                    } else if let ask {
                        ForEach(ask.options, id: \.self) { o in
                            chip(o, symbol: ask.multi ? (agents.picks.contains(o) ? "checkmark.circle.fill" : "circle") : nil) { agents.choose(o) }
                        }
                        if ask.multi { chip("Done", tint: .green) { agents.confirm() }.disabled(agents.picks.isEmpty) }
                    }
                }
            }
            RoundButton(symbol: "terminal", tint: nil, size: 28) { agents.toTerminal() }.help("Answer in the terminal")
            }
        }
    }

    private func chip(_ title: String, symbol: String? = nil, tint: Color? = nil, dim: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(tint ?? .white.opacity(dim ? 0.6 : 1))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(tint.map { $0.opacity(0.22) } ?? Color.white.opacity(dim ? 0.07 : 0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

/// "agents" + Tab in the search bar: each provider's limits, then the question being asked and every session.
struct AgentsPanel: View {
    let radius: CGFloat
    var agents = Agents.shared

    @MainActor static func height(_ a: Agents) -> CGFloat {
        let rows = CGFloat(max(1, min(8, a.visible.count)))
        return PanelLayout.vertical + (a.limits.isEmpty ? 0 : 64 + PanelLayout.gap) + (a.asking ? 110 + PanelLayout.gap : 0) + rows * 30 + 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.gap) {
            if !agents.limits.isEmpty {
                HStack(spacing: PanelLayout.gap) {
                    ForEach([Agents.Provider.claude, .codex], id: \.self) { p in
                        if let l = agents.limits[p] { card(l) }
                    }
                }
                .frame(height: 64)
            }
            if agents.asking {
                AgentsFace(agents: agents).padding(12).frame(height: 110).background(block)
            }
            AgentsFace(agents: agents, rows: 8, asks: false).padding(8).background(block)
        }
        .padding(PanelLayout.edges)
        .environment(\.colorScheme, .dark)
    }

    private var block: some View { RoundedRectangle(cornerRadius: PanelLayout.inner(radius), style: .continuous).fill(Color.black.opacity(0.85)) }

    private func card(_ l: Agents.Limits) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(l.provider.color).frame(width: 7, height: 7)
                Text(l.provider.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
                if let r = l.fiveHour?.resets { Text("5h resets \(r.formatted(date: .omitted, time: .shortened))").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)) }
            }
            AgentLimitGauges(limits: l)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(block)
    }
}

/// Settings › Notch: hooking Claude Code up (Codex needs nothing).
struct AgentsSettings: View {
    @Bindable var store: Store
    @State private var connected = Agents.claudeConnected()
    @State private var problem: String?

    var body: some View {
        Section {
            LabeledContent("Claude Code") {
                Button(connected ? "Disconnect" : "Connect") {
                    do {
                        try Agents.connectClaude(!connected)
                        connected = Agents.claudeConnected()
                        problem = nil
                    } catch {
                        problem = "Couldn’t change ~/.claude/settings.json: \(error.localizedDescription)"
                    }
                }
            }
            LabeledContent("Codex", value: "Read from its session logs")
            if let problem { Text(problem).foregroundStyle(.red).font(.caption) }
        } header: {
            Text("Coding agents")
        } footer: {
            Text("Connecting adds hooks (and a status line, if you don’t have one) to ~/.claude/settings.json, so sessions, their questions and your 5-hour and weekly limits show in the notch. Sessions started before connecting show after a restart.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!store.settings.notchEnabled || !store.settings.notchAgents)
    }
}
