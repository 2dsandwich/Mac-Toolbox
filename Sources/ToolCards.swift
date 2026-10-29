import AppKit
import SwiftUI

/// Rich layouts for answers that need more than one line: weather, money, clocks, switches…
/// A card is one result in the list (↩ runs its main action; chips and buttons inside do the rest).
enum ToolCard {
    struct Chip {
        var label: String
        var value: String
        var action: Answer.Action
    }

    /// A button or a menu on a card (swap units, pick a currency, change length…). Menus list (title, action).
    struct Control {
        var symbol: String
        var title: String?
        var help: String
        var action: Answer.Action?
        var menu: [(String, Answer.Action)] = []
    }

    struct Volume {
        var value: Double
        var muted: Bool
        var set: @MainActor (Double) -> Void
        var toggleMute: Answer.Action
        var chips: [Chip]
    }

    struct Big {
        var title: String
        var symbol: String
        var color: NSColor
        var caption: String?
        var value: String
        var unit: String?
        var detail: String?
        var chips: [Chip] = []
        /// ↻ (dice, passwords…).
        var again: Answer.Action?
        var mono = false
        var controls: [Control] = []
    }

    struct Clock {
        var name: String
        var zone: TimeZone
        /// A fixed moment (time conversions); nil = live.
        var at: Date?
        var here = false
    }

    struct Gauge {
        var title: String
        var symbol: String
        var color: NSColor
        var value: String
        var caption: String
        var fraction: Double
        var detail: String?
    }

    struct Switch {
        var title: String
        var detail: String
        var symbol: String
        var color: NSColor
        var isOn: Bool
        var toggle: Answer.Action
        /// An extra slider under the switch (Night Shift warmth).
        var level: Double?
        var setLevel: (@MainActor (Double) -> Void)?
    }

    case weather(LiveData.Forecast, place: String)
    case rain(LiveData.Forecast, place: String, verdict: String)
    case big(Big)
    case clocks([Clock], convert: Bool)
    case color(NSColor, [Chip])
    case qr(NSImage, text: String)
    case timer(minutes: Double, label: String?, presets: [Chip])
    case password(String, length: Int, chips: [Chip], again: Answer.Action, controls: [Control])
    case translate(source: String, result: String?, lang: String, busy: Bool, controls: [Control])
    case volume(Volume)
    case media
    case define(word: String, detail: String, text: String)
    case moon(emoji: String, phase: String, detail: String, next: [(String, String)])
    case gauge(Gauge)
    case toggle(Switch)

    /// Room for the card: what its content needs, the padding round it, and the header with its gap.
    @MainActor var height: CGFloat { content + 2 * (cardPadding - 14) - (header == nil ? 0 : 1) }

    /// The heights below were measured with a 14 pt inset and a 9 pt gap under the header.
    private var content: CGFloat {
        switch self {
        case .weather: 312
        case .rain: 156
        case .big(let b): 98 + (b.caption == nil ? 0 : 21) + (b.detail == nil ? 0 : 20) + (b.chips.isEmpty ? 0 : 40)
        case .clocks: 138
        case .color: 150
        case .qr: 196
        case .timer: 160
        case .password: 144
        case .translate: 178
        case .define: 168
        case .moon: 124
        case .gauge(let g): g.detail == nil ? 120 : 138
        case .toggle(let t): t.level == nil ? 88 : 128
        case .volume: 140
        case .media: 112
        }
    }

    /// The small heading at the top of the card.
    @MainActor var header: (symbol: String, title: String, color: NSColor)? {
        switch self {
        case .weather(_, let place): ("cloud.sun.fill", "Weather · \(place)", .systemBlue)
        case .rain(_, let place, _): ("umbrella.fill", "Rain · \(place)", .systemBlue)
        case .big(let b): (b.symbol, b.title, b.color)
        case .clocks(_, let convert): (convert ? "clock.arrow.2.circlepath" : "clock.fill", convert ? "Time conversion" : "World clock", .systemIndigo)
        case .color: ("paintpalette.fill", "Color", .systemPink)
        case .qr: ("qrcode", "QR code", .systemGray)
        case .timer: ("timer", "Timer", .systemOrange)
        case .password: ("key.fill", "Password", .systemGray)
        case .translate(_, _, let lang, _, _): ("character.bubble.fill", "Translate → \(lang)", .systemPurple)
        case .volume: ("speaker.wave.2.fill", "Volume", .systemBlue)
        case .media: ("music.note", NowPlaying.shared.available ? "Now playing · \(NowPlaying.shared.appName)" : "Media", .systemPink)
        case .define: ("character.book.closed.fill", "Dictionary", .systemBrown)
        case .moon: ("moon.fill", "Moon", .systemIndigo)
        case .gauge(let g): (g.symbol, g.title, g.color)
        case .toggle(let t): (t.symbol, t.title, t.color)
        }
    }
}

let cardFill = Color.primary.opacity(0.045)
/// The same inset on every side of a card; inner corners are the card's radius minus it (concentric).
/// The same inset as everything else (PanelLayout.inset).
let cardPadding: CGFloat = 16

private struct CardInnerKey: EnvironmentKey { static let defaultValue: CGFloat = 8 }
extension EnvironmentValues {
    var cardInner: CGFloat {
        get { self[CardInnerKey.self] }
        set { self[CardInnerKey.self] = newValue }
    }
}

struct AnswerCardView: View {
    let card: ToolCard
    let hint: String
    let selected: Bool
    let hovered: Bool
    let radius: CGFloat
    let onAction: (Answer.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.gap) {
            if let h = card.header {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(Color(nsColor: h.color).gradient)
                        .frame(width: 18, height: 18)
                        .overlay(Image(systemName: h.symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white))
                    Text(h.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                }
            }
            content
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.cardInner, max(6, radius - cardPadding))
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(selected ? selectedFill : hovered ? hoverFill : cardFill))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var content: some View {
        switch card {
        case .weather(let f, _): WeatherCard(f: f)
        case .rain(let f, _, let verdict): RainCard(f: f, verdict: verdict)
        case .big(let b): BigCard(b: b, onAction: onAction)
        case .clocks(let clocks, let convert): ClocksCard(clocks: clocks, convert: convert)
        case .color(let c, let chips): ColorCard(color: c, chips: chips, onAction: onAction)
        case .qr(let img, let text): QRCard(image: img, text: text, onAction: onAction)
        case .timer(let minutes, let label, let presets): TimerCard(minutes: minutes, label: label, presets: presets, onAction: onAction)
        case .password(let pw, let length, let chips, let again, let controls):
            PasswordCard(password: pw, length: length, chips: chips, again: again, controls: controls, onAction: onAction)
        case .translate(let source, let result, _, let busy, let controls): TranslateCard(source: source, result: result, busy: busy, controls: controls, onAction: onAction)
        case .volume(let v): VolumeCard(v: v, onAction: onAction)
        case .media: MediaCardInList()
        case .define(let word, let detail, let text): DefineCard(word: word, detail: detail, text: text)
        case .moon(let emoji, let phase, let detail, let next): MoonCard(emoji: emoji, phase: phase, detail: detail, next: next)
        case .gauge(let g): GaugeCard(g: g)
        case .toggle(let t): ToggleCard(t: t, onAction: onAction)
        }
    }
}

// MARK: Pieces

private struct ChipButton: View {
    let chip: ToolCard.Chip
    let onAction: (Answer.Action) -> Void
    @State private var hover = false

    var body: some View {
        Button { onAction(chip.action) } label: {
            HStack(spacing: 6) {
                if !chip.label.isEmpty {
                    Text(chip.label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(chip.value).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(hover ? 0.14 : 0.075)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }

    }
}

private struct ChipRow: View {
    let chips: [ToolCard.Chip]
    let onAction: (Answer.Action) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips.indices, id: \.self) { i in ChipButton(chip: chips[i], onAction: onAction) }
            Spacer(minLength: 0)
        }
    }
}

private struct RoundIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

private func deg(_ v: Double) -> String { "\(Int(v.rounded()))°" }

// MARK: Cards

private struct BigCard: View {
    let b: ToolCard.Big
    let onAction: (Answer.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption = b.caption {
                Text(caption).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(b.value)
                    .font(.system(size: 34, weight: .semibold, design: b.mono ? .monospaced : .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                    .textSelection(.enabled)
                if let unit = b.unit {
                    Text(unit).font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 0)
                ForEach(b.controls.indices, id: \.self) { i in
                    ControlButton(control: b.controls[i], onAction: onAction)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                }
                if let again = b.again {
                    RoundIcon(symbol: "arrow.clockwise", help: "Again") { onAction(again) }
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                }
            }
            if let detail = b.detail {
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            if !b.chips.isEmpty {
                ChipRow(chips: b.chips, onAction: onAction).padding(.top, 6)
            }
        }
    }
}

/// Now (a big temperature, the sky, today's high and low) with the details in small tiles; the next hours and the
/// next days beside it, each day's range as a bar on the week's scale.
private struct WeatherCard: View {
    let f: LiveData.Forecast
    @Environment(\.cardInner) private var inner

    var body: some View {
        let now = LiveData.wmo(f.code, day: f.isDay)
        let today = f.days.first
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    Self.symbol(f.code, day: f.isDay).font(.system(size: 34))
                    Text(deg(f.temp)).font(.system(size: 46, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Text(now.text).font(.system(size: 14, weight: .semibold)).padding(.top, 2)
                if let today { Text("H \(deg(today.hi))  L \(deg(today.lo))").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.top, 1) }
                Spacer(minLength: 10)
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        tile("thermometer.medium", "Feels like", deg(f.feels))
                        tile("humidity.fill", "Humidity", "\(f.humidity)%")
                    }
                    GridRow {
                        tile("wind", "Wind", "\(Int(f.wind.rounded())) \(f.windUnit)")
                        tile("umbrella.fill", "Rain", "\(today?.rain ?? 0)%")
                    }
                }
            }
            .frame(width: 210, alignment: .leading)
            VStack(spacing: 8) {
                panel("clock", "Next hours") {
                    HStack(spacing: 0) {
                        ForEach(hours.indices, id: \.self) { i in
                            let h = hours[i]
                            VStack(spacing: 8) {
                                Text(i == 0 ? "Now" : hourLabel(h.time)).font(.system(size: 11)).foregroundStyle(.secondary)
                                Self.symbol(h.code, day: isDay(h.time)).font(.system(size: 17)).frame(height: 20)
                                if hours.contains(where: { $0.rain >= 20 }) {
                                    Text(h.rain >= 20 ? "\(h.rain)%" : " ").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color(red: 0.55, green: 0.8, blue: 1))
                                }
                                Text(deg(h.temp)).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                panel("calendar", "Next \(days.count) days") {
                    VStack(spacing: 0) {
                        ForEach(days.indices, id: \.self) { i in
                            dayRow(days[i], first: i == 0)
                            if i < days.count - 1 { Divider().opacity(0.5) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func tile(_ symbol: String, _ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.system(size: 10.5)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: inner, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func panel<Content: View>(_ symbol: String, _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 10.5)).foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: inner, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    /// One day: name, sky (and chance of rain), low, its range on the week's scale, high. Today marks where it is now.
    private func dayRow(_ d: LiveData.Forecast.Day, first: Bool) -> some View {
        let lo = days.map(\.lo).min() ?? d.lo, hi = days.map(\.hi).max() ?? d.hi
        return HStack(spacing: 8) {
            Text(first ? "Today" : dayLabel(d.date)).font(.system(size: 12.5, weight: .medium)).frame(width: 46, alignment: .leading)
            HStack(spacing: 2) {
                Self.symbol(d.code, day: true).font(.system(size: 14))
                if d.rain >= 30 { Text("\(d.rain)%").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(red: 0.55, green: 0.8, blue: 1)) }
            }
            .frame(width: 44, alignment: .leading)
            Text(deg(d.lo)).font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit().frame(width: 30, alignment: .trailing)
            RangeBar(lo: d.lo, hi: d.hi, min: lo, max: hi, now: first ? f.temp : nil)
            Text(deg(d.hi)).font(.system(size: 12.5, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
        }
        .frame(height: 23)
    }

    /// An SF Symbol for each sky, in colour.
    static func symbol(_ code: Int, day: Bool) -> some View {
        let name: String = switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1: day ? "sun.max.fill" : "moon.fill"
        case 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 65, 82: "cloud.heavyrain.fill"
        case 61...67: "cloud.rain.fill"
        case 80, 81: day ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "thermometer.medium"
        }
        return Image(systemName: name).symbolRenderingMode(.multicolor)
    }

    /// The next seven hours.
    private var hours: [LiveData.Forecast.Hour] {
        let start = f.hours.firstIndex { $0.time > Date().addingTimeInterval(-3600) } ?? 0
        return Array(f.hours[start..<min(f.hours.count, start + 7)])
    }

    private var days: [LiveData.Forecast.Day] { Array(f.days.prefix(5)) }

    /// Day or night at that hour, from that day's sunrise and sunset.
    private func isDay(_ t: Date) -> Bool {
        // In the place's own time zone, not this Mac's.
        var cal = Calendar.current
        cal.timeZone = f.zone
        guard let d = f.days.first(where: { cal.isDate($0.date, inSameDayAs: t) }), let up = d.sunrise, let down = d.sunset else { return f.isDay }
        let mins = { (x: Date) in cal.component(.hour, from: x) * 60 + cal.component(.minute, from: x) }
        return mins(t) >= mins(up) && mins(t) < mins(down)
    }

    private func hourLabel(_ d: Date) -> String {
        let df = DateFormatter()
        df.timeZone = f.zone
        df.setLocalizedDateFormatFromTemplate("j")
        return df.string(from: d)
    }

    private func dayLabel(_ d: Date) -> String {
        let df = DateFormatter()
        df.timeZone = f.zone
        df.dateFormat = "EEE"
        return df.string(from: d)
    }
}

/// A day's low to high, placed on the week's coldest-to-warmest scale, coloured cool to warm (with a dot for now).
private struct RangeBar: View {
    let lo: Double, hi: Double, min: Double, max: Double
    var now: Double?

    var body: some View {
        GeometryReader { g in
            let span = Swift.max(1, max - min)
            let x0 = g.size.width * (lo - min) / span, x1 = g.size.width * (hi - min) / span
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [Self.color(lo), Self.color(hi)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: Swift.max(5, x1 - x0))
                    .offset(x: x0)
                if let now {
                    Circle().fill(.white).frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1.5))
                        .offset(x: Swift.min(g.size.width - 6, Swift.max(0, g.size.width * (now - min) / span - 3)))
                }
            }
        }
        .frame(height: 5)
    }

    /// Blue when cold, green when mild, yellow to orange to red when hot (°C).
    static func color(_ t: Double) -> Color {
        switch t {
        case ..<5: Color(red: 0.35, green: 0.65, blue: 1)
        case ..<12: Color(red: 0.35, green: 0.85, blue: 0.85)
        case ..<18: Color(red: 0.55, green: 0.9, blue: 0.45)
        case ..<24: Color(red: 1, green: 0.85, blue: 0.3)
        case ..<30: Color(red: 1, green: 0.6, blue: 0.2)
        default: Color(red: 1, green: 0.35, blue: 0.25)
        }
    }
}

private struct RainCard: View {
    let f: LiveData.Forecast
    let verdict: String

    var body: some View {
        let next = Array(f.hours.drop { $0.time < Date().addingTimeInterval(-3600) }.prefix(12))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verdict).font(.system(size: 18, weight: .semibold))
                Text("Today \(f.days.first?.rain ?? 0)% · tomorrow \(f.days.count > 1 ? f.days[1].rain : 0)%").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(next.indices, id: \.self) { i in
                    let h = next[i]
                    VStack(spacing: 3) {
                        Text(h.rain > 0 ? "\(h.rain)" : "").font(.system(size: 9.5)).foregroundStyle(.secondary)
                        Capsule().fill(Color.blue.opacity(0.35 + 0.6 * Double(h.rain) / 100))
                            .frame(height: 4 + 36 * CGFloat(h.rain) / 100)
                        Text(i % 3 == 0 ? hour(h.time) : " ").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 66, alignment: .bottom)
        }
    }

    private func hour(_ d: Date) -> String {
        let df = DateFormatter()
        df.timeZone = f.zone
        df.timeStyle = .short
        return df.string(from: d)
    }
}

private struct ClocksCard: View {
    @Environment(\.cardInner) private var inner
    let clocks: [ToolCard.Clock]
    let convert: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 8) {
                ForEach(clocks.indices, id: \.self) { i in
                    if convert, i > 0 {
                        Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    tile(clocks[i], now: ctx.date)
                }
            }
        }
    }

    private func tile(_ c: ToolCard.Clock, now: Date) -> some View {
        let d = c.at ?? now
        let time = DateFormatter()
        time.timeZone = c.zone
        time.timeStyle = .short
        let day = DateFormatter()
        day.timeZone = c.zone
        day.dateFormat = "EEE d"
        let diff = Double(c.zone.secondsFromGMT(for: d) - TimeZone.current.secondsFromGMT(for: d)) / 3600
        let rel = c.here ? "Here" : diff == 0 ? "Same as here" : (diff > 0 ? "+" : "−") + (diff == diff.rounded() ? "\(Int(abs(diff)))" : String(format: "%.1f", abs(diff))) + "h"
        return VStack(alignment: .leading, spacing: 2) {
            Text(c.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(time.string(from: d)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text("\(day.string(from: d)) · \(rel)").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: inner, style: .continuous).fill(Color.primary.opacity(c.here ? 0.09 : 0.05)))
    }
}

private struct ColorCard: View {
    @Environment(\.cardInner) private var inner
    let color: NSColor
    let chips: [ToolCard.Chip]
    let onAction: (Answer.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: inner, style: .continuous)
                .fill(Color(nsColor: color))
                .overlay(RoundedRectangle(cornerRadius: inner, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                .overlay {
                    HStack(spacing: 0) {
                        Text("Aa").foregroundStyle(.white).frame(maxWidth: .infinity)
                        Text("Aa").foregroundStyle(.black).frame(maxWidth: .infinity)
                    }
                    .font(.system(size: 15, weight: .semibold))
                }
                .frame(width: 120, height: 86)
            VStack(alignment: .leading, spacing: 6) {
                ChipRow(chips: Array(chips.prefix(2)), onAction: onAction)
                ChipRow(chips: Array(chips.dropFirst(2)), onAction: onAction)
            }
        }
    }
}

private struct QRCard: View {
    @Environment(\.cardInner) private var inner
    let image: NSImage
    let text: String
    let onAction: (Answer.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: image).resizable().interpolation(.none)
                .frame(width: 124, height: 124)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: inner, style: .continuous).fill(.white))
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 13)).lineLimit(4).textSelection(.enabled)
                ChipRow(chips: [ToolCard.Chip(label: "", value: "Copy text", action: .copy(text))], onAction: onAction)
            }
        }
    }
}

private struct TimerCard: View {
    let minutes: Double
    let label: String?
    let presets: [ToolCard.Chip]
    let onAction: (Answer.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Pomodoro.clock(minutes * 60)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                VStack(alignment: .leading, spacing: 1) {
                    if let label { Text(label).font(.system(size: 15, weight: .semibold)) }
                    TimelineView(.periodic(from: .now, by: 15)) { ctx in
                        Text("Rings at \(Self.time(ctx.date.addingTimeInterval(minutes * 60)))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            ChipRow(chips: presets, onAction: onAction)
        }
    }

    private static func time(_ d: Date) -> String {
        let df = DateFormatter()
        df.timeStyle = .short
        return df.string(from: d)
    }
}

private struct PasswordCard: View {
    let password: String
    let length: Int
    let chips: [ToolCard.Chip]
    let again: Answer.Action
    let controls: [ToolCard.Control]
    let onAction: (Answer.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                colored
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                ForEach(controls.indices, id: \.self) { i in ControlButton(control: controls[i], onAction: onAction) }
                RoundIcon(symbol: "arrow.clockwise", help: "New password") { onAction(again) }
            }
            Text("\(length) characters").font(.system(size: 12)).foregroundStyle(.secondary)
            ChipRow(chips: chips, onAction: onAction).padding(.top, 6)
        }
    }

    /// Digits and symbols tinted so look-alike characters are easier to read.
    private var colored: Text {
        // Digits blue, symbols orange, letters plain: easier to read out.
        var styled = AttributedString()
        for ch in password {
            var piece = AttributedString(String(ch))
            if ch.isNumber { piece.foregroundColor = Color(nsColor: .systemBlue) } else if !ch.isLetter { piece.foregroundColor = Color(nsColor: .systemOrange) }
            styled += piece
        }
        return Text(styled)
    }
}

private struct TranslateCard: View {
    let source: String
    let result: String?
    let busy: Bool
    let controls: [ToolCard.Control]
    let onAction: (Answer.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text(source).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                ForEach(controls.indices, id: \.self) { i in ControlButton(control: controls[i], onAction: onAction) }
            }
            Divider().opacity(0.6)
            if busy {
                HStack(spacing: 8) {
                    ThinkingDots().colorMultiply(.primary)
                    Text("Translating…").font(.system(size: 14)).foregroundStyle(.secondary)
                }
            } else if let result {
                Text(result).font(.system(size: 16)).lineLimit(3).textSelection(.enabled)
            }
        }
    }
}

private struct DefineCard: View {
    let word: String
    let detail: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(word).font(.system(size: 20, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(text).font(.system(size: 13)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MoonCard: View {
    let emoji: String
    let phase: String
    let detail: String
    let next: [(String, String)]

    var body: some View {
        HStack(spacing: 14) {
            Text(emoji).font(.system(size: 50))
            VStack(alignment: .leading, spacing: 2) {
                Text(phase).font(.system(size: 18, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(next.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Text(next[i].0).foregroundStyle(.secondary)
                        Text(next[i].1).fontWeight(.medium)
                    }
                    .font(.system(size: 12.5))
                }
            }
        }
    }
}

private struct GaugeCard: View {
    let g: ToolCard.Gauge

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(g.value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(g.caption).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color(nsColor: g.color).gradient).frame(width: max(8, geo.size.width * min(1, max(0, g.fraction))))
                }
            }
            .frame(height: 8)
            if let d = g.detail {
                Text(d).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct ToggleCard: View {
    @Environment(\.cardInner) private var inner
    let t: ToolCard.Switch
    let onAction: (Answer.Action) -> Void
    @State private var level = 0.5

    var body: some View {
        VStack(spacing: 12) {
            row
            if t.level != nil, let set = t.setLevel {
                HStack(spacing: 10) {
                    Image(systemName: "sun.max").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { level }, set: { level = $0; set($0) }), in: 0...1).tint(.orange)
                    Image(systemName: "sun.max.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                }

            }
        }
        .onAppear { level = t.level ?? 0.5 }
    }

    /// Under the shared header (its icon and name): the state, and the switch.
    private var row: some View {
        HStack(spacing: 12) {
            Text(t.isOn ? "On" : "Off").font(.system(size: 17, weight: .semibold)).contentTransition(.opacity)
            if !t.detail.isEmpty { Text(t.detail).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { t.isOn }, set: { _ in onAction(t.toggle) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.large)
        }
        .frame(height: 32)
    }
}

/// A card control: a round button, a titled pill, or a menu that looks like one.
private struct ControlButton: View {
    let control: ToolCard.Control
    let onAction: (Answer.Action) -> Void
    @State private var hover = false

    var body: some View {
        if control.menu.isEmpty {
            Button { if let a = control.action { onAction(a) } } label: { label }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .help(control.help)
        } else {
            Menu {
                ForEach(control.menu.indices, id: \.self) { i in
                    Button(control.menu[i].0) { onAction(control.menu[i].1) }
                }
            } label: { label }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { hover = $0 }
                .help(control.help)
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: control.symbol).font(.system(size: 12, weight: .semibold))
            if let t = control.title { Text(t).font(.system(size: 12.5, weight: .medium)).lineLimit(1) }
            if !control.menu.isEmpty, control.title != nil { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, control.title == nil ? 0 : 11)
        .frame(minWidth: 32, minHeight: 32)
        .background(Capsule().fill(Color.primary.opacity(hover ? 0.16 : 0.08)))
        .contentShape(Capsule())
    }
}

private struct VolumeCard: View {
    let v: ToolCard.Volume
    let onAction: (Answer.Action) -> Void
    @State private var value = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { onAction(v.toggleMute) } label: {
                    Image(systemName: v.muted ? "speaker.slash.fill" : value < 0.34 ? "speaker.wave.1.fill" : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(v.muted ? "Unmute" : "Mute")
                // Only a drag changes the volume (not the card appearing).
                Slider(value: Binding(get: { value }, set: { value = $0; v.set($0) }), in: 0...1)
                    .opacity(v.muted ? 0.45 : 1)
                Text("\(Int((value * 100).rounded()))%").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            ChipRow(chips: v.chips, onAction: onAction)
        }
        .onAppear { value = v.value }
    }
}

private struct MediaCardInList: View {
    @Environment(\.cardInner) private var inner
    var body: some View { MediaCard(media: NowPlaying.shared, artSize: 48, corner: inner) }
}
