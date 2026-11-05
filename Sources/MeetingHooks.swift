import AppKit
import SwiftUI

/// Off-screen checks for meetings (made-up meetings only, never the real folder, mic or screen):
/// `--meeting-window <png>` draws the floating window, `--speaker-test` checks speaker naming.
extension AppDelegate {
    func runMeetingHook(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--meeting-window"), i + 1 < args.count {
            meetingWindow(args, out: args[i + 1])
            exit(0)
        }
        if args.contains("--speaker-test") {
            speakerTest(live: args.contains("--live"))
            return true
        }
        return false
    }

    /// The floating meeting window with a made-up meeting: --state live|writing|done|idle, --tab transcript|mine,
    /// --chat (open, three exchanges), --rich (notes with a table, toggle and more), --edit (editing those notes),
    /// --speakers (two people told apart; --rename then fixes one name), --type (types into the notepad with key
    /// events sent to this window, saving <png>-slash.png with the "/" menu open and printing the Markdown).
    private func meetingWindow(_ args: [String], out: String) {
        island.onStage = nil
        CalendarEvents.shared.useDemo(CalendarEvents.demoEvents())
        demoMeeting(args)
        let doc = meeting.doc
        if args.contains("--rich") { doc.notes = Self.richNotes }
        if args.contains("--speakers") {
            doc.lines += [.init(me: true, text: "Ben, do you know where the latest contracts are?", at: 760, updated: Date()),
                          .init(me: false, text: "Gaku has them, I'll ask him tonight.", at: 768, updated: Date())]
            SpeakerNames.apply(.init(lines: [0: "Aiko Tanaka", 4: "Ben Ito"]), to: doc, from: 0)
            if args.contains("--rename") { doc.rename("Ben Ito", to: "Ben Itoh") }
            print(doc.transcript)
        }
        let typing = args.contains("--type")
        if typing { doc.myNotes = "" }
        let copilot = MeetingCopilot(store: store, source: .live(meeting))
        if args.contains("--chat") { copilot.exchanges = Self.demoChat(live: meeting.isRunning) }
        let tab = PageTab.allCases.first { args.contains("--tab") && args.contains($0 == .mine ? "mine" : $0.rawValue.lowercased()) } ?? .notes
        let size = NSSize(width: 440, height: typing ? 820 : 620)
        let view = CopilotView(meeting: meeting, copilot: copilot, store: store, hide: {}, window: { nil }, opaque: true, tab: tab,
                               chatOpen: args.contains("--chat"), editing: args.contains("--edit"))
        let hv = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = .clear
        w.isOpaque = false
        w.contentView = hv
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        if typing { typeDemo(w, hv, slashShot: (out as NSString).deletingPathExtension + "-slash.png") }
        Self.shot(hv, out)
    }

    private static func shot(_ v: NSView, _ path: String) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func find<T: NSView>(_ type: T.Type, in v: NSView) -> T? {
        if let t = v as? T { return t }
        for s in v.subviews { if let t = find(type, in: s) { return t } }
        return nil
    }

    /// Types notes the way a person would, as key events to the off-screen window: Markdown shortcuts, list
    /// continuation, the "/" menu (table, divider, toggle, a mention) and Tab between table cells.
    private func typeDemo(_ w: NSWindow, _ hv: NSView, slashShot: String) {
        guard let tv = Self.find(NoteTextView.self, in: hv) else { return print("no notepad") }
        w.makeFirstResponder(tv)
        let pump = { (t: Double) in RunLoop.main.run(until: Date().addingTimeInterval(t)) }
        func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return }
            w.sendEvent(e)
            pump(0.005)
        }
        func type(_ s: String) { for c in s { key(String(c), 0) } }
        let ret = { key("\r", 36) }, tab = { key("\t", 48) }
        type("# Agenda"); ret()
        type("Venue confirmed for the 12th"); ret()
        type("- Budget review"); ret(); type("Sponsor deck by Friday"); ret(); ret()
        type("[] Call Ben about the contracts"); ret(); type("Send the run sheet"); ret(); ret()
        type("1. Load-in at 10:00"); ret(); type("Sound check"); ret(); ret()
        type("> Keep the 12th and stop looking"); ret(); ret()
        type("/ta")
        pump(0.4)
        Self.shot(hv, slashShot)
        key("\u{1b}", 53) // Esc closes it; the text stays
        print("menu after Esc:", tv.slash?.isOpen == true ? "open" : "closed")
        for _ in 0..<3 { key("\u{7f}", 51) }
        type("/tab"); ret()
        for cell in ["Item", "Owner", "Due", "Sponsor deck", "Me", "Fri", "Contracts", "Ben", "Mon"] { type(cell); tab() }
        ret() // the empty row Tab made ends the table
        type("/div"); ret()
        type("/tog"); ret(); type("Venue details"); ret(); type("Load-in from the back gate"); ret(); ret()
        type("/aik"); ret(); type("adds the sponsor logos")
        pump(0.5)
        print("--- notepad Markdown\n" + (meeting.doc.myNotes))
        let typed = meeting.doc.myNotes

        // Smaller cases, each on its own text, checked against the Markdown they should leave.
        var failures = 0
        func check(_ what: String, _ want: String) {
            let ok = tv.string == want
            if !ok { failures += 1 }
            print(ok ? "ok  " : "FAIL", what, ok ? "" : "\n  got:  \(tv.string.debugDescription)\n  want: \(want.debugDescription)")
        }
        func start(_ text: String, caret: Int? = nil) {
            pump(0.1) // lets the last edit reach the binding first
            meeting.doc.myNotes = text // through the binding, as a reload would
            pump(0.1)
            tv.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
            pump(0.05)
        }
        func click(_ i: Int) {
            let p = tv.convert(tv.markerCenter(i), to: nil)
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: kind, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { w.sendEvent(e) }
            }
            pump(0.05)
        }
        let script = "# Agenda\nVenue confirmed for the 12th\n- Budget review\n- Sponsor deck by Friday\n- [ ] Call Ben about the contracts\n- [ ] Send the run sheet\n" +
            "1. Load-in at 10:00\n2. Sound check\n> Keep the 12th and stop looking\n| Item | Owner | Due |\n| --- | --- | --- |\n| Sponsor deck | Me | Fri |\n" +
            "| Contracts | Ben | Mon |\n---\n▾ Venue details\n  Load-in from the back gate\n@Aiko Tanaka adds the sponsor logos"
        if typed != script { failures += 1 }
        print(typed == script ? "ok   typed script" : "FAIL typed script")
        start("- item", caret: 2); key("\u{7f}", 51)
        check("⌫ at the start of a bullet makes it text", "item")
        start(""); type("- a"); ret(); tab(); type("b"); ret(); ret()
        check("⇥ nests, ↩ on an empty nested item un-nests", "- a\n  - b\n- ")
        start(""); type("/"); key(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125); key(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125); ret(); type("Title")
        check("/ then ↓↓↩ picks Heading 2", "## Title")
        start(""); type("* x")
        check("\"* \" becomes \"- \"", "- x")
        start("- [ ] task"); click(0)
        check("clicking the box ticks it", "- [x] task")
        start("▾ Details\n  inside", caret: 0); click(0)
        check("clicking the arrow folds the toggle", "▸ Details\n  inside")
        start(""); type("```"); ret(); type("let x = 1")
        check("``` and ↩ open a code block", "```\nlet x = 1\n```")
        start(""); type("Plan /code")
        check("\"/\" after a space opens the menu too", "Plan /code")
        print(tv.slash?.isOpen == true ? "ok   menu open mid-line" : "FAIL menu open mid-line")
        start("| a | b |\n| --- | --- |\n| 1 | 2 |", caret: 26); tab()
        print(tv.selectedRange() == NSRange(location: 30, length: 1) ? "ok   ⇥ selects the next cell" : "FAIL ⇥ selects the next cell \(tv.selectedRange())")
        start("| a | b |\n| --- | --- |\n| 1 | 2 |", caret: 26); tv.perform(NSSelectorFromString("addColumn"))
        check("Add Column (right-click menu)", "| a |  | b |\n| --- | --- | --- |\n| 1 |  | 2 |")
        start("| a | b |\n| --- | --- |\n| 1 | 2 |", caret: 26); tv.perform(NSSelectorFromString("deleteRow"))
        check("Delete Row", "| a | b |\n| --- | --- |")
        print(failures == 0 ? "all typing checks passed" : "\(failures) typing checks failed")
        meeting.doc.myNotes = typed
        pump(0.2)
    }

    static func demoChat(live: Bool) -> [MeetingCopilot.Exchange] {
        live ? [
            .init(question: "What did I miss?", answer: "- The venue is confirmed for the 12th\n- They need the sponsor deck by Friday\n- Ben asked who owns the artist contracts"),
            .init(question: "Who has the contracts?", answer: "Ben thinks **Gaku** has the latest version. Nobody has said who signs them."),
            .init(question: "What should I say?", answer: nil),
        ] : [
            .init(question: "Follow-up email", answer: "Subject: Sponsor sync, next steps\n\nHi Aiko and Ben,\n\nThanks for today. The venue is confirmed for the 12th, so we can stop looking.\n\n- I'll draft the sponsor deck tomorrow\n- Ben finds the latest artist contracts by Monday\n\nTalk soon"),
            .init(question: "Decisions", answer: "- Keep the 12th and stop looking at other venues\n- Aiko adds the sponsor logos to the deck"),
            .init(question: "Who signs the artist contracts?", answer: "Nobody was named. Ben thinks **Gaku** has the latest version, so ask him first."),
        ]
    }

    static let richNotes = """
    ## Summary
    - Venue confirmed 12th, so the date is locked and load-in starts at 10:00.
    - Sponsor deck by Friday: I draft it tomorrow and @Aiko Tanaka adds the logos.

    ## Run of show
    1. Load-in at 10:00
    2. Sound check at 14:00
    3. Doors at 18:30

    | Item | Owner | Due |
    | --- | --- | --- |
    | Sponsor deck | Me | Fri |
    | Artist contracts | Ben | Mon |

    > Keep the 12th and stop looking at other venues.

    ▸ Venue details
      Load-in from the back gate
      Parking for two vans

    ---

    ## Action items
    - [ ] Me: draft the sponsor deck (tomorrow)
    - [x] Ben: ask Gaku for the contracts
    """

    /// Speaker naming without the AI (what's kept from a reply, renames, the saved file), then with --live three real
    /// requests on made-up transcripts.
    private func speakerTest(live: Bool) {
        island.onStage = nil
        MeetingDoc.folderOverride = MeetingDoc.demoFolder()
        let make = { (attendees: [String], rows: [(Bool, String)]) -> MeetingDoc in
            let d = MeetingDoc(url: MeetingDoc.folder.appendingPathComponent("speaker-test.md"))
            d.title = "Speaker test"
            d.attendees = attendees
            d.lines = rows.enumerated().map { .init(me: $1.0, text: $1.1, at: Double($0) * 20, updated: Date()) }
            return d
        }
        var failures = 0
        func check(_ what: String, _ ok: Bool) {
            print(ok ? "ok  " : "FAIL", what)
            if !ok { failures += 1 }
        }
        let group = make(["Aiko Tanaka", "Ben Ito"], [(false, "Hi everyone, this is Aiko."), (true, "Thanks Aiko. Ben, what do you think?"), (false, "I think Friday works.")])
        var g = SpeakerNames.parse(#"{"others": "", "lines": {"0": "Aiko", "2": "Ben"}}"#, doc: group, from: 0)
        check("first names become attendees", g?.lines == [0: "Aiko Tanaka", 2: "Ben Ito"] && g?.channel == nil)
        g = SpeakerNames.parse(#"Sure: {"others": "Charlie", "lines": {"1": "Aiko", "9": "Ben"}}"#, doc: group, from: 0)
        check("names never said are dropped, Me and missing lines too", g?.channel == nil && g?.lines.isEmpty == true)
        g = SpeakerNames.parse(#"{"others": "Aiko Tanaka", "lines": {"2": "Ben Ito"}}"#, doc: group, from: 0)
        check("two voices: no single name for the channel", g?.channel == nil && g?.lines == [2: "Ben Ito"])
        check("not JSON: nothing", SpeakerNames.parse("I can't tell.", doc: group, from: 0) == nil)
        let one = make(["Dana Mori"], [(true, "Hi Dana, thanks for making time."), (false, "Of course, happy to.")])
        check("1:1 attendee from the calendar", SpeakerNames.oneOnOne(one.attendees) == "Dana Mori")
        check("a 1:1's first name", SpeakerNames.parse(#"{"others": "dana"}"#, doc: one, from: 0)?.channel == "Dana Mori")

        SpeakerNames.apply(.init(lines: [0: "Aiko Tanaka", 2: "Ben Ito"]), to: group, from: 0)
        group.notes = "- [ ] Me: send the deck\n- Others agreed on Friday\n- [ ] Ben Ito: find the contracts"
        group.rename("Ben Ito", to: "Ben Itoh")
        check("rename changes every line and the notes", group.lines[2].speaker == "Ben Itoh" && group.notes.contains("Ben Itoh: find") && group.attendees.contains("Ben Itoh"))
        group.rename("Me", to: "Sam")
        check("renaming Me: owners only, not the word", group.notes.contains("Sam: send") && group.notes.contains("Others agreed") && group.label(group.lines[1]) == "Sam")
        SpeakerNames.apply(.init(channel: "Someone", lines: [2: "Someone"]), to: group, from: 0)
        check("your names beat later guesses", group.lines[2].speaker == "Ben Itoh" && group.othersName == nil)
        let back = MeetingDoc.load(group.url)
        check("saved and read back", back.map { d in d.lines.map(d.label) } == ["Aiko Tanaka", "Sam", "Ben Itoh"] && back?.lines[1].me == true)
        print(failures == 0 ? "all passed" : "\(failures) failed")
        guard live else { exit(failures == 0 ? 0 : 1) }

        // Three real requests, made-up meetings.
        let cases: [(String, MeetingDoc)] = [
            ("1:1, greeted by name", make(["Dana Mori"], [(true, "Hi Dana, can you hear me?"), (false, "Yes, loud and clear. How was the trip?"),
                (true, "Good, tiring. So, the budget."), (false, "Right. I looked at the numbers and we are about ten percent over on staging."),
                (true, "Can we cut the second screen?"), (false, "Maybe. I'd rather drop the lighting upgrade first.")])),
            ("three people, one channel", make(["Chris Park", "Eli Sato", "Fumi Kato"], [(false, "Hi all, Chris here, I'll keep this short."),
                (true, "Thanks Chris. Fumi, did the posters go out?"), (false, "They did, on Tuesday, two hundred of them."),
                (false, "And the online ads start Monday."), (true, "Eli, anything from ticketing?"), (false, "Sales are steady, about forty a day."),
                (false, "That's better than last year.")])),
            ("no names at all", make([], [(false, "So where are we on the venue?"), (true, "Signed this morning."), (false, "Great, and the date?"),
                (true, "The twelfth."), (false, "Perfect, I'll tell the band.")])),
        ]
        Task {
            for (name, d) in cases {
                let g = await SpeakerNames.detect(d, from: 0)
                print("=== \(name):", g.map { "channel \($0.channel ?? "-"), lines \($0.lines.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })" } ?? "no answer")
            }
            exit(failures == 0 ? 0 : 1)
        }
    }
}
