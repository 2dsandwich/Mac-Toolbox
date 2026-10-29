import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI

/// Live help during a meeting (in the spirit of Cluely): what to say next, a recap, follow-up questions,
/// explanations of terms, and free questions about the meeting, optionally looking at the screen too.
@MainActor @Observable final class MeetingCopilot {
    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var failed = false
    }

    enum Quick: String, CaseIterable, Identifiable {
        case say, recap, followUps, explain
        var id: String { rawValue }
        var title: String {
            switch self {
            case .say: "What should I say?"
            case .recap: "Recap"
            case .followUps: "Follow-ups"
            case .explain: "Explain terms"
            }
        }
        var symbol: String {
            switch self {
            case .say: "bubble.left.and.text.bubble.right"
            case .recap: "list.bullet.rectangle"
            case .followUps: "questionmark.bubble"
            case .explain: "book"
            }
        }
        var prompt: String {
            switch self {
            case .say: "What should I say next? If Others just asked me something, give one direct answer I can say out loud, in a sentence or two."
            case .recap: "Recap the meeting so far in at most three short bullets."
            case .followUps: "Give two sharp follow-up questions I could ask right now, one line each."
            case .explain: "Explain the one or two terms or names from the last few minutes I'm most likely not to know, one line each."
            }
        }
    }

    var exchanges: [Exchange] = []
    var useScreen = false
    var busy = false

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let meeting: MeetingRecorder?
    /// A saved meeting's notes and transcript, when chatting about one after the fact.
    @ObservationIgnored private let saved: String?

    /// A meeting that's still going ("What should I say?" only makes sense then).
    var isLive: Bool { meeting?.isRunning ?? false }

    init(store: Store, meeting: MeetingRecorder) {
        self.store = store
        self.meeting = meeting
        saved = nil
    }

    init(store: Store, savedMeeting text: String) {
        self.store = store
        meeting = nil
        saved = text
    }

    func reset() { exchanges = [] }

    func run(_ q: Quick) { ask(q.title, instruction: q.prompt) }

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
        let transcript = String((meeting?.transcript ?? saved ?? "").suffix(min(60_000, AI.budget(.meetingChat, store.settings))))
        let live = meeting.map { m in
            [m.volatileOthers.isEmpty ? nil : "**Others** (still speaking): \(m.volatileOthers)",
             m.volatileMe.isEmpty ? nil : "**Me** (still speaking): \(m.volatileMe)"].compactMap { $0 }.joined(separator: "\n")
        } ?? ""
        let savedNote = saved == nil ? "" : "This meeting is over; you are answering questions about it afterwards from its saved notes and transcript. "
        let withScreen = useScreen
        Task {
            let shot = withScreen ? await Self.screenshot() : nil
            let system = """
            You are a meeting copilot for the user ("Me"). "Others" is everyone else on the call, mixed into one voice. \(savedNote)\
            The transcript comes from speech recognition and has errors: infer what was meant, never invent facts. \
            Keep every answer short enough to glance at mid-conversation: one to three sentences, or at most three short bullets. \
            No headings, no preamble, no restating the question. \
            Answer in the language the user asks in (Japanese question, Japanese answer). \
            \(shot != nil ? "A screenshot of the user's screen is attached; use it when it helps." : "")
            """
            var user = (saved == nil ? "Meeting transcript so far:\n\n" : "Saved meeting:\n\n") + (transcript.isEmpty ? "(nothing transcribed yet)" : transcript)
            if !live.isEmpty { user += "\n\n" + live }
            user += "\n\n---\n\n" + (instruction ?? "My question: \(q)")
            do {
                let answer = try await AI.complete(.meetingChat, system: system, user: user, imageJPEG: shot)
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
        panel = CopilotPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 560), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 340, height: 320)
        panel.setFrameAutosaveName("MoneyMeetingCopilot")
        let panelRef = panel
        let view = FirstMouseHostingView(rootView: CopilotView(meeting: meeting, copilot: copilot, store: store, hide: { [weak self] in self?.hide() },
                                                               window: { [weak panelRef] in panelRef }))
        view.sizingOptions = []
        panel.contentView = view
        if panel.frame.origin == .zero, let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - 420, y: vf.maxY - 600))
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

private struct CopilotView: View {
    let meeting: MeetingRecorder
    let copilot: MeetingCopilot
    let store: Store
    let hide: () -> Void
    let window: () -> NSWindow?

    @AppStorage("copilotSplit") private var split = 0.45

    var body: some View {
        VStack(spacing: 0) {
            header
            if meeting.phase == .done {
                transcript
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .bottomTrailing) { ExpandingChat(copilot: copilot, title: "Ask about this meeting") }
            } else {
                GeometryReader { geo in
                    let h = geo.size.height
                    VStack(spacing: 0) {
                        transcript.frame(height: max(60, (h - 10) * split))
                        SplitHandle(fraction: $split, total: h)
                        assistant.frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: ChatLayout.windowRadius, style: .continuous).fill(.clear)
                .glassEffect(.regular.tint(Color.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: ChatLayout.windowRadius, style: .continuous))
            RoundedRectangle(cornerRadius: ChatLayout.windowRadius, style: .continuous).fill(Color.black.opacity(store.settings.darkness * 0.8))
        }
        .clipShape(RoundedRectangle(cornerRadius: ChatLayout.windowRadius, style: .continuous))
        .overlay { ResizeEdges(window: window) }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            PulsingDot(active: meeting.phase == .recording)
            TextField(title, text: Binding(get: { meeting.name }, set: { meeting.name = $0 }), prompt: Text("Name this meeting"))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: 170)
            Text(meeting.clock).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            audioMenu
            if meeting.isRunning {
                small(meeting.phase == .paused ? "play.fill" : "pause.fill", meeting.phase == .paused ? "Resume" : "Pause") { meeting.togglePause() }
                small("stop.fill", "Stop and write notes", tint: .red) { meeting.stop() }
            } else if meeting.phase != .summarizing {
                small("record.circle", "New meeting", tint: .red) {
                    copilot.reset()
                    meeting.reset()
                    meeting.start()
                }
            }
            small("minus", "Hide (⌘\\)") { hide() }
        }
        .padding(.horizontal, ChatLayout.inset + 4)
        .frame(height: 48)
        .contentShape(Rectangle())
        .modifier(WindowMove(window: window))
        .help("Drag to move")
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
                Image(systemName: meeting.micOn ? "mic.fill" : "mic.slash.fill").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(meeting.micOn ? Color.primary : Color.red)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                // Live input level, so you can see the mic is picking you up.
                Capsule().fill(Color.green.opacity(0.8))
                    .frame(width: 16 * CGFloat(meeting.micOn && meeting.isRunning ? meeting.micLevel : 0), height: 2)
                    .padding(.bottom, 5)
                    .animation(.linear(duration: 0.08), value: meeting.micLevel)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Microphone and sound")
    }

    private var title: String {
        switch meeting.phase {
        case .recording: "Meeting"
        case .paused: "Paused"
        case .summarizing: "Writing notes…"
        case .done: "Meeting notes"
        default: "Meeting"
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if meeting.phase == .done, !meeting.summary.isEmpty {
                        NotesView(markdown: meeting.summary)
                    } else {
                        if meeting.lines.isEmpty, meeting.volatileMe.isEmpty, meeting.volatileOthers.isEmpty {
                            Text(meeting.isRunning ? "Listening…" : "No meeting running.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        }
                        ForEach(meeting.lines.suffix(80)) { l in line(l.me, l.text, live: false) }
                        if !meeting.volatileOthers.isEmpty { line(false, meeting.volatileOthers, live: true) }
                        if !meeting.volatileMe.isEmpty { line(true, meeting.volatileMe, live: true) }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(ChatLayout.inset)
            }
            .onChange(of: meeting.lines.count) { _, _ in withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: meeting.volatileOthers + meeting.volatileMe) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func line(_ me: Bool, _ text: String, live: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(me ? "Me" : "Others").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(me ? ChatLayout.tint : .secondary)
                .frame(width: 40, alignment: .leading)
            Text(text).font(.system(size: 12.5)).foregroundStyle(live ? .secondary : .primary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var assistant: some View { MeetingChat(copilot: copilot) }

    private func small(_ symbol: String, _ help: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
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
            grip(.left).frame(width: t).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.top, 48)
            grip(.right).frame(width: t).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.top, 48)
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

/// One inset inside the meeting window; the message box is a capsule, and the window's corners are its radius plus
/// the inset, so the curves are concentric.
enum ChatLayout {
    static let inset: CGFloat = 12
    static let fieldHeight: CGFloat = 40
    static var windowRadius: CGFloat { fieldHeight / 2 + inset }
    /// The chat's colour (MONEY! green rather than the system blue).
    static let tint = Color(red: 0.18, green: 0.72, blue: 0.45)
}

/// The bar between the transcript and the chat: drag it to give either more room.
private struct SplitHandle: View {
    @Binding var fraction: Double
    let total: CGFloat
    @State private var start: (fraction: Double, mouse: CGFloat)?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 36, height: 4)
        }
        .frame(height: 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { $0 ? NSCursor.resizeUpDown.set() : NSCursor.arrow.set() }
        .gesture(
            // Screen coordinates: the handle itself moves while dragging, so measuring from it made the split shake.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in
                    let y = NSEvent.mouseLocation.y
                    if start == nil { start = (fraction, y) }
                    guard let s = start, total > 20 else { return }
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { fraction = min(0.85, max(0.12, s.fraction + (s.mouse - y) / total)) }
                }
                .onEnded { _ in start = nil }
        )
    }
}

/// Chat about a meeting (live in the floating window, or a saved one in the popup).
struct MeetingChat: View {
    let copilot: MeetingCopilot
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(copilot.exchanges) { ex in
                            VStack(spacing: 6) {
                                HStack {
                                    Spacer(minLength: 40)
                                    Text(ex.question)
                                        .font(.system(size: 13))
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ChatLayout.tint.opacity(0.9)))
                                        .foregroundStyle(.white)
                                }
                                HStack {
                                    Group {
                                        if let a = ex.answer {
                                            NotesView(markdown: a).foregroundStyle(ex.failed ? Color.orange : .primary)
                                        } else {
                                            ThinkingDots().foregroundStyle(.secondary).frame(height: 18)
                                        }
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.09)))
                                    Spacer(minLength: 40)
                                }
                            }
                            .id(ex.id)
                        }
                        Color.clear.frame(height: 1).id("chatEnd")
                    }
                    .padding(.horizontal, ChatLayout.inset)
                    .padding(.top, 8)
                }
                .onChange(of: copilot.exchanges.count) { _, _ in withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo("chatEnd", anchor: .bottom) } }
                .onChange(of: copilot.exchanges.last?.answer) { _, _ in withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo("chatEnd", anchor: .bottom) } }
            }
            // Suggestions sit above the message box.
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(MeetingCopilot.Quick.allCases.filter { copilot.isLive || $0 != .say }) { q in
                        SuggestionChip(title: q.title, on: false) { copilot.run(q) }
                    }
                    if copilot.isLive {
                        SuggestionChip(title: "Screen", on: copilot.useScreen) { copilot.useScreen.toggle() }
                            .help("Let answers look at your screen")
                    }
                }
                .padding(.horizontal, ChatLayout.inset)
            }
            .scrollIndicators(.never)
            .disabled(copilot.busy)
            HStack(spacing: 8) {
                TextField("Message", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(send)
                // Only once something is typed (or while an answer is coming).
                if copilot.busy || !question.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: send) {
                        Image(systemName: copilot.busy ? "ellipsis" : "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: ChatLayout.fieldHeight - 12, height: ChatLayout.fieldHeight - 12)
                            .background(Circle().fill(ChatLayout.tint))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .padding(.leading, ChatLayout.fieldHeight / 2)
            .padding(.trailing, 6)
            .frame(height: ChatLayout.fieldHeight)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .animation(.spring(duration: 0.25, bounce: 0.3), value: copilot.busy || !question.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.horizontal, ChatLayout.inset)
            .padding(.bottom, ChatLayout.inset)
        }
    }

    /// Return (or ⌘↩) sends the question; ⌘↩ with nothing typed asks what to say next.
    private func send() {
        let q = question.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { copilot.run(copilot.isLive ? .say : .recap) } else { copilot.ask(q) }
        question = ""
    }

}

private struct SuggestionChip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Color.white : Color.primary.opacity(0.85))
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(Capsule().fill(on ? ChatLayout.tint.opacity(0.85) : Color.white.opacity(hover ? 0.14 : 0.08)))
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
    @State private var open = false
    @AppStorage("meetingChatWidth") private var width = 360.0
    @AppStorage("meetingChatHeight") private var height = 400.0
    @State private var resizeStart: (mouse: NSPoint, size: CGSize)?

    private var radius: CGFloat { max(8, outerRadius - inset) }
    private var buttonSize: CGFloat { max(40, min(52, radius * 2)) }
    /// The close button sits in the corner, concentric with it.
    private static let closeInset: CGFloat = 8
    private var closeSize: CGFloat { max(20, (radius - Self.closeInset) * 2) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let w = open ? CGFloat(width) : buttonSize, h = open ? CGFloat(height) : buttonSize
        // One shape that changes size: the button itself opens into the chat.
        ZStack(alignment: .topLeading) {
            if open {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Button { open = false } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .frame(width: closeSize, height: closeSize)
                                .background(Circle().fill(Color.white.opacity(0.12)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Close")
                    }
                    .padding(.leading, radius)
                    .padding(.trailing, Self.closeInset)
                    .padding(.top, Self.closeInset)
                    .frame(height: closeSize + Self.closeInset * 2, alignment: .top)
                    MeetingChat(copilot: copilot)
                }
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
                shape.fill(Color.black.opacity(open ? 0.45 : 0))
            }
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(open ? 0.35 : 0.25), radius: open ? 24 : 12, y: open ? 10 : 5)
        .padding(inset)
        .animation(.spring(duration: 0.45, bounce: 0.18), value: open)
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
