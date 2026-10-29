import AppKit
import SwiftUI
import Carbon.HIToolbox

enum Pane: String, CaseIterable, Identifiable {
    case general, stats, appearance, hotkeys, shortcuts, tools, clock, notch, clipboard, dictation, meetings, claude, apps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .stats: "Stats"
        case .appearance: "Appearance"
        case .hotkeys: "Hotkeys"
        case .shortcuts: "Shortcuts"
        case .tools: "Tools"
        case .clock: "Clock"
        case .notch: "Notch"
        case .clipboard: "Clipboard"
        case .dictation: "Dictation"
        case .meetings: "Meetings"
        case .claude: "AI"
        case .apps: "Apps"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .stats: "chart.bar.fill"
        case .appearance: "paintbrush"
        case .hotkeys: "command"
        case .shortcuts: "bolt"
        case .tools: "wand.and.stars"
        case .clock: "clock.fill"
        case .notch: "rectangle.topthird.inset.filled"
        case .clipboard: "doc.on.clipboard"
        case .dictation: "mic"
        case .meetings: "waveform"
        case .claude: "sparkles"
        case .apps: "square.grid.2x2"
        }
    }
    var color: Color {
        switch self {
        case .general: .gray
        case .stats: .purple
        case .appearance: .indigo
        case .hotkeys: .blue
        case .shortcuts: .orange
        case .tools: .mint
        case .clock: .orange
        case .notch: Color(white: 0.25)
        case .clipboard: .teal
        case .dictation: .pink
        case .meetings: .red
        case .claude: Color(red: 0.85, green: 0.45, blue: 0.3)
        case .apps: .green
        }
    }
}

struct SettingsView: View {
    @Bindable var store: Store
    let clipboard: ClipboardStore
    let launcher: LauncherController
    @State var pane = Pane.general

    var body: some View {
        // A plain sidebar + page layout: the system split view fought the fixed-size window
        // (blank sidebar, pages sliding under the title bar).
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Pane.allCases) { p in
                    SidebarRow(pane: p, selected: p == pane) { pane = p }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .frame(width: 200)
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.03))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(pane.title).font(.system(size: 20, weight: .semibold)).padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
                Group {
                    switch pane {
                    case .general: GeneralPane(store: store, launcher: launcher)
                    case .stats: StatsPane(stats: Stats.shared)
                    case .appearance: AppearancePane(store: store, launcher: launcher)
                    case .hotkeys: HotkeysPane(store: store)
                    case .shortcuts: ShortcutsPane(store: store, launcher: launcher)
                    case .tools: ToolsPane(store: store)
                    case .clock: ClockPane(store: store)
                    case .notch: NotchPane(store: store)
                    case .clipboard: ClipboardPane(store: store, clipboard: clipboard)
                    case .dictation: DictationPane(store: store)
                    case .meetings: MeetingsPane(store: store)
                    case .claude: AIPane(store: store)
                    case .apps: AppsPane(store: store, launcher: launcher)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

private struct SidebarRow: View {
    let pane: Pane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pane.color.gradient)
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: pane.symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white))
                Text(pane.title).font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.85) : Color.primary.opacity(hovering ? 0.06 : 0)))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Tools

private struct ToolsPane: View {
    @Bindable var store: Store
    @State private var clocks = ""

    var body: some View {
        Form {
            Section {
                Toggle("Show answers while typing", isOn: $store.settings.instantAnswers)
            } footer: {
                Text("Type in the search bar and answers appear above your apps. Type ? to list every tool.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Weather") {
                TextField("City", text: $store.settings.weatherCity, prompt: Text("Where you are"))
                Picker("Temperature", selection: $store.settings.fahrenheit) {
                    Text("Celsius (°C)").tag(false)
                    Text("Fahrenheit (°F)").tag(true)
                }
            }
            Section("Money and time") {
                Picker("Convert money to", selection: $store.settings.homeCurrency) {
                    ForEach(["JPY", "USD", "EUR", "GBP", "KRW", "CNY", "TWD", "HKD", "SGD", "AUD", "CAD", "THB"].filter { Tools.currencyCodes.contains($0) }, id: \.self) { Text($0).tag($0) }
                }
                TextField("World clocks", text: $clocks, prompt: Text("New York, London, Los Angeles"))
                    .onSubmit(saveClocks)
                    .onChange(of: clocks) { _, _ in saveClocks() }
            }
            Section("Answers") {
                ForEach(ToolGroup.allCases) { g in
                    Toggle(g.title, isOn: Binding(get: { !store.settings.disabledTools.contains(g) }, set: { on in
                        store.settings.disabledTools.removeAll { $0 == g }
                        if !on { store.settings.disabledTools.append(g) }
                    }))
                }
            }
            Section("More") {
                Stepper("Calculator decimals: \(store.settings.calcDecimals)", value: $store.settings.calcDecimals, in: 0...12)
                Toggle("Color what you type in Clock and Calculator", isOn: $store.settings.colorTypedText)
                Toggle("Find QR codes and barcodes in ⌘3 Text", isOn: $store.settings.scanQR)
                Toggle("Remember volume mixer levels", isOn: $store.settings.rememberAppVolumes)
            }
            Section("Everything you can type") {
                ForEach(Tools.catalog, id: \.name) { t in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: t.color).gradient)
                            .frame(width: 20, height: 20)
                            .overlay(Image(systemName: t.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
                        Text(t.name)
                        Spacer()
                        Text(t.example).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { clocks = store.settings.worldClocks.joined(separator: ", ") }
    }

    private func saveClocks() {
        store.settings.worldClocks = clocks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: General

private struct GeneralPane: View {
    @Bindable var store: Store
    let launcher: LauncherController

    var body: some View {
        Form {
            Section {
                Toggle("Open MONEY! at login", isOn: $store.settings.launchAtLogin)
                Toggle("Show icon in the menu bar", isOn: $store.settings.showMenuBarIcon)
            } footer: {
                if !store.settings.showMenuBarIcon {
                    Text("Open MONEY! from Finder or Launchpad to get back to Settings.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Search") {
                Picker("Empty search shows", selection: $store.settings.emptyState) {
                    ForEach(EmptyState.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Complete app names inline (Tab accepts)", isOn: $store.settings.ghostCompletion)
                Toggle("Show what’s playing in the notch", isOn: $store.settings.mediaInNotch)
                Toggle("Show Clipboard, Switch Apps and Settings in results", isOn: $store.settings.builtinsInResults)
                TextField("Placeholder", text: $store.settings.placeholder)
            }
            Section {
                TextField("Clipboard keyword", text: $store.settings.clipboardKeyword)
                TextField("App switcher keyword", text: $store.settings.switcherKeyword)
            } header: {
                Text("Scopes")
            } footer: {
                Text("Type a keyword and press Tab to jump into it. Backspace on an empty field goes back to apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Position") {
                Picker("Open on", selection: $store.settings.screen) {
                    ForEach(ScreenChoice.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Drag the bar to move it; it snaps to the centre and edges.") {
                    Button("Reset Position") { launcher.resetPosition() }
                        .disabled(store.settings.position == nil)
                }
            }
            Section("Keys in the popup") {
                keyRow("↑ ↓", "Move")
                keyRow("↩", "Open, switch or paste")
                keyRow("⇥", "Accept completion / enter a scope")
                keyRow("⌘1", "Apps")
                keyRow("⌘2", "Clipboard")
                keyRow("⌘3", "Text from the screen")
                keyRow("⌘4", "Meeting dictation")
                keyRow("⌘H / ⌘Q", "Hide / quit the selected app")
                keyRow("⌘,", "Settings")
                keyRow("⎋", "Clear, then close")
            }
        }
    }

    private func keyRow(_ keys: String, _ what: String) -> some View {
        LabeledContent(what) { Text(keys).font(.system(.body, design: .rounded)).foregroundStyle(.secondary) }
    }
}

// MARK: Appearance

private struct AppearancePane: View {
    @Bindable var store: Store
    let launcher: LauncherController

    var body: some View {
        // The preview stays put while the settings under it scroll.
        VStack(spacing: 0) {
            BarPreview(store: store, launcher: launcher)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                QuickModesEditor(store: store)
            } header: {
                Text("Buttons beside the bar · ⌘2–⌘5")
            }
            Section {
                Picker("Material", selection: $store.settings.glass) {
                    ForEach(GlassStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Custom tint colour", isOn: $store.settings.customTint)
                if store.settings.customTint {
                    ColorPicker("Tint colour", selection: tintBinding, supportsOpacity: false)
                }
                slider("Tint strength", $store.settings.tintStrength, 0...4, step: 0.25, format: "%.2g×")
                slider("Darkness", $store.settings.darkness, 0...0.9, step: 0.05, format: "%.0f%%", scale: 100)
                Toggle("Darken the glass more inside Clipboard and Switch", isOn: $store.settings.shadeScopes)
            } header: {
                HStack {
                    Text("Look")
                    Spacer()
                    Button("Preview") { launcher.show(.apps) }
                    Button("Reset All") { store.resetAppearance() }
                }
            }
            Section("Size") {
                slider("Width", $store.settings.width, 420...1000, step: 10, format: "%.0f pt")
                slider("Clipboard width", $store.settings.clipboardWidth, 520...1200, step: 10, format: "%.0f pt")
                slider("Bar height", $store.settings.barHeight, 44...110, step: 1, format: "%.0f pt")
                slider("Text size", $store.settings.fontSize, 13...32, step: 1, format: "%.0f pt")
                slider("Corner radius", $store.settings.cornerRadius, 0...55, step: 1, format: "%.0f pt")
                slider("Corner radius in scopes", $store.settings.scopedCornerRadius, 0...55, step: 1, format: "%.0f pt")
                slider("Row height", $store.settings.rowHeight, 28...64, step: 1, format: "%.0f pt")
                Stepper("Rows shown: \(store.settings.maxRows)", value: $store.settings.maxRows, in: 3...14)
            }
            Section("Details") {
                Toggle("Icons", isOn: $store.settings.showIcons)
                Toggle("Key hints", isOn: $store.settings.showHints)
                Toggle("Apps / Clipboard buttons when hovering the bar", isOn: $store.settings.showTabs)
                Toggle("Fade in and out", isOn: $store.settings.animations)
            }
        }
    }

    private var tintBinding: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: store.settings.tintHex) ?? .gray) },
                set: { store.settings.tintHex = NSColor($0).hexString })
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, format: String, scale: Double = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(minWidth: 180)
                Text(String(format: format, value.wrappedValue * scale)).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            }
        }
    }
}

// MARK: Hotkeys

private struct HotkeysPane: View {
    @Bindable var store: Store
    @State private var spotlightOn = SpotlightShortcut.enabled

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { !spotlightOn && store.settings.launcherHotKey == .launcherDefault }, set: useCommandSpace)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open MONEY! with ⌘Space instead of Spotlight")
                        Text(spotlightOn ? "⌘Space opens Spotlight now" : store.settings.launcherHotKey == .launcherDefault ? "⌘Space opens MONEY!. Spotlight’s shortcut is off."
                             : "Spotlight’s shortcut is off; MONEY! uses \(store.settings.launcherHotKey.display)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Turning this off gives ⌘Space back to Spotlight and moves MONEY! to ⌘⇧Space. You can change either key below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Search apps") { HotKeyField(hotKey: $store.settings.launcherHotKey).frame(width: 150, height: 26) }
                LabeledContent("Clipboard history") { HotKeyField(hotKey: $store.settings.clipboardHotKey).frame(width: 150, height: 26) }
                LabeledContent("App switcher") { HotKeyField(hotKey: $store.settings.switcherHotKey).frame(width: 150, height: 26) }
            }
            Section {
                Toggle("Hold the modifier to switch, like ⌘Tab", isOn: $store.settings.holdToSwitch)
            } footer: {
                Text("The switcher opens with the previous app selected. Keep holding the modifier and tap the key again to move down (add ⇧ to move up), then let go to switch. Let go without moving and it stays open: pick with ↑↓ and Return.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Open Keyboard Shortcuts…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }
        }
        .onAppear { spotlightOn = SpotlightShortcut.enabled }
    }

    private func useCommandSpace(_ on: Bool) {
        SpotlightShortcut.set(enabled: !on)
        spotlightOn = SpotlightShortcut.enabled
        if on {
            store.settings.launcherHotKey = .launcherDefault
        } else if store.settings.launcherHotKey == .launcherDefault {
            store.settings.launcherHotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))
        }
        HotKeyCenter.shared.reload?()
    }
}

// MARK: Shortcuts

/// Every app with a box for your own word. Type that word in Flick and the app comes up first.
private struct ShortcutsPane: View {
    @Bindable var store: Store
    let launcher: LauncherController
    @State private var filter = ""
    @State private var onlyAssigned = false

    var body: some View {
        let apps = visibleApps
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Give an app a short word, like “ps” for Photoshop. Type it in MONEY! and that app comes up first. Separate several words with commas.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter apps", text: $filter).textFieldStyle(.plain)
                    Toggle("With shortcuts only", isOn: $onlyAssigned).toggleStyle(.checkbox).fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(apps, id: \.path) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: IconCache.icon(forPath: app.path)).resizable().frame(width: 24, height: 24)
                            Text(app.name).lineLimit(1)
                            Spacer()
                            TextField("", text: binding(app.path), prompt: Text("Type a word"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                        }
                        .padding(.horizontal, 20)
                        .frame(height: 40)
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .overlay {
                if apps.isEmpty {
                    Text(onlyAssigned ? "No app shortcuts yet" : "No apps match").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var visibleApps: [AppEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return launcher.index.apps
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || (store.settings.appKeywords[$0.path] ?? "").localizedCaseInsensitiveContains(q) }
            .filter { !onlyAssigned || !(store.settings.appKeywords[$0.path] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func binding(_ path: String) -> Binding<String> {
        Binding(get: { store.settings.appKeywords[path] ?? "" },
                set: { store.settings.appKeywords[path] = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }
}

// MARK: Clipboard

private struct ClipboardPane: View {
    @Bindable var store: Store
    let clipboard: ClipboardStore
    @State private var trusted = Paster.trusted
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep clipboard history", isOn: $store.settings.clipboardEnabled)
                Stepper("Keep up to \(store.settings.clipboardLimit) items", value: $store.settings.clipboardLimit, in: 20...2000, step: 20)
                Picker("Forget items after", selection: $store.settings.clipboardDays) {
                    Text("1 day").tag(1)
                    Text("1 week").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                    Text("Never").tag(0)
                }
                Toggle("Save images", isOn: $store.settings.saveImages)
                Toggle("Never save API keys, tokens and passwords", isOn: $store.settings.skipSecrets)
                Toggle("Show a preview beside the list", isOn: $store.settings.showPreview)
            } footer: {
                Text("Pinned items (⌘P) are never forgotten. Passwords from password managers are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Return pastes into the app you were in", isOn: $store.settings.pasteOnEnter)
                if store.settings.pasteOnEnter {
                    LabeledContent("Accessibility access") {
                        if trusted {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Allow…") {
                                Paster.requestAccess()
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                        }
                    }
                }
            } footer: {
                Text("Pasting needs Accessibility access so MONEY! can press ⌘V for you. Without it, Return just copies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignore these apps") {
                ForEach(store.settings.ignoredApps, id: \.self) { id in
                    HStack {
                        if let img = IconCache.icon(forBundleID: id) { Image(nsImage: img).resizable().frame(width: 18, height: 18) }
                        Text(appName(id))
                        Spacer()
                        Button { store.settings.ignoredApps.removeAll { $0 == id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Menu("Add Running App") {
                    ForEach(runningApps, id: \.self) { id in
                        Button(appName(id)) { store.settings.ignoredApps.append(id) }
                    }
                }
                .fixedSize()
            }
            Section {
                LabeledContent("\(clipboard.clips.count) items saved") {
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                }
            }
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in trusted = Paster.trusted }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear All but Pinned", role: .destructive) { clipboard.clearAll(keepPinned: true) }
            Button("Clear Everything", role: .destructive) { clipboard.clearAll(keepPinned: false) }
        }
    }

    private var runningApps: [String] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier).filter { !store.settings.ignoredApps.contains($0) }.sorted { appName($0) < appName($1) }
    }

    private func appName(_ id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id
    }
}

// MARK: Apps

private struct AppsPane: View {
    @Bindable var store: Store
    let launcher: LauncherController
    @State private var count = 0

    var body: some View {
        Form {
            Section {
                ForEach(store.settings.searchFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(folder)
                        Spacer()
                        Button { store.settings.searchFolders.removeAll { $0 == folder } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                }
                HStack {
                    Button("Add Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url, !store.settings.searchFolders.contains(url.path) {
                            store.settings.searchFolders.append(url.path)
                        }
                    }
                    Spacer()
                    Text("\(count) apps found").foregroundStyle(.secondary)
                    Button("Rescan") {
                        launcher.index.refresh(folders: store.settings.searchFolders)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { count = launcher.index.apps.count }
                    }
                }
            } header: {
                Text("Look for apps in")
            }
            Section {
                ForEach(store.settings.excludedApps, id: \.self) { path in
                    HStack {
                        Image(nsImage: IconCache.icon(forPath: path)).resizable().frame(width: 18, height: 18)
                        Text(FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
                        Spacer()
                        Button { store.settings.excludedApps.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                }
                Button("Hide an App…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.allowsMultipleSelection = true
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK {
                        for url in panel.urls where !store.settings.excludedApps.contains(url.path) { store.settings.excludedApps.append(url.path) }
                    }
                }
            } header: {
                Text("Never show")
            }
        }
        .onAppear { count = launcher.index.apps.count }
    }
}

// MARK: Dictation

private struct DictationPane: View {
    @Bindable var store: Store
    @State private var models = SpeechModels.shared
    @State private var trusted = Paster.trusted
    @State private var newWord = ""

    var body: some View {
        Form {
            Section {
                Toggle("Dictation", isOn: $store.settings.dictationEnabled)
                Toggle("Hold Fn (🌐) to dictate, Fn + Control to edit by voice", isOn: $store.settings.fnDictation)
                LabeledContent("Dictate") { HotKeyField(hotKey: $store.settings.dictationHotKey).frame(width: 150, height: 26) }
                LabeledContent("Edit by voice") { HotKeyField(hotKey: $store.settings.commandHotKey).frame(width: 150, height: 26) }
            } footer: {
                Text("For Fn, set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”. Hold the key and talk, then let go: the text appears where your cursor is. Tap it (once or twice) to keep listening hands-free, and tap again to finish. Esc cancels. “Edit by voice” works on the selected text: select something, hold the key, and say what to do (“make this more polite”, “translate to English”). With nothing selected it writes what you ask for.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Languages") {
                // Speak any mix of these in one go: each listens, and the phrases are merged.
                let listen = store.settings.listenLocales
                ForEach(listen, id: \.self) { id in
                    LabeledContent(SpeechModels.name(id)) {
                        HStack(spacing: 10) {
                            modelStatus(id)
                            if listen.count > 1 {
                                Button { store.settings.dictationLocales = listen.filter { $0 != id } } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Remove")
                            }
                        }
                    }
                }
                Menu("Add Language") {
                    ForEach(models.supported.filter { !listen.contains($0) }, id: \.self) { id in
                        Button(SpeechModels.name(id)) {
                            store.settings.dictationLocales = listen + [id]
                            models.refresh()
                        }
                    }
                }
                .fixedSize()
                .disabled(listen.count >= 4 || models.supported.isEmpty)
            }
            Section {
                Toggle("Clean up with AI", isOn: $store.settings.aiCleanup)
                Picker("Style", selection: $store.settings.dictationStyle) {
                    ForEach(DictationStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show words while you speak", isOn: $store.settings.livePreview)
                Toggle("Use the Mac's microphone when AirPods or another Bluetooth mic is the default", isOn: $store.settings.builtInMicForBluetooth)
                Toggle("Mute the Mac’s sound while dictating (not during meetings)", isOn: $store.settings.muteWhileDictating)
                Toggle("Start and stop sounds", isOn: $store.settings.dictationSounds)
                Toggle("Keep dictations in clipboard history", isOn: $store.settings.saveDictations)
            } header: {
                Text("Polish")
            } footer: {
                Text("The AI (Settings › AI; on this Mac by default) removes “um”s and false starts, keeps only what you meant when you correct yourself, fixes punctuation (、。 in Japanese) and writes lists, numbers and emails properly. “Match the app” is casual in chat apps, formal in mail, exact in code editors. With it off, MONEY! still removes fillers on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(store.settings.dictionary, id: \.self) { w in
                    HStack {
                        Text(w)
                        Spacer()
                        Button { store.settings.dictionary.removeAll { $0 == w } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Add a name or word…", text: $newWord).onSubmit(addWord)
                    Button("Add", action: addWord).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Dictionary")
            } footer: {
                Text("Names, products and jargon spelled exactly your way, e.g. “Kubernetes”, “TestFlight”, “渋谷”.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($store.settings.snippets) { $sn in
                    HStack(alignment: .top) {
                        TextField("When I say…", text: $sn.trigger).frame(width: 150)
                        TextField("Type this", text: $sn.text, axis: .vertical).lineLimit(1...4)
                        Button { store.settings.snippets.removeAll { $0.id == sn.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                Button("Add Snippet") { store.settings.snippets.append(Snippet()) }
            } header: {
                Text("Snippets")
            } footer: {
                Text("Say a cue like “my email” or “zoom link” and the full text is typed instead.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Microphone") {
                    Button("Open Settings…") { open("Privacy_Microphone") }
                }
                LabeledContent("Accessibility (to paste for you)") {
                    if trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { Paster.requestAccess(); open("Privacy_Accessibility") }
                    }
                }
            }
        }
        .onAppear { models.refresh() }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in trusted = Paster.trusted }
    }

    @ViewBuilder private func modelStatus(_ id: String) -> some View {
        if let p = models.progress[id] {
            HStack {
                ProgressView(value: p).frame(width: 120)
                Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
        } else if models.isInstalled(id) {
            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let e = models.errors[id] {
            HStack {
                Text(e).foregroundStyle(.red).lineLimit(1)
                Button("Retry") { models.download(id) }
            }
        } else if models.status[id] == .unsupported {
            Text("Not available on this Mac").foregroundStyle(.secondary)
        } else {
            Button("Download") { models.download(id) }
                .help("Apple's on-device speech model. Downloads in the background; use Wi-Fi if you can.")
        }
    }

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !store.settings.dictionary.contains(w) else { return }
        store.settings.dictionary.append(w)
        newWord = ""
    }

    private func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

// MARK: Meetings

private struct MeetingsPane: View {
    @Bindable var store: Store
    @State private var screenAccess = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section {
                Picker("Usual language", selection: $store.settings.meetingLanguage) {
                    Text("English").tag(DictationLanguage.english)
                    Text("日本語").tag(DictationLanguage.japanese)
                }
                Picker("Microphone", selection: $store.settings.meetingMicUID) {
                    Text("System default").tag("")
                    ForEach(MicCapture.inputDevices(), id: \.uid) { d in Text(d.name).tag(d.uid) }
                }
                Toggle("Also transcribe the other people (the Mac's sound)", isOn: $store.settings.meetingSystemAudio)
                if store.settings.meetingSystemAudio {
                    LabeledContent("Screen & System Audio Recording") {
                        if screenAccess {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Allow…") {
                                CGRequestScreenCaptureAccess()
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }
                        }
                    }
                }
                Toggle("Write notes with AI when it ends", isOn: $store.settings.meetingSummary)
                Toggle("Floating meeting window with live help", isOn: $store.settings.meetingOverlay)
                LabeledContent("Show / hide it") { HotKeyField(hotKey: $store.settings.copilotHotKey).frame(width: 150, height: 26) }
                Toggle("Hide MONEY! from screen sharing and recordings", isOn: $store.settings.hideFromScreenShare)
            } footer: {
                Text("In the popup, ⌘4 starts recording. Your voice is “Me”; everything the Mac plays (Zoom, Meet, Teams…) is “Others”. Switch EN / 日本語 any time from the bar. Speech is recognized on this Mac; notes are written by the model you pick in Settings › AI (on this Mac by default).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saved to") {
                LabeledContent(store.settings.meetingFolder) {
                    HStack {
                        Button("Change…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { store.settings.meetingFolder = url.path }
                        }
                        Button("Open") {
                            let url = URL(fileURLWithPath: (store.settings.meetingFolder as NSString).expandingTildeInPath)
                            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in screenAccess = CGPreflightScreenCaptureAccess() }
    }
}

// MARK: AI

private struct AIPane: View {
    @Bindable var store: Store
    @State private var lists: [AIProvider: [String]] = [:]
    @State private var listError: [AIProvider: String] = [:]
    @State private var ollamaRunning: Bool?
    @State private var pulling: String?
    @State private var pullProgress = 0.0
    @State private var pullStatus = ""
    @State private var confirmPull: OpenModel?

    var body: some View {
        Form {
            Section {
                ForEach(AITask.allCases) { task in
                    TaskRow(store: store, task: task, lists: lists)
                }
            } header: {
                Text("A model for each job")
            } footer: {
                Text("Every job starts on Apple’s on-device model: free, private and nothing to download. Switch a job to an open model (Ollama, LM Studio) or a cloud service when you want more power. Open each job’s Advanced settings for its temperature and length.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Apple Intelligence") {
                    if let why = AI.appleStatus { Text(why).foregroundStyle(.orange) } else { Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Toggle("Exact output for cleanup (no randomness)", isOn: providerBinding(.apple).greedy)
            } header: {
                Text("On this Mac (Apple)")
            } footer: {
                Text("A small model built into macOS. Great for dictation cleanup and short translations; long meetings are noted in parts.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ollamaSection

            Section {
                ForEach(AIProvider.allCases.filter { $0 != .apple && $0 != .ollama }) { p in
                    ProviderRow(store: store, provider: p, models: lists[p], error: listError[p]) { load(p) }
                }
                ProviderRow(store: store, provider: .ollama, models: lists[.ollama], error: listError[.ollama]) { load(.ollama) }
            } header: {
                Text("Services")
            } footer: {
                Text("Keys are kept in your Keychain. “Load models” asks the service for its current list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await checkOllama() }
        .confirmationDialog("Download \(confirmPull?.name ?? "")?", isPresented: Binding(get: { confirmPull != nil }, set: { if !$0 { confirmPull = nil } }), presenting: confirmPull) { m in
            Button("Download \(m.size)") { pull(m) }
            Button("Cancel", role: .cancel) {}
        } message: { m in
            Text("About \(m.size). Avoid this on a phone hotspot.")
        }
    }

    private var ollamaSection: some View {
        Section {
            LabeledContent("Ollama") {
                switch ollamaRunning {
                case .some(true): Label("Running · \(lists[.ollama]?.count ?? 0) models installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .some(false):
                    HStack {
                        Text("Not running").foregroundStyle(.secondary)
                        Link("Get Ollama", destination: URL(string: "https://ollama.com/download")!)
                        Button("Check again") { Task { await checkOllama() } }
                    }
                case nil: ProgressView().controlSize(.small)
                }
            }
            ForEach(OpenModel.all) { m in
                let installed = lists[.ollama]?.contains { $0 == m.name || $0 == m.name + ":latest" } ?? false
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name).font(.system(size: 13, weight: .medium, design: .monospaced))
                        Text("\(m.why) · \(m.size)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if pulling == m.name {
                        ProgressView(value: pullProgress).frame(width: 90)
                        Text(pullStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 80, alignment: .leading)
                    } else if installed {
                        Label("Installed", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                    } else {
                        Button("Download…") { confirmPull = m }.disabled(ollamaRunning != true || pulling != nil)
                    }
                }
            }
            Button("Use the recommended open model for every job") {
                for t in AITask.allCases {
                    store.settings.aiTasks[t.rawValue] = TaskModel(provider: .ollama, model: t.recommendedOpenModel.name)
                }
            }
        } header: {
            Text("Open models")
        } footer: {
            Text("Free models that run on this Mac through Ollama. Each job has a recommended one: qwen3:4b for dictation, qwen3:8b for editing and notes, gemma3:4b for chat (it can see screenshots) and translation. Nothing downloads until you press Download.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func providerBinding(_ p: AIProvider) -> Binding<ProviderSettings> {
        Binding(get: { AI.options(p, store.settings) }, set: { store.settings.aiProviders[p.rawValue] = $0 })
    }

    private func load(_ p: AIProvider) {
        Task {
            do {
                lists[p] = try await AI.listModels(p, store.settings)
                listError[p] = nil
            } catch {
                listError[p] = error.localizedDescription
            }
        }
    }

    private func checkOllama() async {
        do {
            lists[.ollama] = try await AI.listModels(.ollama, store.settings)
            ollamaRunning = true
        } catch {
            ollamaRunning = false
        }
    }

    private func pull(_ m: OpenModel) {
        pulling = m.name
        pullProgress = 0
        pullStatus = "Starting"
        Task {
            do {
                try await AI.pull(m.name, store.settings) { p, status in
                    pullProgress = p
                    pullStatus = status
                }
            } catch {
                pullStatus = error.localizedDescription
            }
            pulling = nil
            await checkOllama()
        }
    }
}

private struct TaskRow: View {
    @Bindable var store: Store
    let task: AITask
    let lists: [AIProvider: [String]]
    @State private var advanced = false
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        let c = AI.choice(task, store.settings)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: task.symbol).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                    Text(task.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: providerBinding) {
                    ForEach(AIProvider.allCases) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
                .labelsHidden()
                .frame(width: 210)
            }
            if c.provider != .apple {
                HStack(spacing: 6) {
                    TextField("Model", text: binding.model, prompt: Text(c.provider == .ollama ? task.recommendedOpenModel.name : "model name"))
                        .font(.system(size: 12, design: .monospaced))
                    Menu("Models") {
                        let names = Array(Set((lists[c.provider] ?? []) + c.provider.suggestedModels)).sorted()
                        if c.provider == .ollama {
                            Button("\(task.recommendedOpenModel.name) (recommended)") { binding.model.wrappedValue = task.recommendedOpenModel.name }
                            Divider()
                        }
                        ForEach(names, id: \.self) { n in Button(n) { binding.model.wrappedValue = n } }
                    }
                    .fixedSize()
                }
                .padding(.leading, 28)
            }
            if let why = AI.problem(task, store.settings) {
                Text(why).font(.caption).foregroundStyle(.orange).padding(.leading, 28)
            }
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Temperature", isOn: Binding(get: { c.temperature != nil }, set: { binding.temperature.wrappedValue = $0 ? task.temperature : nil }))
                        if let t = c.temperature {
                            Slider(value: Binding(get: { t }, set: { binding.temperature.wrappedValue = ($0 * 20).rounded() / 20 }), in: 0...1.5)
                            Text(String(format: "%.2f", t)).monospacedDigit().frame(width: 36)
                        } else {
                            Text("Tuned for this job (\(String(format: "%.1f", task.temperature)))").foregroundStyle(.secondary)
                        }
                    }
                    Stepper("Longest answer: \(c.maxTokens ?? task.maxTokens) tokens", value: Binding(get: { c.maxTokens ?? task.maxTokens }, set: { binding.maxTokens.wrappedValue = $0 }),
                            in: 128...32_000, step: 256)
                    HStack {
                        Button(testing ? "Testing…" : "Test this job") { test() }.disabled(testing)
                        if let result { Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12))
            .padding(.leading, 28)
        }
        .padding(.vertical, 3)
    }

    private var binding: Binding<TaskModel> {
        Binding(get: { AI.choice(task, store.settings) }, set: { store.settings.aiTasks[task.rawValue] = $0 })
    }

    /// Switching service picks a sensible model for this job.
    private var providerBinding: Binding<AIProvider> {
        Binding(get: { AI.choice(task, store.settings).provider }, set: { p in
            var c = AI.choice(task, store.settings)
            guard c.provider != p else { return }
            c.provider = p
            switch p {
            case .apple: c.model = "On-device"
            case .ollama: c.model = task.recommendedOpenModel.name
            case .anthropic:
                let s = store.settings
                c.model = (task == .dictation ? s.modelDictation : task == .voiceEdit ? s.modelVoiceEdit : task == .meetingChat ? s.modelMeetingChat
                           : task == .meetingNotes ? s.modelMeetingNotes : s.modelTools).rawValue
            default: c.model = lists[p]?.first ?? p.suggestedModels.first ?? ""
            }
            store.settings.aiTasks[task.rawValue] = c
        })
    }

    private func test() {
        testing = true
        result = nil
        let start = Date()
        let (system, user): (String, String) = switch task {
        case .dictation: (Prompts.cleanup(store.settings, context: .plain), "Transcript:\num so this is uh a test of the the dictation cleanup")
        case .translate: ("You translate text into Japanese. Reply with the translation only.", "Good morning! The meeting moved to 3pm.")
        default: ("Answer in one short sentence.", "Say hello and name the model you are.")
        }
        Task {
            do {
                let out = try await AI.complete(task, system: system, user: user)
                result = "“\(Tools.oneLine(out, 120))” · \(String(format: "%.1f", Date().timeIntervalSince(start))) s"
            } catch {
                result = error.localizedDescription
            }
            testing = false
        }
    }
}

private struct ProviderRow: View {
    @Bindable var store: Store
    let provider: AIProvider
    let models: [String]?
    let error: String?
    let load: () -> Void
    @State private var key = ""
    @State private var hasKey = false

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if provider.needsKey || provider == .custom {
                    LabeledContent("API key") {
                        HStack {
                            if hasKey {
                                Label("Saved in Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                                Button("Remove", role: .destructive) {
                                    AI.setKey(nil, for: provider)
                                    hasKey = false
                                }
                            } else {
                                SecureField(provider == .custom ? "optional" : "paste key", text: $key).frame(width: 220)
                                Button("Save") {
                                    AI.setKey(key, for: provider)
                                    key = ""
                                    hasKey = AI.key(provider) != nil
                                }
                                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                                if let url = provider.keyURL.flatMap(URL.init(string:)) { Link("Get a key", destination: url) }
                            }
                        }
                    }
                }
                LabeledContent("Server") {
                    TextField("", text: binding.baseURL, prompt: Text(provider.defaultBaseURL)).frame(width: 300)
                }
                switch provider {
                case .anthropic:
                    Picker("Effort", selection: binding.effort) {
                        Text("Tuned per job").tag("auto")
                        ForEach(["low", "medium", "high", "max"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    Toggle("If Claude declines, retry on a fallback model", isOn: binding.fallback)
                case .ollama:
                    Stepper("Context: \(AI.options(.ollama, store.settings).contextLength) tokens", value: binding.contextLength, in: 2048...131_072, step: 2048)
                    Stepper("Keep loaded for \(AI.options(.ollama, store.settings).keepAlive) min after use", value: binding.keepAlive, in: 0...240, step: 5)
                    Toggle("Let Qwen 3 think before answering (slower, sometimes better)", isOn: binding.thinking)
                default:
                    Picker("Reasoning effort", selection: binding.reasoning) {
                        Text("Model default").tag("default")
                        ForEach(["minimal", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                HStack {
                    Button("Load models", action: load)
                    if let error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1) }
                    else if let models { Text("\(models.count) models").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Label(provider.title, systemImage: provider.symbol)
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { hasKey = AI.key(provider) != nil }
    }

    private var status: String {
        let used = AITask.allCases.filter { AI.choice($0, store.settings).provider == provider }.count
        let state = provider.isLocal ? "On this Mac" : provider.needsKey ? (hasKey ? "Key saved" : "No key") : "No key needed"
        return used > 0 ? "\(state) · \(used) job\(used == 1 ? "" : "s")" : state
    }

    private var binding: Binding<ProviderSettings> {
        Binding(get: { AI.options(provider, store.settings) }, set: { store.settings.aiProviders[provider.rawValue] = $0 })
    }
}

// MARK: Stats

private struct StatsPane: View {
    let stats: Stats
    @State private var chart = Stats.Metric.words
    @State private var confirmReset = false

    private static let charted: [(Stats.Metric, String)] = [(.words, "Words dictated"), (.appsOpened, "Apps opened"), (.copies, "Copies"),
                                                            (.focusMinutes, "Focus minutes"), (.meetingMinutes, "Meeting minutes")]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    tile(number(stats.total(.words)), "words dictated", "mic.fill", .pink)
                    tile(duration(stats.minutesSaved(stats.total(.words), speaking: stats.total(.speakingSeconds))), "saved by talking", "bolt.fill", .orange)
                    tile("\(stats.streak)", stats.streak == 1 ? "day streak" : "days in a row", "flame.fill", .red)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }
            Section {
                Picker("", selection: $chart) {
                    ForEach(Self.charted, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                Bars(values: stats.daily(chart, last: 14).map(\.value))
                    .frame(height: 90)
            } header: {
                Text("Last two weeks")
            }
            Section("Dictation") {
                row("Dictations", "mic", .dictations)
                row("Words", "text.word.spacing", .words)
                LabeledContent {
                    let words = stats.total(.words), secs = stats.total(.speakingSeconds)
                    Text(secs > 0 ? "\(Int(words / (secs / 60))) words a minute" : "—").foregroundStyle(.secondary)
                } label: { Label("Speaking speed", systemImage: "speedometer") }
                LabeledContent {
                    Text(duration(stats.minutesSaved(stats.total(.words), speaking: stats.total(.speakingSeconds)))).foregroundStyle(.secondary)
                } label: { Label("Time saved", systemImage: "bolt") }
            }
            Section("Search and clipboard") {
                row("Apps opened", "app.badge", .appsOpened)
                row("Answers used", "sparkle.magnifyingglass", .answers)
                row("Copies saved", "doc.on.clipboard", .copies)
                row("Text grabbed from the screen", "text.viewfinder", .textScans)
            }
            Section("Meetings and focus") {
                row("Meetings recorded", "waveform", .meetings)
                row("Minutes in meetings", "clock", .meetingMinutes, minutes: true)
                row("Focus sessions", "timer", .focusSessions)
                row("Minutes focused", "brain.head.profile", .focusMinutes, minutes: true)
            }
            Section("Tools") {
                row("Timers", "hourglass", .timers)
                row("Alarms rung", "alarm", .alarms)
                row("Sticky notes", "note.text", .notes)
                row("Calculations", "plus.forwardslash.minus", .calculations)
                row("Translations copied", "character.bubble", .translations)
            }
            Section {
                LabeledContent("Counting since") { Text(stats.since.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary) }
                Button("Reset Stats…", role: .destructive) { confirmReset = true }
            }
        }
        .confirmationDialog("Reset all stats?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { stats.reset() }
        }
    }

    private func tile(_ value: String, _ caption: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    /// All time, with today's beside it.
    private func row(_ title: String, _ symbol: String, _ m: Stats.Metric, minutes: Bool = false) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                let today = stats.today(m)
                if today > 0 { Text("+\(minutes ? duration(today) : number(today)) today").font(.caption).foregroundStyle(.green) }
                Text(minutes ? duration(stats.total(m)) : number(stats.total(m))).monospacedDigit().foregroundStyle(.secondary)
            }
        } label: { Label(title, systemImage: symbol) }
    }

    private func number(_ v: Double) -> String { Int(v.rounded()).formatted() }

    private func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}

/// Fourteen little day bars, today on the right.
private struct Bars: View {
    let values: [Double]

    var body: some View {
        let top = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(values.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(i == values.count - 1 ? Color.purple : Color.purple.opacity(0.45))
                    .frame(height: max(3, CGFloat(values[i] / top) * 80))
                    .frame(maxWidth: .infinity)
                    .help("\(Int(values[i]))")
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .animation(.smooth(duration: 0.3), value: values)
    }
}

// MARK: Search bar preview and ⌘2–⌘5

/// The real search bar, drawn with the current settings over the desktop picture (it can't be typed into here).
/// Options under it drag straight onto the buttons beside the bar; the buttons drag to reorder, or back down to remove.
private struct BarPreview: View {
    @Bindable var store: Store
    let launcher: LauncherController
    @State private var model: LauncherModel?
    @State private var look = 0
    /// What is being dragged, and the buttons as they were when the drag came over the preview.
    @State private var dragging: QuickButton?
    @State private var before: [QuickButton]?
    @State private var trayTargeted = false
    @State private var previewWidth: CGFloat = 600

    private static let height: CGFloat = 180
    /// Tall enough that a long result list never overflows (and re-centres) the drawing.
    private static let canvas: CGFloat = 1000
    private static let top: CGFloat = 14
    /// Your desktop picture, read again each time the pane opens.
    @State private var wallpaper: NSImage?

    private static func loadWallpaper() -> NSImage? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 1400,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $look) {
                Text("Bar").tag(0)
                Text("Buttons").tag(1)
                Text("Results").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            GeometryReader { geo in
                let s = store.settings
                let fullW = CGFloat(s.width) + Metrics.margin * 2
                let scale = min(1, geo.size.width / fullW)
                ZStack(alignment: .topLeading) {
                    backdrop
                    if let model {
                        // Glass can't be captured off screen, so layout snapshots draw it flat.
                        LauncherRoot(model: model, store: store, clipboard: launcher.clipboard, onActivate: { _ in }, onTab: { _ in },
                                     opaque: CommandLine.arguments.contains("--settings-snapshot"))
                            .frame(width: fullW, height: Self.canvas)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: fullW * scale, height: Self.canvas * scale, alignment: .topLeading)
                            .offset(y: Self.top - Metrics.margin * scale)
                            .allowsHitTesting(false)
                    }
                    if look == 1 { handles(scale) }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onDrop(of: [.plainText], delegate: PreviewDrop(owner: self, scale: scale))
            }
            .frame(height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { previewWidth = $0 }
            tray
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: setUp)
        .onChange(of: look) { _, _ in apply() }
        .onChange(of: store.settings) { _, _ in apply() }
    }

    @ViewBuilder private var backdrop: some View {
        if let w = wallpaper {
            Image(nsImage: w).resizable().aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            LinearGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.45), Color(red: 0.45, green: 0.3, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    // MARK: Button slots

    private var size: CGFloat { CGFloat(store.settings.barHeight) }

    /// Left edge of the first button when `count` show, in preview points.
    private func start(_ count: Int, _ scale: CGFloat) -> CGFloat {
        (Metrics.margin + CGFloat(store.settings.width) - TabButtons.width(size, count: count)) * scale
    }

    /// Which slot a point over the preview lands in, with `count` buttons showing.
    fileprivate func slot(at x: CGFloat, count: Int, scale: CGFloat) -> Int {
        let step = (size + TabButtons.gap) * scale
        return min(count - 1, max(0, Int(((x - start(count, scale)) / step).rounded(.down))))
    }

    /// Invisible grips over the buttons in the drawing, so they can be picked up.
    private func handles(_ scale: CGFloat) -> some View {
        let shown = Array(store.settings.quickModes.prefix(4))
        return ForEach(Array(shown.enumerated()), id: \.element) { i, b in
            Circle().fill(Color.white.opacity(dragging == b ? 0.18 : 0.001))
                .frame(width: size * scale, height: size * scale)
                .offset(x: start(shown.count, scale) + CGFloat(i) * (size + TabButtons.gap) * scale, y: Self.top)
                .onDrag {
                    dragging = b
                    return NSItemProvider(object: b.raw as NSString)
                } preview: { roundButton(b) }
                .help("\(b.title) (⌘\(i + 2))")
        }
    }

    /// The buttons if `item` were dropped at slot `index` of the ones there before the drag. With four already
    /// there, a new one takes the place of the one under the pointer.
    fileprivate func arranged(_ item: QuickButton, at index: Int, from list: [QuickButton]) -> [QuickButton] {
        var out = list
        if let old = out.firstIndex(of: item) {
            out.remove(at: old)
        } else if out.count >= 4 {
            out.remove(at: min(index, out.count - 1))
        }
        out.insert(item, at: min(index, out.count))
        return out
    }

    fileprivate func hover(_ x: CGFloat, scale: CGFloat) {
        guard let item = dragging else { return }
        if before == nil {
            before = store.settings.quickModes
            if look != 1 { look = 1 }
        }
        let list = before ?? []
        let count = min(4, list.contains(item) ? list.count : list.count + 1)
        let next = arranged(item, at: slot(at: x, count: count, scale: scale), from: list)
        if next != store.settings.quickModes {
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { store.settings.quickModes = next }
        }
    }

    fileprivate func leave() {
        if let before { withAnimation(.spring(duration: 0.3, bounce: 0.2)) { store.settings.quickModes = before } }
        before = nil
    }

    fileprivate func drop() {
        before = nil
        dragging = nil
    }

    // MARK: Options not in use

    private var unused: [QuickButton] {
        QuickMode.allCases.map { QuickButton.mode($0) }.filter { !store.settings.quickModes.contains($0) }
    }

    private var tray: some View {
        let full = store.settings.quickModes.count >= 4
        return FlowLayout(spacing: 6) {
            ForEach(unused) { b in
                chip(b)
                    .opacity(dragging == b ? 0.4 : 1)
                    .onTapGesture {
                        guard !full else { return }
                        withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                            look = 1
                            store.settings.quickModes.append(b)
                        }
                    }
                    .onDrag {
                        dragging = b
                        return NSItemProvider(object: b.raw as NSString)
                    } preview: { roundButton(b) }
            }
            chip(nil).onTapGesture { chooseApp() }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(trayTargeted ? 0.1 : 0.04)))
        .animation(.easeOut(duration: 0.15), value: trayTargeted)
        // A button dragged back down here comes off the bar.
        .onDrop(of: [.plainText], isTargeted: $trayTargeted) { _ in
            if let b = dragging { withAnimation(.spring(duration: 0.3, bounce: 0.2)) { store.settings.quickModes.removeAll { $0 == b } } }
            drop()
            return true
        }
    }

    /// How much the preview shrinks the real bar.
    private var previewScale: CGFloat { min(1, previewWidth / (CGFloat(store.settings.width) + Metrics.margin * 2)) }

    /// What's carried while dragging: the button itself, as big as it is in the preview. (Glass can't be drawn into
    /// a drag image, so it's the glass's dark look, solid.)
    private func roundButton(_ b: QuickButton) -> some View {
        let d = size * previewScale
        return Group {
            switch b {
            case .mode(let m):
                Image(systemName: m.scope.symbol).font(.system(size: d * 0.27, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            case .app(let path):
                Image(nsImage: IconCache.icon(forPath: path)).resizable().frame(width: d * 0.5, height: d * 0.5)
            }
        }
        .frame(width: d, height: d)
        .background(Circle().fill(Color(white: 0.16).opacity(1 - store.settings.darkness * 0.5)))
        .background(Circle().fill(Color.black.opacity(0.35)))
        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .clipShape(Circle())
        .environment(\.colorScheme, .dark)
    }

    /// One option: its icon and name. `nil` is "App…".
    private func chip(_ b: QuickButton?) -> some View {
        HStack(spacing: 6) {
            switch b {
            case .mode(let m)?: Image(systemName: m.scope.symbol).frame(width: 16)
            case .app(let path)?: Image(nsImage: IconCache.icon(forPath: path)).resizable().frame(width: 16, height: 16)
            case nil: Image(systemName: "plus").frame(width: 16)
            }
            Text(b?.title ?? "App…").lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Color.primary.opacity(0.09)))
        .contentShape(Capsule())
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let b = QuickButton.app(url.path)
        guard !store.settings.quickModes.contains(b) else { return }
        if store.settings.quickModes.count >= 4 { store.settings.quickModes.removeLast() }
        look = 1
        store.settings.quickModes.append(b)
    }

    private func setUp() {
        wallpaper = Self.loadWallpaper()
        if model == nil {
            let m = LauncherModel(store: store, index: launcher.index, switcher: launcher.switcher, clipboard: launcher.clipboard)
            m.presented = true
            model = m
        }
        apply()
    }

    private func apply() {
        guard let m = model else { return }
        m.scope = .apps
        m.tabsShown = look == 1
        m.query = look == 2 ? "s" : ""
        m.recompute()
        if look != 2 { m.items = [] }
    }
}

/// Live drops on the preview: the buttons make room under the pointer while something hovers.
private struct PreviewDrop: DropDelegate {
    let owner: BarPreview
    let scale: CGFloat

    func dropEntered(info: DropInfo) { owner.hover(info.location.x, scale: scale) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        owner.hover(info.location.x, scale: scale)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { owner.leave() }
    func performDrop(info: DropInfo) -> Bool {
        owner.drop()
        return true
    }
}

/// Lays chips out left to right, wrapping onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(proposal.width ?? .infinity, subviews)
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var cur: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            let add = cur.items.isEmpty ? size.width : cur.width + spacing + size.width
            if add > width, !cur.items.isEmpty {
                rows.append(cur)
                cur = ([i], size.width, size.height)
            } else {
                cur = (cur.items + [i], add, max(cur.height, size.height))
            }
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}

/// The chosen buttons in ⌘ order: drag to reorder, minus to remove.
private struct QuickModesEditor: View {
    @Bindable var store: Store

    var body: some View {
        let chosen = store.settings.quickModes
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(Array(chosen.enumerated()), id: \.element) { i, b in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        switch b {
                        case .mode(let m): Image(systemName: m.symbol).frame(width: 22)
                        case .app(let path): Image(nsImage: IconCache.icon(forPath: path)).resizable().frame(width: 20, height: 20).frame(width: 22)
                        }
                        Text(b.title)
                        if case .app = b { Text("App").font(.caption).foregroundStyle(.tertiary) }
                        Spacer()
                        Text("⌘\(i + 2)").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                        Button {
                            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { store.settings.quickModes.removeAll { $0 == b } }
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                    .padding(.vertical, 2)
                }
                .onMove { from, to in store.settings.quickModes.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .frame(height: CGFloat(max(1, chosen.count)) * 32)
            HStack {
                Spacer()
                Button("Default") { store.settings.quickModes = Settings().quickModes }.disabled(chosen == Settings().quickModes)
            }
        }
    }
}

// MARK: Clock

private struct ClockPane: View {
    @Bindable var store: Store

    var body: some View {
        Form {
            Section("Timers") {
                Stepper("New timers start at \(SystemTools.span(store.settings.timerDefaultMinutes))", value: $store.settings.timerDefaultMinutes, in: 1...240, step: 1)
                soundPicker("Sound when a timer ends", $store.settings.timerSound)
            }
            Section("Alarms") {
                soundPicker("Sound for new alarms", $store.settings.alarmSound)
                Picker("Snooze for", selection: $store.settings.alarmSnoozeMinutes) {
                    ForEach([1, 5, 9, 10, 15, 20, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
            }
            Section("Stopwatch") {
                Toggle("Show hundredths of a second", isOn: $store.settings.stopwatchHundredths)
            }
            Section("Focus") {
                Toggle("Show Focus in the notch", isOn: $store.settings.notchFocus)
            }
        }
    }

    private func soundPicker(_ title: String, _ value: Binding<String>) -> some View {
        HStack {
            Picker(title, selection: value) {
                ForEach(ClockSound.names, id: \.self) { Text($0).tag($0) }
            }
            Button { ClockSound.play(value.wrappedValue) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).help("Play")
        }
    }
}

// MARK: Notch

private struct NotchPane: View {
    @Bindable var store: Store

    /// Everything on this pane back to how it started, the order included.
    private func resetNotch() {
        let d = Settings()
        withAnimation {
            store.settings.notchEnabled = d.notchEnabled
            store.settings.notchTimers = d.notchTimers
            store.settings.notchStopwatch = d.notchStopwatch
            store.settings.notchFocus = d.notchFocus
            store.settings.notchMeeting = d.notchMeeting
            store.settings.notchDictation = d.notchDictation
            store.settings.mediaInNotch = d.mediaInNotch
            store.settings.notchInCaptures = d.notchInCaptures
            store.settings.notchHoverExpand = d.notchHoverExpand
            store.settings.notchHoverDelay = d.notchHoverDelay
            store.settings.notchCollapseDelay = d.notchCollapseDelay
            store.settings.notchOrder = d.notchOrder
            store.settings.notchArrangements = [:]
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Use the notch", isOn: $store.settings.notchEnabled)
            } footer: {
                Text("What’s going on shows around the notch (at the top of the screen on Macs without one).").font(.caption).foregroundStyle(.secondary)
            }
            Section("Show") {
                Toggle("Timers", isOn: $store.settings.notchTimers)
                Toggle("Stopwatches", isOn: $store.settings.notchStopwatch)
                Toggle("Focus", isOn: $store.settings.notchFocus)
                Toggle("Meetings", isOn: $store.settings.notchMeeting)
                Toggle("Dictation", isOn: $store.settings.notchDictation)
                Toggle("What’s playing", isOn: $store.settings.mediaInNotch)
            }
            .disabled(!store.settings.notchEnabled)
            Section {
                LabeledContent("Order") {
                    Text(store.settings.notchPriority.map(\.title).joined(separator: " › ")).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack {
                    Spacer()
                    Button("Reset Order") {
                        store.settings.notchOrder = Settings().notchOrder
                        store.settings.notchArrangements = [:]
                    }
                    .disabled(store.settings.notchPriority == Settings().notchPriority && store.settings.notchArrangements.isEmpty)
                }
            } header: {
                Text("Closed notch")
            } footer: {
                Text("With more than three things going on, the closed notch shows the first three running in this order (alarms and dictation always first). Drag rows in the open notch to change it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!store.settings.notchEnabled)
            Section("Screenshots and sharing") {
                Toggle("Show the notch in screenshots, recordings and screen sharing", isOn: $store.settings.notchInCaptures)
            }
            .disabled(!store.settings.notchEnabled)
            Section("Opening") {
                Toggle("Open when the pointer rests on it", isOn: $store.settings.notchHoverExpand)
                LabeledContent("Wait before opening") {
                    Slider(value: $store.settings.notchHoverDelay, in: 0...1, step: 0.05).frame(width: 180)
                    Text(String(format: "%.2f s", store.settings.notchHoverDelay)).monospacedDigit().frame(width: 52)
                }
                .disabled(!store.settings.notchHoverExpand)
                LabeledContent("Close after leaving") {
                    Slider(value: $store.settings.notchCollapseDelay, in: 0.2...3, step: 0.1).frame(width: 180)
                    Text(String(format: "%.1f s", store.settings.notchCollapseDelay)).monospacedDigit().frame(width: 52)
                }
            }
            .disabled(!store.settings.notchEnabled)
            Section {
                HStack {
                    Spacer()
                    Button("Reset Notch Settings") { resetNotch() }
                }
            }
        }
    }
}
