import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The week grid you edit (search bar "timetable" + Tab, and Settings › Timetable): drag a class to move it (⌥ to
// copy), click an empty cell to add one, Delete removes it, the side panel edits it. Files dropped on the grid are
// imported and wait in the same grid for a look before they're saved.

/// What's picked and what's waiting, shared by the search bar's view and Settings.
@MainActor @Observable final class TimetableBoard {
    static let shared = TimetableBoard()

    struct Cell: Hashable { var day: Int; var period: Int }
    /// `into`: the schedule it replaces when kept; nil makes a new one.
    struct Review { var term: TimetableTerm; var notes: String; var file: URL?; var hint = ""; var into: UUID? }
    enum Side: Equatable { case none, day, period(Int), presets, schedules }

    var selected: UUID?
    var cursor: Cell?
    var side = Side.none
    /// An import to look over (and fix) before it's saved.
    var review: Review?
    /// The file being read.
    var reading: String?
    var problem: String?
    @ObservationIgnored private var readTask: Task<Void, Never>?

    var term: TimetableTerm { review?.term ?? Timetables.shared.editing ?? .blank() }
    var selectedClass: ClassItem? { term.classes.first { $0.id == selected } }

    /// Edits go to the import under review (no undo there), else to the saved timetable.
    func change(_ undoKey: String? = nil, _ f: (inout TimetableTerm) -> Void) {
        if review != nil { f(&review!.term) } else { Timetables.shared.edit(undoKey, f) }
    }

    /// A class and the rest of its block (the same class in the periods next to it) change together.
    func changeClass(_ id: UUID, _ undoKey: String? = nil, _ f: (inout ClassItem) -> Void) {
        let ids = Set(term.block(of: id).map(\.id))
        change(undoKey) { t in for i in t.classes.indices where ids.contains(t.classes[i].id) { f(&t.classes[i]) } }
    }

    /// Nothing picked, the side panel left as it is (adding or deleting a schedule from its list).
    func clearPick() {
        let s = side
        select(nil)
        side = s
    }

    func select(_ c: ClassItem?) {
        dropEmpty(except: c?.id)
        selected = c?.id
        if let c { cursor = Cell(day: c.day, period: c.period) }
        side = .none
    }

    /// A new class in an empty cell, picked so its name can be typed (left empty, it goes away again).
    func add(at cell: Cell, name: String = "") {
        dropEmpty(except: nil)
        let c = ClassItem(day: cell.day, period: cell.period, name: name)
        change { $0.classes.append(c) }
        selected = c.id
        cursor = cell
        side = .none
    }

    private func dropEmpty(except id: UUID?) {
        guard let s = selectedClass, s.id != id, s.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        change { $0.classes.removeAll { $0.id == s.id } }
    }

    func delete() {
        guard let id = selected else { return }
        let ids = Set(term.block(of: id).map(\.id))
        change { $0.classes.removeAll { ids.contains($0.id) } }
        selected = nil
    }

    /// The whole block moves, kept inside the day's periods.
    func move(_ id: UUID, to cell: Cell, copy: Bool) {
        let block = term.block(of: id)
        guard let top = block.first, Cell(day: top.day, period: top.period) != cell || copy else { return }
        let first = min(cell.period, max(0, term.periods.count - block.count))
        let moved = block.enumerated().map { k, c in
            var m = c
            (m.day, m.period) = (cell.day, first + k)
            if copy { m.id = UUID() }
            return m
        }
        let ids = Set(block.map(\.id))
        change { t in
            if !copy { t.classes.removeAll { ids.contains($0.id) } }
            t.classes += moved
        }
        selected = moved[0].id
        cursor = Cell(day: cell.day, period: first)
    }

    /// A class dragged from a cell, or files from Finder (imported).
    func drop(_ providers: [NSItemProvider], at cell: Cell?) -> Bool {
        let copy = NSEvent.modifierFlags.contains(.option)
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { TimetableBoard.shared.importFile(url) } }
            }
            return true
        }
        guard let cell, let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = p.loadObject(ofClass: NSString.self) { s, _ in
            guard let s = s as? String, s.hasPrefix("money-class:"), let id = UUID(uuidString: String(s.dropFirst(12))) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { TimetableBoard.shared.move(id, to: cell, copy: copy) } }
        }
        return true
    }

    // MARK: Import and export

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf, .json, .commaSeparatedText, .plainText, UTType(filenameExtension: "ics") ?? .calendarEvent]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    func importFile(_ url: URL, hint: String = "") {
        readTask?.cancel()
        problem = nil
        reading = url.lastPathComponent
        let base = Timetables.shared.editing
        readTask = Task {
            do {
                let r = try await TimetableImport.read(url, hint: hint, base: base)
                guard !Task.isCancelled else { return }
                review = Review(term: r.term, notes: r.notes, file: url, hint: hint)
                selected = nil
                side = .none
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
            reading = nil
        }
    }

    func cancelReading() {
        readTask?.cancel()
        reading = nil
    }

    func keep() {
        guard var r = review else { return }
        r.term.classes.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if let id = r.into { Timetables.shared.replace(id, with: r.term) } else { Timetables.shared.addTerm(r.term) }
        review = nil
        selected = nil
    }

    func export(ics: Bool) {
        let t = term
        let panel = NSSavePanel()
        panel.nameFieldStringValue = t.name + (ics ? ".ics" : ".json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if ics { try TimetableImport.exportICS(t).write(to: url, atomically: true, encoding: .utf8) }
            else { try TimetableImport.exportJSON(t).write(to: url) }
        } catch { problem = error.localizedDescription }
    }

    // MARK: Keys (the search bar's field has them)

    func handle(_ sel: Selector, _ model: LauncherModel) -> Bool {
        let text = model.query.trimmingCharacters(in: .whitespaces)
        switch sel {
        case #selector(NSResponder.moveLeft(_:)) where text.isEmpty: step(-1, 0)
        case #selector(NSResponder.moveRight(_:)) where text.isEmpty: step(1, 0)
        case #selector(NSResponder.moveUp(_:)): step(0, -1)
        case #selector(NSResponder.moveDown(_:)): step(0, 1)
        case #selector(NSResponder.insertNewline(_:)):
            // Typed in the bar: a class of that name in the picked cell (or renames the picked class).
            guard !text.isEmpty, let cell = cursor else { return false }
            if let id = selected { changeClass(id, "\(id)-name") { $0.name = text } }
            else { add(at: cell, name: text) }
            model.setQuery("")
        case #selector(NSResponder.deleteBackward(_:)) where text.isEmpty && selected != nil: delete()
        case #selector(NSResponder.cancelOperation(_:)) where review != nil || selected != nil || cursor != nil || side != .none:
            if selected != nil || cursor != nil || side != .none { select(nil); cursor = nil } else { review = nil }
        default: return false
        }
        return true
    }

    /// ⌘Z, ⇧⌘Z.
    func command(_ e: NSEvent) -> Bool {
        guard e.charactersIgnoringModifiers?.lowercased() == "z", review == nil else { return false }
        let f = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if f == .command { Timetables.shared.undo() } else if f == [.command, .shift] { Timetables.shared.redo() } else { return false }
        return true
    }

    private func step(_ dx: Int, _ dy: Int) {
        let t = term
        guard !t.days.isEmpty, !t.periods.isEmpty else { return }
        let days = t.days.sorted()
        var c = cursor ?? Cell(day: days[0], period: 0)
        if cursor != nil {
            let i = (days.firstIndex(of: c.day) ?? 0) + dx
            c = Cell(day: days[(i + days.count) % days.count], period: (c.period + dy + t.periods.count) % t.periods.count)
        }
        dropEmpty(except: nil)
        cursor = c
        selected = t.classes(day: c.day, period: c.period).first?.id
        side = .none
    }
}

// MARK: The editor

/// Toolbar, week grid and side panel. In Settings the grid takes the whole width and the side panel goes under it
/// (only while something is picked).
struct TimetableEditor: View {
    var board = TimetableBoard.shared
    var store = Timetables.shared
    let radius: CGFloat
    var inSettings = false

    static let toolbar: CGFloat = 30

    @MainActor static var gridHeight: CGFloat {
        let n = CGFloat(max(1, TimetableBoard.shared.term.periods.count))
        return TimetableGrid.header + n * (Timetables.shared.look.cellHeight + TimetableGrid.gap)
    }

    /// The grid's height, or the side panel's room, whichever is more.
    @MainActor static var height: CGFloat { toolbar + PanelLayout.gap + max(gridHeight, 510) } // the class editor fits without scrolling

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.gap) {
            toolbar.frame(height: Self.toolbar)
            if inSettings {
                grid.frame(height: Self.gridHeight)
                if board.reading != nil || board.selected != nil || board.side != .none || board.review != nil {
                    TimetableSide(board: board, radius: radius, scrolls: false)
                }
            } else {
                HStack(alignment: .top, spacing: PanelLayout.gap) {
                    grid
                    TimetableSide(board: board, radius: radius).frame(width: 240)
                }
            }
        }
    }

    private var grid: some View {
        TimetableGrid(term: board.term, look: store.look, board: board, radius: radius)
            .onDrop(of: [.fileURL], isTargeted: nil) { board.drop($0, at: nil) }
    }

    @ViewBuilder private var toolbar: some View {
        HStack(spacing: 8) {
            if board.review != nil {
                Label("Check the classes, then keep them", systemImage: "doc.viewfinder").font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel") { board.review = nil; board.selected = nil }
                Button(board.review?.into == nil ? "Keep as new schedule" : "Keep") { board.keep() }.buttonStyle(.borderedProminent).tint(.accentColor)
            } else {
                // The schedule open here (not the one in use: that goes by date); its list is in the side panel.
                Button { board.select(nil); board.side = board.side == .schedules ? .none : .schedules } label: {
                    HStack(spacing: 5) {
                        Text(store.editing?.name ?? "Timetable").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Schedules")
                if let e = store.editing {
                    Text([e.kind, e.range].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if e.id == store.today?.id { TodayTag() }
                }
                Spacer(minLength: 8)
                if let p = board.problem {
                    Text(p).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2).help(p)
                }
                icon("arrow.uturn.backward", "Undo (⌘Z)", enabled: store.canUndo) { store.undo() }
                icon("arrow.uturn.forward", "Redo (⇧⌘Z)", enabled: store.canRedo) { store.redo() }
                Menu {
                    Button("Choose a file…") { board.chooseFile() }
                    Button("School presets") { board.select(nil); board.side = .presets }
                    Divider()
                    Button("Export JSON…") { board.export(ics: false) }
                    Button("Export to Calendar (.ics)…") { board.export(ics: true) }
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Import and export")
                if !inSettings {
                    icon("slider.horizontal.3", "Look and periods") { (NSApp.delegate as? AppDelegate)?.showSettings(pane: .timetable) }
                }
            }
        }
    }

    private func icon(_ symbol: String, _ help: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: The grid

struct TimetableGrid: View {
    let term: TimetableTerm
    let look: TimetableLook
    var board: TimetableBoard
    let radius: CGFloat
    var editable = true
    @State private var target: TimetableBoard.Cell?

    static let header: CGFloat = 24
    static let gap: CGFloat = 4
    static let label: CGFloat = 46

    var body: some View {
        let days = term.days.sorted()
        let now = Timetables.shared.now, cal = Calendar.current
        // Today's day and class only on the schedule in use today.
        let inUse = Timetables.shared.today?.id == term.id
        let today = inUse ? TimetableTerm.weekday(now, cal) : -1
        let live = inUse ? term.current(at: now) : nil
        GeometryReader { g in
            let col = max(40, (g.size.width - Self.label - CGFloat(days.count) * Self.gap) / CGFloat(max(1, days.count)))
            let n = CGFloat(max(1, term.periods.count))
            // Taller cells fill the room there is; past it, the grid scrolls.
            let cellH = max(look.cellHeight, ((g.size.height - Self.header) / n - Self.gap).rounded(.down))
            ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Self.gap) {
                HStack(spacing: Self.gap) {
                    Button { if editable { board.select(nil); board.side = .day } } label: {
                        Image(systemName: "calendar").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: Self.label, height: Self.header)
                    }
                    .buttonStyle(.plain)
                    .help("School days")
                    ForEach(days, id: \.self) { d in
                        Text(TimetableTerm.dayShort[d])
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(d == today ? Color.white : .secondary)
                            .padding(.horizontal, 8).frame(height: 18)
                            .background(Capsule().fill(d == today ? Color.accentColor : .clear))
                            .frame(width: col, height: Self.header)
                    }
                }
                // Day columns, so the same class in periods next to each other is one tall cell.
                HStack(alignment: .top, spacing: Self.gap) {
                    VStack(spacing: Self.gap) {
                        ForEach(term.periods.indices, id: \.self) { p in
                            periodLabel(p, height: cellH, now: live.map { (($0.first)...($0.last)).contains(p) && $0.item.day == today } ?? false)
                        }
                    }
                    ForEach(days, id: \.self) { d in
                        VStack(spacing: Self.gap) {
                            ForEach(spans(d), id: \.p) { s in
                                cell(TimetableBoard.Cell(day: d, period: s.p), width: col, height: CGFloat(s.n) * (cellH + Self.gap) - Self.gap)
                            }
                        }
                    }
                }
            }
            }
            .scrollIndicators(.never)
        }
    }

    /// The day's cells: each period, or the first of a block and how many periods it takes.
    private func spans(_ d: Int) -> [(p: Int, n: Int)] {
        var out: [(p: Int, n: Int)] = []
        for p in term.periods.indices {
            if let c = term.classes(day: d, period: p).first, term.joinsAbove(c), !out.isEmpty { out[out.count - 1].n += 1 } else { out.append((p, 1)) }
        }
        return out
    }

    private func periodLabel(_ p: Int, height: CGFloat, now: Bool) -> some View {
        let picked = board.side == .period(p)
        return Button { if editable { board.select(nil); board.side = .period(p) } } label: {
            VStack(spacing: 1) {
                Text("\(p + 1)").font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(now ? Color.accentColor : .primary)
                if look.showTime {
                    Text(term.periods[p].start).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                    if look.density > 0 { Text(term.periods[p].end).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary) }
                }
            }
            .lineLimit(1)
            .frame(width: Self.label, height: height)
            .background(RoundedRectangle(cornerRadius: cellRadius, style: .continuous).fill(picked ? selectedFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Period times")
    }

    /// As many lines of the name as the cell has room for under the room and teacher lines.
    private func nameLines(_ height: CGFloat) -> Int {
        let details = CGFloat((look.showRoom ? 1 : 0) + (look.showTeacher ? 1 : 0)) * look.detailSize * 1.3
        return max(1, min(4, Int((height - 10 - details) / (look.nameSize * 1.25))))
    }

    private var cellRadius: CGFloat { max(4, min(10, PanelLayout.inner(radius) - 6)) }

    private func cell(_ c: TimetableBoard.Cell, width: CGFloat, height: CGFloat) -> some View {
        let items = term.classes(day: c.day, period: c.period)
        let shape = RoundedRectangle(cornerRadius: cellRadius, style: .continuous)
        let cursor = board.cursor == c && board.selected == nil
        return VStack(spacing: 2) {
            ForEach(items) { item in
                card(item, lines: items.count > 1 ? 1 : nameLines(height), shared: items.count > 1 && height < 100)
                    .onTapGesture { if editable { board.select(item) } }
                    .onDrag { NSItemProvider(object: "money-class:\(item.id.uuidString)" as NSString) }
            }
        }
        .frame(width: width, height: height)
        .background(shape.fill(items.isEmpty ? Color.primary.opacity(cursor ? 0.12 : 0.045) : .clear))
        .overlay(shape.strokeBorder(Color.accentColor, lineWidth: target == c ? 2 : 0))
        .contentShape(shape)
        .onTapGesture { if editable { if items.isEmpty { board.add(at: c) } else { board.select(items[0]) } } }
        .onDrop(of: [.plainText, .fileURL], isTargeted: Binding(get: { target == c }, set: { target = $0 ? c : (target == c ? nil : target) })) {
            editable && board.drop($0, at: c)
        }
    }

    /// `shared`: one of two classes in a cell (odd and even weeks): the name only.
    private func card(_ item: ClassItem, lines: Int, shared: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: cellRadius, style: .continuous)
        let tint = item.tint
        let solid = look.colorStyle == 1
        let picked = board.selected.map { s in term.block(of: item.id).contains { $0.id == s } } ?? false
        let details = [look.showRoom ? item.room : "", look.showTeacher ? item.teacher : ""].filter { !$0.isEmpty }
        return HStack(spacing: 0) {
            if look.colorStyle == 2 { Rectangle().fill(tint).frame(width: 3) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .top, spacing: 3) {
                    Text(item.name.isEmpty ? " " : item.name)
                        .font(look.nameFont)
                        .foregroundStyle(solid ? Color.white : .primary)
                        .lineLimit(lines)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    if let w = item.weeks?.parity { Text(w == 1 ? "Odd" : "Even").font(.system(size: 8.5, weight: .bold)).foregroundStyle(solid ? .white : tint) }
                    if !item.link.isEmpty, !shared { Image(systemName: "video.fill").font(.system(size: 8)).foregroundStyle(solid ? .white : tint) }
                }
                if !shared {
                    ForEach(details.prefix(lines > 1 ? 2 : 1), id: \.self) { d in
                        Text(d).font(look.detailFont).foregroundStyle(solid ? Color.white.opacity(0.85) : .secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, shared ? 2 : 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(look.colorStyle == 3 ? Color.primary.opacity(0.08) : tint.opacity(solid ? 0.85 : look.colorStyle == 2 ? 0.12 : 0.24)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(picked ? 0.9 : 0), lineWidth: 2))
        .contentShape(shape)
        .help([item.name, item.room, item.teacher].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

// MARK: The side panel

struct TimetableSide: View {
    var board: TimetableBoard
    let radius: CGFloat
    var scrolls = true

    var body: some View {
        // In Settings it shows whole, as tall as it is (a scroll view that can't scroll clipped it to the row).
        Group {
            if scrolls { ScrollView(.vertical) { content }.scrollIndicators(.never) } else { content.fixedSize(horizontal: false, vertical: true) }
        }
        .background(RoundedRectangle(cornerRadius: PanelLayout.inner(radius), style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = board.reading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(r)").font(.system(size: 12.5)).lineLimit(2)
                }
                Button("Stop") { board.cancelReading() }
            } else if let c = board.selectedClass {
                ClassInspector(board: board, item: c)
            } else {
                switch board.side {
                case .period(let p) where p < board.term.periods.count: PeriodInspector(board: board, period: p)
                case .day: DaysInspector(board: board)
                case .presets: PresetsInspector(board: board)
                case .schedules where board.review == nil: SchedulesInspector(board: board)
                default: overview
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Nothing picked: what's next, today, and how to bring a timetable in.
    @ViewBuilder private var overview: some View {
        let store = Timetables.shared
        if let r = board.review {
            Text("From \(r.file?.lastPathComponent ?? "the file")").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(r.term.classes.count) classes, \(r.term.periods.count) periods").font(.system(size: 13, weight: .semibold))
            if !r.notes.isEmpty { Text(r.notes).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            Text("Click a class to fix its name or room.").font(.system(size: 11)).foregroundStyle(.secondary)
            Field("Put the classes in") {
                Picker("", selection: Binding(get: { board.review?.into }, set: { board.review?.into = $0 })) {
                    Text("A new schedule").tag(UUID?.none)
                    ForEach(store.terms) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if r.into == nil {
                ScheduleFields(board: board)
            } else {
                Text("Its name and dates stay. Its days, periods and classes become these.").font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let file = r.file, let t = UTType(filenameExtension: file.pathExtension.lowercased()), t.conforms(to: .image) || t.conforms(to: .pdf) {
                Field("Tell the reader (your class, your options)") {
                    TextField("", text: Binding(get: { board.review?.hint ?? "" }, set: { board.review?.hint = $0 }), axis: .vertical).lineLimit(2...4)
                }
                Button("Read again") { board.importFile(file, hint: r.hint) }
            }
        } else {
            let now = store.now
            if store.today == nil, !store.terms.isEmpty {
                Label("No schedule covers today.", systemImage: "calendar").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let a = store.terms.current(at: now) ?? store.terms.next(after: now) {
                let live = a.start <= now
                Text(live ? "Now" : "Next").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.item.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    if !a.item.room.isEmpty { Label(a.item.room, systemImage: "mappin.and.ellipse").font(.system(size: 12.5)).lineLimit(2) }
                    Text(when(a, now: now, live: live)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: max(4, PanelLayout.inner(radius) - 12), style: .continuous).fill(a.item.tint.opacity(0.22)))
            }
            let today = store.terms.occurrences(on: now)
            if !today.isEmpty {
                Text("Today").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(today, id: \.key) { o in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(o.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        Text(o.item.name).font(.system(size: 12.5)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(o.item.room).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .opacity(o.end < now ? 0.45 : 1)
                }
            }
            Text("Import").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text("Drop a picture, PDF, .ics, .csv or .json of a timetable on the grid.").font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose a file…") { board.chooseFile() }
                Button("Presets") { board.side = .presets }
            }
        }
    }

    private func when(_ a: ClassOccurrence, now: Date, live: Bool) -> String {
        let m = Int(ceil((live ? a.end : a.start).timeIntervalSince(now) / 60))
        let left = m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
        if live { return "\(a.timeRange) · \(left) left" }
        let day = Calendar.current.isDate(a.start, inSameDayAs: now) ? "" : a.start.formatted(.dateTime.weekday(.abbreviated)) + " "
        return day + a.timeRange + (day.isEmpty ? " · in \(left)" : "")
    }
}

/// A caption over a field (fields carry no hint text of their own).
struct Field<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            // Inside a Settings form, fields would take the form's label column and right-align their text.
            content().textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading)
        }
    }
}

private struct ClassInspector: View {
    var board: TimetableBoard
    let item: ClassItem
    @FocusState private var nameFocused: Bool

    var body: some View {
        let t = board.term
        let block = t.block(of: item.id)
        let (a, b) = (block.first?.period ?? item.period, block.last?.period ?? item.period)
        let span = b < t.periods.count ? "\(t.periods[a].start)–\(t.periods[b].end)" : ""
        VStack(alignment: .leading, spacing: 10) {
            Text("\(TimetableTerm.dayShort[item.day]) · " + (a == b ? "Period \(a + 1)" : "Periods \(a + 1)–\(b + 1)") + " · \(span)")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(2)
            Field("Name") { TextField("", text: bind(\.name), axis: .vertical).lineLimit(1...3).focused($nameFocused) }
            Field("Room") { TextField("", text: bind(\.room)) }
            Field("Teacher") { TextField("", text: bind(\.teacher)) }
            Field("Colour") { swatches }
            Field("Weeks") { weeks }
            Field("Online link") { TextField("", text: bind(\.link)) }
            Field("Notes") {
                TextEditor(text: bind(\.note))
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .frame(height: 40)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            HStack {
                Button("Delete", role: .destructive) { board.delete() }
                Spacer()
                if block.count > 1 {
                    Button("Split") { let ids = Set(block.dropFirst().map(\.id)); board.change { t in for i in t.classes.indices where ids.contains(t.classes[i].id) { t.classes[i].apart = true } } }
                        .help("One cell per period")
                } else if item.apart, t.joinsAbove({ var x = item; x.apart = false; return x }()) {
                    Button("Join") { update { $0.apart = false } }.help("One cell with the period before")
                }
                if let url = URL(string: item.link), url.scheme?.hasPrefix("http") == true { Button("Join") { NSWorkspace.shared.open(url) } }
            }
        }
        .onAppear { if item.name.isEmpty { nameFocused = true } }
    }

    private func bind(_ k: WritableKeyPath<ClassItem, String>) -> Binding<String> {
        let id = item.id
        return Binding(get: { board.term.classes.first { $0.id == id }?[keyPath: k] ?? "" },
                       set: { v in board.changeClass(id, "\(id)-\(k)") { $0[keyPath: k] = v } })
    }

    private func update(_ f: (inout ClassItem) -> Void) { board.changeClass(item.id, nil, f) }

    private var swatches: some View {
        let picked = item.color
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 6), count: 7), alignment: .leading, spacing: 4) {
            swatch(nil, picked == nil)
            ForEach(TimetableTerm.palette, id: \.self) { hex in swatch(hex, picked == hex) }
        }
    }

    /// nil: the colour that comes from the name.
    private func swatch(_ hex: String?, _ on: Bool) -> some View {
        Circle()
            .fill(hex.flatMap { NSColor(hex: $0) }.map { Color(nsColor: $0) } ?? Color(nsColor: NSColor(hex: TimetableTerm.palette[TimetableTerm.paletteIndex(item.name)])!))
            .overlay { if hex == nil { Text("A").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) } }
            .frame(width: 16, height: 16)
            .padding(2)
            .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.9 : 0), lineWidth: 1.5))
            .contentShape(Circle())
            .onTapGesture { update { $0.color = hex } }
            .help(hex == nil ? "From the name" : "")
    }

    @ViewBuilder private var weeks: some View {
        let w = item.weeks
        let kind = w?.parity ?? (w?.from != nil || w?.to != nil ? 3 : (w?.only != nil || w?.skip != nil) ? 4 : 0)
        Picker("", selection: Binding(get: { kind }, set: { k in
            update { c in
                switch k {
                case 1, 2: c.weeks = ClassWeeks(parity: k)
                case 3: c.weeks = ClassWeeks(from: board.term.start.isEmpty ? TimetableTerm.dayString(Date(), .current) : board.term.start,
                                             to: board.term.end.isEmpty ? nil : board.term.end)
                default: c.weeks = nil
                }
            }
        })) {
            Text("Every").tag(0)
            Text("Odd").tag(1)
            Text("Even").tag(2)
            Text("Dates").tag(3)
            if kind == 4 { Text("Some").tag(4) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if kind == 3 {
            VStack(alignment: .leading, spacing: 4) {
                dateRow("From", \.from)
                dateRow("To", \.to)
            }
        } else if kind == 4 {
            Text(w?.only.map { "Only " + $0.map(TimetableTerm.short).joined(separator: ", ") } ?? "Not " + (w?.skip ?? []).map(TimetableTerm.short).joined(separator: ", "))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
        }
    }

    private func dateRow(_ title: String, _ k: WritableKeyPath<ClassWeeks, String?>) -> some View {
        DatePicker(title, selection: Binding(
            get: { (item.weeks?[keyPath: k]).flatMap { TimetableTerm.parse($0) } ?? Date() },
            set: { d in update { c in c.weeks = c.weeks ?? ClassWeeks(); c.weeks![keyPath: k] = TimetableTerm.dayString(d, .current) } }
        ), displayedComponents: .date)
        .font(.system(size: 12))
    }
}

/// A period's start and end, and adding or removing periods.
private struct PeriodInspector: View {
    var board: TimetableBoard
    let period: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(TimetableTerm.ordinal(period + 1)) period").font(.system(size: 13, weight: .semibold))
            TimeField(title: "Starts", value: Binding(get: { board.term.periods[safe: period]?.start ?? "9:00" },
                                                       set: { v in board.change("p\(period)-s") { $0.periods[period].start = v } }))
            TimeField(title: "Ends", value: Binding(get: { board.term.periods[safe: period]?.end ?? "10:30" },
                                                     set: { v in board.change("p\(period)-e") { $0.periods[period].end = v } }))
            Text("A period that ends after midnight counts on the day it starts.").font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add a period after") {
                board.change { t in
                    t.periods.insert(TimetableImport.nextPeriod(after: t.periods[period]), at: period + 1)
                    for i in t.classes.indices where t.classes[i].period > period { t.classes[i].period += 1 }
                }
                board.side = .period(period + 1)
            }
            Button("Remove this period", role: .destructive) {
                board.change { t in
                    t.periods.remove(at: period)
                    t.classes.removeAll { $0.period == period }
                    for i in t.classes.indices where t.classes[i].period > period { t.classes[i].period -= 1 }
                }
                board.side = .none
            }
            .disabled(board.term.periods.count <= 1)
        }
    }
}

/// "9:00" as an hour and minute field.
struct TimeField: View {
    let title: String
    @Binding var value: String

    var body: some View {
        HStack {
        if !title.isEmpty { Text(title).frame(width: 48, alignment: .leading) }
        DatePicker(title, selection: Binding(
            get: {
                let m = TimetableTerm.minutes(value) ?? 540
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                value = String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
            }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
        }
    }
}

private struct DaysInspector: View {
    var board: TimetableBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("School days").font(.system(size: 13, weight: .semibold))
            DayToggles(days: Binding(get: { board.term.days }, set: { v in board.change { $0.days = v } }))
            Text("Classes on a day you turn off stay, hidden, until it's back on.").font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Mon … Sun, each one click to switch.
struct DayToggles: View {
    @Binding var days: [Int]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { d in
                let on = days.contains(d)
                Text(String(TimetableTerm.dayShort[d].prefix(2)))
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 26, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.07)))
                    .foregroundStyle(on ? Color.white : .secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { if on, days.count > 1 { days.removeAll { $0 == d } } else if !on { days = (days + [d]).sorted() } }
            }
        }
    }
}

/// School presets: a scheme's days and periods for this term; a Jikanwari catalog's group and courses for a new one.
private struct PresetsInspector: View {
    var board: TimetableBoard
    @State private var presets = TimetablePreset.all()
    @State private var catalog: TimetablePreset?
    @State private var lg = 0
    @State private var taking: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = catalog, let c = p.catalog, c.lgs.indices.contains(lg) {
                Button { catalog = nil } label: { Label(p.name, systemImage: "chevron.left") }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                Picker("Group", selection: $lg) { ForEach(c.lgs.indices, id: \.self) { Text(c.lgs[$0].name).tag($0) } }
                    .onChange(of: lg) { taking = c.defaults(c.lgs[lg]) }
                Text("Your courses").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(c.codes(c.lgs[lg]), id: \.self) { code in
                    Toggle(isOn: Binding(get: { taking.contains(code) }, set: { if $0 { taking.insert(code) } else { taking.remove(code) } })) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c.course(code).name + (c.course(code).note.isEmpty ? "" : " (\(c.course(code).note))")).font(.system(size: 12.5))
                            Text(c.rooms(code, in: c.lgs[lg])).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Button("Review") {
                    // Into the schedule just made for it (still empty), else a new one.
                    let e = Timetables.shared.editing
                    board.review = .init(term: c.term(for: c.lgs[lg], taking: taking), notes: "", file: nil, into: e?.classes.isEmpty == true ? e?.id : nil)
                    board.side = .none
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("School presets").font(.system(size: 13, weight: .semibold))
                ForEach(presets) { p in
                    Button {
                        if let c = p.catalog { catalog = p; lg = 0; taking = c.defaults(c.lgs[0]) } else { apply(p) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(size: 12.5, weight: .medium))
                            Text(p.catalog != nil ? "Pick your group and courses" : "\(p.periods.count) periods · \(p.periods.first!.start)–\(p.periods.last!.end)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("Open the presets folder") {
                    try? FileManager.default.createDirectory(at: TimetablePreset.userFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(TimetablePreset.userFolder)
                }
                .font(.system(size: 12))
            }
        }
    }

    /// The preset's days and periods for this term (classes in periods it doesn't have go). Undo brings them back.
    private func apply(_ p: TimetablePreset) {
        board.change { t in
            t.periods = p.periods
            t.days = p.days
            t.classes.removeAll { $0.period >= p.periods.count }
        }
        board.side = .none
    }
}

// MARK: Schedules

/// "Today" beside the schedule in use today.
struct TodayTag: View {
    var body: some View {
        Text("Today").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6).frame(height: 17)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
    }
}

/// Every schedule with its kind and dates (today's marked); a click opens one in the editor. Under it: new ones, and
/// what the dates add up to (no schedule today, which one is used where two overlap).
struct ScheduleList: View {
    var board = TimetableBoard.shared
    var store = Timetables.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.terms) { t in
                Button { store.select(t.id); board.clearPick() } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(t.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            if t.id == store.today?.id { TodayTag() }
                        }
                        Text([t.kind, t.range].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(t.id == store.editing?.id ? 0.12 : 0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Text("New").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Blank") { store.addTerm(.blank("Schedule \(store.terms.count + 1)")); board.clearPick() }
                if let e = store.editing { Button("Copy") { store.duplicate(e); board.clearPick() }.help("A copy of “\(e.name)” with its classes") }
                Button("Preset") { store.addTerm(.blank("Schedule \(store.terms.count + 1)")); board.select(nil); board.side = .presets }
            }
            .controlSize(.small)
            if store.today == nil, !store.terms.isEmpty { note("No schedule covers today.") }
            ForEach(store.terms.overlapNotes, id: \.self) { note($0) }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The open schedule's (or the import's) name, kind and dates.
struct ScheduleFields: View {
    var board: TimetableBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field("Name") { TextField("", text: bind(\.name)) }
            Field("Kind") { KindPicker(kind: bind(\.kind)) }
            Field("Dates") {
                VStack(alignment: .leading, spacing: 4) {
                    DayField(title: "From", none: "No start", value: bind(\.start))
                    DayField(title: "To", none: "No end", value: bind(\.end))
                }
            }
        }
    }

    private func bind(_ k: WritableKeyPath<TimetableTerm, String>) -> Binding<String> {
        let id = board.term.id
        return Binding(get: { board.term[keyPath: k] }, set: { v in board.change("\(id)-\(k)") { $0[keyPath: k] = v } })
    }
}

/// The schedule list, then the open one's name, kind and dates.
private struct SchedulesInspector: View {
    var board: TimetableBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedules").font(.system(size: 13, weight: .semibold))
            ScheduleList(board: board)
            if Timetables.shared.editing != nil {
                ScheduleFields(board: board)
                DeleteSchedule()
            }
        }
    }
}

/// A kind from a short list, or one of your own.
struct KindPicker: View {
    @Binding var kind: String
    static let common = ["Regular", "Exam period", "Intensive", "Holiday"]

    var body: some View {
        let custom = !kind.isEmpty && !Self.common.contains(kind)
        HStack(spacing: 6) {
            Picker("", selection: Binding(get: { custom ? "custom" : kind }, set: { kind = $0 == "custom" ? "Custom" : $0 })) {
                Text("None").tag("")
                ForEach(Self.common, id: \.self) { Text($0).tag($0) }
                Text("Custom").tag("custom")
            }
            .labelsHidden()
            .fixedSize()
            if custom { TextField("", text: $kind).textFieldStyle(.roundedBorder) }
        }
    }
}

/// A yyyy-MM-dd day, or none ("").
struct DayField: View {
    var title = ""
    let none: String
    @Binding var value: String

    var body: some View {
        HStack(spacing: 6) {
            if !title.isEmpty { Text(title).frame(width: 40, alignment: .leading) }
            if let d = TimetableTerm.parse(value) {
                DatePicker("", selection: Binding(get: { d }, set: { value = TimetableTerm.dayString($0, .current) }), displayedComponents: .date).labelsHidden()
                Button { value = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help(none)
            } else {
                Text(none).foregroundStyle(.secondary)
                Button("Set") { value = TimetableTerm.dayString(Timetables.shared.now, .current) }.controlSize(.small)
            }
        }
    }
}

/// Delete the open schedule, after asking.
struct DeleteSchedule: View {
    var store = Timetables.shared
    @State private var asking = false

    var body: some View {
        if let t = store.editing {
            Button("Delete “\(t.name)”…", role: .destructive) { asking = true }
                .confirmationDialog("Delete “\(t.name)”?", isPresented: $asking) {
                    Button("Delete", role: .destructive) { store.deleteTerm(t.id); TimetableBoard.shared.clearPick() }
                } message: {
                    Text("Its classes go with it. Undo brings it back.")
                }
        }
    }
}

// MARK: In the search bar

struct TimetablePanel: View {
    let radius: CGFloat

    @MainActor static var height: CGFloat { PanelLayout.vertical + TimetableEditor.height }

    var body: some View {
        TimetableEditor(radius: radius)
            .padding(PanelLayout.edges)
            .onDisappear { TimetableBoard.shared.select(nil); TimetableBoard.shared.cursor = nil }
    }
}
