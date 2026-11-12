import AppKit
import SwiftUI

/// How the week grid looks (kept with the timetables, not in Settings).
struct TimetableLook: Codable, Equatable {
    /// Font family; "" is the system font.
    var nameFamily = ""
    var nameSize = 12.5
    /// Index into `weights`.
    var nameWeight = 5
    var detailFamily = ""
    var detailSize = 10.5
    var detailWeight = 3
    /// 0 compact, 1 regular, 2 roomy.
    var density = 1
    /// 0 soft, 1 solid, 2 stripe, 3 plain.
    var colorStyle = 0
    var showRoom = true
    var showTeacher = false
    var showTime = true

    init() {}

    /// Lenient, so looks saved before a new option keep the rest.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let x = TimetableLook()
        nameFamily = (try? c.decode(String.self, forKey: .nameFamily)) ?? x.nameFamily
        nameSize = (try? c.decode(Double.self, forKey: .nameSize)) ?? x.nameSize
        nameWeight = (try? c.decode(Int.self, forKey: .nameWeight)) ?? x.nameWeight
        detailFamily = (try? c.decode(String.self, forKey: .detailFamily)) ?? x.detailFamily
        detailSize = (try? c.decode(Double.self, forKey: .detailSize)) ?? x.detailSize
        detailWeight = (try? c.decode(Int.self, forKey: .detailWeight)) ?? x.detailWeight
        density = (try? c.decode(Int.self, forKey: .density)) ?? x.density
        colorStyle = (try? c.decode(Int.self, forKey: .colorStyle)) ?? x.colorStyle
        showRoom = (try? c.decode(Bool.self, forKey: .showRoom)) ?? x.showRoom
        showTeacher = (try? c.decode(Bool.self, forKey: .showTeacher)) ?? x.showTeacher
        showTime = (try? c.decode(Bool.self, forKey: .showTime)) ?? x.showTime
    }

    static let weights: [(String, Font.Weight)] = [("Ultralight", .ultraLight), ("Thin", .thin), ("Light", .light), ("Regular", .regular),
                                                   ("Medium", .medium), ("Semibold", .semibold), ("Bold", .bold), ("Heavy", .heavy), ("Black", .black)]

    var cellHeight: CGFloat { [44, 58, 76][min(2, max(0, density))] }
    var nameFont: Font { Self.font(nameFamily, nameSize, nameWeight) }
    var detailFont: Font { Self.font(detailFamily, detailSize, detailWeight) }

    static func font(_ family: String, _ size: Double, _ weight: Int) -> Font {
        let w = weights[min(weights.count - 1, max(0, weight))].1
        return family.isEmpty ? .system(size: size, weight: w) : .custom(family, size: size).weight(w)
    }
}

// MARK: Settings › Timetable

struct TimetablePane: View {
    @Bindable var store: Store
    var tt = Timetables.shared
    var board = TimetableBoard.shared
    @State private var families = NSFontManager.shared.availableFontFamilies
    /// `--tt-settings-below`: snapshots of the settings under the grid.
    nonisolated(unsafe) static var formOnly = false

    var body: some View {
        Form {
            if !Self.formOnly {
                Section {
                    TimetableEditor(radius: 16, inSettings: true).padding(.vertical, 4)
                }
            }
            Section {
                ScheduleList()
            } header: {
                Text("Schedules")
            } footer: {
                Text("Each day uses the schedule its dates fall in. Where two overlap, the shorter one is used.").font(.caption).foregroundStyle(.secondary)
            }
            // During an import the grid shows it: the periods below are its, and the side panel holds its name and dates.
            if board.review == nil, tt.editing != nil {
                Section("Schedule") {
                    TextField("Name", text: bind(\.name))
                    LabeledContent("Kind") { KindPicker(kind: bind(\.kind)) }
                    LabeledContent("From") { DayField(none: "No start", value: bind(\.start)) }
                    LabeledContent("To") { DayField(none: "No end", value: bind(\.end)) }
                    LabeledContent("School days") { DayToggles(days: Binding(get: { board.term.days }, set: { v in board.change { $0.days = v } })) }
                    HStack { Spacer(); DeleteSchedule() }
                }
            }
            Section {
                let periods = board.term.periods
                ForEach(periods.indices, id: \.self) { i in
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(width: 20, alignment: .leading)
                        TimeField(title: "", value: Binding(get: { board.term.periods[safe: i]?.start ?? "" }, set: { v in board.change("p\(i)-s") { $0.periods[i].start = v } }))
                            .labelsHidden()
                        Text("to").foregroundStyle(.secondary)
                        TimeField(title: "", value: Binding(get: { board.term.periods[safe: i]?.end ?? "" }, set: { v in board.change("p\(i)-e") { $0.periods[i].end = v } }))
                            .labelsHidden()
                        Spacer()
                        Button { removePeriod(i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .disabled(periods.count <= 1).help("Remove")
                    }
                }
                HStack {
                    Button("Add a period") { board.change { $0.periods.append(TimetableImport.nextPeriod(after: $0.periods.last)) } }
                    Spacer()
                    if board.review == nil {
                        Button("Undo") { tt.undo() }.disabled(!tt.canUndo)
                        Button("Redo") { tt.redo() }.disabled(!tt.canRedo)
                    }
                }
            } header: {
                Text("Periods")
            } footer: {
                Text("A period ending after midnight counts on the day it starts.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Class names") {
                fontRows(family: \.nameFamily, size: \.nameSize, weight: \.nameWeight, range: 9...20)
            }
            Section("Rooms and teachers") {
                fontRows(family: \.detailFamily, size: \.detailSize, weight: \.detailWeight, range: 8...16)
            }
            Section("Grid") {
                Picker("Cell size", selection: look(\.density)) { Text("Compact").tag(0); Text("Regular").tag(1); Text("Roomy").tag(2) }
                    .pickerStyle(.segmented)
                Picker("Colours", selection: look(\.colorStyle)) { Text("Soft").tag(0); Text("Solid").tag(1); Text("Stripe").tag(2); Text("Plain").tag(3) }
                    .pickerStyle(.segmented)
                Toggle("Room", isOn: look(\.showRoom))
                Toggle("Teacher", isOn: look(\.showTeacher))
                Toggle("Period times", isOn: look(\.showTime))
                HStack {
                    Spacer()
                    Button("Reset the look") { tt.look = TimetableLook() }.disabled(tt.look == TimetableLook())
                }
            }
        }
    }

    private func look<V>(_ k: WritableKeyPath<TimetableLook, V>) -> Binding<V> {
        Binding(get: { tt.look[keyPath: k] }, set: { tt.look[keyPath: k] = $0 })
    }

    @ViewBuilder private func fontRows(family: WritableKeyPath<TimetableLook, String>, size: WritableKeyPath<TimetableLook, Double>,
                                       weight: WritableKeyPath<TimetableLook, Int>, range: ClosedRange<Double>) -> some View {
        Picker("Font", selection: look(family)) {
            Text("System").tag("")
            Divider()
            ForEach(families, id: \.self) { Text($0).tag($0) }
        }
        LabeledContent("Size") {
            HStack {
                Slider(value: look(size), in: range, step: 0.5).frame(minWidth: 180)
                Text(String(format: "%.1f pt", tt.look[keyPath: size])).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
        }
        Picker("Weight", selection: look(weight)) {
            ForEach(TimetableLook.weights.indices, id: \.self) { Text(TimetableLook.weights[$0].0).tag($0) }
        }
    }

    /// The open schedule's field (the import's, while one is being looked over).
    private func bind(_ k: WritableKeyPath<TimetableTerm, String>) -> Binding<String> {
        let id = board.term.id
        return Binding(get: { board.term[keyPath: k] }, set: { v in board.change("\(id)-\(k)") { $0[keyPath: k] = v } })
    }

    private func removePeriod(_ i: Int) {
        board.change { t in
            t.periods.remove(at: i)
            t.classes.removeAll { $0.period == i }
            for k in t.classes.indices where t.classes[k].period > i { t.classes[k].period -= 1 }
        }
    }
}
