import AppKit
import SwiftUI

/// Settings › Appearance › Text: the main font, then each area's font, size and weight, each with its own reset.
struct TextSection: View {
    @Bindable var store: Store
    /// The area whose font list is open ("main" for the main font).
    @State private var picking: String?

    var body: some View {
        let s = store.settings
        Section {
            LabeledContent("Font") {
                HStack(spacing: 8) {
                    fontButton("main", Fonts.title(s.fontFamily)) { store.settings.fontFamily = $0 ?? "system" }
                    // Keeps the button and reset in the same columns as the rows under it.
                    Color.clear.frame(width: 110 + 44 + 104 + 2 * 8, height: 1)
                    reset(s.fontFamily == "system") { store.settings.fontFamily = "system" }
                }
            }
            ForEach(TextArea.allCases) { area in row(area) }
        } header: {
            Text("Text")
        } footer: {
            Text("Size and weight apply to every text in that area; headings stay bigger. Answers covers Ask’s replies and sticky notes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ area: TextArea) -> some View {
        let s = store.settings
        let style = Fonts.style(area, s)
        let usual = style == TextStyle() && (area != .bar || s.fontSize == Settings().fontSize)
        return LabeledContent(area.title) {
            HStack(spacing: 8) {
                fontButton(area.rawValue, style.family.map(Fonts.title) ?? "Same") { f in edit(area) { $0.family = f } }
                if area == .bar {
                    Slider(value: Binding(get: { s.fontSize }, set: { store.settings.fontSize = $0.rounded() }), in: 13...32).frame(width: 110)
                    Text("\(Int(s.fontSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                } else {
                    Slider(value: Binding(get: { style.scale }, set: { v in edit(area) { $0.scale = (v * 20).rounded() / 20 } }), in: 0.7...1.6).frame(width: 110)
                    Text("\(Int((style.scale * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
                Picker("Weight", selection: Binding(get: { style.weight ?? "" }, set: { w in edit(area) { $0.weight = w.isEmpty ? nil : w } })) {
                    Text("Usual").tag("")
                    Divider()
                    ForEach(Fonts.weights, id: \.id) { w in Text(Self.weightTitle(w.id)).tag(w.id) }
                }
                .labelsHidden()
                .frame(width: 104, alignment: .trailing)
                reset(usual) {
                    store.settings.textStyles[area.rawValue] = nil
                    if area == .bar { store.settings.fontSize = Settings().fontSize }
                }
            }
        }
    }

    /// Changes one area's style; a style back at the usual look is dropped, so nothing is saved for it.
    private func edit(_ area: TextArea, _ change: (inout TextStyle) -> Void) {
        var t = Fonts.style(area, store.settings)
        change(&t)
        store.settings.textStyles[area.rawValue] = t == TextStyle() ? nil : t
    }

    private func fontButton(_ id: String, _ title: String, pick: @escaping (String?) -> Void) -> some View {
        Button { picking = id } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(width: 112)
        }
        .popover(isPresented: Binding(get: { picking == id }, set: { if !$0 { picking = nil } }), arrowEdge: .bottom) {
            FontPicker(current: id == "main" ? store.settings.fontFamily : Fonts.style(TextArea(rawValue: id) ?? .bar, store.settings).family,
                       allowsSame: id != "main") { f in
                pick(f)
                picking = nil
            }
        }
    }

    private func reset(_ usual: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "arrow.counterclockwise") }
            .buttonStyle(.borderless)
            .help("Reset")
            .disabled(usual)
    }

    static func weightTitle(_ id: String) -> String {
        id == "ultraLight" ? "Ultra light" : id == "semibold" ? "Semibold" : id.capitalized
    }
}

/// Every installed font, each shown in itself, with a search field. Return picks the first match.
struct FontPicker: View {
    let current: String?
    /// Offers "Same as the main font" (nil) at the top.
    let allowsSame: Bool
    /// What the search starts with (snapshots).
    var initialSearch = ""
    let pick: (String?) -> Void
    @State private var search = ""
    @State private var families: [String] = []

    var body: some View {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let designs = Fonts.designs.filter { q.isEmpty || $0.title.lowercased().contains(q) }
        let found = families.filter { q.isEmpty || $0.lowercased().contains(q) }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("", text: $search).textFieldStyle(.plain).accessibilityLabel("Search fonts")
                    .onSubmit { if let f = designs.first?.id ?? found.first { pick(f) } }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if allowsSame && q.isEmpty { item("Same as the main font", font: .system(size: 13), selected: current == nil) { pick(nil) } }
                    ForEach(designs, id: \.id) { d in
                        item(d.title, font: .system(size: 13, design: Self.design(d.id)), selected: current == d.id) { pick(d.id) }
                    }
                    if !designs.isEmpty && !found.isEmpty { Divider().padding(.vertical, 4) }
                    ForEach(found, id: \.self) { f in
                        item(f, font: .custom(f, size: 13), selected: current == f) { pick(f) }
                    }
                    if designs.isEmpty && found.isEmpty {
                        Text("No fonts match").foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 280, height: 360)
        .onAppear {
            families = Fonts.families
            search = initialSearch
        }
    }

    private func item(_ title: String, font: Font, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(font).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.primary.opacity(0.08) : .clear))
    }

    private static func design(_ id: String) -> Font.Design {
        switch id {
        case "rounded": .rounded
        case "serif": .serif
        case "monospaced": .monospaced
        default: .default
        }
    }
}
