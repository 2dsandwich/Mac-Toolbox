import AppKit
import SwiftUI

// MARK: Tasks mode: Moneybag's Google Tasks panel. Type and ↩ to add ("call Ben tomorrow 3pm // notes in Work"),
// ↑↓ to pick, ↩ or ⌘↩ to tick, ⌘E to edit (title, due date and notes in the bar), ⌘⌫ to delete.

@MainActor @Observable final class TasksBoard {
    static let shared = TasksBoard()

    enum Line: Identifiable, Equatable {
        case list(TaskList, first: Bool)
        case task(TaskItem, sub: Bool)
        case doneHeader(Int)

        var id: String {
            switch self {
            case .list(let l, _): "list-" + l.id
            case .task(let t, _): t.id
            case .doneHeader: "done"
            }
        }

        var height: CGFloat {
            if case .list(_, let first) = self { return first ? 20 : 28 }
            return 32
        }
    }

    /// The picked line (a task's id or "done"); nil is the bar.
    var selected: String?
    /// The task whose text is in the bar.
    var editing: String?
    var showDone = false
    /// Ticked, still on screen while the strike and fling play.
    private(set) var leaving: Set<String> = []

    private var tasks: GoogleTasks { .shared }

    var lines: [Line] {
        var out: [Line] = []
        for l in tasks.lists {
            let open = tasks.open(in: l.id)
            guard !open.isEmpty else { continue }
            out.append(.list(l, first: out.isEmpty))
            out += open.map { t in .task(t, sub: t.parent.map { p in open.contains { $0.id == p } } ?? false) }
        }
        let done = tasks.completed
        if !done.isEmpty {
            out.append(.doneHeader(done.count))
            if showDone { out += done.map { .task($0, sub: false) } }
        }
        return out
    }

    private var selectable: [Line] { lines.filter { if case .list = $0 { false } else { true } } }

    var selectedTask: TaskItem? {
        guard let selected else { return nil }
        for case .task(let t, _) in lines where t.id == selected { return t }
        return nil
    }

    func appear() {
        selected = nil
        editing = nil
        if Google.shared.ready, tasks.age > 30 { Task { await tasks.refresh() } }
    }

    func move(_ delta: Int) {
        let all = selectable
        guard !all.isEmpty else { return }
        let i = selected.flatMap { s in all.firstIndex { $0.id == s } } ?? -1
        let next = min(all.count - 1, i + delta)
        selected = next < 0 ? nil : all[next].id
    }

    /// The line after this one, to pick once it's gone.
    private func after(_ id: String) -> String? {
        let all = selectable
        guard let i = all.firstIndex(where: { $0.id == id }) else { return nil }
        return all.indices.contains(i + 1) ? all[i + 1].id : i > 0 ? all[i - 1].id : nil
    }

    func toggle(_ t: TaskItem) {
        if t.done { return withAnimation(.smooth(duration: 0.25)) { tasks.setDone(t, false) } }
        let next = after(t.id)
        let finish = {
            self.leaving.remove(t.id)
            withAnimation(.smooth(duration: 0.25)) { self.tasks.setDone(t, true) }
            if self.selected == t.id { self.selected = next }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return finish() }
        leaving.insert(t.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) { finish() }
    }

    func delete(_ t: TaskItem) {
        if selected == t.id { selected = after(t.id) }
        withAnimation(.smooth(duration: 0.25)) { tasks.delete(t) }
    }

    func startEditing(_ t: TaskItem, _ model: LauncherModel) {
        editing = t.id
        selected = t.id
        var text = t.title
        if let d = t.due { text += " " + QuickAdd.dueText(d) }
        if let n = t.notes { text += " // " + Self.oneLine(n) }
        model.setQuery(text)
    }

    private static func oneLine(_ s: String) -> String { s.split(whereSeparator: \.isNewline).joined(separator: " ") }

    private func saveEdit(_ text: String, _ model: LauncherModel) {
        defer { editing = nil; model.setQuery("") }
        guard let t = tasks.tasks.first(where: { $0.id == editing }), !text.isEmpty else { return }
        Task {
            let p = await QuickAdd.final(text, groups: [])
            // Notes with line breaks come back on one line; unchanged, they keep their breaks.
            let notes = t.notes.map(Self.oneLine) == p.note ? t.notes : p.note
            self.tasks.edit(t, title: p.title, notes: notes, due: p.day)
        }
    }

    /// The bar's keys while Tasks is open.
    func handle(_ sel: Selector, _ model: LauncherModel) -> Bool {
        let text = model.query.trimmingCharacters(in: .whitespaces)
        switch sel {
        case #selector(NSResponder.moveUp(_:)): if editing == nil { move(-1) }
        case #selector(NSResponder.moveDown(_:)): if editing == nil { move(1) }
        case #selector(NSResponder.cancelOperation(_:)):
            if editing != nil {
                editing = nil
                model.setQuery("")
            } else if selected != nil, text.isEmpty {
                selected = nil
            } else {
                return false
            }
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            guard Google.shared.ready else { Google.shared.signInOrSettings(); return true }
            if editing != nil { saveEdit(text, model); return true }
            if !text.isEmpty {
                tasks.add(text, list: selectedTask?.list)
                model.setQuery("")
                selected = nil
            } else if selected == "done" {
                withAnimation(.smooth(duration: 0.25)) { showDone.toggle() }
            } else if let t = selectedTask {
                toggle(t)
            }
        default: return false
        }
        return true
    }

    /// ⌘E edit, ⌘⌫ delete, ⌘↩ tick.
    func command(_ e: NSEvent, _ model: LauncherModel) -> Bool {
        guard let t = selectedTask, editing == nil || e.keyCode == 36 else { return false }
        switch (e.charactersIgnoringModifiers?.lowercased(), e.keyCode) {
        case ("e", _): startEditing(t, model)
        case (_, 51): delete(t)
        case (_, 36), (_, 76): if editing == nil { toggle(t) }
        default: return false
        }
        return true
    }
}

// MARK: The panel

struct TasksPanel: View {
    let board: TasksBoard
    let radius: CGFloat
    @State private var tasks = GoogleTasks.shared
    @State private var google = Google.shared
    @State private var moreBelow = false

    static let maxList: CGFloat = 360

    @MainActor static func height(_ board: TasksBoard) -> CGFloat {
        guard Google.shared.ready else { return PanelLayout.vertical + 34 }
        let lines = board.lines
        let list = GoogleTasks.shared.loaded && !lines.isEmpty ? min(maxList, lines.reduce(0) { $0 + $1.height }) : 32
        return PanelLayout.vertical + list + (GoogleTasks.shared.error == nil ? 0 : 32)
    }

    var body: some View {
        let lines = board.lines
        VStack(alignment: .leading, spacing: 0) {
            if !google.ready {
                GoogleBanner(service: "Google Tasks")
            } else {
                if let e = tasks.error { message(e, color: Color(red: 1, green: 107 / 255, blue: 107 / 255)) }
                if !tasks.loaded || lines.isEmpty {
                    message(tasks.loaded ? "No tasks" : "Loading tasks", color: .secondary)
                } else {
                    list(lines)
                }
            }
        }
        .padding(PanelLayout.edges)
        .onAppear { board.appear() }
        .onDisappear { board.editing = nil }
        .onChange(of: google.status) { board.appear() }
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(color).lineLimit(1).padding(.horizontal, 8).frame(height: 32)
    }

    private func list(_ lines: [TasksBoard.Line]) -> some View {
        let row = PanelLayout.inner(radius)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(lines) { line in
                        Group {
                            switch line {
                            case .list(let l, _):
                                Text(l.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.35))
                                    .padding(.horizontal, 8).padding(.bottom, 4)
                                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                            case .task(let t, let sub):
                                TaskRow(task: t, sub: sub, selected: board.selected == t.id, editing: board.editing == t.id,
                                        leaving: board.leaving.contains(t.id), radius: row) {
                                    board.toggle(t)
                                } pick: {
                                    board.selected = t.id
                                }
                            case .doneHeader(let n):
                                Button {
                                    board.selected = "done"
                                    withAnimation(.smooth(duration: 0.25)) { board.showDone.toggle() }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                                            .rotationEffect(.degrees(board.showDone ? 90 : 0)).frame(width: 16)
                                        Text("Completed").font(.system(size: 12.5)).foregroundStyle(.secondary)
                                        Text("\(n)").font(.system(size: 12.5)).foregroundStyle(Color.primary.opacity(0.35))
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(maxHeight: .infinity)
                                    .background(RoundedRectangle(cornerRadius: row, style: .continuous).fill(board.selected == "done" ? selectedFill : .clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(height: line.height)
                        .id(line.id)
                    }
                }
            }
            .frame(height: min(Self.maxList, lines.reduce(0) { $0 + $1.height }))
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y + g.containerSize.height < g.contentSize.height - 2 } action: { _, more in
                moreBelow = more
            }
            // Fades out at the bottom while there's more below (Moneybag's cue).
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: moreBelow ? 30 : 0)
                }
            }
            .onChange(of: board.selected) { _, id in
                guard let id else { return }
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
    }
}

private struct TaskRow: View {
    let task: TaskItem
    let sub: Bool
    let selected: Bool
    let editing: Bool
    let leaving: Bool
    let radius: CGFloat
    let check: () -> Void
    let pick: () -> Void
    @State private var strike: CGFloat = 0
    @State private var flung = false

    private static let overdue = Color(red: 1, green: 107 / 255, blue: 107 / 255)
    private static let tertiary = Color.primary.opacity(0.35)

    var body: some View {
        let done = task.done || leaving
        HStack(spacing: 10) {
            Button(action: check) {
                ZStack {
                    Circle().strokeBorder(done ? Color.secondary : Self.tertiary, lineWidth: 1.5)
                    if done {
                        Circle().fill(Color.secondary)
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.black)
                    }
                }
                .frame(width: 16, height: 16)
                .contentShape(Rectangle().inset(by: -6))
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Text(task.title).font(.system(size: 13.5)).foregroundStyle(done ? Self.tertiary : Color.primary).strikethrough(task.done)
                    .lineLimit(1)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.secondary).frame(height: 1.5).scaleEffect(x: strike, anchor: .leading)
                    }
                if let n = task.notes {
                    Text(n.split(whereSeparator: \.isNewline).first.map(String.init) ?? n).font(.system(size: 12)).foregroundStyle(Self.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let d = task.due { due(d, done: done) }
        }
        .padding(.leading, 8 + (sub ? 26 : 0))
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(selected || editing ? selectedFill : .clear))
        .overlay { if editing { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Self.tertiary, lineWidth: 1) } }
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        // Ticked: a line through it, then off it goes.
        .opacity(flung ? 0 : 1)
        .offset(x: flung ? 48 : 0, y: flung ? -14 : 0)
        .rotationEffect(.degrees(flung ? 5 : 0))
        .onChange(of: leaving) { _, on in
            guard on else { return }
            withAnimation(.easeOut(duration: 0.18)) { strike = 1 } completion: {
                withAnimation(.easeIn(duration: 0.28)) { flung = true }
            }
        }
        // Back in view under Completed (or ticked off again): whole again.
        .onChange(of: task.done) {
            strike = 0
            flung = false
        }
    }

    private func due(_ d: Date, done: Bool) -> some View {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: d).day ?? 0
        let text = days == 0 ? "Today" : days == 1 ? "Tomorrow" : days == -1 ? "Yesterday"
            : d.formatted(.dateTime.month(.abbreviated).day())
        return Text(text).font(.system(size: 11.5)).foregroundStyle(days < 0 && !done ? Self.overdue : Self.tertiary)
    }
}

/// The sign-in row in the Calendar and Tasks modes while Google isn't connected.
struct GoogleBanner: View {
    let service: String
    @State private var google = Google.shared
    private let coral = Color(red: 1, green: 106 / 255, blue: 85 / 255)

    var body: some View {
        let waiting = google.status == .signingIn
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle").font(.system(size: 11)).foregroundStyle(coral)
            Text(waiting ? "Waiting for Google" : google.error ?? service).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 0)
            Button { waiting ? google.cancelSignIn() : google.signInOrSettings() } label: { Pill(text: waiting ? "Cancel" : "Sign in") }
                .buttonStyle(Press())
        }
        .padding(.leading, 12).padding(.trailing, 1)
        .frame(height: 34)
        .background(Capsule().fill(coral.opacity(0.14)))
    }
}
