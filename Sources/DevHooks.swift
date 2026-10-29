import AppKit
import AVFoundation
import Speech
import SwiftUI

/// Command-line switches for checking the app without using it by hand: off-screen snapshots of each view
/// (`--snapshot`, `--island-snapshot`, `--settings-snapshot`, `--menu-snapshot`) and small tests of the parts
/// that don't need a person (`--tools-test`, `--ai-test`, `--polish-test`, `--merge-file` …). See the README.
extension AppDelegate {
    /// Runs the switch it was launched with, if any; true means it handled the launch (most print and exit).
    func runDevHook(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--ocr-test"), i + 1 < args.count {
            let img = NSImage(contentsOfFile: args[i + 1])!
            let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            Task {
                let r = await ScreenText.recognize(cg, pointSize: img.size)
                print("tokens:", r.tokens.map(\.text).joined(separator: " | "))
                print("full text:\n" + r.fullText)
                if r.tokens.count > 3 { print("words 1...3:", r.text(1...3)) }
                exit(0)
            }
            return true
        }
        if args.contains("--mic-test") {
            // One second from the microphone dictation would use; nothing is kept. Prints what came in.
            let mic = MicCapture(preferBuiltIn: store.settings.builtInMicForBluetooth)
            do { try mic.start() } catch { print("mic failed:", error); exit(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                mic.stop()
                print("buffers:", mic.buffers, "peak:", String(format: "%.4f", mic.peak))
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--dictation-sim"), i + 1 < args.count {
            // Plays a file through the dictation path the way the mic does: 1024-frame chunks in real time,
            // English + Japanese side by side, analyzers starting while audio is already arriving.
            let path = args[i + 1]
            Task {
                let ts = ["en_US", "ja_JP"].map { LiveTranscriber(locale: Locale(identifier: $0)) }
                for t in ts { try? await t.prepare() }
                let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
                print("format:", file.processingFormat)
                for t in ts { Task { do { try await t.start(context: []) } catch { print("start failed", error) } } }
                while true {
                    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
                    guard (try? file.read(into: buf)) != nil, buf.frameLength > 0 else { break }
                    let copy = buf.copied()!
                    ts.forEach { $0.append(copy) }
                    try? await Task.sleep(for: .seconds(Double(buf.frameLength) / file.processingFormat.sampleRate))
                }
                for t in ts { print(t.locale.identifier, "→", await t.finish(), String(format: "(%.2f)", t.averageConfidence)) }
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--merge-file"), i + 3 < args.count {
            let path = args[i + 1], locales = Array(args[(i + 2)...]).filter { !$0.hasPrefix("-") }
            Task {
                print(await mergeFileForTest(path, locales: locales))
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--transcribe-file"), i + 2 < args.count {
            let path = args[i + 1], locale = args[i + 2]
            Task {
                print(await transcribeFileForTest(path, locale: locale))
                exit(0)
            }
            return true
        }
        if args.contains("--dictation-check") {
            // Reports everything dictation depends on, without recording.
            registerHotKeys(force: true)
            Task {
                print("hotkeys refused:", HotKeyCenter.shared.failed.isEmpty ? "none" : HotKeyCenter.shared.failed.joined(separator: ", "))
                print("dictation key:", store.settings.dictationHotKey.display, "enabled:", store.settings.dictationEnabled)
                let mic = AVCaptureDevice.authorizationStatus(for: .audio)
                print("microphone:", mic == .authorized ? "allowed" : mic == .notDetermined ? "not asked yet" : "DENIED (\(mic.rawValue))")
                print("accessibility (paste):", Paster.trusted ? "allowed" : "not allowed")
                print("claude key:", Claude.hasKey ? "saved" : "none")
                let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
                print("speech models installed:", installed.filter { $0 == "en_US" || $0 == "ja_JP" })
                let t = LiveTranscriber(locale: Locale(identifier: "en_US"))
                do { try await t.prepare(); print("en_US transcriber: ready") } catch { print("en_US transcriber: FAILED", error) }
                exit(0)
            }
            return true
        }
        if args.contains("--cloud-polish-test") {
            Task {
                let s = store.settings
                let cases: [(String, [(locale: String, text: String, confidence: Double)])] = [
                    ("so um add a button to the settings that uh resets the notch and also make it red actually don't do that keep it gray and uh yeah thats it", []),
                    ("the formatting of the polishing stage doesn't really do anything it's really bad there are many words that are not correct and there are many filler words make the polishing better it's so bad",
                     [("en_US", "the formatting of the polishing stage doesn't really do anything it's really bad there are many words that are not correct and there are many filler words make the polishing better it's so bad and it's very bad", 0.8),
                      ("ja_JP", "別 とても とにかく悪い", 0.5)]),
                ]
                for (heard, both) in cases {
                    let start = Date()
                    let said = both.isEmpty ? [("en_US", heard, 0.9)] : both
                    do {
                        let out = try await AI.complete(.dictation, system: Prompts.cleanup(s, context: .prompt),
                                                        user: Prompts.cleanupRequest(heard: said, merged: heard, app: nil, context: .prompt))
                        print("[\(AI.label(.dictation, s))]", String(format: "%.1fs", Date().timeIntervalSince(start)), "→", out.replacingOccurrences(of: "\n", with: " ⏎ "))
                    } catch { print("FAILED:", error.localizedDescription) }
                }
                exit(0)
            }
            return true
        }
        if args.contains("--polish-test") {
            Task {
                let long = "so um I don't think that the the dictation cleanup is actually working because I still see a lot of like junk and also very incoherent polished results just like how my output is right now and uh I want you to make sure that the end result feels coherent and that it's a sentence and also it's very hard to hands free dictate so fix that and also add support for bullet points and allow adding items in the same text field after dictating"
                for (text, ctx, before) in [(long, Prompts.WritingContext.prompt, nil as String?),
                                            ("number three send the invites and number four book the band", .document, "1. Book the venue\n2. Order the food"),
                                            ("bullet point milk bullet point eggs bullet point bread", .plain, nil)] {
                    let start = Date()
                    let out = await dictation.polishForTest(text, ctx, before: before)
                    print(ctx.rawValue, String(format: "%.1fs", Date().timeIntervalSince(start)), "→", out.replacingOccurrences(of: "\n", with: " ⏎ "))
                }
                exit(0)
            }
            return true
        }
        if args.contains("--format-test") {
            for t in ["so I need three things number one milk number two eggs and number three bread",
                      "um so the the plan is uh you know number one fix the notch, number two ship it new line thanks",
                      "買うものは一つ目牛乳、二つ目卵、三つ目パン", "I was number one in the race"] {
                print(Prompts.localCleanup(t, snippets: []).replacingOccurrences(of: "\n", with: " ⏎ "))
            }
            for t in ["export OPENAI_API_KEY=sk-proj-A1b2C3d4E5f6G7h8I9j0kLmNoPqRsT", "otpauth://totp/x?secret=ABC", "WIFI:S:home;T:WPA;P:hunter22;;",
                      "TOKEN=\"Zk3Qp9Lr2Xv8Bn5Mw1Ty7Hd4Gs6Jc0Fa\"", "git commit 3f9c2a7b1e4d8f6a0b2c4e6d8f0a1b3c5d7e9f1a", "550e8400-e29b-41d4-a716-446655440000",
                      "The meeting moved to 3pm, see https://example.com/agenda?id=Zk3Qp9Lr2Xv8Bn5Mw1Ty7", "hello world"] {
                print(ClipboardStore.looksSecret(t) ? "SECRET" : "keep  ", t.prefix(50))
            }
            for q in ["weather", "weather tokyo", "weather in new york", "weathering", "天気 大阪", "translate good morning", "forecast for paris"] {
                print(q, "→", LauncherController.modeWithText(q).map { "\($0.0) / \($0.1)" } ?? "no")
            }
            for (id, title) in [("com.mitchellh.ghostty", ""), ("com.google.Chrome", "Inbox - Gmail"), ("com.google.Chrome", "ChatGPT"), ("com.apple.Safari", "Apple")] {
                let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }
                print(id, title, "→", app.map { Prompts.WritingContext(.auto, app: $0, title: title).rawValue } ?? "(not running)")
            }
            exit(0)
        }
        if args.contains("--ai-test") {
            // Runs each job once on its configured model (default: Apple on-device) and prints the result.
            Task {
                let cases: [(AITask, String, String)] = [
                    (.dictation, Prompts.cleanupCompact(store.settings, context: .plain), "Input: um so I think we should uh we should meet on tuesday no wait wednesday at 3\nOutput:"),
                    (.dictation, Prompts.cleanupCompact(store.settings, context: .plain), "Input: えーと明日の会議はあの3時からに変更になりましたよろしくお願いします\nOutput:"),
                    (.dictation, Prompts.cleanupCompact(store.settings, context: .plain), "Input: あのー来週の金曜日って空いてますかもしよかったらランチ行きませんか\nOutput:"),
                    (.dictation, Prompts.cleanupCompact(store.settings, context: .plain), "Input: send the report to john by friday no actually thursday\nOutput:"),
                    (.dictation, Prompts.cleanupCompact(store.settings, context: .plain), "Input: what time is the meeting tomorrow\nOutput:"),
                    (.dictation, Prompts.cleanupCompact(store.settings, context: .prompt), "Input: um so can you like refactor the island dot swift file so that uh the notch is centered and also number one keep the animations number two remember the order\nOutput:"),
                    (.dictation, Prompts.cleanupCompact(store.settings, context: .email), "Input: hi john thanks for the update um i'll send the deck by friday best sam\nOutput:"),
                    (.translate, "You translate text into Japanese. Keep the meaning, tone and formatting, and make it sound natural rather than literal. Reply with the translation only: no quotes, notes, or romanization.", "The venue moved to Shibuya, so please arrive by 6pm."),
                    (.voiceEdit, Prompts.command, Prompts.commandRequest(selection: "hey can u send me the file asap thx", heard: [("en_US", "make this polite", 0.9)])),
                    (.meetingChat, "Answer in one to three sentences.", "Meeting transcript so far:\n\nOthers: We need the deck by Friday.\nMe: OK, I'll draft it.\n\n---\n\nMy question: what did I promise?"),
                ]
                for (task, system, user) in cases {
                    let start = Date()
                    do {
                        let out = try await AI.complete(task, system: system, user: user)
                        print(task.rawValue, "[\(AI.label(task, store.settings))]", String(format: "%.1fs", Date().timeIntervalSince(start)), "→", out.replacingOccurrences(of: "\n", with: " ⏎ "))
                    } catch {
                        print(task.rawValue, "FAILED:", error.localizedDescription)
                    }
                }
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--island-snapshot"), i + 1 < args.count {
            // Renders the notch off screen with demo activities: collapsed and expanded side by side.
            if !args.contains("--media-only") {
                Timers.shared.add(minutes: 25, label: "Tea")
                Timers.shared.add(minutes: 3)
                Stopwatches.shared.add()
            }
            if args.contains("--focus") { pomodoro.start(Pomodoro.Plan()) }
            if !args.contains("--no-media") {
                NowPlaying.shared.title = args.contains("--long") ? "Save Your Tears (Remix) [feat. Ariana Grande] - Extended Club Mix" : "Blinding Lights"
                NowPlaying.shared.artist = args.contains("--long") ? "The Weeknd & Kendrick Lamar" : "The Weeknd"
                NowPlaying.shared.playing = true
                NowPlaying.shared.duration = 200
                NowPlaying.shared.position = 80
            }
            if let j = args.firstIndex(of: "--dictation"), j + 1 < args.count {
                // Dictation as it looks while listening or polishing (with a long take, to see it scroll).
                let d = island.dictation
                d.phase = args[j + 1] == "polishing" ? .processing : .listening
                d.handsFree = args.contains("--hands-free")
                d.preview = args.contains("--long")
                    ? "So the plan for tomorrow is number one finish the notch drag and drop, number two fix the dictation paste, number three ship the build before lunch, and then we can look at the settings preview again and maybe the meeting chat too"
                    : "So the plan for tomorrow is"
                d.levels = (0..<20).map { i in Float(0.15 + 0.6 * abs(sin(Double(i) * 0.7))) }
            }
            island.refresh()
            var images: [NSBitmapImageRep] = []
            for stage in [IslandStage.compact, .expanded] {
                island.lastInteraction = .distantFuture // keep it open for the picture
                island.stage = stage
                island.contentVisible = true
                let size = island.geometry.panelSize
                let hv = NSHostingView(rootView: IslandView(model: island, openMeeting: {}).frame(width: size.width, height: size.height).background(Color(white: 0.85)))
                let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
                w.contentView = hv
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                if let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) { hv.cacheDisplay(in: hv.bounds, to: rep); images.append(rep) }
                w.orderOut(nil)
            }
            for (n, rep) in images.enumerated() {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + "-\(n).png"))
            }
            print("song:", NowPlaying.shared.songTitle, "| with:", NowPlaying.shared.artistLine)
            print("seed", island.geometry.seedSize.width, "compact", island.compactLayout.side)
            exit(0)
        }
        if args.contains("--highlight-test") {
            // Prints which words get which color.
            let m = launcher.model
            let names: [NSColor: String] = [Highlighter.when: "WHEN", Highlighter.place: "PLACE", Highlighter.note: "note", Highlighter.command: "CMD", Highlighter.op: "OP"]
            var settings = store.settings
            if settings.weatherCity.isEmpty { settings.weatherCity = "Tokyo" }
            store.settings = settings
            let cases: [(Scope, ClockMode, String)] = [
                (.apps, .focus, "10 km to mi"), (.apps, .focus, "100 usd to jpy"), (.apps, .focus, "1万円"), (.apps, .focus, "weather osaka"), (.apps, .focus, "大阪の天気"),
                (.apps, .focus, "time in london"), (.apps, .focus, "3pm pst to jst"), (.apps, .focus, "alarm 7:30 gym"), (.apps, .focus, "timer 10m tea"),
                (.apps, .focus, "days until christmas"), (.apps, .focus, "in 90 days"), (.apps, .focus, "tr hello to french"), (.apps, .focus, "15% of 4800"),
                (.apps, .focus, "safari"), (.pomodoro, .focus, "50/10 until 3pm"), (.pomodoro, .focus, "45分 休憩10分 4回"), (.pomodoro, .timer, "1h 30m pasta"),
                (.pomodoro, .alarms, "6:45am wake up"), (.calculator, .focus, "(12+3)×sqrt 4"),
            ]
            for (scope, mode, q) in cases {
                m.scope = scope
                m.clockMode = mode
                m.query = q
                m.recompute()
                let ns = q as NSString
                let parts = Highlighter.spans(q, m).sorted { $0.0.location < $1.0.location }.map { "[\(ns.substring(with: $0.0))=\(names[$0.1] ?? "?")]" }
                print(q, "→", parts.joined(separator: " "))
            }
            exit(0)
        }
        if args.contains("--tools-test") {
            // Prints the instant answers for sample queries, then again once network answers have arrived.
            let queries = args.drop { $0 != "--tools-test" }.dropFirst().filter { !$0.hasPrefix("-") }
            let list = queries.isEmpty ? ["12*8", "(1200 + 380) * 1.1", "15% of 4800", "150 + 10%", "2^10", "sqrt 2", "１＋２", "10 km to mi", "2 in cm", "72f", "5'11\"", "180 cm in ft",
                                          "3 cups to ml", "10坪", "100 usd to jpy", "1万円", "$20", "100ドルは何円", "btc", "time", "time in london", "3pm pst to jst", "tokyo",
                                          "today", "days until christmas", "in 90 days", "3日後", "令和8年", "2019年", "dec 25", "1700000000", "255 to hex", "0xff", "roman 2026",
                                          "#ff8800", "rgb(10, 20, 30)", "upper hello world", "camel hello big world", "kana 東京タワー", "romaji 大阪", "base64 hello", "sha256 hello",
                                          "char あ", "emoji fire", ":cat", "define serendipity", "password 16", "uuid", "random 1-6", "roll 2d6", "coin", "pick ramen, sushi",
                                          "lorem 8", "moon", "battery", "ip", "disk", "memory", "uptime", "cpu", "about this mac", "timer 10m tea", "タイマー 3分", "awake 1h",
                                          "volume 30", "mute", "lock", "dark mode", "eject", "weather", "weather osaka", "大阪の天気", "umbrella", "sunset", "祝日", "tr hello",
                                          "1password", "safari", "2026", "7-zip"] : Array(queries)
            var settings = store.settings
            if settings.weatherCity.isEmpty { settings.weatherCity = "Tokyo" } // no location prompt from a test run
            func dump() {
                for q in list {
                    let r = Tools.answers(q, settings)
                    print(q, "→", r.isEmpty ? "—" : r.prefix(3).map { "[\($0.title) | \($0.subtitle ?? "")]" }.joined(separator: " "))
                }
            }
            dump()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                _ = list.map { Tools.answers($0, settings) } // second step of chained lookups (place → forecast)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    print("\n--- after network ---")
                    dump()
                    exit(0)
                }
            }
            return true
        }
        if args.contains("--pomodoro-test") {
            for t in ["45分 休憩10分 4回", "30/5", "30;5", "50；10", "25／5／20", "30 5", "1h", "50 min focus 10 min break", "until 3pm", "集中90分 休憩なし", "2 rounds of 25", "half an hour"] {
                print(t, "→", Pomodoro.parse(t).map(Pomodoro.describe) ?? "nil")
            }
            exit(0)
        }
        if args.contains("--recorder-test") {
            // Feeds real key events to the shortcut recorder off screen and prints what it recorded.
            let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 200, height: 40), styleMask: .titled, backing: .buffered, defer: false)
            let v = HotKeyRecorderView(frame: NSRect(x: 0, y: 0, width: 150, height: 26))
            w.contentView?.addSubview(v)
            w.orderFrontRegardless()
            w.makeKey()
            func click() {
                let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 10), modifierFlags: [], timestamp: 0,
                                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                v.mouseDown(with: e)
            }
            func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) {
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: w.windowNumber,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                NSApp.sendEvent(e)
            }
            for (code, flags, chars) in [(UInt16(49), NSEvent.ModifierFlags.option, " "), (UInt16(40), [.command, .shift], "k"), (UInt16(0), [], "a"), (UInt16(51), [], "")] {
                click()
                key(code, flags, chars)
                print("pressed", HotKey.modifierSymbols(flags) + "#\(code)", "→ recorded:", v.hotKey.isEmpty ? "none" : v.hotKey.display, "first responder:", w.firstResponder === v)
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--settings-snapshot"), i + 1 < args.count {
            showSettings(pane: i + 2 < args.count ? Pane(rawValue: args[i + 2]) ?? .general : .general)
            settingsWindow?.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            if let v = settingsWindow?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--menu-snapshot"), i + 1 < args.count {
            let hv = NSHostingView(rootView: MenuView(store: store, clipboard: clipboard, meeting: MeetingRecorder(store: store), pomodoro: Pomodoro()) { _ in })
            let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 320, height: 10), styleMask: .borderless, backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
            w.backgroundColor = .windowBackgroundColor
            w.contentView = hv
            w.setContentSize(hv.fittingSize)
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            if let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) {
                hv.cacheDisplay(in: hv.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let value = { (flag: String) in args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            let scope: Scope = switch value("--scope") {
            case "clipboard": .clipboard
            case "switcher": .switcher
            case "text": .text
            case "meeting": .meeting
            case "web": .web
            case "pomodoro": .pomodoro
            case "library": .library
            case "notes": .notes
            case "calculator": .calculator
            case "timer": .timer
            case "mixer": .mixer
            case "translate": .translate
            case "weather": .weather
            default: .apps
            }
            if scope == .text, let img = value("--image").flatMap(NSImage.init(contentsOfFile:)),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    let r = await ScreenText.recognize(cg, pointSize: img.size)
                    await MainActor.run {
                        self.launcher.model.screenText = r
                        self.launcher.model.textSelection = 3...6
                    }
                    done.signal()
                }
                while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            }
            if scope == .meeting {
                meeting.demo()
                if args.contains("--done") {
                    meeting.phase = .done
                    meeting.summary = "# Sponsor sync\n\n## Summary\n- The venue confirmed the 12th\n- The sponsor deck is due Friday\n\n## Action items\n- [ ] Me — finish the deck (tomorrow)\n- [ ] Others — artist contracts"
                }
            }
            if scope == .pomodoro || scope == .timer { launcher.model.pomodoro = pomodoro }
            if scope == .notes {
                NoteBoard.shared.persist = false
                NoteBoard.shared.notes = []
                NoteBoard.shared.add("Call the venue about the 12th")
                NoteBoard.shared.add("Sponsor deck — Friday!")
                NoteBoard.shared.add("買い物: 牛乳、卵、コーヒー")
                NoteBoard.shared.editing = nil
            }
            if scope == .calculator { launcher.model.calcHistory = ["12×8 = 96", "1200×1.1 = 1,320"] }
            if let m = value("--clock").flatMap(ClockMode.init(rawValue:)) { launcher.model.clockMode = m }
            if launcher.model.clockMode == .stopwatch, let w = Stopwatches.shared.list.first { w.banked = 83.42; w.laps = [83.42, 51.2, 24.9] }
            if launcher.model.clockMode == .timer, args.contains("--demo") { Timers.shared.add(minutes: 25, label: "Tea"); Timers.shared.add(minutes: 3) }
            if launcher.model.clockMode == .alarms, args.contains("--demo") {
                if args.contains("--edit") { launcher.model.newAlarm() } else { Alarms.shared.list = [Alarm(hour: 7, minute: 30, label: "Wake up", weekdays: Set(2...6))] }
            }
            if scope == .web, let path = value("--browser") {
                let id = Bundle(path: path)?.bundleIdentifier
                launcher.model.browser = AppEntry(path: path, name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                                                  bundleID: id, altName: nil)
                let loaded = BrowserSites.load(bundleID: id)
                launcher.model.sites = loaded.sites
                launcher.model.favicons = loaded.favicons
            }
            launcher.snapshot(scope: scope, query: value("--query") ?? "", dark: args.contains("--dark"), to: args[i + 1])
            exit(0)
        }

        if args.contains("--menu-test") {
            apply(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("status button:", self.statusItem?.button != nil, "window:", self.statusItem?.button?.window != nil)
                self.togglePopover()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    print("menu shown:", self.menuPanel.isShown, self.menuPanel.debugFrame)
                    exit(0)
                }
            }
            return true
        }
        return false
    }
}
