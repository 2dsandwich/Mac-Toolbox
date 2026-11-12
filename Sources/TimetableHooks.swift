import AppKit

/// Timetable switches for the dev hooks. `--timetable-test` checks the parsers and the next-class logic and exits.
/// The rest set up made-up timetables for the snapshot switches (nothing is read from or saved to the real file):
/// `--timetable-demo` (`--tt-long` long names and rooms, `--tt-empty` none) with the clock at `--tt-now "2026-11-10 10:32"`
/// (a Tuesday, 8 minutes before Programming; "2026-11-17 09:00" is in the exam week), `--tt-edit <schedule>` open in the
/// editor, `--tt-add blank|copy` a schedule just added, `--tt-select <class name>` picked for editing,
/// `--tt-side period|day|presets|schedules`, `--tt-review` an import read from a made-up picture with a canned model
/// reply (never a real model).
extension AppDelegate {
    func runTimetableHook(_ args: [String]) -> Bool {
        if args.contains("--timetable-test") {
            Task { @MainActor in exit(await TimetableTest.run() ? 0 : 1) }
            return true
        }
        guard args.contains("--timetable-demo") else { return false }
        let value = { (flag: String) in args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let now = f.date(from: value("--tt-now") ?? "2026-11-10 10:32") ?? Date()
        let tt = Timetables.shared, board = TimetableBoard.shared
        TimetablePane.formOnly = args.contains("--tt-settings-below")
        tt.useDemo(now: now, long: args.contains("--tt-long"), empty: args.contains("--tt-empty"))
        // After the panel's own reset as it appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                if let name = value("--tt-edit"), let t = tt.terms.first(where: { $0.name.hasPrefix(name) }) { tt.select(t.id) }
                switch value("--tt-add") {
                case "blank": tt.addTerm(.blank("Schedule \(tt.terms.count + 1)"))
                case "copy": if let e = tt.editing { tt.duplicate(e) }
                default: break
                }
                if let name = value("--tt-select") { board.select(board.term.classes.first { $0.name.hasPrefix(name) }) }
                switch value("--tt-side") {
                case "period": board.side = .period(1)
                case "day": board.side = .day
                case "presets": board.side = .presets
                case "schedules": board.side = .schedules
                default: break
                }
            }
        }
        if args.contains("--tt-review") {
            Claude.canned = { _, _ in ([["type": "text", "text": TimetableTest.cannedReply]], "end_turn") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Timetable photo.png")
            let img = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { r in NSColor.white.setFill(); r.fill(); return true }
            if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try? png.write(to: url) }
            board.importFile(url, hint: "Class 2-3")
            let until = Date().addingTimeInterval(3)
            while board.reading != nil, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if let p = board.problem { print("review failed:", p) }
        }
        return false
    }
}

/// Assert-style checks, printed one per line.
@MainActor enum TimetableTest {
    static let cannedReply = """
    Here is the timetable:
    ```json
    {"title": "2年3組 後期", "periods": [{"start": "8:30", "end": "9:20"}, {"start": "9:30", "end": "10:20"}, {"start": "", "end": ""}],
     "days": [0, 1, 2, 3, 4],
     "classes": [{"day": 0, "period": 1, "name": "数学Ⅱ", "room": "2-3", "teacher": "佐藤", "weeks": ""},
                 {"day": 0, "period": 2, "name": "英語コミュニケーション", "room": "LL教室", "teacher": "", "weeks": ""},
                 {"day": 1, "period": 1, "name": "化学基礎", "room": "化学室", "teacher": "田中", "weeks": "odd"},
                 {"day": 1, "period": 1, "name": "生物基礎", "room": "生物室", "teacher": "", "weeks": "even"},
                 {"day": 2, "period": 3, "name": "体育", "room": "体育館", "teacher": "", "weeks": ""},
                 {"day": 3, "period": 2, "name": "現代の国語", "room": "2-3", "teacher": "", "weeks": ""},
                 {"day": 4, "period": 1, "name": "LHR", "room": "2-3", "teacher": "", "weeks": ""}],
     "termStart": "", "termEnd": "2027-03-19", "notes": "The third period's times weren't printed; check them."}
    ```
    """

    static func run() async -> Bool {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print(ok ? "ok  " : "FAIL", name, ok ? "" : detail())
            if !ok { failed += 1 }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func at(_ s: String) -> Date {
            let f = DateFormatter()
            f.calendar = cal
            f.timeZone = cal.timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.date(from: s)!
        }
        let hm = { (d: Date) in String(format: "%02d:%02d", cal.component(.hour, from: d), cal.component(.minute, from: d)) }

        // Next class, the class under way, no classes today.
        let term = Timetables.demoTerm()
        let tue = at("2026-11-10 10:32")
        check("next on Tuesday morning is Programming 10:40", term.next(after: tue, cal).map { "\($0.item.name) \(hm($0.start))" } == "Programming 10:40")
        check("nothing under way before it", term.current(at: tue, cal) == nil)
        let during = term.current(at: at("2026-11-10 11:00"), cal)
        check("Programming under way at 11:00, ends 12:10", during.map { "\($0.item.name) \(hm($0.end))" } == "Programming 12:10")
        check("lunch splits the same class in two", term.occurrences(on: tue, cal).filter { $0.item.name == "Programming" }.count == 2)
        let sat = at("2026-11-14 12:00")
        check("no classes Saturday", term.occurrences(on: sat, cal).isEmpty && term.current(at: sat, cal) == nil)
        check("Saturday: next is Monday's first", term.next(after: sat, cal).map { "\(TimetableTerm.weekday($0.start, cal)) \($0.item.name) \(hm($0.start))" } == "0 Linear Algebra 09:00")
        let late = term.next(after: at("2026-11-13 19:00"), cal)
        check("Friday evening: next is Monday", late.map { TimetableTerm.dayString($0.start, cal) } == "2026-11-16")
        check("outside the term nothing comes", term.next(after: at("2027-02-01 08:00"), cal) == nil)

        // Odd and even weeks (term starts Mon 2026-09-21: that's week 1).
        let tuesdays = (0..<4).map { cal.date(byAdding: .day, value: 7 * $0, to: at("2026-09-22 08:00"))! }
        let fifth = tuesdays.map { d in term.occurrences(on: d, cal).first { $0.first == 4 }?.item.name ?? "-" }
        check("odd and even weeks alternate", fifth == ["French", "Lab Report", "French", "Lab Report"], fifth.joined(separator: ","))
        check("week numbers count from the term's start", term.week(of: at("2026-11-10 08:00"), cal) == 8)

        // A period that crosses midnight.
        var night = TimetableTerm(name: "Night", days: [0, 1, 2, 3, 4], periods: [ClassPeriod(start: "21:00", end: "22:30"), ClassPeriod(start: "23:30", end: "1:00")])
        night.classes = [ClassItem(day: 0, period: 1, name: "Astronomy", room: "Roof")]
        check("period past midnight ends the next day", night.spans[1] == (1410, 1500))
        check("Monday 23:00: next is Astronomy 23:30", night.next(after: at("2026-11-09 23:00"), cal).map { hm($0.start) } == "23:30")
        let past = night.current(at: at("2026-11-10 00:20"), cal)
        check("Tuesday 0:20: Monday's Astronomy still on, ends 1:00", past.map { "\($0.item.name) \(TimetableTerm.dayString($0.end, cal)) \(hm($0.end))" } == "Astronomy 2026-11-10 01:00")
        check("Tuesday 1:10: over", night.current(at: at("2026-11-10 01:10"), cal) == nil)
        var wrap = TimetableTerm(name: "Wrap", periods: [ClassPeriod(start: "22:00", end: "23:30"), ClassPeriod(start: "0:10", end: "1:40")])
        wrap.classes = [ClassItem(day: 2, period: 1, name: "Late lab")]
        check("a period earlier than the one before is after midnight", wrap.next(after: at("2026-11-11 20:00"), cal).map { TimetableTerm.dayString($0.start, cal) + " " + hm($0.start) } == "2026-11-12 00:10")

        // Consecutive periods of one class, and only/skip weeks.
        var block = TimetableTerm(name: "Block", periods: [ClassPeriod(start: "9:00", end: "9:50"), ClassPeriod(start: "10:00", end: "10:50"), ClassPeriod(start: "11:00", end: "11:50")])
        block.classes = [ClassItem(day: 2, period: 0, name: "Lab", room: "L1"), ClassItem(day: 2, period: 1, name: "Lab", room: "L1"),
                         ClassItem(day: 2, period: 2, name: "Lab", room: "L2"),
                         ClassItem(day: 3, period: 0, name: "Only", weeks: ClassWeeks(only: ["2026-11-09"])),
                         ClassItem(day: 3, period: 1, name: "Skip", weeks: ClassWeeks(skip: ["2026-11-09"]))]
        let wed = block.occurrences(on: at("2026-11-11 08:00"), cal)
        check("back-to-back same class and room is one", wed.count == 2 && wed[0].first == 0 && wed[0].last == 1)
        check("only that week", block.occurrences(on: at("2026-11-12 08:00"), cal).map(\.item.name) == ["Only"])
        check("every week but that one", block.occurrences(on: at("2026-11-19 08:00"), cal).map(\.item.name) == ["Skip"])

        // Schedules by date: Fall 2026 (Sep 21 – Jan 29), Exam week inside it (Nov 16 – 20), Spring 2027 from Apr 5 with no end.
        var spring = TimetableTerm(name: "Spring 2027", periods: term.periods, start: "2027-04-05")
        spring.classes = [ClassItem(day: 0, period: 0, name: "Calculus II", room: "B-101")]
        let all = [term, Timetables.demoExams(), spring]
        let used = { (s: String) in all.inEffect(on: at(s), cal)?.name ?? "none" }
        check("overlap: the exam week wins inside Fall", used("2026-11-17 08:00") == "Exam week", used("2026-11-17 08:00"))
        check("overlap: Fall before and after it", used("2026-11-13 08:00") == "Fall 2026" && used("2026-11-23 08:00") == "Fall 2026")
        check("gap between terms", used("2027-02-15 08:00") == "none")
        check("open end runs on", used("2027-04-05 08:00") == "Spring 2027" && used("2031-06-02 08:00") == "Spring 2027")
        check("exam week: Fall's classes don't come", all.current(at: at("2026-11-17 11:00"), cal) == nil
              && all.occurrences(on: at("2026-11-17 08:00"), cal).map(\.item.name) == ["Programming exam"])
        let into = all.next(after: at("2026-11-13 19:00"), cal)
        check("Friday before: next is Monday's exam", into.map { "\($0.item.name) \(TimetableTerm.dayString($0.start, cal)) \(hm($0.start))" } == "Linear Algebra exam 2026-11-16 09:30",
              into.map { "\($0.item.name) \($0.start)" } ?? "-")
        let out = all.next(after: at("2026-11-20 15:00"), cal)
        check("after the last exam: next is Fall's Monday", out.map { "\($0.item.name) \(TimetableTerm.dayString($0.start, cal))" } == "Linear Algebra 2026-11-23")
        check("into an open-ended one across a gap", all.next(after: at("2027-03-29 12:00"), cal).map { TimetableTerm.dayString($0.start, cal) } == "2027-04-05")
        var tie = [TimetableTerm(name: "A", periods: []), TimetableTerm(name: "B", periods: [], start: "2026-01-01"), TimetableTerm(name: "C", periods: [], start: "2026-09-01")]
        check("same length: the later start wins", tie.inEffect("2026-10-01")?.name == "C")
        tie.removeLast()
        check("no dates: used only where nothing else is", tie.inEffect("2025-12-01")?.name == "A" && tie.inEffect("2026-02-01")?.name == "B")
        check("overlap note names the winner", all.overlapNotes == ["Exam week is used over Fall 2026 (Nov 16 – Nov 20)."], all.overlapNotes.joined(separator: " | "))
        check("no note for one with no dates", (all + [TimetableTerm(name: "Any", periods: [])]).overlapNotes.count == 1)

        // Older saved files: no kind, an active term picked by hand (it goes first, so it wins a tie).
        let old = #"{"terms":[{"id":"6B0A1C1E-0000-4000-8000-000000000001","name":"One","periods":[{"start":"9:00","end":"10:30"}],"classes":[{"day":0,"period":0,"name":"Art"}]},"#
            + #"{"id":"6B0A1C1E-0000-4000-8000-000000000002","name":"Two","days":[0,1],"periods":[{"start":"9:00","end":"10:30"}],"start":"","end":""}],"#
            + #""active":"6B0A1C1E-0000-4000-8000-000000000002","look":{"density":2}}"#
        let saved = Timetables.decode(Data(old.utf8))
        check("old file loads", saved?.terms.count == 2 && saved?.terms.allSatisfy { $0.kind.isEmpty } == true && saved?.look?.density == 2)
        check("old active goes first and is in use", saved?.terms.inEffect("2026-11-10")?.name == "Two")
        check("old classes load, not split", saved?.terms[1].classes.first?.apart == false)

        // Blocks: the same class next to itself is one cell; split, it's two.
        var two = term
        let prog = two.classes.first { $0.name == "Programming" }!
        check("block: Programming takes two periods", two.block(of: prog.id).map(\.period) == [1, 2])
        if let i = two.classes.firstIndex(where: { $0.name == "Programming" && $0.period == 2 }) { two.classes[i].apart = true }
        check("block: split is one each", two.block(of: prog.id).count == 1)

        // ICS in.
        let ics = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        X-WR-CALNAME:Fall\r
        BEGIN:VEVENT\r
        SUMMARY:Linear Algebra\r
        LOCATION:B-204\\, Main\r
        DTSTART;TZID=Asia/Tokyo:20260922T090000\r
        DTEND;TZID=Asia/Tokyo:20260922T103000\r
        RRULE:FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20270128T150000Z\r
        EXDATE;TZID=Asia/Tokyo:20261103T090000\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        SUMMARY:French\r
        DTSTART;TZID=Asia/Tokyo:20260929T104000\r
        DTEND;TZID=Asia/Tokyo:20260929T121000\r
        RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=8\r
        DESCRIPTION:Bring the\\nworkbook\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        SUMMARY:Orientation\r
        DTSTART:20260921T010000Z\r
        DTEND:20260921T020000Z\r
        END:VEVENT\r
        END:VCALENDAR\r

        """
        do {
            let (t, notes) = try TimetableImport.ics(ics, name: "x", base: nil, cal)
            check("ics: two weekly events on three days", t.classes.count == 3, "\(t.classes.count)")
            check("ics: periods from the times", t.periods == [ClassPeriod(start: "9:00", end: "10:30"), ClassPeriod(start: "10:40", end: "12:10")], "\(t.periods)")
            check("ics: Tuesday and Thursday", Set(t.classes.filter { $0.name == "Linear Algebra" }.map(\.day)) == [1, 3])
            check("ics: escaped room", t.classes.first?.room == "B-204, Main")
            let fr = t.classes.first { $0.name == "French" }
            check("ics: every other week from week 2 is even", fr?.weeks?.parity == 2, "\(String(describing: fr?.weeks))")
            check("ics: COUNT gives the last week", fr?.weeks?.to == "2027-01-11", fr?.weeks?.to ?? "-")
            check("ics: EXDATE is a week off", t.classes.first?.weeks?.skip == ["2026-11-02"], "\(String(describing: t.classes.first?.weeks))")
            check("ics: one-off event left out", notes.contains("1 event"))
            check("ics: calendar name", t.name == "Fall")
        } catch { check("ics parses", false, error.localizedDescription) }

        // ICS out and back in.
        do {
            let out = TimetableImport.exportICS(term, cal)
            let (back, _) = try TimetableImport.ics(out, name: "x", base: term, cal)
            let names = { (t: TimetableTerm) in t.classes.map { "\($0.day)/\($0.period)/\($0.name)/\($0.room)" }.sorted() }
            check("ics round trip keeps every class in its cell", names(back) == names(term), "\(names(back).count) vs \(names(term).count)")
            check("ics round trip keeps odd and even", back.classes.first { $0.name == "French" }?.weeks?.parity == 1 && back.classes.first { $0.name == "Lab Report" }?.weeks?.parity == 2,
                  "\(String(describing: back.classes.first { $0.name == "French" }?.weeks))")
            check("ics round trip: the same next class", back.next(after: tue, cal)?.item.name == "Programming")
        } catch { check("ics round trip", false, error.localizedDescription) }

        // CSV.
        let csv = "\u{FEFF}曜日,時限,科目,教室,先生,週\n月,1,\"Calculus, Part 1\",\"Hall \"\"A\"\"\",Dr. Ng,\nTue,2,English,301,,odd\n3,3,Lab,,,even\n,,,,,\nSun,9,Bad,,,\nFri,x,No period,,,\n"
        do {
            let (t, notes) = try TimetableImport.csv(csv, name: "csv", base: Timetables.demoTerm())
            check("csv: rows with a day, name and period", t.classes.count == 4, "\(t.classes.map(\.name))")
            check("csv: quoted commas and quotes", t.classes.first?.name == "Calculus, Part 1" && t.classes.first?.room == "Hall \"A\"")
            check("csv: Japanese headers and day names", t.classes.first?.day == 0 && t.classes[1].day == 1 && t.classes[2].day == 2)
            check("csv: weeks", t.classes[1].weeks?.parity == 1 && t.classes[2].weeks?.parity == 2)
            check("csv: Sunday added, periods grown to 9", t.days.contains(6) && t.periods.count == 9)
            check("csv: bad rows counted", notes.hasPrefix("1 row was"), notes)
        } catch { check("csv parses", false, error.localizedDescription) }
        do {
            let (t, _) = try TimetableImport.csv("day,start,end,name\nMon,9:00,10:30,A\nWed,13:00,14:30,B\nWed,9:00,10:30,C\n", name: "t", base: nil)
            check("csv: periods from start and end", t.periods.count == 2 && t.classes.map(\.period) == [0, 1, 0])
        } catch { check("csv times", false, error.localizedDescription) }

        // JSON: our own, and Jikanwari's.
        do {
            let (t, _) = try TimetableImport.json(TimetableImport.exportJSON(term), name: "j")
            check("json round trip", t == term)
            let jw = """
            {"title":"高2","periods":[{"start":"8:30","end":"9:15"},{"start":"9:25","end":"10:10"}],"dayCount":5,"termEnd":"2027-03-31",
             "patterns":[{"name":"A/B週","weekStarts":[],"days":[[{"group":"","variants":[{"key":"","name":"数学","teacher":"","room":"301"}]},
                {"group":"英語クラス","variants":[{"key":"s","name":"英コミ","teacher":"","room":"310"},{"key":"d","name":"英コミ","teacher":"","room":"313"}]}],[],[],[],[]]},
              {"name":"B'週","weekStarts":["2026-11-09"],"days":[[{"group":"","variants":[{"key":"","name":"数学","teacher":"","room":"301"}]},
                {"group":"","variants":[{"key":"","name":"探究","teacher":"","room":"講義室"}]}],[],[],[],[]]}]}
            """
            let (j, _) = try TimetableImport.json(Data(jw.utf8), name: "j")
            check("jikanwari: same class both weeks is every week", j.classes.first { $0.name == "数学" }?.weeks == nil)
            check("jikanwari: electives kept, normal weeks skip B'", j.classes.filter { $0.name == "英コミ" }.allSatisfy { $0.weeks?.skip == ["2026-11-09"] } && j.classes.filter { $0.name == "英コミ" }.count == 2)
            check("jikanwari: B' only on its weeks", j.classes.first { $0.name == "探究" }?.weeks?.only == ["2026-11-09"])
            check("jikanwari: B' week shows 探究", j.occurrences(on: at("2026-11-09 08:00"), cal).map(\.item.name) == ["数学", "探究"])
        } catch { check("json parses", false, error.localizedDescription) }

        // Presets: the bundled data files, Jikanwari's school catalog among them.
        let presets = TimetablePreset.all()
        check("presets load from data files", presets.count >= 6, "\(presets.count)")
        if let c = presets.first(where: { $0.catalog != nil })?.catalog, let lg = c.lgs.first {
            let t = c.term(for: lg, taking: c.defaults(lg))
            check("school catalog builds a term", !t.classes.isEmpty && t.periods.count == 8, "\(t.classes.count)")
        } else { check("school catalog preset", false) }

        // The model's reply (canned, never a real model), straight and through the reader.
        do {
            let (t, notes) = try TimetableReader.parse(cannedReply, base: nil)
            check("reader: classes and odd/even", t.classes.count == 7 && t.classes.filter { $0.weeks != nil }.count == 2)
            check("reader: missing times follow on", t.periods[2] == ClassPeriod(start: "10:30", end: "12:00"), "\(t.periods[2])")
            check("reader: notes and term end", !notes.isEmpty && t.end == "2027-03-19")
            check("reader: not a timetable is an error", (try? TimetableReader.parse("Sorry, I can't.", base: nil)) == nil)
        } catch { check("reader parses", false, error.localizedDescription) }
        Claude.canned = { _, _ in ([["type": "text", "text": cannedReply]], "end_turn") }
        let csvURL = FileManager.default.temporaryDirectory.appendingPathComponent("tt-test.txt")
        try? "月 1限 数学".write(to: csvURL, atomically: true, encoding: .utf8)
        do {
            let r = try await TimetableImport.read(csvURL, base: nil)
            check("reader through Claude.canned", r.term.classes.count == 7)
        } catch { check("reader through Claude.canned", false, error.localizedDescription) }
        Claude.canned = nil

        // Launcher answer and Ask (the store reads the Mac's own time zone).
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd HH:mm"
        Timetables.shared.useDemo(now: local.date(from: "2026-11-10 10:32")!)
        check("search bar answer", Timetables.shared.answer("next class")?.title == "Programming · PC Lab 2", Timetables.shared.answer("next class")?.title ?? "-")
        check("no answer for other words", Timetables.shared.answer("nextcloud") == nil)
        let ask = Timetables.shared.askResult(date: "2026-11-10") as? [String: Any]
        let exam = Timetables.shared.askResult(date: "2026-11-17") as? [String: Any]
        check("ask: a day in the exam week uses it", exam?["schedule"] as? String == "Exam week" && (exam?["on_date"] as? [Any])?.count == 1)
        check("ask: next and that day's classes", (ask?["next"] as? [String: Any])?["room"] as? String == "PC Lab 2" && (ask?["on_date"] as? [Any])?.count == 3)

        print(failed == 0 ? "all passed" : "\(failed) failed")
        return failed == 0
    }
}
