import AppKit
import Carbon.HIToolbox
import Observation

enum GlassStyle: String, Codable, CaseIterable, Identifiable {
    case clear, regular, solid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clear: "Clear glass"
        case .regular: "Frosted glass"
        case .solid: "Solid"
        }
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum EmptyState: String, Codable, CaseIterable, Identifiable {
    case nothing, recents, running
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nothing: "Nothing (just the bar)"
        case .recents: "Recently opened apps"
        case .running: "Running apps"
        }
    }
}

enum ScreenChoice: String, Codable, CaseIterable, Identifiable {
    case mouse, main
    var id: String { rawValue }
    var title: String { self == .mouse ? "Screen with the pointer" : "Main screen" }
}

enum ClaudeModel: String, Codable, CaseIterable, Identifiable {
    case opus = "claude-opus-5-5", sonnet = "claude-sonnet-5-5", haiku = "claude-haiku-5-5"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .opus: "Claude Opus 5.5 (best)"
        case .sonnet: "Claude Sonnet 5.5"
        case .haiku: "Claude Haiku 5.5 (fastest, cheapest)"
        }
    }
}

enum DictationLanguage: String, Codable, CaseIterable, Identifiable {
    case both, english, japanese
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: "English + 日本語 (mixed)"
        case .english: "English"
        case .japanese: "日本語"
        }
    }
    var locales: [String] {
        switch self {
        case .both: ["en_US", "ja_JP"]
        case .english: ["en_US"]
        case .japanese: ["ja_JP"]
        }
    }
}

enum DictationStyle: String, Codable, CaseIterable, Identifiable {
    case auto, casual, neutral, formal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Match the app"
        case .casual: "Casual"
        case .neutral: "Neutral"
        case .formal: "Formal"
        }
    }
}

/// What ⌘2–⌘5 and the round buttons beside the bar open (up to four, in order).
enum QuickMode: String, Codable, CaseIterable, Identifiable {
    case clipboard, text, meeting, clock, notes, calculator, translate, weather, mixer, library, switcher
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .text: "Text from screen"
        case .meeting: "Meetings"
        case .clock: "Clock"
        case .notes: "Sticky notes"
        case .calculator: "Calculator"
        case .translate: "Translate"
        case .weather: "Weather"
        case .mixer: "Volume mixer"
        case .library: "All Apps"
        case .switcher: "App switcher"
        }
    }
    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .text: "text.viewfinder"
        case .meeting: "waveform"
        case .clock: "clock.fill"
        case .notes: "note.text"
        case .calculator: "plus.forwardslash.minus"
        case .translate: "character.bubble.fill"
        case .weather: "cloud.sun.fill"
        case .mixer: "slider.vertical.3"
        case .library: "square.grid.3x3.fill"
        case .switcher: "rectangle.stack"
        }
    }
    var scope: Scope {
        switch self {
        case .clipboard: .clipboard
        case .text: .text
        case .meeting: .meeting
        case .clock: .pomodoro
        case .notes: .notes
        case .calculator: .calculator
        case .translate: .translate
        case .weather: .weather
        case .mixer: .mixer
        case .library: .library
        case .switcher: .switcher
        }
    }
}

/// A button beside the bar (and ⌘2–⌘5): one of MONEY!'s modes, or an app to open.
/// Saved as a plain string ("clipboard", "app:/Applications/Safari.app"), so older settings still load.
enum QuickButton: Codable, Hashable, Identifiable {
    case mode(QuickMode)
    case app(String)

    var id: String { raw }
    var raw: String {
        switch self {
        case .mode(let m): m.rawValue
        case .app(let path): "app:" + path
        }
    }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        if s.hasPrefix("app:") { self = .app(String(s.dropFirst(4))) } else { self = .mode(QuickMode(rawValue: s) ?? .clipboard) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    var title: String {
        switch self {
        case .mode(let m): m.title
        case .app(let path): FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        }
    }
}

/// What the closed notch shows first when more than three things are going on (alarms and dictation always lead).
enum NotchKind: String, Codable, CaseIterable, Identifiable {
    case media, timer, meeting, focus, stopwatch, message
    var id: String { rawValue }
    var title: String {
        switch self {
        case .media: "What’s playing"
        case .timer: "Timers"
        case .meeting: "Meetings"
        case .focus: "Focus"
        case .stopwatch: "Stopwatches"
        case .message: "Messages"
        }
    }
    var symbol: String {
        switch self {
        case .media: "music.note"
        case .timer: "timer"
        case .meeting: "waveform"
        case .focus: "brain.head.profile"
        case .stopwatch: "stopwatch"
        case .message: "checkmark.circle"
        }
    }
}

/// Groups of search-bar answers that can be switched off.
enum ToolGroup: String, Codable, CaseIterable, Identifiable {
    case calculator, units, currency, weather, time, dates, text, generators, colors, system, emoji, translate, define
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calculator: "Calculator"
        case .units: "Unit conversion"
        case .currency: "Currency and crypto"
        case .weather: "Weather"
        case .time: "World clock and time zones"
        case .dates: "Dates, countdowns, Japanese era"
        case .text: "Text tools (case, Base64, hashes, kana…)"
        case .generators: "Passwords, UUIDs, dice, random"
        case .colors: "Colors, number bases, QR codes"
        case .system: "Mac info and switches"
        case .emoji: "Emoji"
        case .translate: "Translate"
        case .define: "Dictionary"
        }
    }
}

struct Snippet: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var trigger = ""
    var text = ""
}

struct Settings: Codable, Equatable {
    /// 2: per-app hotkeys replaced custom shortcuts; empty search shows running apps.
    var version = 3

    // Hotkeys
    var launcherHotKey = HotKey.launcherDefault
    var clipboardHotKey = HotKey.clipboardDefault
    var switcherHotKey = HotKey.switcherDefault
    var holdToSwitch = true

    // Appearance (defaults match the Moneybag ⌘T popup)
    var width: Double = 700
    var clipboardWidth: Double = 700
    var barHeight: Double = 76
    var fontSize: Double = 20
    var cornerRadius: Double = 38
    var scopedCornerRadius: Double = 26
    var rowHeight: Double = 44
    var maxRows = 7
    var glass = GlassStyle.clear
    var tintStrength: Double = 1
    /// Black laid over the glass, 0…0.9.
    var darkness: Double = 0.55
    var customTint = false
    var tintHex = "#4C4C4F"
    var appearance = AppearanceMode.system
    var shadeScopes = true
    var showIcons = true
    var showHints = true
    var showTabs = true
    var animations = true
    var placeholder = "Search apps"

    // Position: centre x and bar centre y as fractions of the screen (y from the top).
    var position: [Double]? = nil
    var screen = ScreenChoice.mouse

    // Behaviour
    var emptyState = EmptyState.running
    var ghostCompletion = true
    var builtinsInResults = true
    var searchSettingsPages = true

    // Tools: instant answers while you type (weather, calculator, units, currency, time zones…)
    var instantAnswers = true
    /// What's playing (Music, Spotify) with controls, in the notch and at the top of the popup.
    var mediaInNotch = true
    var mediaInPopup = true
    var disabledTools: [ToolGroup] = []
    var calcDecimals = 10
    /// Color the understood words while typing in a mode.
    var colorTypedText = true

    // ⌘2–⌘5 and the buttons beside the bar.
    var quickModes: [QuickButton] = [.mode(.clipboard), .mode(.text), .mode(.meeting), .mode(.clock)]

    // Clock
    var timerDefaultMinutes: Double = 5
    var timerSound = "Glass"
    var alarmSound = "Glass"
    var alarmSnoozeMinutes = 9
    var stopwatchHundredths = true

    // Notch
    var notchEnabled = true
    var notchTimers = true
    var notchStopwatch = true
    var notchFocus = true
    var notchMeeting = true
    var notchDictation = true
    var notchHoverExpand = true
    var notchHoverDelay: Double = 0.18
    var notchCollapseDelay: Double = 0.7
    /// Let the notch appear in screenshots, recordings and screen sharing.
    var notchInCaptures = false
    var notchOrder: [NotchKind] = [.media, .timer, .meeting, .focus, .stopwatch, .message]
    /// The closed notch's order for each mix of activities you've dragged into place.
    var notchArrangements: [String: [String]] = [:]

    /// The saved order, with any kinds added in later versions at the end.
    var notchPriority: [NotchKind] { notchOrder + NotchKind.allCases.filter { !notchOrder.contains($0) } }

    // Other
    var scanQR = true
    var rememberAppVolumes = true
    /// Empty = where you are.
    var weatherCity = ""
    var fahrenheit = false
    var homeCurrency = "JPY"
    var worldClocks = ["New York", "London", "Los Angeles"]
    var modelTools = ClaudeModel.haiku

    // AI: a service and model per job (Settings › AI). Unset jobs use Apple's on-device model.
    var aiTasks: [String: TaskModel] = [:]
    var aiProviders: [String: ProviderSettings] = [:]
    var clipboardKeyword = "clip"
    var switcherKeyword = "switch"
    var showMenuBarIcon = true
    var launchAtLogin = false

    // Apps
    var searchFolders = ["/Applications", "/System/Applications", "~/Applications", "/System/Library/CoreServices/Applications"]
    var excludedApps: [String] = []

    // Shortcuts: app path → words that bring that app to the top when typed ("ps, photo")
    var appKeywords: [String: String] = [:]

    // Dictation (Wispr Flow style)
    var dictationEnabled = true
    var dictationHotKey = HotKey.dictationDefault
    /// Hold Fn to dictate, Fn + Control to edit by voice (like Wispr Flow).
    var fnDictation = true
    /// Use the Mac's microphone when the default one is Bluetooth (AirPods drop to call quality and lose words).
    var builtInMicForBluetooth = true
    /// Silence the Mac's sound while dictating (never during a meeting recording).
    var muteWhileDictating = false
    var commandHotKey = HotKey.commandDefault
    var dictationLanguage = DictationLanguage.both
    /// Languages to listen for, any number (empty: the older two-way choice above).
    var dictationLocales: [String] = []
    var listenLocales: [String] { dictationLocales.isEmpty ? dictationLanguage.locales : dictationLocales }
    var aiCleanup = true
    var claudeModel = ClaudeModel.opus
    // A model per job (Settings › Claude): fast for dictation, careful for meeting notes, whatever you like.
    var modelDictation = ClaudeModel.opus
    var modelVoiceEdit = ClaudeModel.opus
    var modelMeetingChat = ClaudeModel.opus
    var modelMeetingNotes = ClaudeModel.opus
    var dictationStyle = DictationStyle.auto
    var livePreview = true
    var dictationSounds = true
    var saveDictations = true
    var dictionary: [String] = []
    var snippets: [Snippet] = []

    // Meetings
    var meetingLanguage = DictationLanguage.english
    var meetingSystemAudio = true
    /// The microphone meetings record ("" = the system's default).
    var meetingMicUID = ""
    var meetingSummary = true
    /// The floating meeting window with live help (opens when a meeting starts).
    var meetingOverlay = true
    var copilotHotKey = HotKey(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(cmdKey))
    /// Leave Halo's windows out of screen sharing and recordings.
    var hideFromScreenShare = true
    var meetingFolder = "~/Documents/MONEY Meetings"

    // Clipboard
    var clipboardEnabled = true
    var skipSecrets = true
    var clipboardLimit = 300
    var clipboardDays = 30
    var saveImages = true
    var pasteOnEnter = true
    var showPreview = true
    var ignoredApps = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess", "com.apple.Passwords", "com.bitwarden.desktop"]

}

@MainActor @Observable final class Store {
    static let shared = Store()
    private static let key = "settings"

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            save()
            onChange?(oldValue)
        }
    }

    @ObservationIgnored var onChange: ((Settings) -> Void)?

    private init() {
        settings = Store.load()
    }

    /// Decodes saved settings over the defaults, so keys added in later versions keep their defaults.
    private static func load() -> Settings {
        guard let saved = UserDefaults.standard.data(forKey: key),
              let savedDict = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
              let defaults = try? JSONEncoder().encode(Settings()),
              var merged = try? JSONSerialization.jsonObject(with: defaults) as? [String: Any] else { return Settings() }
        merged.merge(savedDict) { _, new in new }
        if savedDict["version"] == nil {
            // Settings from 1.0: the Apps tab now lists running apps until you type.
            merged["emptyState"] = EmptyState.running.rawValue
        }
        if ["~/Documents/Flick Meetings", "~/Documents/Halo Meetings"].contains(merged["meetingFolder"] as? String ?? "") {
            merged["meetingFolder"] = "~/Documents/MONEY Meetings"
        }
        if (savedDict["version"] as? Int ?? 1) < 3 {
            // Apps and Clipboard share one width so switching tabs doesn't jump sideways.
            if (merged["width"] as? Double) == 620 && (merged["clipboardWidth"] as? Double) == 780 {
                merged["width"] = 700.0
                merged["clipboardWidth"] = 700.0
            }
            merged["version"] = 3
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Store.key) }
    }

    func resetAppearance() {
        let d = Settings()
        var s = settings
        s.width = d.width; s.clipboardWidth = d.clipboardWidth; s.barHeight = d.barHeight; s.fontSize = d.fontSize
        s.cornerRadius = d.cornerRadius; s.scopedCornerRadius = d.scopedCornerRadius; s.rowHeight = d.rowHeight
        s.maxRows = d.maxRows; s.glass = d.glass; s.tintStrength = d.tintStrength; s.darkness = d.darkness; s.customTint = d.customTint
        s.tintHex = d.tintHex; s.appearance = d.appearance; s.shadeScopes = d.shadeScopes; s.showIcons = d.showIcons
        s.showHints = d.showHints; s.showTabs = d.showTabs; s.animations = d.animations
        settings = s
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let a = h.count == 8 ? CGFloat(v & 0xFF) / 255 : 1
        let rgb = h.count == 8 ? v >> 8 : v
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: a)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
