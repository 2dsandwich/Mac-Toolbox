import AppKit
import Quartz
import UniformTypeIdentifiers

/// The newer list scopes in the search bar (files, processes, colors, snippets, the front app's menus) and the
/// quicklinks and speed test in the main search. Every row is an answer row: ↩ runs its action, ⌘↩ its `alt`.
enum LauncherExtras {
    /// Snapshots and tests: made-up files, processes, menus, colors and snippets; nothing read from this Mac or run.
    @MainActor static var demo = false
}

extension LauncherModel {
    static let extraScopes: [Scope] = [.files, .processes, .colors, .snippets, .menu]

    /// A scope was just opened: read what it lists (processes, the front app's menus).
    func enteredExtra() {
        switch scope {
        case .processes: Processes.shared.refresh()
        case .menu: MenuCommands.shared.load(frontApp)
        default: break
        }
    }

    func extraItems(_ q: String) -> [ResultItem] {
        switch scope {
        case .files:
            FileSearch.shared.search(q, min: 2)
            return FileSearch.shared.hits.map(fileRow)
        case .processes:
            return Processes.shared.list.filter { q.isEmpty || matchScore($0.name, q) > 0 }.map(processRow)
        case .colors:
            let pick = Answer(title: "Pick a color", subtitle: "From anywhere on the screen, then its HEX is copied", symbol: "eyedropper", color: .systemPink,
                              action: ColorPicks.pickAction(clipboard), hint: "Pick ↩")
            return [row("pick", pick)] + ColorPicks.list.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }.map { hex in
                var a = Tools.answers(hex, store.settings).first ?? Answer(title: hex, image: NSColor(hex: hex).map(Tools.swatch), action: .copy(hex))
                a.card = nil // a row, not the big color card
                return row("color-" + hex, a)
            }
        case .snippets:
            return snippetRows(q)
        case .menu:
            return menuRows(q)
        default:
            return []
        }
    }

    /// Quicklinks and the speed test, above the other answers in the main search.
    func searchExtras(_ q: String) -> [ResultItem] {
        let l = q.lowercased()
        var out: [Answer] = []
        let links = store.settings.quicklinks.filter { !$0.keyword.isEmpty && !$0.url.isEmpty }
        if let space = q.firstIndex(of: " "), let link = links.first(where: { $0.keyword.lowercased() == l[..<space].description }) {
            let text = q[space...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, let url = link.link(text) {
                out.append(Answer(title: "Search \(link.name) for “\(text)”", subtitle: url.host, symbol: "link", color: .systemBlue, action: .open(url)))
            }
        } else if ["quicklinks", "quicklink", "links"].contains(l) {
            out = links.map(fillAnswer)
        } else if l.count >= 2 {
            out = links.filter { $0.keyword.lowercased() == l || $0.name.lowercased().hasPrefix(l) }.map(fillAnswer)
        }
        if l.count >= 4, ["speed test", "speedtest", "internet speed", "network quality", "wifi speed", "スピードテスト", "回線速度"].contains(where: { $0.hasPrefix(l) || l == $0 }) {
            out.append(SpeedTest.shared.answer)
        }
        return out.enumerated().map { row("extra-\($0)", $1) }
    }

    /// A few matching files for the main search (all of them are in the Files scope).
    func fileHits(_ q: String) -> [ResultItem] {
        guard store.settings.filesInResults else { return [] }
        FileSearch.shared.search(q, min: 3)
        return FileSearch.shared.hits.prefix(store.settings.fileResults).map(fileRow)
    }

    private func fillAnswer(_ link: Quicklink) -> Answer {
        Answer(title: link.name, subtitle: "\(link.keyword) and what to search for", symbol: "link", color: .systemBlue, action: .fill(link.keyword + " "))
    }

    private func row(_ id: String, _ a: Answer, alt: Answer.Action? = nil, url: URL? = nil, keyword: String? = nil) -> ResultItem {
        var r = ResultItem(id: id, title: a.title, subtitle: a.subtitle, kind: .answer(a), keyword: keyword, image: a.image)
        r.alt = alt
        r.url = url
        return r
    }

    private func fileRow(_ u: URL) -> ResultItem {
        let icon = LauncherExtras.demo ? NSWorkspace.shared.icon(for: UTType(filenameExtension: u.pathExtension) ?? .folder)
            : NSWorkspace.shared.icon(forFile: u.path)
        let a = Answer(title: FileManager.default.displayName(atPath: u.path), subtitle: (u.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                       image: icon, action: .open(u))
        return row("file-" + u.path, a, alt: .run(keepOpen: false) { NSWorkspace.shared.activateFileViewerSelecting([u]) }, url: u)
    }

    private func processRow(_ p: Processes.Proc) -> ResultItem {
        let memory = ByteCountFormatter.string(fromByteCount: Int64(p.memory), countStyle: .memory)
        let detail = (p.icon == nil ? "Background · " : "") + String(format: "%.0f%% CPU · ", p.cpu) + memory
        let a = Answer(title: p.name, subtitle: detail, symbol: "gearshape.fill", color: .systemGray, image: p.icon,
                       action: .run(keepOpen: true) { Processes.shared.quit(p, force: false) }, hint: "Quit ↩")
        return row("proc-\(p.pid)", a, alt: .run(keepOpen: true) { Processes.shared.quit(p, force: true) })
    }

    private func snippetRows(_ q: String) -> [ResultItem] {
        let list = LauncherExtras.demo ? Snippets.demo : store.settings.snippets
        let copied = Snippets.clipboardText()
        var rows = list.filter { !$0.text.isEmpty && (q.isEmpty || matchScore($0.trigger, q) > 400 || $0.text.localizedCaseInsensitiveContains(q)) }
            .sorted { matchScore($0.trigger, q) > matchScore($1.trigger, q) }
            .map { sn in
                row("snip-\(sn.id)", Answer(title: sn.trigger.isEmpty ? Tools.oneLine(sn.text, 60) : sn.trigger, subtitle: Tools.oneLine(sn.text, 120),
                                            symbol: "text.quote", color: .systemPurple, action: .paste(Snippets.expand(sn.text, clipboard: copied ?? ""))))
            }
        // Type a name to keep the copied text as a snippet under it.
        let name = q.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let copied, !copied.isEmpty, !list.contains(where: { $0.trigger.lowercased() == name.lowercased() }) {
            rows.append(row("snip-add", Answer(title: "Save the copied text as “\(name)”", subtitle: Tools.oneLine(copied, 120), symbol: "plus", color: .systemPurple,
                                               action: .run(keepOpen: true) { [weak self] in
                                                   guard let self, !LauncherExtras.demo else { return }
                                                   self.store.settings.snippets.append(Snippet(trigger: name, text: copied))
                                                   self.setQuery("")
                                               }, hint: "Save ↩")))
        }
        return rows
    }

    private func menuRows(_ q: String) -> [ResultItem] {
        guard LauncherExtras.demo || frontApp != nil else {
            return [row("menu-none", Answer(title: "No app in front", symbol: "filemenu.and.selection", color: .systemGray))]
        }
        guard LauncherExtras.demo || AXIsProcessTrusted() else {
            return [row("menu-ax", Answer(title: "Allow Accessibility to search menus", subtitle: "System Settings › Privacy & Security › Accessibility",
                                          symbol: "lock.shield", color: .systemBlue, action: .run(keepOpen: false) { Paster.requestAccess() }, hint: "Allow ↩"))]
        }
        let items = MenuCommands.shared.items(frontApp)
        let scored = q.isEmpty ? items.map { ($0, 0) }
            : items.map { i in (i, max(matchScore(i.title, q), matchScore((i.path + [i.title]).joined(separator: " "), q) - 50)) }.filter { $0.1 > 400 }.sorted { $0.1 > $1.1 }
        return scored.prefix(200).enumerated().map { n, s in
            let item = s.0
            return row("menu-\(n)", Answer(title: item.title, subtitle: item.path.joined(separator: " › "), symbol: "filemenu.and.selection", color: .systemBlue,
                                           action: .run(keepOpen: false) { item.press() }, hint: "Run ↩"), keyword: item.keys)
        }
    }
}

// MARK: Files

/// Spotlight by name, after a short pause in typing. Exact and starting matches first, then the most recently used.
@MainActor final class FileSearch {
    static let shared = FileSearch()
    var onUpdate: () -> Void = {}
    private(set) var hits: [URL] = []
    private var term = ""
    private var query: NSMetadataQuery?
    private var pending: DispatchWorkItem?

    private init() {
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                let s = FileSearch.shared
                guard let m = n.object as? NSMetadataQuery, m === s.query else { return }
                m.stop()
                let paths = (0..<min(m.resultCount, 300)).compactMap { (m.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
                s.hits = Array(Self.rank(paths.map(URL.init(fileURLWithPath:)), s.term).prefix(30))
                s.query = nil
                s.onUpdate()
            }
        }
    }

    /// Shorter text than `min` finds nothing (one letter matches most of the disk).
    func search(_ q: String, min: Int) {
        guard q != term else { return }
        pending?.cancel()
        query?.stop()
        query = nil
        term = q
        // The last results stay until the new ones come, so the list doesn't blink while typing.
        guard q.count >= min else { hits = []; return }
        if LauncherExtras.demo {
            hits = Self.rank(Self.demoFiles.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(q) }, q)
            return
        }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let m = NSMetadataQuery()
                m.predicate = NSPredicate(format: "%K CONTAINS[cd] %@ AND %K != %@", NSMetadataItemDisplayNameKey, q, NSMetadataItemContentTypeKey, "com.apple.application-bundle")
                m.searchScopes = [NSMetadataQueryUserHomeScope]
                m.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
                FileSearch.shared.query = m
                m.start()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// The popup closed: stop looking and let the results go.
    func reset() {
        pending?.cancel()
        query?.stop()
        query = nil
        hits = []
        term = ""
    }

    /// Stable: within the same kind of match the most recently used stays first.
    static func rank(_ urls: [URL], _ q: String) -> [URL] {
        let l = q.lowercased()
        func score(_ u: URL) -> Int {
            let name = u.deletingPathExtension().lastPathComponent.lowercased()
            return name == l || u.lastPathComponent.lowercased() == l ? 3 : name.hasPrefix(l) ? 2 : name.contains(" " + l) ? 1 : 0
        }
        return urls.enumerated().sorted { (score($0.1), -$0.0) > (score($1.1), -$1.0) }.map(\.1)
    }

    static var demoFiles: [URL] {
        let home = NSHomeDirectory()
        return ["Documents/Q3 Budget.pdf", "Documents/Budget 2027.xlsx", "Downloads/budget-template.pdf", "Desktop/Festival Budget Notes.txt",
                "Documents/Venue Contract.pdf", "Pictures/Venue Map.png", "Documents/Sponsor Deck.key", "Developer/budget-tool"]
            .map { URL(fileURLWithPath: home + "/" + $0) }
    }
}

/// Space (or ⌘Y) on a file row: Quick Look beside the bar, without taking the keys from it.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    var url: URL?

    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(_ url: URL, above level: NSWindow.Level) {
        self.url = url
        guard let p = QLPreviewPanel.shared() else { return }
        p.dataSource = self
        p.level = NSWindow.Level(level.rawValue + 1)
        p.reloadData()
        p.orderFront(nil)
    }

    func close() {
        guard isOpen else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}

// MARK: Processes

/// This user's apps, and background processes using real CPU or memory, busiest first. MONEY! itself and the ones
/// macOS can't do without are never listed.
@MainActor final class Processes {
    static let shared = Processes()
    struct Proc {
        let pid: pid_t
        let name: String
        let app: NSRunningApplication?
        let icon: NSImage?
        let cpu: Double
        let memory: UInt64
    }

    var onUpdate: () -> Void = {}
    private(set) var list: [Proc] = []
    private var last: [pid_t: UInt64] = [:]
    private var lastAt: UInt64 = 0
    static let protected: Set<String> = ["WindowServer", "loginwindow", "kernel_task", "launchd", "Dock", "SystemUIServer", "ControlCenter",
                                         "NotificationCenter", "cfprefsd", "distnoted", "UserEventAgent", "coreaudiod", "MONEY", "MONEY!"]

    /// Two readings a moment apart: CPU use is the time spent between them.
    func refresh() {
        if LauncherExtras.demo { list = Self.demoList; return }
        sample()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                Processes.shared.sample()
                Processes.shared.onUpdate()
            }
        }
    }

    func quit(_ p: Proc, force: Bool) {
        guard !LauncherExtras.demo, p.pid > 1, p.pid != getpid(), !Self.protected.contains(p.name) else { return }
        if let app = p.app { _ = force ? app.forceTerminate() : app.terminate() } else { kill(p.pid, force ? SIGKILL : SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { Processes.shared.refresh() } }
    }

    private func sample() {
        let now = mach_absolute_time()
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let apps = Dictionary(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { ($0.processIdentifier, $0) }) { a, _ in a }
        let me = getpid()
        var seen: [pid_t: UInt64] = [:]
        var out: [Proc] = []
        for pid in pids.prefix(max(0, n)) where pid > 1 && pid != me {
            var info = rusage_info_v4()
            // Other users' processes (root, system daemons) can't be read, so they never show.
            let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
            guard ok == 0 else { continue }
            // Both in mach ticks, so their ratio needs no timebase.
            let cpuTime = info.ri_user_time + info.ri_system_time
            seen[pid] = cpuTime
            let cpu = lastAt > 0 && now > lastAt ? last[pid].map { Double(cpuTime &- $0) / Double(now - lastAt) * 100 } ?? 0 : 0
            let app = apps[pid]
            if app == nil, cpu < 2, info.ri_phys_footprint < 300 << 20 { continue }
            let name = app?.localizedName ?? Self.name(pid)
            guard !name.isEmpty, !Self.protected.contains(name) else { continue }
            out.append(Proc(pid: pid, name: name, app: app, icon: app?.icon, cpu: max(0, cpu), memory: info.ri_phys_footprint))
        }
        last = seen
        lastAt = now
        list = out.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }
    }

    private static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static var demoList: [Proc] {
        let icon = { (path: String) in NSWorkspace.shared.icon(forFile: path) }
        return [Proc(pid: 9001, name: "Photos", app: nil, icon: icon("/System/Applications/Photos.app"), cpu: 48, memory: 2_300_000_000),
                Proc(pid: 9002, name: "Preview", app: nil, icon: icon("/System/Applications/Preview.app"), cpu: 12, memory: 1_400_000_000),
                Proc(pid: 9003, name: "Renderer Helper", app: nil, icon: nil, cpu: 9, memory: 640_000_000),
                Proc(pid: 9004, name: "Music", app: nil, icon: icon("/System/Applications/Music.app"), cpu: 3, memory: 210_000_000),
                Proc(pid: 9005, name: "mds_stores", app: nil, icon: nil, cpu: 2, memory: 90_000_000),
                Proc(pid: 9006, name: "Notes", app: nil, icon: icon("/System/Applications/Notes.app"), cpu: 0, memory: 180_000_000)]
    }
}

// MARK: Colors

/// The color sampler's loupe; the picked HEX is copied and kept in a short list (newest first).
@MainActor enum ColorPicks {
    private static let key = "colorPicks"
    private static var sampler: NSColorSampler?

    static var list: [String] {
        LauncherExtras.demo ? ["#FF8800", "#2D6CDF", "#34C759", "#1E1E20"] : UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func pickAction(_ clipboard: ClipboardStore) -> Answer.Action {
        .run(keepOpen: false) {
            guard !LauncherExtras.demo else { return }
            let s = NSColorSampler()
            sampler = s
            s.show { color in
                MainActor.assumeIsolated {
                    sampler = nil
                    guard let hex = color?.hexString else { return }
                    UserDefaults.standard.set(Array(([hex] + list.filter { $0 != hex }).prefix(8)), forKey: key)
                    clipboard.copy(text: hex, source: "Color Picker")
                    Tools.flash(hex, "Copied", "eyedropper")
                }
            }
        }
    }
}

// MARK: Snippets

enum Snippets {
    static let demo = [Snippet(trigger: "email", text: "ben@example.com"), Snippet(trigger: "address", text: "1-2-3 Jingumae, Shibuya, Tokyo 150-0001"),
                       Snippet(trigger: "thanks", text: "Thanks for this, I'll get back to you by {date}."), Snippet(trigger: "meeting notes", text: "Notes {date} {time}\n\n{clipboard}")]

    /// {date}, {time} and {clipboard} filled in.
    static func expand(_ text: String, clipboard: String, now: Date = Date()) -> String {
        text.replacingOccurrences(of: "{date}", with: now.formatted(date: .abbreviated, time: .omitted))
            .replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened))
            .replacingOccurrences(of: "{clipboard}", with: clipboard)
    }

    @MainActor static func clipboardText() -> String? {
        LauncherExtras.demo ? "Room 4B, the code is 2580" : NSPasteboard.general.string(forType: .string)
    }
}

// MARK: Speed test

/// `networkQuality -c` in the background; its card shows the seconds while it runs, then the results.
@MainActor final class SpeedTest {
    static let shared = SpeedTest()
    enum State { case idle, running(Date), done(down: Double, up: Double, rpm: Double), failed }
    var state = State.idle
    var onUpdate: () -> Void = {}
    private var ticker: Timer?

    func start() {
        if case .running = state { return }
        guard !LauncherExtras.demo else { return }
        state = .running(Date())
        onUpdate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { SpeedTest.shared.onUpdate() } }
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
            p.arguments = ["-c"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            let ran = (try? p.run()) != nil
            let data = ran ? out.fileHandleForReading.readDataToEndOfFile() : Data()
            if ran { p.waitUntilExit() }
            await MainActor.run {
                let s = SpeedTest.shared
                s.ticker?.invalidate()
                s.state = Self.parse(data) ?? .failed
                s.onUpdate()
            }
        }
    }

    /// Throughput comes in bits per second, responsiveness in round trips per minute.
    nonisolated static func parse(_ data: Data) -> State? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let down = (j["dl_throughput"] as? NSNumber)?.doubleValue, let up = (j["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        return .done(down: down / 1e6, up: up / 1e6, rpm: (j["responsiveness"] as? NSNumber)?.doubleValue ?? 0)
    }

    var answer: Answer {
        let again = Answer.Action.run(keepOpen: true) { SpeedTest.shared.start() }
        let mbps = { (v: Double) in v < 100 ? String(format: "%.1f", v) : String(format: "%.0f", v) }
        var big = ToolCard.Big(title: "Speed Test", symbol: "speedometer", color: .systemGreen, value: "")
        switch state {
        case .idle:
            return Answer(title: "Speed Test", subtitle: "Download, upload and responsiveness, in about 20 seconds", symbol: "speedometer", color: .systemGreen,
                          action: again, hint: "Start ↩")
        case .running(let since):
            big.caption = "Testing the connection"
            big.value = "\(max(0, Int(Date().timeIntervalSince(since)))) s"
            big.detail = "Download, upload and responsiveness"
            return Answer(title: "Speed Test", symbol: "speedometer", color: .systemGreen, card: .big(big))
        case .done(let down, let up, let rpm):
            big.caption = "Download"
            big.value = mbps(down)
            big.unit = "Mbps"
            big.detail = "Upload \(mbps(up)) Mbps · Responsiveness \(Int(rpm)) RPM"
            big.again = again
            return Answer(title: "Speed Test", symbol: "speedometer", color: .systemGreen,
                          action: .copy("Download \(mbps(down)) Mbps, upload \(mbps(up)) Mbps, responsiveness \(Int(rpm)) RPM"), card: .big(big))
        case .failed:
            big.caption = "No result"
            big.value = "Offline?"
            big.detail = "networkQuality couldn't reach its server"
            big.again = again
            return Answer(title: "Speed Test", symbol: "speedometer", color: .systemGreen, action: again, hint: "Again ↩", card: .big(big))
        }
    }
}

// MARK: Menus of the front app

/// The menu bar of the app you were in, read through Accessibility (once per app, then kept), every enabled
/// command with its path and shortcut. ↩ presses it.
@MainActor final class MenuCommands {
    static let shared = MenuCommands()
    struct Item {
        let title: String
        let path: [String]
        let keys: String?
        let element: AXUIElement?

        func press() {
            guard let element else { return }
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }

    var onUpdate: () -> Void = {}
    private var cache: [pid_t: [Item]] = [:]

    func items(_ app: NSRunningApplication?) -> [Item] {
        LauncherExtras.demo ? Self.demo : app.flatMap { cache[$0.processIdentifier] } ?? []
    }

    /// The chip's name and icon.
    func label(_ app: NSRunningApplication?) -> (String, NSImage?)? {
        if LauncherExtras.demo { return ("Notes", NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app")) }
        return app.map { ($0.localizedName ?? "Menu", $0.icon) }
    }

    /// Reads the menus again in the background (they change as the app does); the cached ones show meanwhile.
    func load(_ app: NSRunningApplication?) {
        guard !LauncherExtras.demo, let app, AXIsProcessTrusted() else { return }
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Self.walk(pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MenuCommands.shared.cache[pid] = items
                    MenuCommands.shared.onUpdate()
                }
            }
        }
    }

    nonisolated private static func walk(_ pid: pid_t) -> [Item] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let bar = element(app, kAXMenuBarAttribute) else { return [] }
        var out: [Item] = []
        for top in children(bar).dropFirst() { // the Apple menu is the same everywhere
            let name = value(top, kAXTitleAttribute) as? String ?? ""
            for menu in children(top) { collect(menu, [name], &out, depth: 0) }
        }
        return out
    }

    nonisolated private static func collect(_ menu: AXUIElement, _ path: [String], _ out: inout [Item], depth: Int) {
        guard depth < 4, out.count < 1000 else { return }
        for item in children(menu) {
            guard let title = value(item, kAXTitleAttribute) as? String, !title.isEmpty else { continue }
            let subs = children(item)
            if !subs.isEmpty {
                for m in subs { collect(m, path + [title], &out, depth: depth + 1) }
            } else if value(item, kAXEnabledAttribute) as? Bool != false {
                out.append(Item(title: title, path: path, keys: shortcut(item), element: item))
            }
        }
    }

    /// "⌥⌘F": AX gives the key and which modifiers are added (1 ⇧, 2 ⌥, 4 ⌃) or ⌘ taken away (8).
    nonisolated private static func shortcut(_ item: AXUIElement) -> String? {
        guard let key = value(item, kAXMenuItemCmdCharAttribute) as? String, !key.isEmpty else { return nil }
        let m = (value(item, kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0
        return (m & 4 != 0 ? "⌃" : "") + (m & 2 != 0 ? "⌥" : "") + (m & 1 != 0 ? "⇧" : "") + (m & 8 == 0 ? "⌘" : "") + key.uppercased()
    }

    nonisolated private static func value(_ e: AXUIElement, _ key: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success ? v : nil
    }

    nonisolated private static func element(_ e: AXUIElement, _ key: String) -> AXUIElement? {
        guard let o = value(e, key), CFGetTypeID(o) == AXUIElementGetTypeID() else { return nil }
        return (o as! AXUIElement)
    }

    nonisolated private static func children(_ e: AXUIElement) -> [AXUIElement] {
        (value(e, kAXChildrenAttribute) as? [AnyObject] ?? []).filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { $0 as! AXUIElement }
    }

    static let demo: [Item] = [
        ("New Note", ["File"], "⌘N"), ("New Folder", ["File"], "⇧⌘N"), ("Export as PDF…", ["File"], nil), ("Undo", ["Edit"], "⌘Z"),
        ("Find…", ["Edit", "Find"], "⌘F"), ("Find and Replace…", ["Edit", "Find"], "⌥⌘F"), ("Checklist", ["Format"], "⇧⌘L"),
        ("Table", ["Format"], "⌥⌘T"), ("Show Folders", ["View"], nil), ("Zoom In", ["View"], "⌘+"), ("Pin Note", ["Window"], nil),
    ].map { Item(title: $0.0, path: $0.1, keys: $0.2, element: nil) }
}
