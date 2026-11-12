import SwiftUI

// The coding agents' views, shared by the notch and the search bar: sessions on the left (each with what it's doing
// now, its subagents folding out under it), each provider's limits and the day's tokens in its own block on the right,
// and a question or permission prompt with the question on the left and the answers stacked on the right.

/// A limit's bar with its pace tick: past the tick, it's being used faster than the window allows for.
struct LimitBar: View {
    /// White, orange from 75%, red from 90%.
    static func color(_ used: Double) -> Color { used >= 90 ? .red : used >= 75 ? .orange : .white }
    let limit: Agents.Limit
    let now: Date
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(Self.color(limit.used)).frame(width: max(height, w * min(100, limit.used) / 100))
                if let f = limit.elapsed(now) {
                    Capsule().fill(Color.white).frame(width: 2, height: height + 4)
                        .background(Capsule().fill(Color.black).frame(width: 4, height: height + 6))
                        .offset(x: min(w - 2, max(0, w * f - 1)))
                }
            }
            .frame(height: g.size.height)
        }
        .frame(height: height)
    }
}

/// What a session is doing: a spinner while it works, orange when it waits on you, a tick when it's done.
struct AgentStateIcon: View {
    let state: Agents.State
    var size: CGFloat = 14

    var body: some View {
        switch state {
        case .working: PolishSpinner(size: size, line: max(1.5, size / 7))
        case .needsYou: Image(systemName: "questionmark.bubble.fill").font(.system(size: size * 0.9, weight: .semibold)).foregroundStyle(.orange)
        case .idle: Image(systemName: "checkmark.circle.fill").font(.system(size: size * 0.9, weight: .semibold)).foregroundStyle(.green)
        }
    }
}

/// The open notch's face (and the search bar's): the question being asked, or the sessions beside the stats. It
/// reports its natural height; taller than `maxHeight`, it scrolls.
struct AgentsFace: View {
    var agents = Agents.shared
    var asks = true
    /// Its cards' corners: concentric with whatever it sits in.
    var radius = IslandView.cardRadius
    var maxHeight: CGFloat = 360
    var onHeight: (CGFloat) -> Void = { _ in }
    @State private var listHeight: CGFloat = 0
    @State private var statsHeight: CGFloat = 0
    @State private var askHeight: CGFloat = 0
    /// The session under the pointer: a session with subagents shows its fold-out arrow then.
    @State private var hovered: Agents.Session.ID?

    var body: some View {
        if asks, let q = agents.questions.first {
            ScrollView { AgentQuestion(agents: agents, q: q, radius: radius).measured { askHeight = $0 } }
                .scrollIndicators(.never)
                .frame(height: min(askHeight, maxHeight))
                .onChange(of: min(askHeight, maxHeight), initial: true) { onHeight($1) }
        } else {
            let providers = [Agents.Provider.claude, .codex].filter { agents.limits[$0] != nil || agents.tokens[$0] != nil }
            // No sessions: the blocks side by side, so one line doesn't sit in a column as tall as both.
            let none = agents.visible.isEmpty
            HStack(alignment: none ? .center : .top, spacing: 12) {
                ScrollView { list.measured { listHeight = $0 } }
                    .scrollIndicators(.never)
                    .frame(height: min(listHeight, maxHeight))
                    // More below: the last row fades out rather than being cut by the edge.
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: listHeight > maxHeight ? 0.88 : 1),
                                                 .init(color: listHeight > maxHeight ? .clear : .black, location: 1)], startPoint: .top, endPoint: .bottom))
                if !providers.isEmpty {
                    (none ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))) {
                        ForEach(providers, id: \.self) { AgentStats(agents: agents, provider: $0, radius: radius).frame(width: Self.statsWidth) }
                    }
                    .measured { statsHeight = $0 }
                }
            }
            .onChange(of: max(min(listHeight, maxHeight), providers.isEmpty ? 0 : statsHeight), initial: true) { onHeight($1) }
        }
    }

    static let statsWidth: CGFloat = 204

    private var list: some View {
        let shown = agents.visible
        return VStack(alignment: .leading, spacing: 2) {
            if shown.isEmpty {
                Text("No coding sessions").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            ForEach(shown) { row($0) }
        }
    }

    private func row(_ s: Agents.Session) -> some View {
        let open = agents.expanded.contains(s.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                // A session with subagents: hovering turns its state into the fold-out arrow (kept while open).
                if !s.subs.isEmpty, open || hovered == s.id { subsButton(s, open) } else { AgentStateIcon(state: s.shown).frame(width: 18, height: 17) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // The folder trails the title in the same text, so a long title wraps instead of cutting it.
                        let folder = s.name != s.project && !s.project.isEmpty && s.project != Self.home ? "  " + s.project.replacingOccurrences(of: "-", with: "\u{2011}") : "" // never split at its hyphen
                        Text("\(Text(s.name).foregroundStyle(.white))\(Text(folder).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4)))")
                            .font(.system(size: 13, weight: .semibold)).lineLimit(3)
                        Spacer(minLength: 4)
                        // Ticks on its own while it shows, so only this text redraws.
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(when(s.shown, s.started, s.updated, ctx.date)).font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        let working = s.subs.filter { $0.state == .working }.count
                        Text(s.waitingOnSubs ? (working == 1 ? "1 subagent working" : "\(working) subagents working") : s.detail).font(.system(size: 12)).foregroundStyle(s.state == .needsYou ? Color.orange : .white.opacity(0.62)).lineLimit(2)
                        Spacer(minLength: 0)
                        meters(s)
                    }
                    if let t = s.todo {
                        HStack(spacing: 5) {
                            Image(systemName: "checklist").font(.system(size: 9.5, weight: .semibold))
                            Text("\(t.done)/\(t.total)").monospacedDigit().fontWeight(.semibold)
                            if !t.current.isEmpty, t.current != s.detail { Text(t.current).lineLimit(1) }
                        }
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture { agents.open(s) }
            .onHover { inside in
                if inside { hovered = s.id } else if hovered == s.id { hovered = nil }
            }
            if open {
                ForEach(s.subs) { sub($0) }
                    .padding(.leading, 28)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// A session started in the home folder: its name says nothing, so it isn't shown.
    private static let home = (NSHomeDirectory() as NSString).lastPathComponent

    /// Folds its subagents out and back in, in the state icon's place.
    private func subsButton(_ s: Agents.Session, _ open: Bool) -> some View {
        Button { withAnimation(.spring(duration: 0.3, bounce: 0)) { agents.toggleSubs(s) } } label: {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(open ? 90 : 0))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 18, height: 17)
                .background(Circle().fill(Color.white.opacity(0.12)).frame(width: 20, height: 20))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide subagents" : s.subs.count == 1 ? "Show 1 subagent" : "Show \(s.subs.count) subagents")
    }

    private func sub(_ a: Agents.Sub) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AgentStateIcon(state: a.state, size: 11).frame(width: 14, height: 15)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Text(a.name).foregroundStyle(.white.opacity(0.88)))\(Text(a.kind.isEmpty ? "" : "  " + a.kind).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.4)))")
                        .font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 4)
                    if a.state == .working {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(Pomodoro.clock(ctx.date.timeIntervalSince(a.started))).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
                if !a.activity.isEmpty { Text(a.activity).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.52)).lineLimit(2) }
            }
        }
        .padding(.vertical, 3)
    }

    /// Its context, and the lines it has changed.
    private func meters(_ s: Agents.Session) -> some View {
        HStack(spacing: 8) {
            if let c = s.context {
                HStack(spacing: 4) {
                    ProgressRing(progress: c / 100, color: c >= 80 ? .orange : .white.opacity(0.7), size: 10, lineWidth: 2)
                    Text("\(Int(c.rounded()))%")
                }
                .help("Context used")
            }
            if s.added + s.removed > 0 {
                HStack(spacing: 3) {
                    Text("+\(s.added)").foregroundStyle(.green.opacity(0.85))
                    Text("−\(s.removed)").foregroundStyle(.red.opacity(0.85))
                }
                .help("Lines changed")
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.55))
        .fixedSize()
    }

    /// A working turn's running time; when it finished, otherwise.
    private func when(_ state: Agents.State, _ started: Date, _ updated: Date, _ now: Date) -> String {
        state == .idle ? updated.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) : Pomodoro.clock(now.timeIntervalSince(started))
    }
}

/// One provider's block: its 5-hour and weekly limits (when each resets, and whether it lasts until then at this pace)
/// and today's tokens.
struct AgentStats: View {
    var agents = Agents.shared
    let provider: Agents.Provider
    var radius: CGFloat = 12

    var body: some View {
        // The resets and pace move on by the minute.
        TimelineView(.everyMinute) { ctx in stats(agents.limits[provider], ctx.date) }
    }

    private func stats(_ l: Agents.Limits?, _ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(provider.color).frame(width: 7, height: 7)
                Text(provider.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
                if let t = agents.tokens[provider] {
                    Text("\(t.formatted(.number.notation(.compactName))) today").font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                }
            }
            if let f = l?.fiveHour { gauge("5h", f, now) }
            if let w = l?.week { gauge("Week", w, now) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func gauge(_ label: String, _ l: Agents.Limit, _ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).frame(width: 30, alignment: .leading)
                LimitBar(limit: l, now: now, height: 5)
                Text("\(Int(l.used.rounded()))%").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white).frame(width: 32, alignment: .trailing)
            }
            HStack(spacing: 4) {
                if let r = l.resets { Text("resets in " + Self.span(r.timeIntervalSince(now))) }
                Spacer(minLength: 0)
                if let out = l.runsOut(now) {
                    Text("runs out ~" + Self.time(out, now)).foregroundStyle(.orange)
                } else if l.resets != nil {
                    Text("lasts to reset")
                }
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
            .lineLimit(1)
        }
    }

    /// "2h 14m", "3d 4h".
    static func span(_ t: TimeInterval) -> String {
        let m = Int(max(0, t) / 60), h = m / 60, d = h / 24
        return d > 0 ? "\(d)d \(h % 24)h" : h > 0 ? "\(h)h \(m % 60)m" : "\(m)m"
    }

    /// A time today, else its weekday too.
    static func time(_ d: Date, _ now: Date) -> String {
        d.timeIntervalSince(now) < 20 * 3600 ? d.formatted(date: .omitted, time: .shortened) : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// A question or a permission prompt: what's asked on the left, the answers stacked on the right (in rows under it when
/// there are more than three).
struct AgentQuestion: View {
    var agents = Agents.shared
    let q: Agents.Question
    var radius: CGFloat = 15

    var body: some View {
        let ask = agents.step < q.asks.count ? q.asks[agents.step] : nil
        // Many answers go in rows under the question: stacked beside a short question, they left a tall gap under it.
        let wide = q.permission == nil && (ask?.options.count ?? 0) > 3
        let layout = wide ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        layout {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if q.permission != nil {
                        Image(systemName: "hand.raised.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                    } else { AgentStateIcon(state: .needsYou, size: 13) }
                    Text("\(Text(q.project).foregroundStyle(.orange))\(Text(verb).foregroundStyle(.white.opacity(0.55)))")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                    if q.asks.count > 1 {
                        Text("\(agents.step + 1) of \(q.asks.count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                    }
                    // Leaves the question to the terminal (and shows it): with the question, apart from the answers.
                    RoundButton(symbol: "terminal", tint: nil, size: 24) { agents.toTerminal() }.help("Answer in the terminal")
                }
                if let ask {
                    Text(ask.question).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                } else if let plan = q.plan {
                    code { Text(Self.markdown(plan)).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.88)).lineSpacing(2) }
                } else if let d = q.diff {
                    diff(d)
                } else if let p = q.permission {
                    if let what = q.input["description"] as? String { Text(what).font(.system(size: 14, weight: .medium)).foregroundStyle(.white) }
                    code { Text(p.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.88)).lineLimit(8) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if wide {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) { answers(ask) }
            } else {
                VStack(spacing: 6) { answers(ask) }.frame(width: Self.answersWidth)
            }
        }
    }

    @ViewBuilder private func answers(_ ask: Agents.Ask?) -> some View {
        if q.permission != nil {
            let plan = q.plan != nil
            answer(plan ? "Approve" : "Allow", tint: .green) { agents.allow(true) }
            if let s = q.suggestions.first { answer(Self.always(s, plan: plan)) { agents.allow(true, always: true) } }
            answer(plan ? "Keep planning" : "Deny") { agents.allow(false) }
        } else if let ask {
            ForEach(ask.options, id: \.self) { option($0, ask) }
            if ask.multi {
                answer("Done", tint: .green) { agents.confirm() }.disabled(agents.picks.isEmpty).opacity(agents.picks.isEmpty ? 0.5 : 1)
            }
        }
    }

    static let answersWidth: CGFloat = 214

    private func option(_ o: Agents.Option, _ ask: Agents.Ask) -> some View {
        answer(o.label, detail: o.detail, symbol: ask.multi ? (agents.picks.contains(o.label) ? "checkmark.circle.fill" : "circle") : nil,
               selected: agents.picks.contains(o.label)) { agents.choose(o.label) }
    }

    private var verb: String {
        guard let p = q.permission else { return " asks" }
        switch p.tool {
        case "ExitPlanMode": return " has a plan"
        case "Bash": return " wants to run"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return " wants to edit"
        default: return " wants to use \(p.tool)"
        }
    }

    /// Always Allow's words for Claude Code's suggestion: a rule for this command or tool, or a permission mode.
    static func always(_ s: [String: Any], plan: Bool) -> String {
        guard s["type"] as? String == "setMode" else { return "Always allow" }
        switch s["mode"] as? String {
        case "acceptEdits": return plan ? "Approve, allow edits" : "Allow all edits"
        case "bypassPermissions": return "Allow everything"
        default: return "Always allow"
        }
    }

    /// The changed lines, taken out over put in, a few of each.
    private func diff(_ d: Agents.Diff) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(d.file).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                Text("+\(d.added.count)").foregroundStyle(.green)
                Text("−\(d.removed.count)").foregroundStyle(.red)
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            code {
                VStack(alignment: .leading, spacing: 1) {
                    lines(d.removed, "−", .red, max: 4)
                    lines(d.added, "+", .green, max: 6)
                }
                .font(.system(size: 11.5, design: .monospaced))
            }
        }
    }

    @ViewBuilder private func lines(_ l: [String], _ mark: String, _ tint: Color, max: Int) -> some View {
        ForEach(Array(l.prefix(max).enumerated()), id: \.offset) { _, s in
            Text(mark + " " + s).foregroundStyle(tint.opacity(0.9)).lineLimit(1).truncationMode(.tail)
        }
        if l.count > max { Text("\(l.count - max) more").foregroundStyle(.white.opacity(0.4)) }
    }

    private func code(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: min(radius, 12), style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func answer(_ title: String, detail: String = "", symbol: String? = nil, tint: Color? = nil, dim: Bool = false, selected: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    if !detail.isEmpty { Text(detail).font(.system(size: 10.5, weight: .medium)).opacity(0.6) }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint ?? .white.opacity(dim ? 0.6 : 1))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(tint.map { $0.opacity(0.22) } ?? Color.white.opacity(dim ? 0.07 : selected ? 0.2 : 0.13)))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }

    /// A plan's Markdown, inline styles kept and line breaks as written.
    static func markdown(_ s: String) -> AttributedString {
        let plain = s.split(separator: "\n", omittingEmptySubsequences: false).map { l in
            l.hasPrefix("#") ? String(l.drop { $0 == "#" }.drop { $0 == " " }) : String(l)
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: plain, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(plain)
    }
}

/// "agents" + Tab in the search bar: the question being asked, then every session beside each provider's stats.
struct AgentsPanel: View {
    let radius: CGFloat
    var agents = Agents.shared

    @MainActor static func height(_ a: Agents, width: CGFloat) -> CGFloat {
        PanelLayout.vertical + max(80, a.panelHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.gap) {
            let inner = PanelLayout.inner(PanelLayout.inner(radius), by: 12)
            if agents.asking { AgentsFace(agents: agents, radius: inner, maxHeight: 300).padding(12).background(block) }
            AgentsFace(agents: agents, asks: false, radius: inner, maxHeight: 380).padding(12).background(block)
        }
        .measured { agents.panelHeight = $0 }
        .padding(PanelLayout.edges)
        .environment(\.colorScheme, .dark)
    }

    private var block: some View { RoundedRectangle(cornerRadius: PanelLayout.inner(radius), style: .continuous).fill(Color.black.opacity(0.85)) }
}

/// Settings › Notch: hooking Claude Code up (Codex needs nothing).
struct AgentsSettings: View {
    @Bindable var store: Store
    @State private var connected = Agents.claudeConnected()
    @State private var outdated = Agents.claudeOutdated()
    @State private var problem: String?

    var body: some View {
        Section {
            LabeledContent("Claude Code") {
                HStack {
                    // Connected by an older version: some events (subagents, tasks) aren't sent yet.
                    if outdated { Button("Update") { connect(true) } }
                    Button(connected ? "Disconnect" : "Connect") { connect(!connected) }
                }
            }
            LabeledContent("Codex", value: "Read from its own files")
            if let problem { Text(problem).foregroundStyle(.red).font(.caption) }
        } header: {
            Text("Coding agents")
        } footer: {
            Text("Connecting adds hooks (and a status line, if you don’t have one) to ~/.claude/settings.json, so sessions, their questions and your 5-hour and weekly limits show in the notch. Sessions started before connecting show after a restart.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!store.settings.notchEnabled || !store.settings.notchAgents)
    }

    private func connect(_ on: Bool) {
        do {
            try Agents.connectClaude(on)
            problem = nil
        } catch {
            problem = "Couldn’t change ~/.claude/settings.json: \(error.localizedDescription)"
        }
        connected = Agents.claudeConnected()
        outdated = Agents.claudeOutdated()
    }
}

private extension View {
    /// Laid out at its natural height, which it reports.
    func measured(_ action: @escaping (CGFloat) -> Void) -> some View {
        fixedSize(horizontal: false, vertical: true).onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: action)
    }
}
