import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI

/// Chat about meetings: live help during one (what did I miss, what to say), prompts for one that ended
/// (follow-up email, action items), and questions across every saved meeting.
@MainActor @Observable final class MeetingCopilot {
    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var failed = false
    }

    /// A prebuilt prompt: its chip's title and what it asks.
    struct Recipe: Identifiable {
        let title: String
        let prompt: String
        var id: String { title }
    }

    enum Source {
        case live(MeetingRecorder)
        case doc(MeetingDoc)
        case all([MeetingRecorder.Past])
    }

    var exchanges: [Exchange] = []
    var useScreen = false
    var busy = false

    @ObservationIgnored private let store: Store
    @ObservationIgnored let source: Source

    init(store: Store, source: Source) {
        self.store = store
        self.source = source
    }

    /// A meeting that's still going ("What should I say?" only makes sense then).
    var isLive: Bool {
        if case .live(let m) = source { return m.isRunning }
        return false
    }

    var title: String {
        if case .all = source { return "Ask about all meetings" }
        return "Ask about this meeting"
    }

    var recipes: [Recipe] {
        if isLive {
            return [Recipe(title: "What did I miss?", prompt: "What did I miss in the last few minutes? At most three short bullets."),
                    Recipe(title: "What should I say?", prompt: "What should I say next? If Others just asked me something, give one direct answer I can say out loud, in a sentence or two."),
                    Recipe(title: "Follow-up questions", prompt: "Give two sharp follow-up questions I could ask right now, one line each."),
                    Recipe(title: "Explain terms", prompt: "Explain the one or two terms or names from the last few minutes I'm most likely not to know, one line each.")]
        }
        if case .all = source {
            var next = "my next meeting"
            if let e = CalendarEvents.shared.events.first(where: { $0.start > Date() }) {
                next = "\"\(e.title)\" at \(e.start.formatted(date: .omitted, time: .shortened))" + (e.attendees.isEmpty ? "" : " with \(e.attendees.joined(separator: ", "))")
            }
            return [Recipe(title: "What did I promise?", prompt: "What did I (Me) promise to do in these meetings? A checklist, newest first, each with the meeting's name and date."),
                    Recipe(title: "Open action items", prompt: "List the action items that are still open, grouped by owner, each with the meeting's name and date."),
                    Recipe(title: "Recurring topics", prompt: "Which topics, problems or objections keep coming up across meetings? Short bullets with the meetings they came up in."),
                    Recipe(title: "Prep my next meeting", prompt: "Brief me for \(next): what we discussed last time with these people or on this topic, what was promised, and what is still open. Three to six bullets.")]
        }
        return [Recipe(title: "Follow-up email", prompt: "Write the follow-up email I should send after this meeting: a subject line, a short thank-you, the decisions, who does what by when, and the next step. Plain and friendly, ready to send, in the meeting's language. No placeholders such as [Your name]; end with a short sign-off and no name."),
                Recipe(title: "Action items", prompt: "List every action item as a checklist: \"- [ ] Owner: task (when)\". Use Me for me, names where the transcript gives them."),
                Recipe(title: "Decisions", prompt: "List the decisions that were made, one bullet each, with the reason when it was said."),
                Recipe(title: "Open questions", prompt: "List the questions that were left open or need an answer later."),
                Recipe(title: "Client update", prompt: "Rewrite this meeting as a short update for someone who wasn't there: three to five bullets, then next steps.")]
    }

    func reset() { exchanges = [] }

    func run(_ r: Recipe) { ask(r.title, instruction: r.prompt) }

    func ask(_ question: String, instruction: String? = nil) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        if let why = AI.problem(.meetingChat, store.settings) {
            exchanges.append(Exchange(question: q, answer: why, failed: true))
            return
        }
        exchanges.append(Exchange(question: q))
        let index = exchanges.count - 1
        busy = true
        let budget = min(120_000, AI.budget(.meetingChat, store.settings))
        let context: String
        var about = ""
        switch source {
        case .live(let m) where !m.isRunning:
            about = "This meeting just ended; you answer from its notes and transcript."
            context = String(m.doc.markdown.prefix(budget))
        case .live(let m):
            about = "The meeting is still going."
            var t = "Meeting: \(m.doc.displayTitle)\n\nMy notes so far:\n\(m.doc.myNotes.isEmpty ? "(none)" : m.doc.myNotes)\n\nTranscript:\n\n"
            t += String(m.transcript.suffix(budget))
            let live = [m.volatileOthers.isEmpty ? nil : "**Others** (still speaking): \(m.volatileOthers)",
                        m.volatileMe.isEmpty ? nil : "**Me** (still speaking): \(m.volatileMe)"].compactMap { $0 }.joined(separator: "\n")
            context = live.isEmpty ? t : t + "\n" + live
        case .doc(let d):
            about = "This meeting is over; you answer from its saved notes and transcript."
            context = String(d.markdown.prefix(budget))
        case .all(let list):
            about = "You answer from the user's saved meetings (newest first). Name the meeting and date for each point you use."
            var t = ""
            for p in list {
                let block = "=== \(p.title) (\(p.date.formatted(date: .abbreviated, time: .shortened)))\n\(p.text)\n\n"
                if t.count + block.count > budget { break }
                t += block
            }
            context = t.isEmpty ? "(no saved meetings)" : t
        }
        let live = isLive
        let withScreen = useScreen && live
        let length = live
            ? "Keep every answer short enough to glance at mid-conversation: one to three sentences, or at most three short bullets."
            : "Be complete but brief. Use Markdown bullets or checkboxes where they help."
        Task {
            let shot = withScreen ? await Self.screenshot() : nil
            let system = """
            You help the user ("Me") with their meetings. Other speakers are labelled by name when known; "Others" is everyone else \
            on a call, mixed into one voice. \(about) \
            Transcripts come from speech recognition and have errors: infer what was meant, never invent facts. \
            \(length) No headings, no preamble, no restating the question, no em dashes. \
            Answer in the language the user asks in (Japanese question, Japanese answer). \
            \(shot != nil ? "A screenshot of the user's screen is attached; use it when it helps." : "")
            """
            let user = context + "\n\n---\n\n" + (instruction ?? "My question: \(q)")
            do {
                // Streamed, so the answer fades in as it comes (a screenshot needs the one-shot call).
                let answer = shot == nil
                    ? try await AI.stream(.meetingChat, system: system, user: user) { partial in
                        if self.exchanges.indices.contains(index) { self.exchanges[index].answer = partial }
                    }
                    : try await AI.complete(.meetingChat, system: system, user: user, imageJPEG: shot)
                if exchanges.indices.contains(index) { exchanges[index].answer = answer }
            } catch {
                if exchanges.indices.contains(index) {
                    exchanges[index].answer = error.localizedDescription
                    exchanges[index].failed = true
                }
            }
            busy = false
        }
    }

    /// The main screen without Halo's own windows, shrunk for the API.
    static func screenshot() async -> Data? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else { return nil }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let cfg = SCStreamConfiguration()
        let scale = min(1, 1568 / Double(max(display.width, display.height)))
        cfg.width = Int(Double(display.width) * scale * 2)
        cfg.height = Int(Double(display.height) * scale * 2)
        cfg.showsCursor = false
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []),
                                                                    configuration: cfg) else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}

// MARK: - Floating window

/// Stays above other apps (clicking elsewhere doesn't bury it), never steals focus from the call,
/// and is left out of screen sharing and recordings.
@MainActor final class CopilotWindow {
    private let panel: NSPanel
    private let store: Store
    private(set) var isVisible = false

    init(store: Store, meeting: MeetingRecorder, copilot: MeetingCopilot) {
        self.store = store
        panel = CopilotPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 620), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 380, height: 420)
        panel.setFrameAutosaveName("MoneyMeetingCopilot")
        let panelRef = panel
        let view = FirstMouseHostingView(rootView: CopilotView(meeting: meeting, copilot: copilot, store: store, hide: { [weak self] in self?.hide() },
                                                               window: { [weak panelRef] in panelRef }))
        view.sizingOptions = []
        panel.contentView = view
        if panel.frame.origin == .zero, let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - 460, y: vf.maxY - 660))
        }
        applyPrivacy()
    }

    func applyPrivacy() {
        panel.sharingType = store.settings.hideFromScreenShare ? .none : .readOnly
    }

    func show() {
        applyPrivacy()
        isVisible = true
        panel.orderFrontRegardless()
    }

    func hide() {
        isVisible = false
        panel.orderOut(nil)
    }

    func toggle() { isVisible ? hide() : show() }
}

private final class CopilotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The floating meeting window: a bar (recording state and controls), then the meeting as a document.
struct CopilotView: View {
    let meeting: MeetingRecorder
    let copilot: MeetingCopilot
    let store: Store
    let hide: () -> Void
    let window: () -> NSWindow?
    /// Off-screen snapshots: a solid background instead of glass, and where to start.
    var opaque = false
    var tab = PageTab.notes
    var chatOpen = false
    var editing = false

    private let inset = PanelLayout.inset

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChatLayout.windowRadius, style: .continuous)
        VStack(spacing: 0) {
            header
            switch meeting.phase {
            case .idle, .failed:
                idle
            default:
                MeetingPage(doc: meeting.doc, recorder: meeting, chat: copilot, outerRadius: ChatLayout.windowRadius, tab: tab, chatOpen: chatOpen,
                            editing: editing)
                    .id(meeting.doc.id)
            }
        }
        .background {
            if opaque {
                shape.fill(Color(white: 0.11))
            } else {
                shape.fill(.clear).glassEffect(.regular.tint(Color.black.opacity(0.35)), in: shape)
                shape.fill(Color.black.opacity(store.settings.darkness * 0.8))
            }
        }
        .clipShape(shape)
        .overlay { ResizeEdges(window: window) }
        .environment(\.colorScheme, .dark)
    }

    /// Recording: the clock, language, sound, pause and stop. Ended: copy, share, a new meeting. Always: hide.
    private var header: some View {
        HStack(spacing: PanelLayout.gap) {
            switch meeting.phase {
            case .recording, .paused:
                PulsingDot(active: meeting.phase == .recording)
                Text(meeting.clock).font(.system(size: 13, weight: .semibold).monospacedDigit())
                Spacer(minLength: 0)
                LanguageToggle(meeting: meeting)
                audioMenu
                button(meeting.phase == .paused ? "play.fill" : "pause.fill", meeting.phase == .paused ? "Resume" : "Pause") { meeting.togglePause() }
                button("stop.fill", "Stop and write notes", tint: .red) { meeting.stop() }
            case .summarizing:
                Text("Writing notes").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                ThinkingDots().foregroundStyle(.secondary)
                Spacer(minLength: 0)
            case .done:
                Spacer(minLength: 0)
                CopyMenu(doc: meeting.doc)
                ShareButton(url: meeting.doc.url)
                button("folder", "Show in Finder") { meeting.showInFinder(meeting.doc.url) }
                button("record.circle", "New meeting", tint: .red) { newMeeting() }
            case .idle, .failed:
                Spacer(minLength: 0)
            }
            button("minus", "Hide (⌘\\)") { hide() }
        }
        .padding(inset)
        .contentShape(Rectangle())
        .modifier(WindowMove(window: window))
    }

    /// Nothing recording: start one (named after the calendar event on now, if there is one).
    private var idle: some View {
        VStack(spacing: 12) {
            if case .failed(let why) = meeting.phase {
                Text(why).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let e = CalendarEvents.shared.current() {
                Text(e.title).font(.system(size: 17, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
            }
            PillButton(title: "Start Recording", symbol: "record.circle", tint: .red) { newMeeting() }
        }
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func newMeeting() {
        copilot.reset()
        meeting.reset()
        meeting.start()
    }

    /// Which microphone, and whether each side is transcribed.
    private var audioMenu: some View {
        Menu {
            Section("Microphone") {
                Picker("Microphone", selection: Binding(get: { store.settings.meetingMicUID }, set: { meeting.useMic($0) })) {
                    Text("System default").tag("")
                    ForEach(MicCapture.inputDevices(), id: \.uid) { d in Text(d.name).tag(d.uid) }
                }
                .pickerStyle(.inline)
            }
            Section("Transcribe") {
                Toggle("Me (microphone)", isOn: Binding(get: { meeting.micOn }, set: { meeting.micOn = $0 }))
                Toggle("Others (the Mac’s sound)", isOn: Binding(get: { meeting.computerOn }, set: { meeting.setComputerAudio($0) }))
            }
        } label: {
            ZStack(alignment: .bottom) {
                MeetingIcon(symbol: meeting.micOn ? "mic.fill" : "mic.slash.fill", tint: meeting.micOn ? nil : .red)
                // Live input level, so you can see the mic is picking you up.
                Capsule().fill(ChatLayout.tint)
                    .frame(width: 16 * CGFloat(meeting.micOn && meeting.isRunning ? meeting.micLevel : 0), height: 2)
                    .padding(.bottom, 6)
                    .animation(.linear(duration: 0.08), value: meeting.micLevel)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Microphone and sound")
    }

    private func button(_ symbol: String, _ help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { MeetingIcon(symbol: symbol, tint: tint) }
            .buttonStyle(.plain)
            .help(help)
    }
}

// MARK: - Moving and resizing a borderless window from SwiftUI

/// Drags the window by its header. Uses the mouse's screen position, so moving the window mid-drag doesn't jitter.
private struct WindowMove: ViewModifier {
    let window: () -> NSWindow?
    @State private var start: (mouse: NSPoint, origin: NSPoint)?

    func body(content: Content) -> some View {
        content.gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { _ in
                guard let w = window() else { return }
                let m = NSEvent.mouseLocation
                if start == nil { start = (m, w.frame.origin) }
                guard let s = start else { return }
                w.setFrameOrigin(NSPoint(x: s.origin.x + m.x - s.mouse.x, y: s.origin.y + m.y - s.mouse.y))
            }
            .onEnded { _ in start = nil })
    }
}

/// Invisible grips on the left, right and bottom edges and the bottom corners.
private struct ResizeEdges: View {
    let window: () -> NSWindow?
    private let t: CGFloat = 7

    var body: some View {
        ZStack {
            grip(.left).frame(width: t).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.top, 64)
            grip(.right).frame(width: t).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.top, 64)
            grip(.bottom).frame(height: t).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            grip(.bottomLeft).frame(width: 16, height: 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            grip(.bottomRight).frame(width: 16, height: 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private func grip(_ edge: ResizeGrip.Edge) -> some View { ResizeGrip(edge: edge, window: window) }
}

private struct ResizeGrip: View {
    enum Edge { case left, right, bottom, bottomLeft, bottomRight }
    let edge: Edge
    let window: () -> NSWindow?
    @State private var start: (mouse: NSPoint, frame: NSRect)?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside else { return NSCursor.arrow.set() }
                switch edge {
                case .left, .right: NSCursor.resizeLeftRight.set()
                case .bottom: NSCursor.resizeUpDown.set()
                case .bottomLeft: NSCursor.frameResize(position: .bottomLeft, directions: .all).set()
                case .bottomRight: NSCursor.frameResize(position: .bottomRight, directions: .all).set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in
                        guard let w = window() else { return }
                        let m = NSEvent.mouseLocation
                        if start == nil { start = (m, w.frame) }
                        guard let s = start else { return }
                        let dx = m.x - s.mouse.x, dy = m.y - s.mouse.y
                        let minW = w.minSize.width, minH = w.minSize.height
                        var f = s.frame
                        if edge == .right || edge == .bottomRight { f.size.width = max(minW, s.frame.width + dx) }
                        if edge == .left || edge == .bottomLeft {
                            let width = max(minW, s.frame.width - dx)
                            f.origin.x = s.frame.maxX - width
                            f.size.width = width
                        }
                        if edge == .bottom || edge == .bottomLeft || edge == .bottomRight {
                            let height = max(minH, s.frame.height - dy)
                            f.origin.y = s.frame.maxY - height
                            f.size.height = height
                        }
                        w.setFrame(f, display: true)
                    }
                    .onEnded { _ in start = nil }
            )
    }
}

/// One inset inside the meeting window; the window's corners are its buttons' radius plus the inset, so the curves are
/// concentric.
enum ChatLayout {
    static let inset: CGFloat = PanelLayout.inset
    /// Concentric with the bar's 32 pt round buttons, one inset in.
    static var windowRadius: CGFloat { 16 + inset }
    /// The chat's colour (MONEY! green rather than the system blue).
    static let tint = Color(red: 0.18, green: 0.72, blue: 0.45)
}

/// Chat about a meeting, laid out like Ask: the message field on top, the prompts under it, then the thread with the
/// newest exchange first (your message a grey bubble on the right, the answer plain text that fades in). In a side
/// panel the field sits where Ask's bar is, so the newest answer is always right under where you typed.
struct MeetingChat: View {
    let copilot: MeetingCopilot
    let placeholder: String
    /// The close button's size and its distance from the panel's corner (concentric with it).
    var closeSize: CGFloat = 20
    var closeInset: CGFloat = 8
    let close: () -> Void
    @State private var question = ""
    @FocusState private var focused: Bool

    private var typed: Bool { !question.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PanelLayout.gap) {
                TextField(placeholder, text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($focused)
                    .onSubmit(send)
                if copilot.busy || typed {
                    Button(action: send) {
                        Image(systemName: copilot.busy ? "ellipsis" : "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: closeSize, height: closeSize)
                            .background(Circle().fill(ChatLayout.tint))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: closeSize, height: closeSize)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .animation(.spring(duration: 0.25, bounce: 0.3), value: copilot.busy || typed)
            .padding(.leading, PanelLayout.inset)
            .padding(.trailing, closeInset)
            .frame(height: closeSize + closeInset * 2)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(copilot.recipes) { r in PromptChip(title: r.title, on: false) { copilot.run(r) } }
                    if copilot.isLive {
                        PromptChip(title: "Screen", on: copilot.useScreen) { copilot.useScreen.toggle() }
                            .help("Let answers look at your screen")
                    }
                }
                .padding(.horizontal, PanelLayout.inset)
            }
            .scrollIndicators(.never)
            .disabled(copilot.busy)
            .padding(.top, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(copilot.exchanges.reversed()) { ex in
                            ChatTurn(exchange: ex, busy: copilot.busy && ex.id == copilot.exchanges.last?.id)
                                .transition(.opacity)
                        }
                    }
                    .padding(PanelLayout.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("thread")
                }
                .scrollIndicators(.never)
                // A new question goes to the top: show it there.
                .onChange(of: copilot.exchanges.count) { _, _ in proxy.scrollTo("thread", anchor: .top) }
            }
            .animation(AssistantView.animates ? .smooth(duration: 0.3) : nil, value: copilot.exchanges.count)
        }
        .onAppear { focused = true }
    }

    /// Return (or ⌘↩) sends the question; ⌘↩ with nothing typed runs the first prompt.
    private func send() {
        let q = question.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { if let r = copilot.recipes.first { copilot.run(r) } } else { copilot.ask(q) }
        question = ""
    }
}

/// One exchange, as in Ask: the question as a bubble, then the answer, which dissolves in as it arrives.
private struct ChatTurn: View {
    let exchange: MeetingCopilot.Exchange
    let busy: Bool
    /// How much of the answer is revealed (see `NotesView.shown`); a turn still being answered starts hidden.
    @State private var shown: Double

    init(exchange: MeetingCopilot.Exchange, busy: Bool) {
        self.exchange = exchange
        self.busy = busy
        _shown = State(initialValue: busy ? 0 : Self.full(exchange.answer ?? ""))
    }

    private static func full(_ s: String) -> Double { Double(s.count) + FadeIn.ramp }

    var body: some View {
        let answer = exchange.answer ?? ""
        VStack(alignment: .leading, spacing: 10) {
            Text(exchange.question)
                .font(.system(size: 13.5))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.primary.opacity(0.1)))
                .padding(.leading, 56)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if exchange.failed {
                Label(answer, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
            } else if !answer.isEmpty {
                NotesView(markdown: answer, spaced: true, shown: shown)
            } else {
                ThinkingDots().colorMultiply(.primary).frame(height: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: answer) { old, new in reveal(old, new) }
    }

    /// Paces the reveal: each arrival takes longer the more it brings, so bursts glide in instead of jumping.
    private func reveal(_ old: String, _ new: String) {
        guard AssistantView.animates else { shown = Self.full(new); return }
        if !new.hasPrefix(old) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { shown = 0 }
        }
        let fresh = Double(new.count - (new.hasPrefix(old) ? old.count : 0))
        withAnimation(.linear(duration: min(1.4, max(0.35, fresh / 110)))) { shown = Self.full(new) }
    }
}

/// A prebuilt prompt, styled like the app's other chips.
private struct PromptChip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(on ? ChatLayout.tint : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(on ? ChatLayout.tint.opacity(0.2) : Color.primary.opacity(hover ? 0.14 : 0.075)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A Liquid Glass button in the corner that grows into the chat (like the Moneybag browser's), for notes that keep
/// the whole space until you want to ask something. Its corners are the surrounding corner's radius minus the gap to
/// it, so the curves line up; drag its top-left corner to resize it.
struct ExpandingChat: View {
    let copilot: MeetingCopilot
    let title: String
    /// Radius of the corner it sits in, and its distance from that corner's edges.
    var outerRadius: CGFloat = ChatLayout.windowRadius
    var inset: CGFloat = ChatLayout.inset
    var startOpen = false
    @State private var open = false
    @AppStorage("meetingChatWidth") private var width = 360.0
    @AppStorage("meetingChatHeight") private var height = 400.0
    @State private var resizeStart: (mouse: NSPoint, size: CGSize)?

    private var radius: CGFloat { max(8, outerRadius - inset) }
    private var buttonSize: CGFloat { Self.buttonSize(outerRadius: outerRadius, inset: inset) }
    static func buttonSize(outerRadius: CGFloat, inset: CGFloat) -> CGFloat { max(40, min(52, max(8, outerRadius - inset) * 2)) }
    /// The close button sits in the corner, concentric with it.
    private static let closeInset: CGFloat = 8
    private var closeSize: CGFloat { max(20, (radius - Self.closeInset) * 2) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let w = open ? CGFloat(width) : buttonSize, h = open ? CGFloat(height) : buttonSize
        // One shape that changes size: the button itself opens into the chat.
        ZStack(alignment: .topLeading) {
            if open {
                MeetingChat(copilot: copilot, placeholder: title, closeSize: closeSize, closeInset: Self.closeInset) { open = false }
                    .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.12)))
                resizeGrip
            } else {
                Button { open = true } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: buttonSize, height: buttonSize)
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .help(title)
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .background {
            ZStack {
                Color.clear.glassEffect(open ? .regular : .regular.tint(ChatLayout.tint.opacity(0.6)).interactive(), in: shape)
                shape.fill(Color(white: 0.08).opacity(open ? 0.94 : 0))
            }
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(open ? 0.35 : 0.25), radius: open ? 24 : 12, y: open ? 10 : 5)
        .padding(inset)
        .animation(.spring(duration: 0.45, bounce: 0.18), value: open)
        .onAppear { if startOpen { open = true } }
    }

    /// Top-left corner: the chat is pinned bottom-right, so it grows up and to the left.
    private var resizeGrip: some View {
        Color.clear
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onHover { inside in inside ? NSCursor.frameResize(position: .topLeft, directions: .all).set() : NSCursor.arrow.set() }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in
                    let m = NSEvent.mouseLocation
                    if resizeStart == nil { resizeStart = (m, CGSize(width: width, height: height)) }
                    guard let st = resizeStart else { return }
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        width = Double(min(720, max(280, st.size.width - (m.x - st.mouse.x))))
                        height = Double(min(700, max(260, st.size.height + (m.y - st.mouse.y))))
                    }
                }
                .onEnded { _ in resizeStart = nil })
    }
}
