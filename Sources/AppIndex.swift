import AppKit

struct AppEntry: Hashable, Sendable {
    let path: String
    let name: String
    let bundleID: String?
    /// The file name when it differs from the display name (e.g. "Visual Studio Code" ↔ "Code").
    let altName: String?
}

/// Every app in the configured folders, plus how often each one is opened.
@MainActor final class AppIndex {
    /// macOS's Apps (it opens Spotlight's app grid); MONEY! shows its own All Apps grid instead.
    nonisolated static let appsLauncherPath = "/System/Applications/Apps.app"

    private(set) var apps: [AppEntry] = []
    private var lastScan = Date.distantPast
    private var scanning = false
    private var usage: [String: [Double]] // path → [count, last opened]
    var onUpdate: (() -> Void)?

    init() {
        usage = UserDefaults.standard.dictionary(forKey: "usage") as? [String: [Double]] ?? [:]
    }

    func refreshIfStale(folders: [String]) {
        if Date().timeIntervalSince(lastScan) > 45 { refresh(folders: folders) }
    }

    func refresh(folders: [String]) {
        guard !scanning else { return }
        scanning = true
        let roots = folders.map { ($0 as NSString).expandingTildeInPath }
        Task.detached(priority: .utility) {
            let found = AppIndex.scan(roots)
            await MainActor.run {
                self.apps = found
                self.lastScan = Date()
                self.scanning = false
                self.onUpdate?()
            }
        }
    }

    nonisolated private static func scan(_ roots: [String]) -> [AppEntry] {
        var result: [AppEntry] = []
        var seen = Set<String>()
        let fm = FileManager.default
        func add(_ link: URL) {
            let url = link.resolvingSymlinksInPath()
            let path = url.path
            let bundle = Bundle(url: url)
            let id = bundle?.bundleIdentifier
            guard seen.insert(id ?? path).inserted else { return }
            if bundle?.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true { return }
            let name = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            let file = link.deletingPathExtension().lastPathComponent
            result.append(AppEntry(path: path, name: name, bundleID: id, altName: file == name ? nil : file))
        }
        for root in roots {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                                        options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                // Not .skipsHiddenFiles: /Applications/Safari.app is a symlink flagged hidden.
                if url.lastPathComponent.hasPrefix(".") {
                    e.skipDescendants()
                } else if url.pathExtension == "app" {
                    add(url)
                    e.skipDescendants()
                } else if e.level >= 3 {
                    e.skipDescendants()
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return result
    }

    // MARK: Usage

    func recordLaunch(_ path: String) {
        var u = usage[path] ?? [0, 0]
        u[0] += 1
        u[1] = Date().timeIntervalSince1970
        usage[path] = u
        UserDefaults.standard.set(usage, forKey: "usage")
    }

    func recents(limit: Int) -> [AppEntry] {
        let byPath = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return usage.sorted { $0.value[1] > $1.value[1] }.compactMap { byPath[$0.key] }.prefix(limit).map { $0 }
    }

    /// Bonus for apps opened often and lately, capped so it only breaks near-ties.
    func boost(_ path: String) -> Int {
        guard let u = usage[path] else { return 0 }
        let days = (Date().timeIntervalSince1970 - u[1]) / 86400
        let recency = max(0, 60 - days * 4)
        return Int(min(90, log2(u[0] + 1) * 18) + recency)
    }
}

/// How well `query` matches `text`: 0 = no match. Prefix > word start > initials > contains > in-order letters.
func matchScore(_ text: String, _ query: String) -> Int {
    let t = text.lowercased()
    let q = query.lowercased()
    guard !q.isEmpty else { return 0 }
    if t == q { return 1000 }
    if t.hasPrefix(q) { return 900 - min(100, t.count - q.count) }
    let words = splitWords(text)
    if words.contains(where: { $0.hasPrefix(q) }) { return 780 - min(80, t.count - q.count) }
    let initials = String(words.compactMap(\.first))
    if initials.hasPrefix(q) { return 720 }
    if t.contains(q) { return 600 - min(100, t.count - q.count) }
    // In-order letters, punished for gaps.
    var gaps = 0
    var ti = t.startIndex
    for ch in q {
        guard let found = t[ti...].firstIndex(of: ch) else { return 0 }
        gaps += t.distance(from: ti, to: found)
        ti = t.index(after: found)
    }
    return max(1, 400 - gaps * 12)
}

/// "Visual Studio Code" → visual, studio, code; "iTerm2" → i, term2; "OneDrive" → one, drive.
private func splitWords(_ s: String) -> [String] {
    var words: [String] = []
    var cur = ""
    var prev: Character?
    for ch in s {
        if ch == " " || ch == "-" || ch == "_" || ch == "." {
            if !cur.isEmpty { words.append(cur) }
            cur = ""
        } else if ch.isUppercase, let p = prev, p.isLowercase {
            if !cur.isEmpty { words.append(cur) }
            cur = String(ch)
        } else {
            cur.append(ch)
        }
        prev = ch
    }
    if !cur.isEmpty { words.append(cur) }
    return words.map { $0.lowercased() }
}

/// Running apps in most-recently-used order.
@MainActor final class Switcher {
    private var order: [pid_t] = []

    init() {
        if let front = NSWorkspace.shared.frontmostApplication { order = [front.processIdentifier] }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self?.order.removeAll { $0 == pid }
                self?.order.insert(pid, at: 0)
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.order.removeAll { $0 == pid } }
        }
    }

    func apps() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return running.enumerated().sorted { a, b in
            (rank[a.element.processIdentifier] ?? 10_000 + a.offset) < (rank[b.element.processIdentifier] ?? 10_000 + b.offset)
        }.map(\.element)
    }
}

@MainActor enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    static func icon(forPath path: String) -> NSImage {
        if let i = cache.object(forKey: path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(i, forKey: path as NSString)
        return i
    }

    static func icon(forBundleID id: String) -> NSImage? {
        if let i = cache.object(forKey: id as NSString) { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(i, forKey: id as NSString)
        return i
    }
}
