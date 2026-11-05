import Foundation

/// `--google-test`: the quick-add reader and the Google JSON mapping on made-up fixtures (no network, no account).
@MainActor enum GoogleTests {
    static func run() {
        var failed = 0, passed = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1; print("FAIL", name) }
        }
        let cal = Calendar.current
        // Wednesday 4 November 2026, 10:00 here.
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10))!
        let today = cal.startOfDay(for: now)
        let day = { (n: Int) in cal.date(byAdding: .day, value: n, to: today)! }
        let on = { (m: Int, d: Int, y: Int) in cal.date(from: DateComponents(year: y, month: m, day: d))! }
        let p = { (t: String, g: [String]) in QuickAdd.parse(t, now: now, groups: g) }

        var r = p("call Ben tomorrow 3pm", [])
        check("tomorrow 3pm", r.title == "call Ben" && r.day == day(1) && r.hour == 15)
        r = p("Buy milk // 2 litres, the good one", [])
        check("note", r.title == "Buy milk" && r.note == "2 litres, the good one" && r.day == nil)
        r = p("Renew passport next friday", [])
        check("next friday", r.title == "Renew passport" && r.day == day(9))
        r = p("Renew passport friday", [])
        check("friday", r.day == day(2))
        r = p("Sponsor deck in Festival", ["Festival", "My Tasks"])
        check("list", r.title == "Sponsor deck" && r.group == "Festival")
        r = p("Work on the deck", ["Work"])
        check("list needs in/to", r.group == nil && r.title == "Work on the deck")
        r = p("dentist tommorow", [])
        check("misspelt tomorrow", r.title == "dentist" && r.day == day(1))
        r = p("明日 牛乳を買う", [])
        check("明日", r.title == "牛乳を買う" && r.day == day(1))
        r = p("report due Nov 12", [])
        check("Nov 12", r.title == "report" && r.day == on(11, 12, 2026))
        r = p("pay rent 12/1", [])
        check("12/1", r.title == "pay rent" && r.day == on(12, 1, 2026))
        r = p("tax return 3/15", [])
        check("past month rolls to next year", r.day == on(3, 15, 2027))
        r = p("standup tomorrow at 9:30", [])
        check("at 9:30", r.title == "standup" && r.hour == 9 && r.minute == 30)
        r = p("call mom tonight", [])
        check("tonight", r.title == "call mom" && r.day == today && r.hour == 19)
        r = p("12月24日 プレゼント", [])
        check("12月24日", r.day == on(12, 24, 2026) && r.title == "プレゼント")
        r = p("finish slides in 3 days", [])
        check("in 3 days", r.title == "finish slides" && r.day == day(3))
        check("needs model", p("dinner next month", []).needsModel && !p("Buy milk", []).needsModel)
        check("spans", p("call Ben tomorrow // x", []).spans.map(\.kind) == [.when, .note])
        check("capital", QuickAdd.formatTitle("call Ben") == "Call Ben" && QuickAdd.formatTitle("iPhone case") == "iPhone case"
            && QuickAdd.formatTitle("done!!!") == "Done!")
        for n in [0, 1, 20, -3, 400] {
            let d = day(n)
            check("due text round trip \(n)", QuickAdd.parse("Task " + QuickAdd.dueText(d, now: now), now: now).day == d)
        }

        // Calendar JSON.
        let list: [String: Any] = ["items": [
            ["id": "primary@example.com", "summary": "Me", "backgroundColor": "#9fe1e7", "primary": true, "selected": true],
            ["id": "work@group.calendar.google.com", "summary": "Work", "summaryOverride": "Office", "backgroundColor": "#f83a22", "selected": true],
            ["id": "off@group.calendar.google.com", "summary": "Unticked", "backgroundColor": "#000000"],
            ["id": "hidden@group.calendar.google.com", "summary": "Hidden", "selected": true, "hidden": true],
        ]]
        let cals = GoogleCalendar.calendars(list)
        check("calendar list", cals.map(\.name) == ["Me", "Office"] && cals[0].primary && cals[1].color == "#f83a22")
        let events = """
        {"items": [
          {"id": "e1", "summary": "Design review", "status": "confirmed", "htmlLink": "https://www.google.com/calendar/event?eid=e1",
           "start": {"dateTime": "2026-11-04T13:00:00+09:00"}, "end": {"dateTime": "2026-11-04T14:00:00+09:00"},
           "location": " Room 4 ", "description": "Agenda<br>1. Slides<br/>2. Q&amp;A",
           "hangoutLink": "https://meet.google.com/abc-defg-hij", "colorId": "11",
           "attendees": [{"email": "me@example.com", "self": true, "responseStatus": "accepted"},
                         {"email": "fumi@example.com", "displayName": "Fumi Kato"}, {"email": "gaku@example.com"},
                         {"email": "room@resource.calendar.google.com", "resource": true}]},
          {"id": "e2", "summary": "Tokyo Game Show", "start": {"date": "2026-11-12"}, "end": {"date": "2026-11-15"}},
          {"id": "e3", "summary": "Declined", "start": {"dateTime": "2026-11-04T09:00:00Z"}, "end": {"dateTime": "2026-11-04T10:00:00Z"},
           "attendees": [{"email": "me@example.com", "self": true, "responseStatus": "declined"}]},
          {"id": "e4", "status": "cancelled", "start": {"dateTime": "2026-11-04T09:00:00Z"}, "end": {"dateTime": "2026-11-04T10:00:00Z"}},
          {"id": "e5", "summary": "Home", "eventType": "workingLocation", "start": {"date": "2026-11-04"}, "end": {"date": "2026-11-05"}},
          {"id": "e6", "start": {"dateTime": "2026-11-04T18:00:00.000Z"}, "end": {"dateTime": "2026-11-04T18:30:00.000Z"},
           "conferenceData": {"entryPoints": [{"entryPointType": "phone", "uri": "tel:+1"}, {"entryPointType": "video", "uri": "https://zoom.us/j/123"}]}}
        ]}
        """
        struct Page: Decodable { var items: [GoogleCalendar.GEvent] }
        let page = try? JSONDecoder().decode(Page.self, from: Data(events.utf8))
        let mapped = (page?.items ?? []).compactMap { GoogleCalendar.map($0, cals[1]) }
        check("event count (declined, cancelled, working location skipped)", mapped.map(\.id) == ["e1", "e2", "e6"])
        if mapped.count == 3 {
            let e = mapped[0].event
            check("timed event", e.start == ISO8601DateFormatter().date(from: "2026-11-04T04:00:00Z") && e.end.timeIntervalSince(e.start) == 3600 && !e.allDay)
            check("meet link", e.link?.absoluteString == "https://meet.google.com/abc-defg-hij")
            check("people", e.attendees == ["Fumi Kato", "gaku@example.com"])
            check("place and notes", e.location == "Room 4" && e.notes == "Agenda\n1. Slides\n2. Q&A")
            check("event colour", mapped[0].color == "#D50000" && e.calendar == "Office" && e.web != nil)
            let a = mapped[1].event
            check("all-day", a.allDay && a.start == on(11, 12, 2026) && a.days.count == 3 && a.color.hexString == "#F83A22")
            check("video entry point and untitled", mapped[2].link == "https://zoom.us/j/123" && mapped[2].title == "(No title)")
        }

        // Tasks JSON.
        let t1 = GoogleTasks.task(["id": "a", "title": " Call Ben ", "notes": "", "status": "needsAction", "due": "2026-11-12T00:00:00.000Z",
                                   "position": "00001", "parent": "p"], list: "L")
        check("task", t1?.title == "Call Ben" && t1?.notes == nil && t1?.due == on(11, 12, 2026) && t1?.parent == "p" && t1?.done == false)
        let t2 = GoogleTasks.task(["id": "b", "title": "Done one", "status": "completed", "completed": "2026-11-03T08:00:00.000Z"], list: "L")
        check("completed task", t2?.done == true && t2?.completed != nil)
        check("deleted and untitled skipped", GoogleTasks.task(["id": "c", "title": "x", "deleted": true], list: "L") == nil
            && GoogleTasks.task(["id": "d", "title": "  "], list: "L") == nil)
        check("due string", GoogleTasks.dueString(on(11, 12, 2026)) == "2026-11-12T00:00:00.000Z")
        GoogleTasks.shared.useDemo()
        check("subtasks follow their parent", GoogleTasks.shared.open(in: "l2").map(\.id) == ["t4", "t5", "t6", "t7", "t8"])
        check("completed newest first", GoogleTasks.shared.completed.map(\.id) == ["t9", "t10"])

        print("google-test: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
