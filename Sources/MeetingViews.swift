import AppKit
import SwiftUI

// One meeting as a calm document, in the floating meeting window and in ⌘4: its name, when and with whom,
// then Notes (a notepad while it runs; the AI notes after, your own words brighter), My notes and Transcript,
// with the chat in the corner.

enum PageTab: String, CaseIterable {
    case notes = "Notes", mine = "My notes", transcript = "Transcript"
}

struct MeetingPage: View {
    let doc: MeetingDoc
    /// The recorder, when this is the meeting being recorded (or just ended).
    var recorder: MeetingRecorder?
    var chat: MeetingCopilot?
    var query = ""
    /// Radius of the corner the chat sits in.
    let outerRadius: CGFloat
    var chatOpen = false
    @State private var tab: PageTab
    /// Editing the AI notes (after the meeting) instead of reading them.
    @State private var editing = false

    init(doc: MeetingDoc, recorder: MeetingRecorder? = nil, chat: MeetingCopilot?, query: String = "", outerRadius: CGFloat,
         tab: PageTab = .notes, chatOpen: Bool = false, editing: Bool = false) {
        self.doc = doc
        self.recorder = recorder
        self.chat = chat
        self.query = query
        self.outerRadius = outerRadius
        self.chatOpen = chatOpen
        _tab = State(initialValue: tab)
        _editing = State(initialValue: editing)
    }

    private let inset = PanelLayout.inset
    private var live: Bool { recorder?.isRunning == true }
    private var writing: Bool { doc.writing != nil || recorder?.phase == .summarizing }
    private var tabs: [PageTab] { live || doc.myNotes.isEmpty ? [.notes, .transcript] : PageTab.allCases }
    /// Room under the text for the chat button.
    private var chatRoom: CGFloat { chat == nil ? inset : ExpandingChat.buttonSize(outerRadius: outerRadius, inset: inset) + inset * 2 }

    var body: some View {
        @Bindable var doc = doc
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Untitled meeting", text: $doc.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .onSubmit { if !live { doc.save() } }
                Text(meta).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, inset)
            HStack(spacing: PanelLayout.gap) {
                ForEach(tabs, id: \.self) { t in TabPill(title: t.rawValue, on: tab == t) { tab = t } }
                Spacer(minLength: 0)
                if tab == .notes, !live, !writing, !doc.notes.isEmpty {
                    Button { editing.toggle() } label: { MeetingIcon(symbol: editing ? "checkmark" : "pencil") }
                        .buttonStyle(.plain)
                        .help(editing ? "Done" : "Edit notes")
                }
                // Just the icon when the row is too narrow for the template's name.
                ViewThatFits(in: .horizontal) {
                    TemplateMenu(doc: doc, live: live)
                    TemplateMenu(doc: doc, live: live, compact: true)
                }
            }
            .padding(.horizontal, inset)
            .padding(.vertical, inset)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .bottomLeading) {
            if let r = recorder, live, tab == .notes { LiveCaption(recorder: r) { tab = .transcript }.padding(inset).padding(.trailing, chatRoom) }
        }
        .overlay(alignment: .bottomTrailing) {
            if let chat { ExpandingChat(copilot: chat, title: chat.title, outerRadius: outerRadius, inset: inset, startOpen: chatOpen) }
        }
        .onChange(of: live) { _, _ in tab = .notes }
        .onDisappear { if !live, !writing { doc.saveIfChanged() } }
    }

    /// "Thu, Nov 5 · 14:00 · 32 min · Aiko Tanaka, Ben Ito".
    private var meta: String {
        var parts = [doc.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), doc.date.formatted(date: .omitted, time: .shortened)]
        if !live, doc.duration >= 60 { parts.append("\(Int((doc.duration / 60).rounded())) min") }
        if !doc.attendees.isEmpty { parts.append(doc.attendees.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        @Bindable var doc = doc
        switch tab {
        case .notes where live:
            NoteEditor(text: $doc.myNotes, people: doc.people, bottom: chatRoom)
        case .notes where editing && !writing:
            NoteEditor(text: $doc.notes, people: doc.people, bottom: chatRoom)
                .onChange(of: doc.notes) { _, _ in doc.save() }
        case .notes:
            notes
        case .mine:
            NoteEditor(text: $doc.myNotes, people: doc.people, bottom: chatRoom)
                .onChange(of: doc.myNotes) { _, _ in doc.save() }
        case .transcript:
            TranscriptView(doc: doc, volatileMe: live ? recorder?.volatileMe ?? "" : "", volatileOthers: live ? recorder?.volatileOthers ?? "" : "",
                           query: query, follow: live, bottom: chatRoom)
        }
    }

    private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let w = doc.writing, !w.isEmpty {
                    NotesView(markdown: w, mine: cues, spaced: true)
                } else if writing {
                    HStack(spacing: 8) {
                        ThinkingDots()
                        Text("Writing notes").font(.system(size: 13))
                    }
                    .foregroundStyle(.secondary)
                } else if !doc.notes.isEmpty {
                    NotesView(markdown: filtered(doc.notes), mine: cues, spaced: true)
                } else {
                    if let p = doc.problem { Text(p).font(.system(size: 13)).foregroundStyle(.secondary) }
                    PillButton(title: "Write notes", symbol: "sparkles") { Task { await doc.enhance() } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.bottom, chatRoom)
        }
        .scrollIndicators(.automatic)
    }

    /// Your notes, line by line, to show brighter where the AI notes kept them.
    private var cues: [String] { doc.myNotes.components(separatedBy: "\n") }

    /// Typing in the search bar keeps the lines that mention it (and the headings).
    private func filtered(_ md: String) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return md }
        return md.components(separatedBy: "\n").filter { $0.hasPrefix("#") || $0.localizedCaseInsensitiveContains(q) }.joined(separator: "\n")
    }
}

/// A tab: plain text, the chosen one bright on a soft pill.
private struct TabPill: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(Color.primary.opacity(on ? 0.12 : hover ? 0.06 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Which template shapes the notes. After the meeting, picking one writes the notes again.
struct TemplateMenu: View {
    let doc: MeetingDoc
    let live: Bool
    var compact = false

    var body: some View {
        Menu {
            item("Auto (\(MeetingTemplate.pick(title: doc.title, attendees: doc.attendees).name))", "")
            Divider()
            ForEach(MeetingTemplate.all) { t in item(t.name, t.name) }
            if !live, doc.writing == nil {
                Divider()
                Button("Write again", systemImage: "arrow.clockwise") { Task { await doc.enhance() } }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.rectangle")
                if !compact { Text(doc.resolvedTemplate.name).lineLimit(1) }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 0 : 12)
            .frame(width: compact ? 32 : nil, height: 32)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(compact ? "Template: \(doc.resolvedTemplate.name)" : "Template")
    }

    private func item(_ title: String, _ name: String) -> some View {
        Button {
            if live { doc.template = name } else { Task { await doc.enhance(name) } }
        } label: {
            if doc.template == name { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// What's being said, one line at the bottom of the notepad; click it for the whole transcript.
private struct LiveCaption: View {
    let recorder: MeetingRecorder
    let open: () -> Void

    var body: some View {
        let text = [recorder.volatileOthers, recorder.volatileMe, recorder.lines.last?.text ?? ""].first { !$0.isEmpty } ?? ""
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ChatLayout.tint)
                    .symbolEffect(.variableColor.iterative, isActive: recorder.phase == .recording)
                Text(text.isEmpty ? (recorder.phase == .paused ? "Paused" : "Listening") : text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Transcript")
    }
}

/// Who said what, when: each line under its speaker's tag (click it to fix the name), still-being-said text dimmer.
struct TranscriptView: View {
    let doc: MeetingDoc
    var volatileMe = ""
    var volatileOthers = ""
    var query = ""
    var follow = false
    let bottom: CGFloat

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(doc.lines.filter { q.isEmpty || $0.text.localizedCaseInsensitiveContains(q) }) { l in
                        block(doc.label(l), me: l.me, l.text, at: l.at, live: false)
                    }
                    if !volatileOthers.isEmpty { block(doc.othersName ?? "Others", me: false, volatileOthers, at: nil, live: true) }
                    if !volatileMe.isEmpty { block(doc.meName, me: true, volatileMe, at: nil, live: true) }
                    if doc.lines.isEmpty, volatileMe.isEmpty, volatileOthers.isEmpty {
                        Text(follow ? "Listening" : "Nothing was transcribed").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, PanelLayout.inset)
                .padding(.bottom, bottom)
            }
            .onAppear { if follow { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: doc.lines.count) { _, _ in if follow { withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) } } }
            .onChange(of: volatileMe + volatileOthers) { _, _ in if follow { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    private func block(_ name: String, me: Bool, _ text: String, at: TimeInterval?, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SpeakerTag(doc: doc, name: name, me: me)
                if let at { Text(MeetingDoc.clock(at)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary) }
            }
            Text(text)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(live ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A speaker's name as a tag. Click it to fix the name: every line they said, the notes and the file change with it.
struct SpeakerTag: View {
    let doc: MeetingDoc
    let name: String
    let me: Bool
    @State private var editing = false
    @State private var draft = ""
    @State private var hover = false
    @FocusState private var focused: Bool

    /// Me in green, Others grey, each named person a colour of their own.
    static func color(_ name: String, me: Bool) -> Color {
        if me { return ChatLayout.tint }
        if name == "Others" { return .secondary }
        let palette: [Color] = [Color(red: 0.45, green: 0.62, blue: 1), Color(red: 1, green: 0.62, blue: 0.35), Color(red: 0.74, green: 0.56, blue: 1),
                                Color(red: 1, green: 0.5, blue: 0.68), Color(red: 0.36, green: 0.8, blue: 0.86), Color(red: 0.92, green: 0.78, blue: 0.36)]
        let hash = name.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0xFFFFFF }
        return palette[hash % palette.count]
    }

    var body: some View {
        let tint = Self.color(name, me: me)
        Group {
            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, on in if !on { commit() } }
                    .frame(width: max(64, CGFloat(draft.count) * 7 + 16))
                    .onAppear {
                        draft = name
                        focused = true
                    }
            } else {
                Button { editing = true } label: { Text(name).lineLimit(1) }
                    .buttonStyle(.plain)
                    .help("Rename")
            }
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(tint.opacity(hover || editing ? 0.24 : 0.14)))
        .contentShape(Capsule())
        .onHover { hover = $0 }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        doc.rename(name, to: draft)
    }
}

/// Copy the notes, the transcript or both (rich text for Mail and Docs, Markdown for the rest).
struct CopyMenu: View {
    let doc: MeetingDoc

    var body: some View {
        Menu {
            Button("Copy Notes") { doc.copy(.notes) }
            Button("Copy Transcript") { doc.copy(.transcript) }
            Button("Copy Everything") { doc.copy(.all) }
        } label: {
            MeetingIcon(symbol: "doc.on.doc")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy")
    }
}

/// The saved file through the system's share menu (Mail, Messages, Notes, AirDrop).
struct ShareButton: View {
    let url: URL

    var body: some View {
        ShareLink(item: url) { MeetingIcon(symbol: "square.and.arrow.up") }
            .buttonStyle(.plain)
            .help("Share")
    }
}

/// A 32 pt round icon, for buttons and menus in the meeting bars.
struct MeetingIcon: View {
    let symbol: String
    var tint: Color? = nil
    @State private var hover = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tint ?? .primary)
            .frame(width: 32, height: 32)
            .background(Circle().fill((tint ?? .primary).opacity(hover ? 0.2 : 0.1)))
            .contentShape(Circle())
            .onHover { hover = $0 }
    }
}
