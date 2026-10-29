import AppKit
import SwiftUI

// MARK: ⌘5 Clock: Focus, Timers, Stopwatches, Alarms

private let gap = PanelLayout.gap
private let orange = Color(nsColor: .systemOrange)

struct ClockHub: View {
    let model: LauncherModel
    let pomodoro: Pomodoro
    let radius: CGFloat

    static let tabsHeight: CGFloat = 38

    static func height(_ model: LauncherModel) -> CGFloat {
        let body: CGFloat = switch model.clockMode {
        case .focus: 140
        case .timer: TimersView.height(model)
        case .stopwatch: StopwatchesView.height()
        case .alarms: AlarmsView.height(model)
        }
        return PanelLayout.inset * 2 + gap + tabsHeight + body
    }

    var body: some View {
        VStack(spacing: gap) {
            ClockTabs(model: model, pomodoro: pomodoro, radius: radius)
                .frame(height: Self.tabsHeight)
            Group {
                switch model.clockMode {
                case .focus:
                    Block(radius: radius) { PomodoroView(pomodoro: pomodoro, query: model.query) { plan in model.setQuery(plan) } }
                case .timer: TimersView(model: model, timers: Timers.shared, radius: radius)
                case .stopwatch: StopwatchesView(watches: Stopwatches.shared, radius: radius)
                case .alarms: AlarmsView(model: model, alarms: Alarms.shared, radius: radius)
                }
            }
            .transition(.opacity)
        }
        .padding(PanelLayout.inset)
    }
}

/// The four clocks as a segmented row; a dot marks the ones that are running.
private struct ClockTabs: View {
    let model: LauncherModel
    let pomodoro: Pomodoro
    let radius: CGFloat

    var body: some View {
        let outer = PanelLayout.inner(radius)
        HStack(spacing: 4) {
            ForEach(ClockMode.allCases) { m in
                let on = model.clockMode == m
                Button { model.setClockMode(m) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: m.symbol).font(.system(size: 12, weight: .semibold))
                        Text(m.title).font(.system(size: 13, weight: .medium))
                        if running(m) { Circle().fill(orange).frame(width: 5, height: 5) }
                    }
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: max(4, outer - 4), style: .continuous).fill(Color.primary.opacity(on ? 0.16 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: outer, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func running(_ m: ClockMode) -> Bool {
        switch m {
        case .focus: pomodoro.active
        case .timer: !Timers.shared.running.isEmpty
        case .stopwatch: !Stopwatches.shared.running.isEmpty
        case .alarms: !Alarms.shared.upcoming.isEmpty
        }
    }
}

/// A round icon button (the clock controls are icons only).
struct ClockButton: View {
    let symbol: String
    var tint: Color?
    var help = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint == nil ? Color.primary : Color.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.map { $0.opacity(hover ? 1 : 0.9) } ?? Color.primary.opacity(hover ? 0.18 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// A small text choice (presets, days, durations).
private struct Choice: View {
    let title: String
    var on = false
    var round = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, round ? 0 : 12)
                .frame(width: round ? 32 : nil, height: 30)
                .background(Capsule().fill(on ? orange : Color.primary.opacity(hover ? 0.16 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct Ring: View {
    let progress: Double
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3.5)
            Circle().trim(from: 0, to: progress).stroke(orange, style: StrokeStyle(lineWidth: 3.5, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

// MARK: Timers

/// Several clocks show as a grid of tiles, two across (one alone fills the width).
private func gridColumns(_ count: Int) -> [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: PanelLayout.gap), count: count > 1 ? 2 : 1)
}
private let tileHeight: CGFloat = 86

private func gridHeight(_ count: Int, maxRows: Int) -> CGFloat {
    let rows = min(count > 1 ? (count + 1) / 2 : count, maxRows)
    return rows > 0 ? CGFloat(rows) * tileHeight + CGFloat(rows - 1) * PanelLayout.gap : 0
}

struct TimersView: View {
    let model: LauncherModel
    let timers: Timers
    let radius: CGFloat

    static let composerHeight: CGFloat = 124
    static var defaultMinutes: Double { Store.shared.settings.timerDefaultMinutes }
    private static let presets = [1, 3, 5, 10, 15, 30, 60]

    static func composing(_ model: LauncherModel) -> Bool { model.timerComposer || Timers.shared.list.isEmpty }

    /// "5m, 10m tea, 1h": one timer per comma.
    static func parts(_ query: String) -> [(minutes: Double, label: String)] {
        query.components(separatedBy: CharacterSet(charactersIn: ",、，")).compactMap { part in
            let p = SystemTools.minutes(part.trimmingCharacters(in: .whitespaces))
            return p.value.map { ($0, p.label) }
        }
    }

    static func height(_ model: LauncherModel) -> CGFloat {
        let composer = composing(model)
        let grid = gridHeight(Timers.shared.list.count, maxRows: composer ? 1 : 2)
        return (composer ? composerHeight : 0) + grid + (composer && grid > 0 ? PanelLayout.gap : 0)
    }

    var body: some View {
        let all = Self.parts(model.query)
        let first = all.first
        let mins = first?.minutes ?? Self.defaultMinutes
        let label = first.flatMap { $0.label.isEmpty ? nil : $0.label }
        VStack(spacing: PanelLayout.gap) {
            if Self.composing(model) {
                Block(radius: radius) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            Text(Pomodoro.clock(mins * 60))
                                .font(.system(size: 44, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(.smooth(duration: 0.25), value: mins)
                            VStack(alignment: .leading, spacing: 1) {
                                if let label { Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary) }
                                if all.count > 1 {
                                    Text(all.dropFirst().map { SystemTools.span($0.minutes) + ($0.label.isEmpty ? "" : " " + $0.label) }.joined(separator: " · "))
                                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            if all.count <= 1 {
                                ClockButton(symbol: "minus", help: "1 minute less") { set(max(1, mins - 1), label) }
                                ClockButton(symbol: "plus", help: "1 minute more") { set(mins + 1, label) }
                            }
                            ClockButton(symbol: "play.fill", tint: orange, help: all.count > 1 ? "Start \(all.count) timers" : "Start") {
                                (NSApp.delegate as? AppDelegate)?.launcher.startTimer()
                            }
                        }
                        HStack(spacing: 6) {
                            ForEach(Self.presets, id: \.self) { m in
                                Choice(title: m == 60 ? "1 h" : "\(m) min", on: all.count <= 1 && Double(m) == mins) { set(Double(m), label) }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(16)
                }
                .frame(height: Self.composerHeight)
            }
            if !timers.list.isEmpty {
                ScrollView(.vertical) {
                    LazyVGrid(columns: gridColumns(timers.list.count), spacing: PanelLayout.gap) {
                        ForEach(timers.list) { t in tile(t) }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: gridHeight(timers.list.count, maxRows: Self.composing(model) ? 1 : 2))
            }
        }
    }

    private func tile(_ t: CountdownTimer) -> some View {
        let now = timers.now
        return Block(radius: radius) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Ring(progress: t.progress(now), size: 18)
                    Text(t.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .center) {
                    Text(Pomodoro.clock(t.remaining(now)))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(t.finished ? orange : t.paused ? .secondary : .primary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 4)
                    ClockButton(symbol: "goforward.60", help: "1 minute more") { timers.extend(t, 60) }
                    ClockButton(symbol: t.finished ? "arrow.clockwise" : t.paused ? "play.fill" : "pause.fill", tint: orange,
                                help: t.finished ? "Again" : t.paused ? "Resume" : "Pause") { timers.toggle(t) }
                    ClockButton(symbol: "xmark", help: "Remove") { timers.remove(t) }
                }
            }
            .padding(14)
        }
        .frame(height: tileHeight)
    }

    private func set(_ minutes: Double, _ label: String?) {
        let text = minutes == minutes.rounded() ? "\(Int(minutes))m" : "\(Int(minutes))m \(Int(((minutes - minutes.rounded(.down)) * 60).rounded()))s"
        model.setQuery(text + (label.map { " " + $0 } ?? ""))
    }
}

// MARK: Stopwatches

struct StopwatchesView: View {
    let watches: Stopwatches
    let radius: CGFloat

    static let lapHeight: CGFloat = 24

    static func height() -> CGFloat {
        let list = Stopwatches.shared.list
        let laps = min(list.first?.laps.count ?? 0, 3)
        return gridHeight(list.count, maxRows: 2) + (laps > 0 ? PanelLayout.gap + CGFloat(laps) * lapHeight + 24 : 0)
    }

    var body: some View {
        VStack(spacing: PanelLayout.gap) {
            ScrollView(.vertical) {
                LazyVGrid(columns: gridColumns(watches.list.count), spacing: PanelLayout.gap) {
                    ForEach(Array(watches.list.enumerated()), id: \.element.id) { i, w in tile(w, number: watches.list.count - i) }
                }
            }
            .scrollIndicators(.never)
            .frame(height: gridHeight(watches.list.count, maxRows: 2))
            if let first = watches.list.first, !first.laps.isEmpty { laps(first) }
        }
    }

    private func tile(_ w: Stopwatch, number: Int) -> some View {
        Block(radius: radius) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "stopwatch").font(.system(size: 13, weight: .semibold)).foregroundStyle(w.running ? orange : .secondary)
                    Text(watches.list.count > 1 ? "Stopwatch \(number)" : "Stopwatch").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .center) {
                    Text(Stopwatch.format(w.elapsed(watches.now), hundredths: Store.shared.settings.stopwatchHundredths))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(w.active ? .primary : .secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 4)
                    if w.running {
                        ClockButton(symbol: "flag.fill", help: "Lap") { watches.lap(w) }
                    } else if w.active {
                        ClockButton(symbol: "arrow.counterclockwise", help: "Reset") { watches.reset(w) }
                    }
                    ClockButton(symbol: w.running ? "pause.fill" : "play.fill", tint: orange, help: w.running ? "Pause" : "Start") { watches.toggle(w) }
                    if watches.list.count > 1 { ClockButton(symbol: "xmark", help: "Remove") { watches.remove(w) } }
                }
            }
            .padding(14)
        }
        .frame(height: tileHeight)
    }

    private func laps(_ w: Stopwatch) -> some View {
        let splits = zip(w.laps, w.laps.dropFirst() + [0]).map { $0 - $1 }
        let fastest = splits.count > 1 ? splits.min() : nil, slowest = splits.count > 1 ? splits.max() : nil
        let shown = min(w.laps.count, 3)
        return Block(radius: radius) {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(w.laps.indices, id: \.self) { i in
                        HStack {
                            Text("Lap \(w.laps.count - i)").foregroundStyle(.secondary)
                            Spacer()
                            Text(Stopwatch.format(splits[i])).foregroundStyle(splits[i] == fastest ? Color.green : splits[i] == slowest ? Color.red : Color.primary)
                            Text(Stopwatch.format(w.laps[i])).foregroundStyle(.tertiary).frame(width: 96, alignment: .trailing)
                        }
                        .font(.system(size: 13).monospacedDigit())
                        .frame(height: Self.lapHeight)
                    }
                }
            }
            .scrollIndicators(.never)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(height: CGFloat(shown) * Self.lapHeight + 24)
    }
}

// MARK: Alarms

struct AlarmsView: View {
    let model: LauncherModel
    let alarms: Alarms
    let radius: CGFloat

    static let rowHeight: CGFloat = 58
    static let editorHeight: CGFloat = 318
    static let headerHeight: CGFloat = 20

    static func height(_ model: LauncherModel) -> CGFloat {
        let a = Alarms.shared
        var h: CGFloat = a.ringing != nil ? 58 + gap : 0
        if model.alarmDraft != nil { return h + editorHeight }
        let up = a.upcoming.count, past = a.past.count
        if up + past == 0 { return h + 64 }
        let rows = min(up + past, 4)
        h += CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * gap
        if past > 0, rows > up { h += headerHeight + gap }
        return h
    }

    var body: some View {
        VStack(spacing: gap) {
            if let a = alarms.ringing { ringing(a) }
            if let draft = model.alarmDraft {
                AlarmEditor(model: model, draft: draft, radius: radius)
                    .frame(height: Self.editorHeight)
            } else if alarms.list.isEmpty {
                Block(radius: radius) {
                    Image(systemName: "alarm").font(.system(size: 22)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 64)
            } else {
                let up = alarms.upcoming, past = alarms.past
                let rows = min(up.count + past.count, 4)
                ScrollView(.vertical) {
                    VStack(spacing: gap) {
                        ForEach(up) { a in row(a, past: false) }
                        if !past.isEmpty {
                            HStack {
                                Text("Past").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear") { alarms.clearPast() }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(orange)
                            }
                            .padding(.horizontal, 6)
                            .frame(height: Self.headerHeight)
                            ForEach(past) { a in row(a, past: true) }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: CGFloat(rows) * Self.rowHeight + CGFloat(max(0, rows - 1)) * gap + (past.isEmpty || rows <= up.count ? 0 : Self.headerHeight + gap))
            }
        }
    }

    private func ringing(_ a: Alarm) -> some View {
        Block(radius: radius, fill: 0.14) {
            HStack(spacing: 12) {
                Image(systemName: "alarm.waves.left.and.right.fill").font(.system(size: 20)).foregroundStyle(orange).symbolEffect(.bounce, options: .repeating)
                VStack(alignment: .leading, spacing: 0) {
                    Text(a.time).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(a.label.isEmpty ? "Alarm" : a.label).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if a.snooze { ClockButton(symbol: "zzz", help: "Snooze \(a.snoozeMinutes) min") { alarms.snooze() } }
                ClockButton(symbol: "stop.fill", tint: orange, help: "Stop") { alarms.dismiss() }
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 58)
    }

    private func row(_ a: Alarm, past: Bool) -> some View {
        Block(radius: radius, fill: past ? 0.035 : 0.06) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(a.time).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(a.enabled ? .primary : .secondary)
                    Text(detail(a, past: past)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { a.enabled }, set: { alarms.setEnabled(a.id, $0) })).toggleStyle(.switch).labelsHidden()
                ClockButton(symbol: "pencil", help: "Edit") { model.editAlarm(a) }
                ClockButton(symbol: "trash", help: "Delete") { alarms.remove(a.id) }
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.rowHeight)
    }

    private func detail(_ a: Alarm, past: Bool) -> String {
        let name = a.label.isEmpty ? "Alarm" : a.label
        if past, let rang = a.lastRang {
            let df = DateFormatter()
            df.doesRelativeDateFormatting = true
            df.dateStyle = .short
            df.timeStyle = .short
            return "\(name) · rang \(df.string(from: rang))"
        }
        return "\(name) · \(a.repeatText)"
    }
}

/// Add or edit an alarm, like the Clock app: a big time with the part you're changing highlighted.
private struct AlarmEditor: View {
    let model: LauncherModel
    let draft: AlarmDraft
    let radius: CGFloat

    var body: some View {
        Block(radius: radius) {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Spacer()
                    TimePicker(model: model, hour: draft.hour, minute: draft.minute)
                    VStack(spacing: 4) {
                        ClockButton(symbol: "chevron.up", help: "Later") { model.nudgeAlarm(1) }
                        ClockButton(symbol: "chevron.down", help: "Earlier") { model.nudgeAlarm(-1) }
                    }
                    Spacer()
                }
                field("Repeat") {
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { d in
                            Choice(title: String(Calendar.current.veryShortWeekdaySymbols[d - 1]), on: draft.weekdays.contains(d), round: true) {
                                model.updateDraft { if $0.weekdays.contains(d) { $0.weekdays.remove(d) } else { $0.weekdays.insert(d) } }
                            }
                        }
                    }
                }
                field("Label") {
                    TextField("", text: Binding(get: { draft.label }, set: { v in model.updateDraft { $0.label = v } }), prompt: Text("Alarm"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .frame(width: 260, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.25)))
                }
                field("Sound") {
                    Menu(draft.sound) {
                        ForEach(ClockSound.names, id: \.self) { n in
                            Button(n) {
                                model.updateDraft { $0.sound = n }
                                ClockSound.play(n)
                            }
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
                field("Snooze") {
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(get: { draft.snooze }, set: { v in model.updateDraft { $0.snooze = v } })).toggleStyle(.checkbox).labelsHidden()
                        Menu("\(draft.snoozeMinutes) min") {
                            ForEach([1, 5, 9, 10, 15, 20, 30], id: \.self) { m in Button("\(m) min") { model.updateDraft { $0.snoozeMinutes = m } } }
                        }
                        .menuStyle(.button)
                        .fixedSize()
                        .disabled(!draft.snooze)
                    }
                }
                HStack(spacing: 8) {
                    if let id = draft.editing {
                        Button("Delete") {
                            Alarms.shared.remove(id)
                            model.alarmDraft = nil
                        }
                        .buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 13, weight: .medium))
                    }
                    Spacer()
                    Choice(title: "Cancel") { withAnimation(.smooth(duration: 0.2)) { model.alarmDraft = nil } }
                    Choice(title: "Save", on: true) { model.saveAlarmDraft() }
                }
            }
            .padding(16)
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
        .frame(height: 30)
    }
}

enum TimePickerInfo {
    static var segments: Int { TimePicker.twelveHour ? 3 : 2 }
}

/// HH : MM (and AM/PM where the Mac uses a 12-hour clock). Click a part, then ↑↓, the chevrons, or type the time in the bar.
struct TimePicker: View {
    let model: LauncherModel
    let hour: Int
    let minute: Int

    static var twelveHour: Bool { (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a") }

    var body: some View {
        let twelve = Self.twelveHour
        let h = twelve ? (hour % 12 == 0 ? 12 : hour % 12) : hour
        HStack(spacing: 0) {
            part(0, twelve ? "\(h)" : String(format: "%02d", h))
            Text(":").font(.system(size: 54, weight: .light, design: .rounded)).foregroundStyle(.secondary).padding(.bottom, 6)
            part(1, String(format: "%02d", minute))
            if twelve { part(2, hour < 12 ? "AM" : "PM", small: true).padding(.leading, 6) }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func part(_ i: Int, _ text: String, small: Bool = false) -> some View {
        let on = model.alarmSegment == i
        return Text(text)
            .font(.system(size: small ? 24 : 54, weight: .light, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? orange : .clear))
            .contentShape(Rectangle())
            .onTapGesture { model.alarmSegment = i }
    }
}
