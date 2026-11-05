import AppKit
import AVFoundation
import EventKit
import Speech
import SwiftUI

/// Command-line switches for checking the app without using it by hand: off-screen snapshots of each view
/// (`--snapshot`, `--island-snapshot`, `--settings-snapshot`, `--menu-snapshot`) and small tests of the parts
/// that don't need a person (`--tools-test`, `--ai-test`, `--ask`, `--polish-test`, `--merge-file` …). See the README.
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
        if let i = args.firstIndex(of: "--meeting-sim"), i + 1 < args.count {
            // Plays a file through a meeting's mixed English + Japanese transcriber in real time; prints each line.
            let path = args[i + 1]
            Task {
                let t = MixedTranscriber(locales: ["en_US", "ja_JP"])
                t.onFinal = { print("line:", $0) }
                try? await t.prepare()
                t.start(context: [])
                let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
                while true {
                    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
                    guard (try? file.read(into: buf)) != nil, buf.frameLength > 0 else { break }
                    t.append(buf.copied()!)
                    try? await Task.sleep(for: .seconds(Double(buf.frameLength) / file.processingFormat.sampleRate))
                }
                await t.finish()
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
        if let i = args.firstIndex(of: "--transcribe-media"), i + 1 < args.count {
            // The Dictation view's file transcription: any audio or video file → text and subtitles, every installed
            // dictation language at once (or the locales given after the path).
            let path = args[i + 1], given = args.dropFirst(i + 2).filter { !$0.hasPrefix("-") }
            Task {
                let start = Date()
                do {
                    let r = try await FileTranscriber.transcribe(URL(fileURLWithPath: path), locales: given.isEmpty ? store.settings.listenLocales : Array(given)) { _ in }
                    print(String(format: "%.1fs of audio in %.1fs", r.seconds, Date().timeIntervalSince(start)))
                    print("text:", r.text)
                    print(FileTranscriber.srt(r.lines))
                } catch {
                    print("failed:", error.localizedDescription)
                }
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
                                                        user: Prompts.cleanupRequest(heard: said, merged: heard, target: Prompts.Target(), context: .prompt))
                        print("[\(AI.label(.dictation, s))]", String(format: "%.1fs", Date().timeIntervalSince(start)), "→", out.replacingOccurrences(of: "\n", with: " ⏎ "))
                    } catch { print("FAILED:", error.localizedDescription) }
                }
                // Mixed English + Japanese where the phrase merge leaned on one language (what goes wrong in real use).
                let mixed: [(merged: String, en: String, ja: String, before: String?)] = [
                    ("a share no meeting what son G Cara day yo nay then I'll send the slides",
                     "a share no meeting what son G Cara day yo nay then I'll send the slides",
                     "明日のミーティングは3時からでいいよね。ゼン アイル センド ザ スライズ", nil),
                    ("このバグ直して。ザ ボタン ダズント ショーアップ ウェン アイ オープン セッティングス",
                     "Kono bug now she take the button doesn't show up when I open settings",
                     "このバグ直して。ザ ボタン ダズント ショーアップ ウェン アイ オープン セッティングス", nil),
                    ("Rio Kai jaa kin you be need oh Kuri mass",
                     "Rio Kai jaa kin you be need oh Kuri mass",
                     "了解、じゃあ金曜日に送ります", "Sounds good, can you send it by Friday?"),
                    ("明日のミーティングは3時からでいいよね",
                     "a share no meeting what son G Cara day yo nay then I'll send the slides after lunch",
                     "明日のミーティングは3時からでいいよね。ゼン", nil),
                    ("Can you check the",
                     "Can you check the yeah me sure Oh MIT tell us way",
                     "キャンユーチェックザ請求書を見て確認して", nil),
                    ("I think the 予算 is too high だから let's cut the ads",
                     "I think the yo son is too high the color let's cut the ads",
                     "アイシンクザ予算イズトゥーハイだからレッツカットジアズ", nil),
                ]
                for m in mixed {
                    let out = try? await AI.complete(.dictation, system: Prompts.cleanup(s, context: .chat),
                                                     user: Prompts.cleanupRequest(heard: [("en_US", m.en, 0.6), ("ja_JP", m.ja, 0.6)], merged: m.merged,
                                                                                  target: Prompts.Target(name: "LINE"), context: .chat, before: m.before))
                    print("mixed →", (out ?? "FAILED").replacingOccurrences(of: "\n", with: " ⏎ "))
                }
                if args.contains("--mixed-only") { exit(0) }
                // One thing said, written for different places.
                let said = "um hey sarah so the files are uh ready i put them in the shared folder let me know if you need anything thanks tom"
                for (ctx, name, field) in [(Prompts.WritingContext.chat, "LINE", ""), (.email, "Mail", ""), (.prompt, "ChatGPT", "Ask anything"),
                                           (.search, "Spotify", "Search"), (.plain, "Hearth", "Write a message")] {
                    let t = Prompts.Target(name: name, field: field)
                    let q = ctx == .search ? "um play that song by uh fred again" : said
                    let out = try? await AI.complete(.dictation, system: Prompts.cleanup(s, context: ctx),
                                                     user: Prompts.cleanupRequest(heard: [("en_US", q, 0.9)], merged: q, target: t, context: ctx))
                    print("\(ctx.rawValue) (\(name)) →", (out ?? "FAILED").replacingOccurrences(of: "\n", with: " ⏎ "))
                }
                exit(0)
            }
            return true
        }
        if args.contains("--paste-test") {
            // Dictation's insert-and-check against text fields in an off-screen window of this process. No key events
            // are sent (the ⌘V "doesn't land"), so each field goes through the Accessibility insert and its check.
            setbuf(stdout, nil)
            let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 420, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            let field = NSTextField(frame: NSRect(x: 10, y: 150, width: 400, height: 24))
            field.stringValue = "Hello"
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 10, y: 10, width: 400, height: 120)
            let view = scroll.documentView as! NSTextView
            view.string = "First line"
            let label = NSTextField(labelWithString: "Not editable")
            label.frame = NSRect(x: 10, y: 130, width: 400, height: 18)
            [field, scroll, label].forEach { w.contentView?.addSubview($0) }
            w.orderFrontRegardless()
            let pid = ProcessInfo.processInfo.processIdentifier
            print("accessibility:", Paster.trusted ? "allowed" : "NOT ALLOWED (AX calls will fail)")
            print("chunks:", Paster.typingChunks("日本語のテキストと English words 👋🏽 together\nnext line").map { "\($0.utf16.count)" }.joined(separator: " "),
                  Paster.typingChunks("日本語のテキストと English words 👋🏽 together\nnext line").joined() == "日本語のテキストと English words 👋🏽 together\nnext line" ? "(rejoin ok)" : "(REJOIN BROKEN)")
            Task {
                let cases: [(String, NSView, () -> String)] = [("text field", field, { field.stringValue }), ("text view", view, { view.string }),
                                                               ("label", label, { label.stringValue })]
                for (name, v, read) in cases {
                    w.makeFirstResponder(v.acceptsFirstResponder ? v : nil)
                    let was = read()
                    try? await Task.sleep(for: .milliseconds(150))
                    let how = await Task.detached { () -> String in
                        // Only ever this process's own focus: the system-wide one is whatever the person is typing in.
                        let app = AXUIElementCreateApplication(pid)
                        AXUIElementSetMessagingTimeout(app, 1)
                        var f: AnyObject?
                        let err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f)
                        guard err == .success, let f, CFGetTypeID(f) == AXUIElementGetTypeID() else { return "no focused element (\(err.rawValue))" }
                        let el = f as! AXUIElement
                        var owner: pid_t = 0
                        guard AXUIElementGetPid(el, &owner) == .success, owner == pid else { return "focus is in another app: skipped" }
                        let before = Paster.snapshot(el).map { "\($0)" } ?? "nil"
                        let r = await Paster.deliver(" 音声 dictated ✓", pid: pid, field: el, post: false)
                        return "before \(before) → \(r.rawValue), after \(Paster.snapshot(el).map { "\($0)" } ?? "nil")"
                    }.value
                    print("\(name): \(how); \(was.count) → \(read().count) chars")
                }
                // Undo polish: the polished words just typed swap for the raw ones in place (and back), in the text view.
                w.makeFirstResponder(view)
                view.string = "Notes: Can you move the standup to 11?"
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
                try? await Task.sleep(for: .milliseconds(150))
                let app = AXUIElementCreateApplication(pid)
                var f: AnyObject?
                if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f, CFGetTypeID(f) == AXUIElementGetTypeID() {
                    let el = f as! AXUIElement
                    let polished = " Can you move the standup to 11?", raw = " um can you move the standup to ten no eleven"
                    let swapped = await Paster.replaceBeforeCursor(polished, with: raw, pid: pid, field: el, post: false)
                    print("undo polish:", swapped ? "swapped" : "NOT SWAPPED", "→", view.string)
                    let back = await Paster.replaceBeforeCursor(raw, with: polished, pid: pid, field: el, post: false)
                    print("again:", back ? "swapped back" : "NOT SWAPPED", "→", view.string)
                    let stale = await Paster.replaceBeforeCursor("something else", with: raw, pid: pid, field: el, post: false)
                    print("not right before the cursor:", stale ? "SWAPPED (wrong)" : "left alone")
                    // Learning: the watcher reads this field, a word is fixed by hand, it's added.
                    let learner = CorrectionWatcher()
                    var got: [String] = []
                    learner.onLearn = { got.append($0) }
                    view.string = "Deploy it to cooper netties today"
                    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
                    learner.watch(pasted: "Deploy it to cooper netties today", pid: pid, field: el)
                    view.string = "Deploy it to Kubernetes today"
                    learner.poll(focusCheck: false)
                    learner.finish()
                    print("learned from the field:", got)
                }
                let span = { (s: String) in NSRange(location: 0, length: (s as NSString).length) }
                for (before, after) in [("Send it to Ayko tomorrow", "Send it to Aiko tomorrow"), ("ship it with test flight", "ship it with TestFlight"),
                                        ("I think their right", "I think they're right"), ("so we should go", "So we should go"),
                                        ("meet at 3", "meet at 4"), ("open the link", "open https://example.com"),
                                        ("we talked about the plan", "we talked about the plan and then a whole lot more was written here")] {
                    print("learn \"\(before)\" → \"\(after)\":", CorrectionWatcher.learned(before: before, after: after, span: span(before), known: []) ?? "nothing")
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
            // Where dictation would go: (bundle ID, app name, category, window title, field) → style.
            let targets: [(String, String, String, String, String)] = [
                ("com.mitchellh.ghostty", "Ghostty", "developer-tools", "~/Developer", ""),
                ("com.openai.codex", "ChatGPT", "developer-tools", "ChatGPT", "Ask anything"),
                ("com.anthropic.claudefordesktop", "Claude", "productivity", "Claude", ""),
                ("com.ardia.browser", "Moneybag", "", "Inbox (3) - Gmail", ""),
                ("com.ardia.browser", "Moneybag", "", "ChatGPT", ""),
                ("com.google.Chrome", "Google Chrome", "", "Apple", "Address and search bar"),
                ("com.apple.Safari", "Safari", "productivity", "Online timeline", ""),
                ("jp.naver.line.mac", "LINE", "social-networking", "LINE", ""),
                ("com.tinyspeck.slackmacgap", "Slack", "business", "general", "Message #general"),
                ("com.microsoft.Outlook", "Microsoft Outlook", "productivity", "Inbox", ""),
                ("com.apple.mail", "Mail", "productivity", "New Message", "Subject"),
                ("notion.id", "Notion", "productivity", "Plans", ""),
                ("com.apple.Notes", "Notes", "productivity", "Notes", ""),
                ("com.microsoft.Word", "Microsoft Word", "productivity", "Essay.docx", ""),
                ("com.spotify.client", "Spotify", "music", "Spotify", "Search"),
                ("com.example.newchat", "Chatter", "social-networking", "Chatter", ""),
                ("com.example.tasks", "Tasks", "productivity", "Today", "Task name"),
                ("com.apple.dt.Xcode", "Xcode", "developer-tools", "Launcher.swift", ""),
                ("com.example.game", "Game", "games", "Game", ""),
            ]
            for (id, name, cat, title, field) in targets {
                let t = Prompts.Target(bundleID: id, name: name, category: cat, title: title, field: field)
                print(name, "·", title, field.isEmpty ? "" : "· [\(field)]", "→", Prompts.WritingContext.guess(t, browser: Prompts.Target.browsers.contains(id)).rawValue)
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
        if let i = args.firstIndex(of: "--ask"), i + 1 < args.count {
            // One real question through Ask (the same path as ↩ in the popup); prints the answer and its sources.
            let a = Assistant.shared
            let start = Date()
            a.ask(args[i + 1])
            Task {
                while a.busy { try? await Task.sleep(for: .milliseconds(100)) }
                let t = a.turns.last
                print("[\(AI.label(.assistant, store.settings))]", String(format: "%.1fs", Date().timeIntervalSince(start)), "updates:", a.updates,
                      t?.failed == true ? "FAILED:" : "→", t?.answer ?? "")
                for src in t?.sources ?? [] { print("  source:", src.title, src.url.absoluteString) }
                if let follow = args.dropFirst(i + 2).first(where: { !$0.hasPrefix("-") }) {
                    // A follow-up in the same thread.
                    a.ask(follow)
                    while a.busy { try? await Task.sleep(for: .milliseconds(100)) }
                    let f = a.turns.last
                    print("follow-up", f?.failed == true ? "FAILED:" : "→", f?.answer ?? "")
                    for src in f?.sources ?? [] { print("  source:", src.title, src.url.absoluteString) }
                }
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--lyrics-test"), i + 3 < args.count {
            // `--lyrics-test "<track>" "<artist>" <duration> [<at>]`: looks the song up (cache, then LRCLIB) and prints
            // only counts and times, never the words.
            island.onStage = nil // the real notch stays hidden
            NowPlaying.shared.frozen = true
            let duration = Double(args[i + 3]) ?? 0
            let at = i + 4 < args.count ? Double(args[i + 4]) ?? duration / 2 : duration / 2
            let song = Lyrics.Song(title: args[i + 1], name: args[i + 1], artist: args[i + 2], album: "", duration: duration)
            func clock(_ t: Double) -> String { String(format: "%02d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
            Task {
                guard store.settings.notchLyrics else { print("lyrics are off in Settings › Notch"); exit(0) }
                let (entry, via) = await Lyrics.shared.lookUp(song)
                guard let entry else { print("source:", via, "→ network failed"); exit(1) }
                let cues = entry.synced.map { Lyrics.parse($0, duration: duration) } ?? []
                let plain = entry.plain.map { $0.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count } ?? 0
                print("source:", via, "| synced:", entry.synced != nil, "| plain lines:", plain, "| instrumental:", entry.instrumental)
                let lines = cues.filter { $0.text != nil }, gaps = cues.count - lines.count
                print("cues:", cues.count, "| lines:", lines.count, "| breaks (note):", gaps)
                if let f = lines.first, let l = lines.last { print("first line:", clock(f.time), "| last line:", clock(l.time)) }
                let k = cues.lastIndex { $0.time <= at } ?? -1
                let what = k < 0 ? "before the first line" : cues[k].text == nil ? "break (note)" : "line"
                print("at \(clock(at)): cue \(k) of \(cues.count) (\(what))" + (k + 1 < cues.count ? ", next at \(clock(cues[k + 1].time))" : ""))
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--battery-states"), i + 1 < args.count {
            // The battery glance in each state it can be in (made up), on black, plus the real one last.
            islandController.freeze()
            typealias S = Battery.State
            let states: [(String, S?)] = [
                ("on battery 80%", S(pct: 80)), ("on battery 45%", S(pct: 45)), ("low 18%", S(pct: 18)), ("critical 7%", S(pct: 7)),
                ("charging 35%", S(pct: 35, charging: true, plugged: true)), ("charging 92%", S(pct: 92, charging: true, plugged: true)),
                ("plugged, held at 80%", S(pct: 80, plugged: true)), ("full, plugged", S(pct: 100, plugged: true, charged: true)),
                ("Low Power Mode 55%", S(pct: 55, lowPower: true)), ("Low Power Mode 15%", S(pct: 15, lowPower: true)),
                ("real: " + (Battery.shared.state?.detail ?? "no battery"), Battery.shared.state),
            ]
            let view = VStack(alignment: .leading, spacing: 10) {
                ForEach(states.indices, id: \.self) { k in
                    HStack(spacing: 16) {
                        BatteryGlance(fixed: states[k].1).frame(width: 70, alignment: .leading)
                        Text(states[k].0).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .padding(16).frame(width: 360, alignment: .leading).background(Color.black).environment(\.colorScheme, .dark)
            let hv = NSHostingView(rootView: view)
            hv.frame = NSRect(origin: .zero, size: hv.fittingSize)
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: hv.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
            w.contentView = hv
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            if let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) {
                hv.cacheDisplay(in: hv.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            print("real:", Battery.shared.state.map { "\($0)" } ?? "none")
            exit(0)
        }
        if args.contains("--idle-track-test") {
            // Hover the bare notch with a pretend pointer, then move away: it should open, then close all the way.
            // The real panel never comes on screen (no onStage).
            island.onStage = nil
            island.haptic = {}
            let c = islandController!
            func run(_ secs: Double, _ p: NSPoint) {
                c.mouseOverride = p
                let end = Date().addingTimeInterval(secs)
                // `--timer`: only the app's own pointer checks run (as on a fresh launch), none called from here.
                while Date() < end {
                    if !args.contains("--timer") { c.trackOnce() }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
            }
            if args.contains("--real") { RunLoop.main.run(until: Date().addingTimeInterval(4)) } // real now-playing polls first
            let r = c.notchRect
            print("activities:", island.activities, "stage:", island.stage, "song:", NowPlaying.shared.available, NowPlaying.shared.playing)
            run(args.contains("--timer") ? 2.5 : 1.0, NSPoint(x: r.midX, y: r.maxY - 10))
            print("after hovering:", island.stage, "idleOpen:", island.idleOpen)
            run(0.5, NSPoint(x: r.midX, y: r.minY - 60)) // just under the open notch
            print("0.5 s after leaving:", island.stage)
            run(Store.shared.settings.notchCollapseDelay + 1.5, NSPoint(x: r.midX, y: r.minY - 400))
            print("well after leaving:", island.stage, "idleOpen:", island.idleOpen)
            exit(0)
        }
        if let i = args.firstIndex(of: "--island-snapshot"), i + 1 < args.count {
            // Renders the notch off screen with demo activities: collapsed and expanded side by side. The real notch
            // panel stays hidden (nothing shows on screen), and the demo song stands in for whatever is really playing.
            island.onStage = nil
            island.haptic = {}
            islandController.freeze()
            CameraMirror.placeholder = true // the real camera never comes on here
            NowPlaying.shared.demo = true
            if !args.contains("--media-only") {
                Timers.shared.add(minutes: 25, label: "Tea")
                Timers.shared.add(minutes: 3)
                Stopwatches.shared.add()
            }
            if args.contains("--focus") { pomodoro.start(Pomodoro.Plan()) }
            if !args.contains("--no-media") {
                let m = NowPlaying.shared
                m.title = args.contains("--long") ? "Save Your Tears (Remix) [feat. Ariana Grande] - Extended Club Mix" : "Blinding Lights"
                m.artist = args.contains("--long") ? "The Weeknd & Kendrick Lamar" : "The Weeknd"
                m.playing = !args.contains("--paused")
                m.duration = 200
                m.position = 80
                m.artwork = args.contains("--no-art") ? nil : Self.demoArt()
                if args.contains("--lyrics") || args.contains("--lyrics-face") {
                    // Made-up lines (`--lyrics-at <seconds>` moves the song, 92 for the break's note).
                    if let j = args.firstIndex(of: "--lyrics-at"), j + 1 < args.count { m.position = Double(args[j + 1]) ?? 80 }
                    m.updated = Date()
                    Lyrics.shared.showDemo()
                    // The player's lyrics face (the saved setting stays as it is).
                    if args.contains("--lyrics-face") { island.lyricsOverride = true }
                }
            }
            if let j = args.firstIndex(of: "--dictation"), j + 1 < args.count {
                // Dictation as it looks while listening or polishing (with a long take, to see it scroll).
                let d = island.dictation
                d.phase = args[j + 1] == "polishing" ? .processing : .listening
                d.handsFree = args.contains("--hands-free")
                d.noSound = args.contains("--no-sound")
                d.preview = args.contains("--long")
                    ? "So the plan for tomorrow is number one finish the notch drag and drop, number two fix the dictation paste, number three ship the build before lunch, and then we can look at the settings preview again and maybe the meeting chat too"
                    : "So the plan for tomorrow is"
                d.levels = (0..<20).map { i in Float(0.15 + 0.6 * abs(sin(Double(i) * 0.7))) }
                if d.noSound { d.preview = ""; d.levels = d.levels.map { _ in 0 } }
            }
            if args.contains("--event") || args.contains("--event-now") {
                // A made-up event with a Meet link, 12 minutes off (or just started), instead of the real calendar.
                let now = Date().addingTimeInterval(args.contains("--event-now") ? 13 * 60 : 0)
                CalendarEvents.shared.useDemo(CalendarEvents.demoEvents(Date()))
                CalendarEvents.shared.setNowForDemo(now)
                // Alone, so its open view comes first (whatever is really playing stays out).
                if args.contains("--no-media") { NowPlaying.shared.onChange = nil; NowPlaying.shared.title = "" }
            }
            // The idle notch's extras, made up: `--home` a stopped song to play again, weather and an event later today.
            if args.contains("--home") {
                NowPlaying.shared.last = .init(title: "Blinding Lights", artist: "The Weeknd", artwork: Self.demoArt(), appID: "com.apple.Music")
                BandData.shared.weather = ("cloud.sun.fill", 18, 21, 12)
                let at = Calendar.current.date(bySettingHour: 21, minute: 30, second: 0, of: Date()) ?? Date()
                CalendarEvents.shared.useDemo([CalendarEvent(id: "demo-later", title: "Design review", start: at, end: at.addingTimeInterval(1800), color: .systemPurple)])
            }
            // `--no-notch`: as on a Mac without a notch.
            if args.contains("--no-notch") { island.geometry = .plain(island.geometry.screenFrame) }
            // `--band battery,weather`: the glances left of the notch (the saved settings stay as they are).
            if let j = args.firstIndex(of: "--band"), j + 1 < args.count {
                island.bandOverride = args[j + 1].split(separator: ",").compactMap { BandItem(rawValue: String($0)) }
            }
            island.refresh()
            if args.contains("--idle") {
                // Nothing running: hovering opens it (clock, battery, camera); leaving closes it all the way.
                island.openIdle()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                print("idle open:", island.stage, island.idleOpen)
                island.collapse()
                RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                print("idle after leaving:", island.stage, island.idleOpen)
                island.idleOpen = true
            }
            if args.contains("--swipe-test") {
                // Feeds trackpad swipes (finger travel in points) to the notch and says what it did.
                var skipped: [Bool] = []
                island.skip = { skipped.append($0) }
                func swipe(_ dx: CGFloat, _ dy: CGFloat, player: Bool = true) -> Bool {
                    var took = island.swipe(.began, dx: 0, dy: 0, overPlayer: player)
                    for _ in 0..<10 { took = island.swipe(.changed, dx: dx / 10, dy: dy / 10, overPlayer: player) || took }
                    print(String(format: "  pull %.1f×%.1f", island.pull.width, island.pull.height), terminator: "")
                    return island.swipe(.ended, dx: 0, dy: 0, overPlayer: player) && took
                }
                island.stage = .compact
                print("compact, up 40 →", swipe(0, -40), island.stage)
                print("compact, down 15 →", swipe(0, 15), island.stage)
                print("compact, down 40 →", swipe(0, 40), island.stage)
                print("expanded, left 60 over player →", swipe(-60, 0), skipped)
                print("expanded, right 60 over player →", swipe(60, 0), skipped)
                print("expanded, right 60 below player →", swipe(60, 0, player: false), skipped)
                print("expanded, up 40 →", swipe(0, -40), island.stage)
                print("front app full screen:", IslandController.frontIsFullScreen(on: island.geometry.screenFrame))
                exit(0)
            }
            if let k = args.firstIndex(of: "--dictation-frames"), k + 1 < args.count {
                // Dictation starting (`start`) or finishing (`end`), caught every 40 ms on one contact sheet: from the
                // closed notch, or with `--idle` from the open one with nothing else running.
                let d = island.dictation, island = island!
                let (w, hv) = islandWindow(args)
                island.lastInteraction = .distantFuture
                if args.contains("--idle") {
                    island.idleOpen = false
                    island.stage = .hidden
                    island.openIdle()
                }
                d.handsFree = args.contains("--hands-free")
                d.levels = (0..<20).map { i in Float(0.15 + 0.6 * abs(sin(Double(i) * 0.7))) }
                let words = "So the plan for tomorrow is"
                var steps: [(ms: Double, run: () -> Void)]
                if args[k + 1] == "end" {
                    d.phase = .listening
                    d.preview = words
                    island.refresh()
                    steps = [(80, { d.phase = .processing; island.refresh() }), (780, { d.phase = .idle; d.preview = ""; island.refresh() })]
                } else {
                    steps = [(80, { d.phase = .starting; island.refresh() }), (320, { d.phase = .listening; island.refresh() }),
                             (600, { d.preview = words; island.refresh() })]
                }
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                var frames: [(String, NSBitmapImageRep)] = []
                let start = Date()
                for ms in stride(from: 0.0, through: 1400, by: 40) {
                    while let s = steps.first, s.ms <= ms { s.run(); steps.removeFirst() }
                    RunLoop.main.run(until: start.addingTimeInterval((ms + 39) / 1000))
                    let size = island.geometry.panelSize
                    let crop = NSRect(x: size.width / 2 - 340, y: hv.isFlipped ? 0 : size.height - 190, width: 680, height: 190)
                    if let rep = hv.bitmapImageRepForCachingDisplay(in: crop) { hv.cacheDisplay(in: crop, to: rep); frames.append(("\(Int(ms)) ms", rep)) }
                }
                w.orderOut(nil)
                try? Self.contactSheet(frames, columns: 3).flatMap { $0.representation(using: .png, properties: [:]) }?
                    .write(to: URL(fileURLWithPath: args[i + 1] + "-dictation-\(args[k + 1]).png"))
                print("stage", island.stage, "activities", island.activities)
                exit(0)
            }
            var images: [NSBitmapImageRep] = []
            for stage in [IslandStage.compact, .expanded] {
                island.lastInteraction = .distantFuture // keep it open for the picture
                island.stage = stage
                island.contentVisible = true
                if stage == .expanded {
                    // `--camera`: the mirror (a stand-in picture); `--promote-tile`: the first tile tapped to the front.
                    if args.contains("--camera") { island.camera = true }
                    if args.contains("--promote-tile") { island.focus = island.tiles.first }
                }
                let size = island.geometry.panelSize
                setbuf(stdout, nil)
                let (w, hv) = islandWindow(args)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                if let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) { hv.cacheDisplay(in: hv.bounds, to: rep); images.append(rep) }
                if stage == .expanded, let k = args.firstIndex(of: "--click"), k + 1 < args.count {
                    // Clicks a button the way the mouse would and says what happened: hands-free dictation's stop or
                    // cancel (right of the words, under the band), or the camera button in the band itself.
                    let g = island.geometry
                    let left = size.width / 2 - island.shapeSize.width / 2 + island.sideInset
                    let p: NSPoint
                    if args[k + 1] == "camera" {
                        p = NSPoint(x: size.width / 2 + island.shapeSize.width / 2 - island.sideInset - 16, y: size.height - g.topInset - island.bandTop - island.bandHeight / 2)
                    } else {
                        // Bottom-aligned with the words, the words centred beside the tiles.
                        let right = left + island.mainWidth - IslandView.rowPad - 16, d = island.detailHeight
                        let y = g.topInset + island.contentTop + max(d, island.tilesHeight) / 2 + d / 2 - 16
                        p = NSPoint(x: args[k + 1] == "stop" ? right : right - 32 - 8, y: size.height - y)
                    }
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            w.sendEvent(e)
                        }
                        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    }
                    print("clicked", args[k + 1], "at", p, "→ phase", island.dictation.phase, "handsFree", island.dictation.handsFree, "camera", island.camera)
                }
                w.orderOut(nil)
            }
            if args.contains("--face-frames") {
                // The player switching to its lyrics face and back, caught part way.
                island.stage = .expanded
                island.lyricsOverride = false
                let size = island.geometry.panelSize
                let hv = NSHostingView(rootView: IslandView(model: island, openMeeting: {}).frame(width: size.width, height: size.height).background(Color(white: 0.85)))
                let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
                w.contentView = hv
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                for on in [true, false] {
                    withAnimation(islandSpring) { island.lyricsOverride = on }
                    var last = 0.0
                    for ms in [50.0, 110, 180, 300] {
                        RunLoop.main.run(until: Date().addingTimeInterval((ms - last) / 1000))
                        last = ms
                        if let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) { hv.cacheDisplay(in: hv.bounds, to: rep); images.append(rep) }
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                }
                w.orderOut(nil)
            }
            if args.contains("--frames") {
                // Opening and closing caught part way: 60, 120 and 220 ms into each.
                island.stage = .compact
                let size = island.geometry.panelSize
                let hv = NSHostingView(rootView: IslandView(model: island, openMeeting: {}).frame(width: size.width, height: size.height).background(Color(white: 0.85)))
                let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
                w.contentView = hv
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                for open in [true, false] {
                    if open { island.expand(haptic: false) } else { island.collapse() }
                    var last = 0.0
                    for ms in [60.0, 120, 220] {
                        RunLoop.main.run(until: Date().addingTimeInterval((ms - last) / 1000))
                        last = ms
                        if let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) { hv.cacheDisplay(in: hv.bounds, to: rep); images.append(rep) }
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                }
                w.orderOut(nil)
            }
            for (n, rep) in images.enumerated() {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + "-\(n).png"))
            }
            print("song:", NowPlaying.shared.songTitle, "| with:", NowPlaying.shared.artistLine)
            print("seed", island.geometry.seedSize.width, "compact", island.compactLayout.side, "open", island.shapeSize, "tiles", island.tiles.count, "lane", island.bandLane, "clear each side", (island.openWidth - island.geometry.seedSize.width) / 2 - island.sideInset - island.bandLane)
            print("panel level", islandController.panelLevel, "(menu bar \(NSWindow.Level.mainMenu.rawValue))")
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
            setbuf(stdout, nil)
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
        if args.contains("--google-test") {
            GoogleTests.run()
        }
        if args.contains("--chats") { AskChats.shared.useDemo() } // made-up Ask chats (settings and ask snapshots)
        if args.contains("--ask-test") { askTest(); exit(0) }
        if let i = args.firstIndex(of: "--settings-snapshot"), i + 1 < args.count {
            // Google: a made-up account (or signed out), never the Keychain.
            Google.shared.useDemo(signedIn: !args.contains("--signed-out"), email: "ben@example.com")
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
            // --live: a made-up meeting recording and a timer running.
            if args.contains("--live") {
                island.onStage = nil
                demoMeeting([])
                Timers.shared.add(minutes: 25, label: "Tea")
            }
            let hv = NSHostingView(rootView: MenuView(store: store, meeting: args.contains("--live") ? meeting : MeetingRecorder(store: store), pomodoro: Pomodoro()) { _ in })
            setbuf(stdout, nil)
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
            case "calendar": .calendar
            case "tasks": .tasks
            case "dictation": .dictation
            case "assistant", "ask": .assistant
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
                // Made-up meetings only (--list, --past, --done, else one recording).
                CalendarEvents.shared.useDemo(CalendarEvents.demoEvents())
                demoMeeting(args)
                if args.contains("--list") || args.contains("--past") {
                    meeting.reset()
                    launcher.model.reloadPastMeetings()
                    if args.contains("--past"), let first = meeting.pastMeetings().first, let doc = MeetingDoc.load(first.url) {
                        launcher.model.openedMeeting = doc
                        launcher.model.pastChat = MeetingCopilot(store: store, source: .doc(doc))
                    }
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
            if scope == .assistant, args.contains("--demo") {
                Assistant.shared.demo(busy: args.contains("--busy") || args.contains("--stream"))
                if args.contains("--first") { Assistant.shared.turns.removeFirst(Assistant.shared.turns.count - 1) } // only the open question
                if let c = value("--cards") { Assistant.shared.demoCards(c) } // one canned answer with cards (AskCards.demos)
            }
            // Made-up events, never the real calendar ("calendar", "予定"); the real notch stays hidden.
            island.onStage = nil
            CalendarEvents.shared.useDemo(CalendarEvents.demoEvents())
            // Made-up Google tasks; --signed-out shows the sign-in row. --select <id|done>, --completed, --edit.
            Google.shared.useDemo(signedIn: !args.contains("--signed-out"))
            if scope == .tasks {
                GoogleTasks.shared.useDemo()
                let b = TasksBoard.shared
                // After the panel's own reset on appearing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    b.showDone = args.contains("--completed")
                    b.selected = value("--select")
                    if args.contains("--edit"), let t = b.selectedTask { b.startEditing(t, self.launcher.model) }
                }
            }
            if scope == .calendar {
                let board = CalendarBoard.shared
                if let span = value("--span").flatMap(CalendarSpan.init(rawValue:)) { board.span = span }
                // --focus event: ↩ opens the next event; --focus day: today's "+N more".
                if let f = value("--focus") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if f == "day" {
                            board.open(.day(board.anchor), from: board.frames.first { $0.key.hasPrefix("more") }?.value ?? .zero)
                        } else {
                            _ = board.handle(#selector(NSResponder.insertNewline(_:)), typing: false)
                        }
                    }
                }
            }
            if scope == .dictation {
                // Made-up dictations only (--raw: the original words, --job: a file being transcribed, --setup: what's missing,
                // --empty: nothing yet).
                let h = DictationHistory.shared
                h.useDemo()
                if args.contains("--empty") { h.clear() }
                h.showRaw = args.contains("--raw")
                if args.contains("--file") { h.selected = h.entries.first { $0.kind == .file }?.id }
                if args.contains("--job") { h.job = ("Interview with Aiko.mp4", 0.42) }
                DictationSetup.shown = args.contains("--setup") ? [.microphone, .accessibility, .model] : []
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
            // --stream: a made-up answer streams into the open question; frames catch its fade-in part way.
            let stream = scope == .assistant && args.contains("--stream")
            launcher.snapshot(scope: scope, query: value("--query") ?? "", dark: args.contains("--dark"), to: args[i + 1],
                              frames: stream ? [0.15, 0.3, 0.45, 0.6, 0.8, 1.0, 1.3, 1.7, 3.5] : []) { Assistant.shared.demoStream() }
            exit(0)
        }

        if runMeetingHook(args) { return true }
        if args.contains("--meeting-ai-test") {
            // Two real requests on Haiku with the made-up meeting: its notes, then the follow-up email prompt. Prints both.
            island.onStage = nil
            demoMeeting(["--done"])
            let doc = meeting.doc
            let (system, user) = doc.notesPrompt
            Task {
                do {
                    let notes = try await Claude.complete(system: system, user: user, model: "claude-haiku-5-5", effort: "low", timeout: 60)
                    print("=== notes (\(doc.resolvedTemplate.name))\n" + notes)
                    doc.notes = notes
                    let chat = MeetingCopilot(store: store, source: .doc(doc))
                    let r = chat.recipes[0]
                    let email = try await Claude.complete(system: "You help the user with their meetings. Be complete but brief. No em dashes.",
                                                          user: doc.markdown + "\n\n---\n\n" + r.prompt, model: "claude-haiku-5-5", effort: "low", timeout: 60)
                    print("=== \(r.title)\n" + email)
                } catch { print("failed:", error.localizedDescription) }
                exit(0)
            }
            return true
        }
        if args.contains("--layout-test") {
            // Window layout math on made-up screens, then a real AX move of a window this test makes (never anyone else's).
            layoutTest()
            return true
        }
        if args.contains("--calendar-count") {
            // How many events EventKit has today, as counts only. Never asks for access or shows the notch.
            island.onStage = nil
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .fullAccess else {
                print("calendar access:", status == .notDetermined ? "not asked yet" : "not allowed (\(status.rawValue))")
                exit(0)
            }
            let store = EKEventStore()
            let day = Calendar.current.startOfDay(for: Date())
            let all = store.events(matching: store.predicateForEvents(withStart: day, end: day.addingTimeInterval(86_400), calendars: nil))
            let timed = all.filter { !$0.isAllDay }
            let declined = timed.filter { $0.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined }
            let links = timed.filter { CalendarEvent.meetingLink([$0.url?.absoluteString, $0.location, $0.notes]) != nil }
            print("calendars:", store.calendars(for: .event).count, "| today:", all.count, "timed:", timed.count, "all-day:", all.count - timed.count,
                  "declined:", declined.count, "with call link:", links.count, "| still to come:", timed.filter { $0.endDate > Date() }.count)
            CalendarEvents.shared.reload()
            print("notch list:", CalendarEvents.shared.events.count, "| in the notch now:", CalendarEvents.shared.upcoming == nil ? "no" : "yes")
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

    /// A made-up meeting for the snapshots (never the real folder): recording, or with --state / --done, writing or done.
    func demoMeeting(_ args: [String]) {
        MeetingDoc.folderOverride = MeetingDoc.demoFolder()
        meeting.demo()
        let state = args.firstIndex(of: "--state").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? (args.contains("--list") || args.contains("--past") ? "idle" : args.contains("--done") ? "done" : "live")
        let notes = """
        ## Summary
        - Venue confirmed 12th, so the date is locked and load-in starts at 10:00.
        - Sponsor deck by Friday: I draft it tomorrow and Aiko adds the sponsor logos.
        - Artist contracts? Still open. Ben thinks Gaku has the latest version.

        ## Decisions
        - Keep the 12th and stop looking at other venues.

        ## Action items
        - [ ] Me: draft the sponsor deck (tomorrow)
        - [ ] Ben: find the latest artist contracts (Monday)

        ## Open questions
        - Who signs the artist contracts?
        """
        switch state {
        case "idle": meeting.phase = .done; meeting.reset()
        case "writing":
            meeting.phase = .summarizing
            meeting.doc.writing = String(notes.prefix(210))
        case "done":
            meeting.phase = .done
            meeting.doc.duration = 1920
            meeting.doc.notes = notes
            meeting.volatileMe = ""
        default: break
        }
    }

    /// The notch drawn off screen in its own window, on a light backdrop; `--show-notch` marks the camera housing
    /// (2 pt past the gap the menu bar leaves on each side) in red, to check nothing sits over it.
    func islandWindow(_ args: [String]) -> (NSWindow, NSView) {
        let g = island.geometry, size = g.panelSize
        let root = IslandView(model: island, openMeeting: {})
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .top) {
                if args.contains("--show-notch"), g.hasNotch {
                    Rectangle().fill(Color.red.opacity(0.45)).frame(width: g.seedSize.width + 4, height: g.notchHeight)
                }
            }
            .background(Color(white: 0.85))
        let hv = NSHostingView(rootView: root)
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = hv
        w.orderFrontRegardless()
        return (w, hv)
    }

    /// Frames side by side, each with its label, at half size.
    static func contactSheet(_ frames: [(String, NSBitmapImageRep)], columns: Int) -> NSBitmapImageRep? {
        guard let first = frames.first?.1 else { return nil }
        let fw = first.size.width, fh = first.size.height + 16
        let rows = (frames.count + columns - 1) / columns
        let size = NSSize(width: fw * CGFloat(columns), height: fh * CGFloat(rows))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (n, (label, f)) in frames.enumerated() {
            let x = CGFloat(n % columns) * fw, y = size.height - CGFloat(n / columns + 1) * fh
            f.draw(in: NSRect(x: x, y: y, width: fw, height: fh - 16))
            (label as NSString).draw(at: NSPoint(x: x + 4, y: y + fh - 15), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
            NSColor(white: 0.6, alpha: 1).setFill()
            NSRect(x: x + fw - 1, y: y, width: 1, height: fh).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// A stand-in album cover for snapshots: a red sky over a dark street.
    static func demoArt() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { r in
            NSGradient(colors: [NSColor(red: 0.95, green: 0.18, blue: 0.2, alpha: 1), NSColor(red: 0.35, green: 0.02, blue: 0.08, alpha: 1)])?.draw(in: r, angle: 90)
            NSColor(white: 0.05, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: r.width, height: r.height * 0.28).fill()
            return true
        }
    }
}

// MARK: --layout-test

extension AppDelegate {
    func layoutTest() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print(ok ? "  ok  " : "  FAIL", what)
        }
        func r(_ x: CGRect) -> String { "(\(Int(x.minX)), \(Int(x.minY)), \(Int(x.width))×\(Int(x.height)))" }
        let inside = { (a: CGRect, v: CGRect) in v.insetBy(dx: -0.5, dy: -0.5).contains(a) }

        // A notched MacBook (37pt menu bar, Dock hidden), the same with the Dock at the bottom, a bigger display to
        // the right (its bottom below the built-in's), and one above.
        let mac = Display(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 0, width: 1512, height: 945))
        let macDock = Display(frame: mac.frame, visible: CGRect(x: 0, y: 70, width: 1512, height: 875))
        let right = Display(frame: CGRect(x: 1512, y: -218, width: 2560, height: 1440), visible: CGRect(x: 1512, y: -218, width: 2560, height: 1415))
        let above = Display(frame: CGRect(x: -524, y: 982, width: 2560, height: 1440), visible: CGRect(x: -524, y: 982, width: 2560, height: 1415))
        let setups: [(String, [Display])] = [("single, notch", [mac]), ("single, Dock at bottom", [macDock]),
                                             ("two side by side", [mac, right]), ("display above", [mac, above])]
        for (name, displays) in setups {
            let H = displays[0].frame.height
            for d in displays {
                let v = d.visible
                let window = CGRect(x: v.minX + 100, y: v.minY + 120, width: 900, height: 600)
                print("\n[\(name)] screen \(r(d.frame)) visible \(r(v))")
                var t: [WindowLayout: CGRect] = [:]
                for l in WindowLayout.allCases where l != .restore && l != .nextDisplay {
                    t[l] = WindowMath.target(l, window: window, visible: v)
                    print("  \(l.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) appkit \(r(t[l]!))  ax \(r(WindowMath.flip(t[l]!, primaryHeight: H)))")
                }
                check(t.values.allSatisfy { inside($0, v) }, "every layout stays inside the visible frame")
                check(t[.leftHalf]!.maxX == t[.rightHalf]!.minX && t[.leftHalf]!.width + t[.rightHalf]!.width == v.width, "halves meet, no gap")
                check(t[.topHalf]!.maxY == v.maxY && t[.bottomHalf]!.minY == v.minY && t[.topHalf]!.minY == t[.bottomHalf]!.maxY, "top/bottom halves meet")
                check(t[.leftThird]!.maxX == t[.centerThird]!.minX && t[.centerThird]!.maxX == t[.rightThird]!.minX && t[.rightThird]!.maxX == v.maxX, "thirds tile")
                check(t[.topLeft]!.maxY == v.maxY && t[.bottomRight]!.minY == v.minY && t[.topRight]!.maxX == v.maxX, "quarters in the corners")
                check(t[.maximize]! == v, "maximize = visible frame (menu bar and Dock left alone)")
                check(t[.center]!.size == window.size && abs(t[.center]!.midX - v.midX) <= 1, "centre keeps the size")
                let ax = WindowMath.flip(t[.maximize]!, primaryHeight: H)
                check(WindowMath.flip(ax, primaryHeight: H) == t[.maximize]!, "AX flip goes back exactly")
                // In AX the top of this screen's usable area is (primary height − its top), measured down from the primary's top.
                check(ax.minY == H - v.maxY, "AX top \(Int(ax.minY)) = primary height \(Int(H)) − visible top \(Int(v.maxY))")
            }
        }

        print("\n[AX conversion spot checks]")
        let H = mac.frame.height
        check(WindowMath.flip(WindowMath.target(.maximize, window: .zero, visible: mac.visible), primaryHeight: H).minY == 37, "notch menu bar: maximized window's AX y is 37")
        let onRight = WindowMath.flip(CGRect(x: 1600, y: 100, width: 800, height: 600), primaryHeight: H)
        check(onRight.minY == 282, "window on the right display: AX y \(Int(onRight.minY)) (982 − 700)")
        let onAbove = WindowMath.flip(WindowMath.target(.maximize, window: .zero, visible: above.visible), primaryHeight: H)
        check(onAbove.minY == -1415, "display above: AX y is negative (\(Int(onAbove.minY)))")

        print("\n[1/2 → 2/3 → 1/3]")
        var prev: (layout: WindowLayout, step: Int, frame: CGRect)?
        var current = CGRect(x: 300, y: 200, width: 800, height: 500)
        var widths: [CGFloat] = []
        for _ in 0..<4 {
            let step = WindowMath.step(.leftHalf, previous: prev, current: current)
            current = WindowMath.target(.leftHalf, window: current, visible: mac.visible, step: step)
            widths.append(current.width)
            prev = (.leftHalf, step, current)
        }
        print("  left half ×4 widths:", widths.map { Int($0) })
        check(widths == [756, 1008, 504, 756], "cycles 756 → 1008 → 504 → 756")
        check(WindowMath.step(.leftHalf, previous: prev, current: current.offsetBy(dx: 40, dy: 0)) == 0, "moved by hand: starts over at 1/2")
        check(WindowMath.step(.rightHalf, previous: prev, current: current) == 0, "a different half starts at 1/2")
        check(WindowMath.step(.leftThird, previous: (.leftThird, 0, current), current: current) == 0, "thirds don't cycle")

        print("\n[next display]")
        let pair = [mac, right], stack = [mac, above]
        check(WindowMath.nextDisplay(after: mac, in: pair) == right && WindowMath.nextDisplay(after: right, in: pair) == mac, "side by side: built-in → right → built-in")
        check(WindowMath.nextDisplay(after: above, in: stack) == mac, "stacked: ordered left to right (above starts further left)")
        check(WindowMath.nextDisplay(after: mac, in: [mac]) == nil, "one display: nothing to do")
        let m = WindowMath.moved(CGRect(x: 100, y: 100, width: 900, height: 600), from: mac.visible, to: right.visible)
        print("  900×600 window moved to the right display:", r(m))
        check(m.size == CGSize(width: 900, height: 600) && inside(m, right.visible), "keeps its size, lands inside")
        let big = WindowMath.moved(CGRect(x: 0, y: 0, width: 2500, height: 1400), from: right.visible, to: mac.visible)
        check(inside(big, mac.visible), "a big window shrinks to fit the smaller screen \(r(big))")
        check(WindowMath.displayIndex(for: CGRect(x: 1300, y: 100, width: 800, height: 400), in: pair) == 1, "a window across both belongs to the one with more of it")
        check(WindowMath.displayIndex(for: CGRect(x: 9000, y: 9000, width: 100, height: 100), in: pair) == 1, "off every screen: the nearest")

        print("\n[minimum sizes]")
        let rh = WindowMath.target(.rightHalf, window: .zero, visible: mac.visible)
        let s1 = WindowMath.settled(rh, actual: CGSize(width: 900, height: 945), visible: mac.visible)
        check(s1.maxX == mac.visible.maxX, "right half with a 900pt minimum width stays on the right \(r(s1))")
        let th = WindowMath.target(.topHalf, window: .zero, visible: mac.visible)
        let s2 = WindowMath.settled(th, actual: CGSize(width: 1512, height: 600), visible: mac.visible)
        check(s2.maxY == mac.visible.maxY, "top half that won't shrink stays at the top \(r(s2))")
        let lh = WindowMath.target(.leftHalf, window: .zero, visible: mac.visible)
        let s3 = WindowMath.settled(lh, actual: CGSize(width: 756, height: 900), visible: mac.visible)
        check(s3.maxY == mac.visible.maxY && s3.minX == 0, "max height shorter than the screen: top left \(r(s3))")

        // The quit rows: what they say before and after the first ↩ (only the arming is called; nothing is quit).
        print("\n[quit / hide rows]")
        for q in ["quit all apps", "quit other apps", "hide other apps"] {
            let before = WindowCommands.answers(q, q, store.settings).first
            print("  \(q): \(before?.title ?? "—") | \(before?.subtitle ?? "")")
        }
        WindowCommands.arm("quitOthers", query: "quit other apps")
        let armedRow = WindowCommands.answers("quit other apps", "quit other apps", store.settings).first
        print("  after the first ↩: \(armedRow?.title ?? "—") | \(armedRow?.subtitle ?? "") | \(armedRow?.hintText ?? "")")
        check(armedRow?.title.hasSuffix("apps?") == true, "several apps: the row asks first")
        let other = WindowCommands.answers("quit others", "quit others", store.settings).first
        check(other?.title.hasSuffix("?") != true, "typing something else drops the question")

        // A real move through AX, on an invisible window of this process only.
        print("\n[AX on this test's own window]")
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.title = "MONEY layout test"
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        let screen = NSScreen.main ?? NSScreen.screens[0]
        w.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.minY + 80))
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        print("  accessibility trusted:", Paster.trusted)
        let app = AXUIElementCreateApplication(getpid())
        var list: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list)
        let element = (list as? [AXUIElement] ?? []).first { el in
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &t)
            return t as? String == "MONEY layout test"
        }
        if let element {
            let displays = Display.current
            let v = displays[WindowMath.displayIndex(for: w.frame, in: displays) ?? 0].visible
            let start = w.frame
            let mover = WindowMover.shared
            for (l, expect) in [(WindowLayout.leftHalf, WindowMath.target(.leftHalf, window: .zero, visible: v, step: 0)),
                                (.leftHalf, WindowMath.target(.leftHalf, window: .zero, visible: v, step: 1)),
                                (.leftHalf, WindowMath.target(.leftHalf, window: .zero, visible: v, step: 2)),
                                (.center, nil), (.maximize, v), (.restore, start)] as [(WindowLayout, CGRect?)] {
                let got = mover.apply(l, to: element)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                let real = w.frame
                print("  \(l.rawValue): AX says \(got.map(r) ?? "nil"), NSWindow frame \(r(real))")
                if let expect { check(got.map { WindowMath.same($0, expect, tolerance: 1) } == true && WindowMath.same(real, expect, tolerance: 1), "\(l.rawValue) → \(r(expect))") }
                else { check(got.map { abs($0.midX - v.midX) <= 1 && abs($0.midY - v.midY) <= 1 } == true, "centred on the visible frame") }
            }
            if displays.count > 1 {
                _ = mover.apply(.rightHalf, to: element)
                let got = mover.apply(.nextDisplay, to: element)
                print("  nextDisplay:", got.map(r) ?? "nil")
                check(got.map { g in displays.contains { WindowMath.same(g, WindowMath.target(.rightHalf, window: .zero, visible: $0.visible), tolerance: 1) } } == true,
                      "right half carries over to the next display")
            } else {
                print("  next display: one screen here, covered by the math above")
            }
        } else {
            print("  FAIL couldn't find the test window through AX (Accessibility not granted to whatever launched this?)")
            failures += 1
        }
        w.close()
        print(failures == 0 ? "\nall layout checks passed" : "\n\(failures) layout check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

// MARK: --ask-test

extension AppDelegate {
    /// Ask's chat list, keys and links, on made-up chats only (the real ones are never read, written or printed).
    /// No AI is called and nothing shows on screen.
    func askTest() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print(ok ? "  ok  " : "  FAIL", what)
        }
        let a = Assistant.shared, chats = AskChats.shared, l = launcher!, m = l.model
        chats.useDemo()
        let key = { (s: Selector) in _ = l.handle(s) }

        // Saved chats keep the thread and Claude's raw blocks exactly.
        let raw: [[String: Any]] = [["role": "user", "content": "q"],
                                    ["role": "assistant", "content": [["type": "text", "text": "a", "citations": [["url": "https://example.com"]]]]]]
        let json = String(data: try! JSONSerialization.data(withJSONObject: raw, options: .sortedKeys), encoding: .utf8)!
        let chat = AskChat(title: "q", date: Date(), turns: [Assistant.Turn(question: "q", answer: "a", sources: [.init(title: "E", url: URL(string: "https://example.com")!)])],
                           messages: json)
        let back = try! JSONDecoder().decode(AskChat.self, from: JSONEncoder().encode(chat))
        check(back.id == chat.id && back.turns.first?.answer == "a" && back.turns.first?.sources.count == 1 && back.messages == json, "a chat survives saving")

        // The list: newest picked, ↑↓ move, ↩ continues, typing searches.
        m.scope = .assistant
        a.reset()
        m.setQuery("")
        check(a.pick == 0 && AssistantView.height(a, query: "", store.settings) > 0, "empty Ask lists earlier chats, newest picked")
        key(#selector(NSResponder.moveDown(_:)))
        key(#selector(NSResponder.moveDown(_:)))
        let third = chats.all[2]
        key(#selector(NSResponder.insertNewline(_:)))
        check(a.turns.first?.question == third.title && a.chatID == third.id, "↓↓↩ continues the third chat")
        key(#selector(NSResponder.moveUp(_:)))
        check(m.query == a.turns.last?.question, "↑ in an empty bar brings back the last question")
        m.setQuery("")
        key(#selector(NSResponder.deleteBackward(_:)))
        check(a.turns.isEmpty && m.scope == .assistant, "⌫ in an empty bar goes back to the list")
        m.setQuery("kyoto")
        check(a.pick == nil && chats.matching("kyoto").count == 1, "typing searches the chats; ↩ would ask")
        key(#selector(NSResponder.moveDown(_:)))
        check(a.pick == 0, "↓ picks the match")

        // Esc stops an answer being written and keeps what came; the chat is saved.
        m.setQuery("")
        a.demo(busy: true)
        a.demoStream()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let got = a.turns.last?.answer.count ?? 0
        key(#selector(NSResponder.cancelOperation(_:)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        check(!a.busy && got > 0 && a.turns.last?.answer.count == got && l.isShown == false, "Esc stops the answer at \(got) characters")
        check(chats.all.first?.id == a.chatID && chats.all.first?.turns.count == a.turns.count, "the stopped chat is saved, at the top")
        let n = a.turns.count
        check(a.takeBackLast() == "Which trail is easiest for a first climb?" && a.turns.count == n - 1, "regenerate takes the last question back to ask again")

        // Leaving keeps the draft; Tab brings it back with a fresh thread.
        m.setQuery("half a question")
        m.scope = .apps
        check(a.turns.isEmpty && a.draft == "half a question", "leaving Ask keeps the draft")
        m.setQuery("")
        key(#selector(NSResponder.insertTab(_:)))
        check(m.scope == .assistant && m.query == "half a question", "Tab puts the draft back")

        // Links: Markdown, bare addresses and sources; the right-click menu.
        let t = Assistant.Turn(question: "q", answer: "See [the docs](https://example.com/docs) or https://example.org/page.",
                               sources: [.init(title: "S", url: URL(string: "https://example.net")!)])
        check(Assistant.links(t).compactMap(\.host) == ["example.com", "example.org", "example.net"], "links: Markdown, bare and sources")
        print("       menu:", Assistant.menu(t).map(\.title).joined(separator: " | "))

        // A click on a link goes to the link handler: the view drawn in a window off screen that only says it's key
        // (it never takes the keyboard), the link found by its colour, and a click sent to that window.
        var opened: URL?
        Assistant.onOpen = { opened = $0 }
        func click(_ view: some View) -> URL? {
            opened = nil
            let hv = FirstMouseHostingView(rootView: view.padding(16).frame(width: 600, height: 300, alignment: .top))
            let w = SeemsKeyWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = hv
            w.orderFrontRegardless()
            defer { w.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds)!
            hv.cacheDisplay(in: hv.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / hv.bounds.width
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide / 2, by: 2) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.blueComponent > 0.6, c.blueComponent - c.redComponent > 0.3 else { continue }
                    let p = NSPoint(x: CGFloat(x) / scale + 6, y: hv.bounds.height - CGFloat(y) / scale - 2)
                    // The release waits in this app's own queue (a text view's click loop reads it from there), then the press.
                    func event(_ type: NSEvent.EventType) -> NSEvent {
                        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    }
                    if CommandLine.arguments.contains("--debug-click") { print("       link pixel at", p) }
                    NSApp.postEvent(event(.leftMouseUp), atStart: false)
                    w.sendEvent(event(.leftMouseDown))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    return opened
                }
            }
            return nil
        }
        // One exchange (the thread's scroll view takes no synthetic clicks at all, not even on tap rows, so it's left out).
        let doc = "[Read the full documentation here](https://example.com/docs)", bare = "https://example.org/a/long/page/address"
        for (answer, url) in [(doc, "https://example.com/docs"), (bare, bare)] {
            check(click(AssistantTurn(turn: Assistant.Turn(question: "Docs?", answer: answer), busy: false))?.absoluteString == url,
                  "\(answer.hasPrefix("[") ? "Markdown" : "bare") link in an answer: tinted, and a click opens it")
        }
        // A finished answer is a text view: selectable across lines, and its links still open on a click.
        check(click(SelectableNotes(markdown: doc))?.absoluteString == "https://example.com/docs", "finished answer: selectable, and a link click opens it")
        Assistant.onOpen = nil

        print(failures == 0 ? "\nall Ask checks passed" : "\n\(failures) Ask check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

/// Says it's the key window without taking the keyboard, so clicks in an off-screen test reach selectable text.
final class SeemsKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}
