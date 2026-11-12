import AppKit
import SwiftUI

/// Where text shows. Each has its own font, size and weight (Settings › Appearance › Text).
enum TextArea: String, Codable, CaseIterable, Identifiable {
    case bar, rows, notch, lyrics, answers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bar: "Search bar"
        case .rows: "Results"
        case .notch: "Notch"
        case .lyrics: "Lyrics"
        case .answers: "Answers"
        }
    }
}

/// One area's changes from the usual look. Empty keeps it as it was.
struct TextStyle: Codable, Equatable {
    /// nil: the main font.
    var family: String?
    var scale: Double = 1
    /// nil: each text keeps its own weight.
    var weight: String?
}

/// Every font the areas use goes through here, so the settings reach them all. Untouched settings give the
/// exact system font each place used before.
@MainActor enum Fonts {
    static let designs: [(id: String, title: String)] = [("system", "System"), ("rounded", "Rounded"), ("serif", "Serif"), ("monospaced", "Monospaced")]
    /// Name, SwiftUI weight, AppKit weight, and NSFontManager's 0–15 weight.
    static let weights: [(id: String, font: Font.Weight, ns: NSFont.Weight, manager: Int)] = [
        ("ultraLight", .ultraLight, .ultraLight, 2), ("thin", .thin, .thin, 3), ("light", .light, .light, 4),
        ("regular", .regular, .regular, 5), ("medium", .medium, .medium, 6), ("semibold", .semibold, .semibold, 8),
        ("bold", .bold, .bold, 9), ("heavy", .heavy, .heavy, 11), ("black", .black, .black, 12),
    ]

    /// The system text size against the usual 13 pt body (1 unless it's changed in Accessibility › Display).
    static var systemScale: Double { NSFont.preferredFont(forTextStyle: .body).pointSize / 13 }

    static func style(_ area: TextArea, _ s: Settings) -> TextStyle { s.textStyles[area.rawValue] ?? TextStyle() }
    static func family(_ area: TextArea, _ s: Settings) -> String { style(area, s).family ?? s.fontFamily }

    static func size(_ area: TextArea, _ size: CGFloat, _ s: Settings) -> CGFloat {
        size * style(area, s).scale * (s.followTextSize ? systemScale : 1)
    }

    private static func weightIndex(_ area: TextArea, _ s: Settings) -> Int? { style(area, s).weight.flatMap { w in weights.firstIndex { $0.id == w } } }

    static func font(_ area: TextArea, _ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design? = nil) -> Font {
        let s = Store.shared.settings
        let asked = size, size = Self.size(area, size, s)
        let weight = weightIndex(area, s).map { weights[$0].font } ?? weight
        switch family(area, s) {
        case "system": return .system(size: size, weight: weight, design: design ?? .default)
        case "rounded": return .system(size: size, weight: weight, design: .rounded)
        case "serif": return .system(size: size, weight: weight, design: .serif)
        case "monospaced": return .system(size: size, weight: weight, design: .monospaced)
        // The same face AppKit measures with (a family's weights don't always match SwiftUI's).
        case _: return Font(ns(area, asked, weight: weights.first { $0.font == weight }?.ns ?? .regular) as CTFont)
        }
    }

    static func ns(_ area: TextArea, _ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let s = Store.shared.settings
        let size = Self.size(area, size, s)
        let w = weightIndex(area, s).map { weights[$0].ns } ?? weight
        let system = NSFont.systemFont(ofSize: size, weight: w)
        switch family(area, s) {
        case "system": return system
        case let f where designs.contains { $0.id == f }:
            let d: NSFontDescriptor.SystemDesign = f == "rounded" ? .rounded : f == "serif" ? .serif : .monospaced
            return system.fontDescriptor.withDesign(d).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case let name:
            return NSFontManager.shared.font(withFamily: name, traits: [], weight: weights.first { $0.ns == w }?.manager ?? 5, size: size) ?? system
        }
    }

    /// Installed font families, for the picker.
    static var families: [String] { NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") } }

    static func title(_ family: String) -> String { designs.first { $0.id == family }?.title ?? family }
}

extension Font {
    /// `.system(size:weight:design:)` for one of the areas the text settings cover.
    @MainActor static func app(_ area: TextArea, _ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design? = nil) -> Font {
        Fonts.font(area, size, weight: weight, design: design)
    }
}
