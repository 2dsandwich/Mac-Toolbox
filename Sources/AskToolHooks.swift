import AppKit
import SwiftUI

/// Off-screen checks for Ask's own tools (AskTools.swift), on made-up data only: no real tasks, timers, alarms,
/// calendar, clipboard, meetings, location prompt or settings change.
/// `--ask-tools-test`: every tool once, a source switched off, then the tool loop with canned model answers.
/// `--ask-tools-snapshot <dir>`: the status line on a tool, and the receipts with Undo (status.png, receipts.png,
/// event-receipts.png).
/// `--ask-tools-live "question"`: one real question; prints only the tools it called and whether it answered.
extension AppDelegate {
    func runAskToolsHook(_ args: [String]) -> Bool {
        if args.contains("--ask-tools-test") {
            askToolsDemoWorld()
            Task { await askToolsTest(); exit(0) }
            return true
        }
        if let i = args.firstIndex(of: "--ask-tools-snapshot"), i + 1 < args.count {
            askToolsDemoWorld()
            askToolsSnapshots(dir: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--ask-tools-live"), i + 1 < args.count {
            askToolsDemoWorld()
            Task { await askToolsLive(args[i + 1]); exit(0) }
            return true
        }
        return false
    }

    private func askToolsDemoWorld() {
        island.onStage = nil
        AskTools.sandbox = true
        AskSource.testSources = Dictionary(uniqueKeysWithValues: AskSource.allCases.map { ($0.rawValue, true) })
        Location.shared.useFake(.init(lat: 35.6580, lon: 139.7016, city: "Tokyo", area: "Shibuya", region: "Tokyo", country: "Japan",
                                      countryCode: "JP", zone: TimeZone(identifier: "Asia/Tokyo")))
        CalendarEvents.shared.useDemo(CalendarEvents.demoEvents())
        Google.shared.useDemo(signedIn: true)
        GoogleTasks.shared.useDemo()
        MeetingDoc.folderOverride = MeetingDoc.demoFolder()
        NoteBoard.shared.persist = false
        NoteBoard.shared.notes = [StickyNote(text: "Call the venue about the 12th"), StickyNote(text: "Wi-Fi at the venue: ZeppGuest")]
        let n = NowPlaying.shared
        n.frozen = true
        n.title = "Blinding Lights"
        n.artist = "The Weeknd"
        n.album = "After Hours"
        n.appID = "com.apple.Music"
        n.playing = true
        n.duration = 200
        n.position = 64
        n.updated = Date()
        AskTools.fakeClips = [
            Clip(kind: .text, text: "Ben Ito 090-1234-5678", hash: "1", sourceName: "Messages"),
            Clip(kind: .text, text: "export OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx1234", hash: "2", sourceName: "Terminal"),
            Clip(kind: .text, text: "Zepp Shinjuku, 1-29-1 Kabukicho", hash: "3", sourceName: "Safari"),
        ]
    }

    private func askToolsTest() async {
        let tools = AskTools.shared
        let turn = UUID()
        let day = AskTools.show(Date(), time: false).split(separator: " ").last.map(String.init) ?? ""
        let tomorrow = AskTools.show(Date().addingTimeInterval(86_400), time: false).split(separator: " ").last.map(String.init) ?? ""
        let calls: [(String, [String: Any])] = [
            ("get_location", [:]),
            ("calendar_events", ["from": day, "to": tomorrow]),
            ("calendar_events", ["from": day, "to": day, "query": "design"]),
            ("tasks_list", ["list": "Festival"]),
            ("add_task", ["title": "Call Ben about the stage", "due": tomorrow, "list": "My Tasks"]),
            ("add_task", ["title": "Nowhere", "list": "No such list"]),
            ("add_event", ["title": "Lunch with Aki", "start": tomorrow + "T12:30", "minutes": 90]),
            ("add_event", ["title": "No time", "start": tomorrow]),
            ("complete_task", ["id": "t3"]),
            ("create_timer", ["minutes": 10, "label": "Tea"]),
            ("set_alarm", ["time": "07:30", "label": "Wake up", "repeat": "weekdays"]),
            ("now_playing", [:]),
            ("search_clipboard", ["query": "ben"]),
            ("search_clipboard", ["query": "export"]),
            ("search_meetings", ["query": "venue"]),
            ("meeting_notes", ["id": "../../etc/passwd"]),
            ("search_notes", ["query": "venue"]),
            ("system_status", [:]),
            ("open", ["url": "https://example.com"]),
            ("open", ["url": "file:///etc/passwd"]),
        ]
        for (k, (name, input)) in calls.enumerated() {
            let r = await tools.run([["type": "tool_use", "id": "t\(k)", "name": name, "input": input]], turn: turn).first ?? [:]
            let text = (r["content"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            print(r["is_error"] as? Bool == true ? "ERR" : "ok ", name, "→", String(text.prefix(220)))
        }
        if let id = (try? JSONSerialization.jsonObject(with: Data(((await tools.run([["type": "tool_use", "id": "m", "name": "search_meetings", "input": [:]]], turn: turn))
            .first?["content"] as? String ?? "").utf8)) as? [[String: Any]])?.first?["id"] as? String {
            let r = await tools.run([["type": "tool_use", "id": "m2", "name": "meeting_notes", "input": ["id": id]]], turn: turn).first ?? [:]
            print(r["is_error"] as? Bool == true ? "ERR" : "ok ", "meeting_notes", "→", String((r["content"] as? String ?? "").replacingOccurrences(of: "\n", with: " ").prefix(220)))
        }
        print("receipts:", tools.receipts[turn]?.map { "\($0.title) [\($0.detail ?? "")]" } ?? [])
        let before = GoogleTasks.shared.tasks.count
        if let r = tools.receipts[turn]?.first { tools.undo(r, in: turn) }
        print("undo task: tasks", before, "→", GoogleTasks.shared.tasks.count, "undone:", tools.receipts[turn]?.first?.undone == true)

        // A source switched off: not offered, and refused if called anyway.
        AskSource.testSources?[AskSource.clipboard.rawValue] = false
        let names = AskTools.definitions(Store.shared.settings, history: []).compactMap { $0["name"] as? String }
        let refused = await tools.run([["type": "tool_use", "id": "x", "name": "search_clipboard", "input": [:]]], turn: turn).first
        print("clipboard off: offered", names.contains("search_clipboard"), "| refused", refused?["is_error"] as? Bool == true, "|", refused?["content"] ?? "")
        let kept = AskTools.definitions(Store.shared.settings, history: [["role": "assistant", "content": [["type": "tool_use", "name": "search_clipboard"]]]])
        print("still offered when the thread used it:", kept.contains { $0["name"] as? String == "search_clipboard" })
        AskSource.testSources?[AskSource.clipboard.rawValue] = true

        // The loop: tool calls go out, results come back in one user message, the answer comes last.
        guard AI.choice(.assistant, store.settings).provider == .anthropic else {
            print("loop: skipped, Ask isn't on Claude (\(AI.label(.assistant, store.settings)))")
            return
        }
        var step = 0
        Claude.canned = { messages, tools in
            defer { step += 1 }
            let last = messages.last ?? [:]
            let results = (last["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "tool_result" }
            print("  step \(step): \(messages.count) messages, \(tools.count) tools, results in last:", results.count,
                  results.map { ($0["is_error"] as? Bool == true ? "error " : "") + ($0["tool_use_id"] as? String ?? "") })
            switch step {
            case 0:
                return ([["type": "text", "text": "Let me check."],
                         ["type": "tool_use", "id": "a1", "name": "calendar_events", "input": ["from": tomorrow, "to": tomorrow]]], "tool_use")
            case 1:
                return ([["type": "tool_use", "id": "a2", "name": "add_task", "input": ["title": "Book the dentist", "due": tomorrow]],
                         ["type": "tool_use", "id": "a3", "name": "create_timer", "input": ["minutes": 3, "label": "Eggs"]]], "tool_use")
            default:
                return ([["type": "text", "text": "Added it for tomorrow, and the egg timer is running."]], "end_turn")
            }
        }
        let a = Assistant.shared
        a.reset()
        a.ask("Remind me to book the dentist tomorrow and start a 3 minute egg timer")
        while a.busy { try? await Task.sleep(for: .milliseconds(50)) }
        let t = a.turns.last
        print("loop answer:", t?.failed == true ? "FAILED" : "ok", "|", t?.answer ?? "", "| receipts:", t.map { tools.receipts[$0.id]?.count ?? 0 } ?? 0)
        step = 2
        a.ask("Thanks")
        while a.busy { try? await Task.sleep(for: .milliseconds(50)) }
        print("follow-up:", a.turns.last?.failed == true ? "FAILED" : "ok", a.turns.last?.answer ?? "")
        Claude.canned = nil
    }

    private func askToolsSnapshots(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let a = Assistant.shared
        a.reset()
        a.turns = [Assistant.Turn(question: "What’s on tomorrow?", status: .using("Checking your calendar", "calendar"))]
        a.busy = true
        launcher.snapshot(scope: .assistant, query: "", dark: true, to: dir + "/status.png")

        a.reset()
        let t = Assistant.Turn(question: "Remind me to call Ben about the stage tomorrow, set a 10 minute tea timer and wake me at 7:30 on weekdays",
                               answer: "Done: the task is due tomorrow, the tea timer is running and the alarm rings at 7:30 on weekdays.")
        a.turns = [t]
        AskTools.shared.demoReceipts([
            AskReceipt(symbol: "checklist", color: .systemBlue, title: "Call Ben about the stage", detail: "Added to My Tasks · due Fri, Nov 6") {},
            AskReceipt(symbol: "timer", color: .systemOrange, title: "Tea", detail: "Timer started · 10 min") {},
            AskReceipt(symbol: "alarm.fill", color: .systemOrange, title: "Wake up", detail: "Alarm set · 7:30 AM · Weekdays", undo: {}, undone: true),
        ], turn: t.id)
        launcher.snapshot(scope: .assistant, query: "", dark: true, to: dir + "/receipts.png")

        // Events added through the real tool (into the made-up calendar), a long title among them.
        a.reset()
        let ev = Assistant.Turn(question: "Put lunch with Aki on Friday at 12:30 for an hour and a half, and the planning offsite on Monday at 10",
                                answer: "Both are in your Work calendar.")
        a.turns = [ev]
        let day = { (w: String) in AskTools.show(QuickAdd.parse(w).day ?? Date(), time: false).split(separator: " ").last.map(String.init) ?? "" }
        var added = false
        Task {
            _ = await AskTools.shared.run([
                ["type": "tool_use", "id": "e1", "name": "add_event", "input": ["title": "Lunch with Aki", "start": day("fri") + "T12:30", "minutes": 90]],
                ["type": "tool_use", "id": "e2", "name": "add_event",
                 "input": ["title": "Quarterly planning offsite with the festival sponsors and the venue team", "start": day("mon") + "T10:00", "minutes": 240]],
            ], turn: ev.id)
            added = true
        }
        while !added { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        launcher.snapshot(scope: .assistant, query: "", dark: true, to: dir + "/event-receipts.png")

        // The Settings section on its own (it sits below the models in Settings › AI). Switches as saved.
        AskSource.testSources = nil
        let hv = NSHostingView(rootView: Form { AskSourcesSection(store: store) }.formStyle(.grouped).frame(width: 560, height: 520))
        let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 560, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) {
            hv.cacheDisplay(in: hv.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/settings.png"))
        }
        print("wrote", dir + "/status.png", dir + "/receipts.png", dir + "/event-receipts.png", dir + "/settings.png")
    }

    /// One real question on the user's Ask model, against the made-up data. Prints tool names and success only.
    private func askToolsLive(_ q: String) async {
        let a = Assistant.shared
        a.reset()
        let start = Date()
        a.ask(q)
        let before = AskTools.shared.calls.count
        while a.busy { try? await Task.sleep(for: .milliseconds(50)) }
        let seen = Array(AskTools.shared.calls.dropFirst(before))
        let t = a.turns.last
        let receipts = t.map { AskTools.shared.receipts[$0.id]?.map(\.detail) ?? [] } ?? []
        print("[\(AI.label(.assistant, store.settings))]", String(format: "%.1fs", Date().timeIntervalSince(start)),
              "| tools:", seen, "| receipts:", receipts.compactMap { $0 }, "|", t?.failed == true ? "FAILED: \(t?.answer ?? "")" : "answered (\(t?.answer.count ?? 0) chars)")
    }
}
