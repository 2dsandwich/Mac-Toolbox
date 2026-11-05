import Foundation

/// Names the people on the "Others" channel. The Mac's sound is one channel with no voice information, so names can
/// only come from what's said and the calendar: a 1:1's one attendee, introductions, greetings, people addressed by name.
/// The meeting AI looks once, and a name is only used when it was certain and checks out (an attendee, or said aloud).
@MainActor enum SpeakerNames {
    struct Guess: Equatable {
        /// The one person on the channel.
        var channel: String?
        /// Lines told apart when several people share the channel (by line number).
        var lines: [Int: String] = [:]
    }

    /// A 1:1 on the calendar: its one other attendee.
    static func oneOnOne(_ attendees: [String]) -> String? { attendees.count == 1 ? attendees[0] : nil }

    static let system = """
    You work out who is speaking in a meeting transcript made by speech recognition. "Me" is the user's microphone. "Others" is \
    the computer's sound: everyone else on the call on one channel, so different Others lines can be different people.
    Reply with JSON only: {"others": "", "lines": {}}
    "others": the name of the person on the Others channel, only when exactly one person speaks there and you are sure who it is: \
    they introduce themselves, Me greets or thanks them by name ("thanks, Ben"), they are addressed by name and answer, or the \
    calendar lists exactly one attendee and nothing in the transcript points to anyone else. Otherwise "".
    "lines": only when two or more people speak on the Others channel. Map an Others line number to a name only when the \
    transcript makes that line's speaker certain: they say who they are in it ("this is Aiko", "Ben here"), or the line just \
    before asks them by name and this line is the answer. Leave every other line out. Never guess from topic, tone or role.
    Use the calendar spelling when a first name matches one attendee, otherwise the name as said. Never name Me. People who are \
    only talked about ("Ben will send it") are not speakers. When in doubt, leave it out: a wrong name is worse than "Others".
    """

    /// The transcript with line numbers (lines from `from`, with a little before it for context), at most ~8,000 characters.
    static func prompt(_ doc: MeetingDoc, from: Int) -> String {
        var t = "Meeting: \(doc.displayTitle)\nCalendar attendees besides Me: \(doc.attendees.isEmpty ? "(none)" : doc.attendees.joined(separator: ", "))\n\nTranscript:\n"
        for i in max(0, from - 6)..<doc.lines.count {
            let l = doc.lines[i]
            let row = "[\(i)] \(l.me ? "Me" : "Others"): \(l.text)\n"
            if t.count + row.count > 8000 { break }
            t += row
        }
        return from > 0 ? t + "\nOnly label lines numbered \(from) or later." : t
    }

    /// The reply, kept only where it checks out: an attendee (a first name becomes their full name) or a name that was said.
    static func parse(_ reply: String, doc: MeetingDoc, from: Int) -> Guess? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let json = try? JSONSerialization.jsonObject(with: Data(reply[open...close].utf8)) as? [String: Any] else { return nil }
        let heard = doc.lines.map(\.text).joined(separator: "\n").lowercased()
        let check = { (raw: String) -> String? in
            let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty, n.count <= 40, !["me", "others", "unknown", doc.meName.lowercased()].contains(n.lowercased()) else { return nil }
            if let a = doc.attendees.first(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { return a }
            let first = doc.attendees.filter { $0.split(separator: " ").first?.lowercased() == n.lowercased() }
            if first.count == 1 { return first[0] }
            return heard.contains(n.lowercased()) ? n : nil
        }
        var g = Guess(channel: (json["others"] as? String).flatMap(check))
        for (k, v) in json["lines"] as? [String: Any] ?? [:] {
            guard let i = Int(k), i >= from, doc.lines.indices.contains(i), !doc.lines[i].me, let name = (v as? String).flatMap(check) else { continue }
            g.lines[i] = name
        }
        // Lines told apart mean more than one voice: then the channel has no single name.
        if !g.lines.isEmpty, g.channel != nil, Set(g.lines.values) != [g.channel] { g.channel = nil }
        if let c = g.channel, Set(g.lines.values) == [c] { g.lines = [:] }
        return g
    }

    static func detect(_ doc: MeetingDoc, from: Int) async -> Guess? {
        guard AI.problem(.meetingNotes, Store.shared.settings) == nil,
              let reply = try? await AI.complete(.meetingNotes, system: system, user: prompt(doc, from: from)) else { return nil }
        return parse(reply, doc: doc, from: from)
    }

    /// Uses a guess, unless you've named someone yourself (your names always win).
    static func apply(_ g: Guess, to doc: MeetingDoc, from: Int) {
        guard !doc.namedByYou else { return }
        if from == 0 { doc.othersName = g.channel }
        for (i, name) in g.lines where doc.lines.indices.contains(i) { doc.lines[i].speaker = name }
    }
}
