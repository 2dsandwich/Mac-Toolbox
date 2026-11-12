import AppKit
import Observation

/// One meeting as a Markdown file: a little front matter (date, length, attendees, template), the AI notes,
/// the notes you typed during it, and the transcript. Old files (notes, then "## Transcript") read the same way.
@MainActor @Observable final class MeetingDoc {
    typealias Line = MeetingRecorder.Line

    var url: URL
    var title = ""
    var date = Date()
    var duration: TimeInterval = 0
    var attendees: [String] = []
    /// The template's name ("" = picked from the title and attendees).
    var template = ""
    /// The notes the AI wrote (Markdown, no title line).
    var notes = ""
    /// What you typed during the meeting.
    var myNotes = ""
    var lines: [Line] = []
    /// What the microphone's lines are labelled ("Me" unless you renamed it).
    var meName = "Me"
    /// The name of the one person on the computer's sound, once known (nil: "Others").
    var othersName: String?
    /// You named a speaker yourself, so guesses no longer change the names.
    var namedByYou = false
    /// Writing the notes: the text so far (streamed), or nil when not writing.
    var writing: String?
    var problem: String?
    var id: URL { url }
    /// The document as last read or written, to skip writing it unchanged.
    @ObservationIgnored private var clean = ""

    init(url: URL, date: Date = Date()) {
        self.url = url
        self.date = date
    }

    // MARK: Folder

    /// Off-screen snapshots point this at made-up meetings, so real ones never show.
    static var folderOverride: URL?

    static var folder: URL {
        folderOverride ?? URL(fileURLWithPath: (Store.shared.settings.meetingFolder as NSString).expandingTildeInPath)
    }

    /// A new file named after the start time ("2026-11-05 14.00 Meeting.md"), with seconds if that minute is taken.
    static func newFile(_ start: Date) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        var stamp = f.string(from: start)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.contains(where: { $0.hasPrefix(stamp + " ") }) == true {
            f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            stamp = f.string(from: start)
        }
        return folder.appendingPathComponent("\(stamp) Meeting.md")
    }

    // MARK: Reading and writing

    static func load(_ url: URL) -> MeetingDoc? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let d = MeetingDoc(url: url)
        d.read(text)
        d.clean = d.markdown
        return d
    }

    private func read(_ text: String) {
        var body = Substring(text)
        var meta: [String: String] = [:]
        if body.hasPrefix("---\n"), let end = body.dropFirst(4).range(of: "\n---\n") {
            for row in body[body.index(body.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                guard let colon = row.firstIndex(of: ":") else { continue }
                meta[row[..<colon].trimmingCharacters(in: .whitespaces)] = row[row.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            body = body[end.upperBound...]
        }
        var rest = String(body)
        meName = meta["me"] ?? "Me"
        othersName = meta["others"]
        if let r = rest.range(of: "## Transcript\n", options: .backwards) {
            lines = Self.parseTranscript(String(rest[r.upperBound...]), me: meName, others: othersName)
            rest = String(rest[..<r.lowerBound])
        }
        if let r = rest.range(of: "## My notes\n", options: .backwards) {
            myNotes = rest[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            rest = String(rest[..<r.lowerBound])
        }
        var rows = rest.components(separatedBy: "\n")
        if let i = rows.firstIndex(where: { $0.hasPrefix("# ") }) {
            let t = rows[i].dropFirst(2).trimmingCharacters(in: .whitespaces)
            title = t == "Meeting" ? "" : t
            rows.remove(at: i)
        }
        notes = rows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.hasSuffix("---") { notes = String(notes.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        attendees = meta["attendees"].map { $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        template = meta["template"] ?? ""
        duration = (Double(meta["duration"]?.components(separatedBy: " ").first ?? "") ?? 0) * 60
        if duration == 0, let last = lines.last { duration = last.at + 30 }
        date = Self.stampDate(url) ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
    }

    /// "**Me** (01:02): text" and "**Aiko Tanaka** (01:10): text" back into lines.
    static func parseTranscript(_ text: String, me: String = "Me", others: String? = nil) -> [Line] {
        text.components(separatedBy: "\n").compactMap { row in
            guard row.hasPrefix("**"), let mark = row.range(of: "** ("), let close = row[mark.upperBound...].firstIndex(of: ")") else { return nil }
            let label = String(row[row.index(row.startIndex, offsetBy: 2)..<mark.lowerBound])
            let clock = row[mark.upperBound..<close].split(separator: ":").compactMap { Double($0) }
            guard !label.isEmpty, !clock.isEmpty else { return nil }
            let text = row[row.index(after: close)...].drop { $0 == ":" || $0 == " " }
            let isMe = label == me
            return Line(me: isMe, text: String(text), at: clock.reduce(0) { $0 * 60 + $1 }, updated: .distantPast,
                        speaker: isMe || label == "Others" || label == others ? nil : label)
        }
    }

    private static func stampDate(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let r = name.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}"#, options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f.date(from: String(name[r]))
    }

    var transcript: String {
        lines.map { l in "**\(label(l))** (\(Self.clock(l.at))): \(l.text)" }.joined(separator: "\n\n")
    }

    // MARK: Speakers

    /// Who said a line: Me (or your name), the person told apart, the channel's name, else Others.
    func label(_ l: Line) -> String { l.me ? meName : l.speaker ?? othersName ?? "Others" }

    /// Everyone who can be mentioned: the attendees and the people named in the transcript.
    var people: [String] {
        var seen = Set<String>()
        return (attendees + lines.map(label)).filter { $0 != meName && $0 != "Others" && seen.insert($0).inserted }
    }

    /// Fixes a speaker's name everywhere: each line they said, the notes, your notes and the attendees. Then saves.
    func rename(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        namedByYou = true
        if old == meName {
            meName = name
        } else {
            if old == othersName || (othersName == nil && old == "Others") { othersName = name }
            for i in lines.indices where lines[i].speaker == old { lines[i].speaker = name }
        }
        // "Me" and "Others" are ordinary words too: only where they name an owner ("Me: send the deck").
        let word = NSRegularExpression.escapedPattern(for: old)
        let pattern = old == "Me" || old == "Others" ? "(?<![\\p{L}\\p{N}])\(word)(?=:)" : "(?<![\\p{L}\\p{N}])\(word)(?![\\p{L}\\p{N}])"
        let swap = { (s: String) in s.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: name), options: .regularExpression) }
        notes = swap(notes)
        myNotes = swap(myNotes)
        attendees = attendees.map { $0 == old ? name : $0 }
        save()
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    var displayTitle: String { title.isEmpty ? "Untitled meeting" : title }

    /// The notes with a title, ready to paste or send.
    var notesMarkdown: String { "# \(displayTitle)\n\n" + (notes.isEmpty ? myNotes : notes) }

    var markdown: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var front = ["date: " + f.string(from: date)]
        if duration > 0 { front.append("duration: \(Int((duration / 60).rounded())) min") }
        if !attendees.isEmpty { front.append("attendees: " + attendees.joined(separator: ", ")) }
        if !template.isEmpty { front.append("template: " + template) }
        if meName != "Me" { front.append("me: " + meName) }
        if let othersName { front.append("others: " + othersName) }
        var doc = "---\n" + front.joined(separator: "\n") + "\n---\n\n# \(title.isEmpty ? "Meeting" : title)\n\n"
        if !notes.isEmpty { doc += notes + "\n\n---\n\n" }
        if !myNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { doc += "## My notes\n\n" + myNotes + "\n\n" }
        return doc + "## Transcript\n\n" + transcript + "\n"
    }

    /// Writes the file; a name you typed renames it too (the start time stays at the front).
    func save() {
        let file = url.deletingPathExtension().lastPathComponent
        let prefix = file.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}(\.\d{2})?"#, options: .regularExpression).map { String(file[$0]) } ?? file
        let name = title.trimmingCharacters(in: .whitespaces)
        let wanted = url.deletingLastPathComponent().appendingPathComponent("\(prefix) \(name.isEmpty ? "Meeting" : Self.safe(name)).md")
        if wanted != url, FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.moveItem(at: url, to: wanted) }
        url = wanted
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        clean = markdown
        try? clean.write(to: url, atomically: true, encoding: .utf8)
    }

    func saveIfChanged() { if markdown != clean { save() } }

    static func safe(_ name: String) -> String {
        String(name.map { "/:\\".contains($0) ? "-" : $0 }.prefix(80))
    }

    // MARK: Notes

    /// The template used: the one picked, else one chosen from the title and attendees.
    var resolvedTemplate: MeetingTemplate {
        MeetingTemplate.all.first { $0.name == template } ?? MeetingTemplate.pick(title: title, attendees: attendees)
    }

    /// What the notes model is asked (system, user).
    var notesPrompt: (String, String) {
        let t = resolvedTemplate
        let system = """
        You write meeting notes. You get the notes the user typed during the meeting (short cues, maybe typos) and a speech-to-text \
        transcript. "\(meName)" is the user. Other speakers are labelled by name when known; "Others" is everyone else on the call, \
        mixed into one voice. The transcript has recognition errors: \
        infer the intended words from context, but never invent facts, names or numbers.
        The user's notes are the backbone. Every point they wrote must appear, in the section where it fits, as a bullet that starts with \
        their exact words (fix only obvious typos, capitalise the first letter) and runs on as one natural sentence with the detail from \
        the transcript. Then add the other points that matter.
        Shape: \(t.guidance)
        Markdown only: "## " section headings, "- " bullets, "- [ ] Owner: task (when)" for action items where the owner is known. \
        If my notes have a Markdown table, keep it as a table (fill it in from the transcript where it helps). \
        No title line, no preamble, no closing remarks. Leave out empty sections. Short, plain sentences; no em dashes. \
        Write in the meeting's main language (a Japanese meeting gets Japanese notes).
        """
        var user = "Meeting: \(displayTitle)\nDate: \(date.formatted(date: .complete, time: .shortened))\n"
        if !attendees.isEmpty { user += "Attendees: \(attendees.joined(separator: ", "))\n" }
        user += "\nMy notes:\n" + (myNotes.isEmpty ? "(none)" : myNotes) + "\n\nTranscript:\n\n" + (lines.isEmpty ? "(nothing transcribed)" : transcript)
        return (system, user)
    }

    /// Writes the notes: your notes are the backbone, the transcript fills them in, the template shapes them.
    func enhance(_ templateName: String? = nil) async {
        if let templateName { template = templateName }
        guard !lines.isEmpty || !myNotes.isEmpty else {
            problem = "Nothing was transcribed."
            return
        }
        if let why = AI.problem(.meetingNotes, Store.shared.settings) {
            problem = why
            return
        }
        problem = nil
        writing = ""
        let (system, user) = notesPrompt
        do {
            let out = try await AI.stream(.meetingNotes, system: system, user: user) { [weak self] partial in self?.writing = partial }
            notes = out.replacingOccurrences(of: #"^# .*\n+"#, with: "", options: .regularExpression)
        } catch {
            problem = "Couldn't write notes: \(error.localizedDescription)"
        }
        writing = nil
        save()
    }

    // MARK: Copy

    enum Part { case notes, transcript, all }

    func copy(_ part: Part) {
        let md = switch part {
        case .notes: notesMarkdown
        case .transcript: "# \(displayTitle)\n\n" + transcript
        case .all: notesMarkdown + "\n\n## Transcript\n\n" + transcript
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        // Rich text for Mail, Notes and Docs; the Markdown for everything else.
        pb.setString(Self.html(md), forType: .html)
        pb.setString(md, forType: .string)
    }

    /// Just enough Markdown to HTML for pasting: headings, bullets, checkboxes, bold.
    static func html(_ md: String) -> String {
        var out = "", inList = false
        for raw in md.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            let item = t.hasPrefix("- ") || t.hasPrefix("* ")
            if inList, !item { out += "</ul>"; inList = false }
            var s = t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
            if s.hasPrefix("# ") { out += "<h2>\(s.dropFirst(2))</h2>" }
            else if s.hasPrefix("## ") || s.hasPrefix("### ") { out += "<h3>\(s.drop { $0 == "#" }.dropFirst())</h3>" }
            else if item {
                if !inList { out += "<ul>"; inList = true }
                var li = String(s.dropFirst(2))
                if li.hasPrefix("[ ] ") { li = "☐ " + li.dropFirst(4) } else if li.hasPrefix("[x] ") { li = "☑ " + li.dropFirst(4) }
                out += "<li>\(li)</li>"
            } else if !s.isEmpty { out += "<p>\(s)</p>" }
        }
        return out + (inList ? "</ul>" : "")
    }

    /// Made-up meetings for the off-screen snapshots.
    static func demoFolder(many: Bool = false) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("money-demo-meetings")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let now = Date()
        let samples: [(Double, String, [String], String, String)] = [
            (-3, "Sponsor sync", ["Aiko Tanaka", "Ben Ito"], "## Summary\n- Venue confirmed for the 12th\n- Sponsor deck due Friday",
             "**Others** (00:10): The venue confirmed the 12th.\n\n**Me** (00:42): I can finish the deck tomorrow."),
            (-26, "Weekly team sync", ["Chris Park", "Dana Mori", "Eli Sato"], "## Updates\n- Ticketing page goes live Monday\n- Merch order placed",
             "**Others** (00:05): Ticketing goes live Monday."),
            (-50, "Design review", ["Fumi Kato"], "## Feedback\n- Poster type is too thin at small sizes",
             "**Others** (00:20): The poster type feels thin."),
            (-122, "Artist call", ["Gaku Ono"], "## Summary\n- Set length is 45 minutes\n- 来週リハーサルの日程を決める",
             "**Others** (01:00): Forty five minutes works."),
        ]
        // `--many`: a long list (a fortnight of syncs), to see it scroll.
        var extra: [(Double, String, [String], String, String)] = []
        for n in 1...16 where many {
            let title = n % 2 == 0 ? "Daily standup" : "Production check-in"
            extra.append((Double(-130 - n * 20), title, ["Chris Park"], "## Done\n- Item \(n)", "**Others** (00:05): Fine."))
        }
        for (hours, title, people, notes, transcript) in samples + extra {
            let date = now.addingTimeInterval(hours * 3600)
            let doc = "---\nduration: 30 min\nattendees: \(people.joined(separator: ", "))\n---\n\n# \(title)\n\n\(notes)\n\n---\n\n## Transcript\n\n\(transcript)\n"
            try? doc.write(to: dir.appendingPathComponent("\(f.string(from: date)) \(title).md"), atomically: true, encoding: .utf8)
        }
        return dir
    }
}

/// How the notes are shaped. Built in, plus your own: any Markdown file in the meetings folder's "Templates" folder
/// (its name is the template's name, its text says what sections to write).
struct MeetingTemplate: Identifiable, Hashable {
    let name: String
    let guidance: String
    var keywords: [String] = []
    var id: String { name }

    static let builtIn = [
        MeetingTemplate(name: "General", guidance: "## Summary (3 to 6 bullets), ## Decisions, ## Action items, ## Open questions."),
        MeetingTemplate(name: "1:1", guidance: "## Updates, ## Feedback (both ways), ## Blockers, ## Action items, ## For next time.",
                        keywords: ["1:1", "1-1", "1on1", "1 on 1", "one on one", "one-on-one", "面談"]),
        MeetingTemplate(name: "Standup", guidance: "## Done, ## Next, ## Blockers. Group bullets by person when the transcript makes it clear.",
                        keywords: ["standup", "stand-up", "stand up", "daily", "scrum", "朝会", "朝礼"]),
        MeetingTemplate(name: "Team sync", guidance: "## Updates (one bullet per topic), ## Decisions, ## Action items, ## Open questions.",
                        keywords: ["weekly", "sync", "team", "all hands", "all-hands", "定例", "全体"]),
        MeetingTemplate(name: "Customer call", guidance: "## Their situation, ## Needs and pain points, ## Objections, ## Pricing and terms, ## Next steps.",
                        keywords: ["customer", "client", "sales", "demo", "prospect", "pitch", "商談", "提案"]),
        MeetingTemplate(name: "Interview", guidance: "## Background, ## Strengths, ## Concerns, ## Notable answers, ## Recommendation (only if one was said).",
                        keywords: ["interview", "candidate", "hiring", "screen", "面接", "採用"]),
        MeetingTemplate(name: "User research", guidance: "## Who they are, ## How they work today, ## Pain points, ## Quotes (their exact words), ## Insights.",
                        keywords: ["user interview", "research", "discovery", "usability", "ヒアリング", "インタビュー"]),
    ]

    @MainActor static var all: [MeetingTemplate] { builtIn + custom }

    @MainActor static var customFolder: URL { MeetingDoc.folder.appendingPathComponent("Templates") }

    /// The folder for your own templates, made (with one to copy from) the first time.
    @MainActor static func openFolder() -> URL {
        let dir = customFolder
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? """
            A project kickoff. Write these sections:
            ## Goal (one or two sentences)
            ## Scope (in and out)
            ## Roles (who owns what)
            ## Milestones (with dates when said)
            ## Risks
            ## Action items
            """.write(to: dir.appendingPathComponent("Project kickoff.md"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @MainActor static var custom: [MeetingTemplate] {
        let files = (try? FileManager.default.contentsOfDirectory(at: customFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" || $0.pathExtension == "txt" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
            return MeetingTemplate(name: url.deletingPathExtension().lastPathComponent, guidance: text)
        }
        .sorted { $0.name < $1.name }
    }

    /// The default from Settings, else by the title's words, else 1:1 for one other person, else General.
    @MainActor static func pick(title: String, attendees: [String]) -> MeetingTemplate {
        if let d = all.first(where: { $0.name == Store.shared.settings.meetingTemplate }) { return d }
        let t = title.lowercased()
        // Longer phrases first, so "user interview" isn't read as a hiring interview.
        let ranked = builtIn.flatMap { m in m.keywords.map { (m, $0) } }.sorted { $0.1.count > $1.1.count }
        if let hit = ranked.first(where: { t.contains($0.1) }) { return hit.0 }
        return attendees.count == 1 ? builtIn[1] : builtIn[0]
    }
}
