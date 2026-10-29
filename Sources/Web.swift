import AppKit
import SQLite3

/// A website's home page, as the Moneybag browser bar suggests them.
struct SiteHome: Sendable {
    let host: String
    let home: String
    var visits: Int
    var lastVisit: Double
    let names: [String]
}

/// Reads a browser's history (Chromium family or Safari) into site homes, like Moneybag's `siteHomes`.
enum BrowserSites {
    static let popular = [
        "google.com", "youtube.com", "mail.google.com", "facebook.com", "instagram.com", "x.com", "wikipedia.org", "amazon.com",
        "reddit.com", "linkedin.com", "netflix.com", "tiktok.com", "web.whatsapp.com", "chatgpt.com", "claude.ai", "openai.com",
        "anthropic.com", "github.com", "gitlab.com", "stackoverflow.com", "apple.com", "icloud.com", "microsoft.com",
        "outlook.live.com", "office.com", "bing.com", "yahoo.com", "duckduckgo.com", "twitch.tv", "discord.com", "open.spotify.com",
        "music.apple.com", "soundcloud.com", "pinterest.com", "tumblr.com", "quora.com", "medium.com", "substack.com", "notion.so",
        "figma.com", "canva.com", "slack.com", "zoom.us", "dropbox.com", "drive.google.com", "docs.google.com", "calendar.google.com",
        "maps.google.com", "translate.google.com", "news.google.com", "photos.google.com", "meet.google.com", "gemini.google.com",
        "ebay.com", "etsy.com", "walmart.com", "target.com", "bestbuy.com", "aliexpress.com", "paypal.com", "stripe.com", "airbnb.com",
        "booking.com", "expedia.com", "tripadvisor.com", "uber.com", "nytimes.com", "bbc.com", "cnn.com", "theguardian.com", "wsj.com",
        "bloomberg.com", "reuters.com", "forbes.com", "espn.com", "imdb.com", "hulu.com", "disneyplus.com", "primevideo.com",
        "crunchyroll.com", "vercel.com", "cloudflare.com", "npmjs.com", "developer.mozilla.org", "w3schools.com", "coursera.org",
        "khanacademy.org", "duolingo.com", "wordpress.com", "trello.com", "asana.com", "linear.app", "atlassian.com", "indeed.com",
        "weather.com", "archive.org", "yelp.com", "store.steampowered.com", "epicgames.com", "roblox.com", "chess.com", "genius.com",
        "behance.net", "dribbble.com", "threads.net", "bsky.app", "telegram.org", "line.me", "yahoo.co.jp", "amazon.co.jp",
        "rakuten.co.jp", "nicovideo.jp", "jp.mercari.com", "tabelog.com", "note.com", "pixiv.net", "qiita.com", "zenn.dev",
        "perplexity.ai", "deepl.com",
    ]
    static let aliases: [String: [String]] = ["mail.google.com": ["gmail"]]

    /// Chromium "User Data" folders by browser bundle id.
    private static let chromiumRoots: [String: String] = [
        "com.ardia.browser": "com.ardia.browser/Chromium",
        "company.thebrowser.dia": "Dia/User Data",
        "company.thebrowser.Browser": "Arc/User Data",
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "com.operasoftware.Opera",
    ]

    struct Loaded: Sendable {
        let sites: [SiteHome]
        let favicons: [String: Data]
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (Date, Loaded)] = [:]

    /// Everything we know for a browser (cached for 5 minutes). Runs off the main thread.
    static func load(bundleID: String?) -> Loaded {
        let key = bundleID ?? "-"
        if let hit = cacheLock.withLock({ cache[key] }), Date().timeIntervalSince(hit.0) < 300 { return hit.1 }
        var history: [(url: String, visits: Int, last: Double)] = []
        var favicons: [String: Data] = [:]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let id = bundleID, let rel = chromiumRoots[id] {
            for profile in profiles(support.appendingPathComponent(rel)) {
                history += query(profile.appendingPathComponent("History"),
                                 "SELECT url, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY visit_count DESC LIMIT 4000") {
                    (text($0, 0), Int(sqlite3_column_int64($0, 1)), Double(sqlite3_column_int64($0, 2)))
                }
                history += bookmarks(profile.appendingPathComponent("Bookmarks")).map { ($0, 1, 0) }
                let icons = query(profile.appendingPathComponent("Favicons"),
                                  "SELECT m.page_url, b.image_data, b.width FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id") {
                    (text($0, 0), blob($0, 1), Int(sqlite3_column_int($0, 2)))
                }
                var bestWidth: [String: Int] = [:]
                for (url, data, width) in icons {
                    guard let host = host(of: url), let data else { continue }
                    let score = width >= 32 ? 1000 - width : width // prefer 32–64px
                    if score > (bestWidth[host] ?? -1) {
                        bestWidth[host] = score
                        favicons[host] = data
                    }
                }
            }
        } else if bundleID == "com.apple.Safari" {
            let db = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/History.db")
            history = query(db, "SELECT url, visit_count FROM history_items ORDER BY visit_count DESC LIMIT 4000") {
                (text($0, 0), Int(sqlite3_column_int64($0, 1)), 0)
            }
        }
        var byHost: [String: SiteHome] = [:]
        func note(_ url: String, _ visits: Int, _ last: Double) {
            guard let m = url.range(of: #"^(https?)://([^/?#:]+)"#, options: [.regularExpression, .caseInsensitive]) else { return }
            let raw = String(url[m]).lowercased()
            let scheme = raw.hasPrefix("https") ? "https" : "http"
            let fullHost = String(raw.dropFirst(scheme.count + 3))
            let host = fullHost.hasPrefix("www.") ? String(fullHost.dropFirst(4)) : fullHost
            if var site = byHost[host] {
                site.visits += visits
                site.lastVisit = max(site.lastVisit, last)
                byHost[host] = site
            } else {
                byHost[host] = SiteHome(host: host, home: "\(scheme)://\(fullHost)/", visits: visits, lastVisit: last,
                                        names: [host] + host.split(separator: ".").map(String.init) + (aliases[host] ?? []))
            }
        }
        for h in history { note(h.url, h.visits, h.last) }
        for p in popular { note("https://\(p)/", 0, 0) }
        let loaded = Loaded(sites: Array(byHost.values), favicons: favicons)
        cacheLock.withLock { cache[key] = (Date(), loaded) }
        return loaded
    }

    /// Moneybag's ranking: full host prefix, then any part of the host, then most visited.
    static func suggest(_ query: String, in sites: [SiteHome], limit: Int) -> (items: [SiteHome], completion: String) {
        var typed = query.trimmingCharacters(in: .whitespaces).lowercased()
        for p in ["https://", "http://", "www."] where typed.hasPrefix(p) { typed.removeFirst(p.count) }
        if typed.isEmpty {
            let top = sites.filter { $0.visits > 0 }.sorted { $0.visits > $1.visits }.prefix(limit)
            return (Array(top), "")
        }
        guard !typed.contains(" "), !typed.contains("/") else { return ([], "") }
        let ranked = sites.compactMap { s -> (SiteHome, Int)? in
            if s.host.hasPrefix(typed) { return (s, 0) }
            if s.names.contains(where: { $0.hasPrefix(typed) }) { return (s, 1) }
            return nil
        }
        .sorted { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.visits != b.0.visits ? a.0.visits > b.0.visits : a.0.lastVisit > b.0.lastVisit }
        .prefix(limit).map(\.0)
        guard let best = ranked.first else { return ([], "") }
        if best.host.hasPrefix(typed) { return (ranked, String(best.host.dropFirst(typed.count))) }
        let alias = (aliases[best.host] ?? []).first { $0.hasPrefix(typed) }
        return (ranked, alias.map { String($0.dropFirst(typed.count)) } ?? "")
    }

    /// Where Return goes for text that isn't a suggested site: an address if it looks like one, else a web search.
    static func url(for typed: String) -> URL? {
        let t = typed.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t) }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t), u.host != nil { return u }
        return URL(string: "https://www.google.com/search?q=" + (t.addingPercentEncoding(withAllowedCharacters: .queryValue) ?? t))
    }

    // MARK: Reading the browser's files

    private static func profiles(_ root: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { fm.fileExists(atPath: $0.appendingPathComponent("History").path) }
    }

    /// Browsers keep their databases locked, so read a copy.
    private static func query<T>(_ db: URL, _ sql: String, _ row: (OpaquePointer) -> T) -> [T] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flick-\(UUID().uuidString).db")
        guard (try? FileManager.default.copyItem(at: db, to: tmp)) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: tmp) }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else { return [] }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    private static func blob(_ s: OpaquePointer, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(s, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
    }

    private static func bookmarks(_ file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [String] = []
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                if let url = d["url"] as? String { out.append(url) }
                d.values.forEach(walk)
            } else if let a = node as? [Any] {
                a.forEach(walk)
            }
        }
        walk(json)
        return out
    }

    static func host(of url: String) -> String? {
        guard let h = URL(string: url)?.host?.lowercased() else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Apps that can open web pages.
    @MainActor static let browserPaths: Set<String> = {
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
        return Set(urls.map { $0.resolvingSymlinksInPath().path })
    }()
}

/// System Settings pages, searchable by name and everyday words ("wifi", "dark mode", "dock").
struct SettingsPane: Sendable {
    let name: String
    let keywords: [String]
    let target: String
    let symbol: String
    let color: NSColor

    var url: URL? { URL(string: "x-apple.systempreferences:" + target) }

    static let all: [SettingsPane] = [
        .init(name: "Wi-Fi", keywords: ["wifi", "wi-fi", "wireless", "internet"], target: "com.apple.wifi-settings-extension", symbol: "wifi", color: .systemBlue),
        .init(name: "Bluetooth", keywords: ["bluetooth", "airpods", "headphones"], target: "com.apple.BluetoothSettings", symbol: "dot.radiowaves.left.and.right", color: .systemBlue),
        .init(name: "Network", keywords: ["network", "ethernet", "proxy", "dns", "firewall"], target: "com.apple.Network-Settings.extension", symbol: "network", color: .systemBlue),
        .init(name: "VPN", keywords: ["vpn"], target: "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", symbol: "network.badge.shield.half.filled", color: .systemBlue),
        .init(name: "Battery", keywords: ["battery", "power", "energy", "low power", "charging"], target: "com.apple.Battery-Settings.extension", symbol: "battery.100", color: .systemGreen),
        .init(name: "General", keywords: ["general"], target: "com.apple.systempreferences.GeneralSettings", symbol: "gearshape", color: .systemGray),
        .init(name: "About This Mac", keywords: ["about", "serial", "macos version", "specs"], target: "com.apple.SystemProfiler.AboutExtension", symbol: "info.circle", color: .systemGray),
        .init(name: "Software Update", keywords: ["update", "upgrade", "software update"], target: "com.apple.Software-Update-Settings.extension", symbol: "arrow.triangle.2.circlepath", color: .systemGray),
        .init(name: "Storage", keywords: ["storage", "disk space", "free space"], target: "com.apple.settings.Storage", symbol: "internaldrive", color: .systemGray),
        .init(name: "AirDrop & Handoff", keywords: ["airdrop", "handoff", "airplay receiver"], target: "com.apple.AirDrop-Handoff-Settings.extension", symbol: "airplayaudio", color: .systemGray),
        .init(name: "Login Items & Extensions", keywords: ["login items", "startup", "open at login", "background items", "extensions"], target: "com.apple.LoginItems-Settings.extension", symbol: "list.bullet", color: .systemGray),
        .init(name: "Language & Region", keywords: ["language", "region", "言語", "地域"], target: "com.apple.Localization-Settings.extension", symbol: "globe", color: .systemGray),
        .init(name: "Date & Time", keywords: ["date", "time", "clock", "time zone"], target: "com.apple.Date-Time-Settings.extension", symbol: "clock", color: .systemGray),
        .init(name: "Sharing", keywords: ["sharing", "file sharing", "screen sharing", "remote login", "computer name"], target: "com.apple.Sharing-Settings.extension", symbol: "person.2", color: .systemGray),
        .init(name: "Time Machine", keywords: ["time machine", "backup"], target: "com.apple.Time-Machine-Settings.extension", symbol: "clock.arrow.circlepath", color: .systemGray),
        .init(name: "Transfer or Reset", keywords: ["reset", "erase", "transfer"], target: "com.apple.Transfer-Reset-Settings.extension", symbol: "arrow.counterclockwise", color: .systemGray),
        .init(name: "Startup Disk", keywords: ["startup disk", "boot"], target: "com.apple.Startup-Disk-Settings.extension", symbol: "externaldrive", color: .systemGray),
        .init(name: "Device Management", keywords: ["profiles", "mdm", "device management"], target: "com.apple.Profiles-Settings.extension", symbol: "checkmark.seal", color: .systemGray),
        .init(name: "Accessibility", keywords: ["accessibility", "voiceover", "zoom", "reduce motion", "a11y"], target: "com.apple.Accessibility-Settings.extension", symbol: "accessibility", color: .systemBlue),
        .init(name: "Appearance", keywords: ["appearance", "dark mode", "light mode", "accent colour", "accent color", "theme", "scroll bars"], target: "com.apple.Appearance-Settings.extension", symbol: "circle.lefthalf.filled", color: .black),
        .init(name: "Apple Intelligence & Siri", keywords: ["siri", "apple intelligence", "ai"], target: "com.apple.Siri-Settings.extension", symbol: "sparkle", color: .systemPurple),
        .init(name: "Spotlight", keywords: ["spotlight"], target: "com.apple.Spotlight-Settings.extension", symbol: "magnifyingglass", color: .systemGray),
        .init(name: "Control Center", keywords: ["control center", "control centre", "menu bar"], target: "com.apple.ControlCenter-Settings.extension", symbol: "switch.2", color: .systemGray),
        .init(name: "Desktop & Dock", keywords: ["dock", "desktop", "stage manager", "hot corners", "mission control", "widgets", "windows"], target: "com.apple.Desktop-Settings.extension", symbol: "dock.rectangle", color: .black),
        .init(name: "Displays", keywords: ["display", "displays", "monitor", "resolution", "brightness", "night shift", "true tone"], target: "com.apple.Displays-Settings.extension", symbol: "sun.max", color: .systemBlue),
        .init(name: "Wallpaper", keywords: ["wallpaper", "background"], target: "com.apple.Wallpaper-Settings.extension", symbol: "photo", color: .systemTeal),
        .init(name: "Notifications", keywords: ["notifications", "alerts", "banners"], target: "com.apple.Notifications-Settings.extension", symbol: "bell.badge", color: .systemRed),
        .init(name: "Sound", keywords: ["sound", "volume", "audio", "output", "input", "alert sound"], target: "com.apple.Sound-Settings.extension", symbol: "speaker.wave.2", color: .systemPink),
        .init(name: "Focus", keywords: ["focus", "do not disturb", "dnd"], target: "com.apple.Focus-Settings.extension", symbol: "moon", color: .systemIndigo),
        .init(name: "Screen Time", keywords: ["screen time", "app limits"], target: "com.apple.Screen-Time-Settings.extension", symbol: "hourglass", color: .systemIndigo),
        .init(name: "Lock Screen", keywords: ["lock screen", "screen saver", "sleep", "require password"], target: "com.apple.Lock-Screen-Settings.extension", symbol: "lock.display", color: .black),
        .init(name: "Privacy & Security", keywords: ["privacy", "security", "filevault", "gatekeeper", "permissions"], target: "com.apple.settings.PrivacySecurity.extension", symbol: "hand.raised", color: .systemBlue),
        .init(name: "Touch ID & Password", keywords: ["touch id", "password", "fingerprint", "login password"], target: "com.apple.Touch-ID-Settings.extension", symbol: "touchid", color: .systemRed),
        .init(name: "Users & Groups", keywords: ["users", "groups", "guest user", "accounts"], target: "com.apple.Users-Groups-Settings.extension", symbol: "person.2.fill", color: .systemBlue),
        .init(name: "Internet Accounts", keywords: ["internet accounts", "email accounts", "google account", "mail accounts"], target: "com.apple.Internet-Accounts-Settings.extension", symbol: "at", color: .systemBlue),
        .init(name: "Apple Account", keywords: ["apple id", "apple account", "icloud"], target: "com.apple.systempreferences.AppleIDSettings", symbol: "applelogo", color: .systemGray),
        .init(name: "Family", keywords: ["family", "family sharing"], target: "com.apple.Family-Settings.extension", symbol: "person.3", color: .systemBlue),
        .init(name: "Wallet & Apple Pay", keywords: ["wallet", "apple pay", "cards"], target: "com.apple.WalletSettingsExtension", symbol: "wallet.pass", color: .black),
        .init(name: "Game Center", keywords: ["game center"], target: "com.apple.Game-Center-Settings.extension", symbol: "gamecontroller", color: .systemGray),
        .init(name: "Game Controllers", keywords: ["game controllers", "controller", "gamepad"], target: "com.apple.Game-Controller-Settings.extension", symbol: "gamecontroller.fill", color: .systemGray),
        .init(name: "Keyboard", keywords: ["keyboard", "shortcuts", "keyboard shortcuts", "input sources", "key repeat", "dictation", "入力ソース"], target: "com.apple.Keyboard-Settings.extension", symbol: "keyboard", color: .systemGray),
        .init(name: "Mouse", keywords: ["mouse", "pointer speed"], target: "com.apple.Mouse-Settings.extension", symbol: "computermouse", color: .systemGray),
        .init(name: "Trackpad", keywords: ["trackpad", "gestures", "tap to click", "scroll direction", "force click"], target: "com.apple.Trackpad-Settings.extension", symbol: "rectangle.and.hand.point.up.left", color: .systemGray),
        .init(name: "Printers & Scanners", keywords: ["printer", "printers", "scanner", "print"], target: "com.apple.Print-Scan-Settings.extension", symbol: "printer", color: .systemGray),
        .init(name: "Microphone Access", keywords: ["microphone", "mic permission"], target: "com.apple.preference.security?Privacy_Microphone", symbol: "mic", color: .systemOrange),
        .init(name: "Camera Access", keywords: ["camera", "webcam"], target: "com.apple.preference.security?Privacy_Camera", symbol: "camera", color: .systemGreen),
        .init(name: "Screen & System Audio Recording", keywords: ["screen recording", "screen capture", "system audio"], target: "com.apple.preference.security?Privacy_ScreenCapture", symbol: "rectangle.dashed.badge.record", color: .systemPurple),
        .init(name: "Accessibility Access", keywords: ["accessibility access", "accessibility permission"], target: "com.apple.preference.security?Privacy_Accessibility", symbol: "accessibility", color: .systemBlue),
        .init(name: "Full Disk Access", keywords: ["full disk access", "disk access"], target: "com.apple.preference.security?Privacy_AllFiles", symbol: "externaldrive.badge.checkmark", color: .systemGray),
        .init(name: "Location Services", keywords: ["location", "location services", "gps"], target: "com.apple.preference.security?Privacy_LocationServices", symbol: "location.fill", color: .systemBlue),
        .init(name: "Input Monitoring", keywords: ["input monitoring", "keyboard monitoring"], target: "com.apple.preference.security?Privacy_ListenEvent", symbol: "keyboard.badge.eye", color: .systemGray),
        .init(name: "Automation", keywords: ["automation", "apple events"], target: "com.apple.preference.security?Privacy_Automation", symbol: "gearshape.2", color: .systemGray),
    ]
}

extension CharacterSet {
    /// What can stay as it is inside one query value ("Simon & Garfunkel" keeps its "&" as text, not a new parameter).
    static let queryValue: CharacterSet = {
        var s = CharacterSet.urlQueryAllowed
        s.remove(charactersIn: "&+=?#/:")
        return s
    }()
}
