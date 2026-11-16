import AppKit
import Observation
import SwiftUI

/// A terminal color scheme, in herdr-app's theme format.
nonisolated struct TerminalTheme: Codable, Equatable, Sendable {
    var background: String
    var foreground: String
    var selection: String?
    var cursor: String?
    var ansi: [String]
    /// What Messages fills the Send button with; without it, the Mac's
    /// accent color.
    var accent: String? = nil

    static let catppuccinMocha = TerminalTheme(
        background: "#1e1e2e", foreground: "#cdd6f4", selection: "#585b70", cursor: "#f5e0dc",
        ansi: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
               "#585b70", "#f7aec2", "#c2ecbf", "#fcd682", "#aeccfc", "#f398da", "#b1eae1", "#a6adc8"]
    )

    /// Swiftr's own theme in dark: herdr's Graphite, as herdr-app and Herdr for
    /// iOS draw it.
    static let graphite = TerminalTheme(
        background: "#17191d", foreground: "#d2d4d9", selection: "#394454", cursor: "#d2d4d9",
        ansi: ["#45484f", "#dc8c95", "#a6bd91", "#d8be87", "#96b2d7", "#b5a2ce", "#8cbdc3", "#d2d4d9",
               "#818793", "#f0a5ad", "#bad5a2", "#ead2a1", "#b0cbef", "#cbb7e6", "#a4d5db", "#f0f0f2"],
        accent: "#96b2d7"
    )

    /// Swiftr's own theme in light: herdr's Paper.
    static let paper = TerminalTheme(
        background: "#ffffff", foreground: "#25272c", selection: "#cfdcf5", cursor: "#25272c",
        ansi: ["#25272c", "#c62a2a", "#1a7f37", "#8f5d00", "#1f62d0", "#7a45c8", "#0f6f74", "#5f6068",
               "#7b7e87", "#d1242f", "#1f883d", "#9a6700", "#0969da", "#8250df", "#1b7c83", "#111214"],
        accent: "#1f62d0"
    )

    /// Swiftr's theme for a light or dark app.
    static func swiftr(dark: Bool) -> TerminalTheme { dark ? graphite : paper }

    var backgroundColor: NSColor { NSColor(hex: background) ?? .black }
    var foregroundColor: NSColor { NSColor(hex: foreground) ?? .white }
    var cursorColor: NSColor { cursor.flatMap { NSColor(hex: $0) } ?? foregroundColor }
    var selectionColor: NSColor { selection.flatMap { NSColor(hex: $0) } ?? NSColor.selectedTextBackgroundColor }
    var accentColor: NSColor? { accent.flatMap { NSColor(hex: $0) } }

    /// Whether text on this background should be light.
    var isDark: Bool {
        guard let c = RGB(hex: background) else { return true }
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b < 0.5
    }
}

/// A color as three components from 0 to 1.
nonisolated struct RGB: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xff) / 255
        g = Double((v >> 8) & 0xff) / 255
        b = Double(v & 0xff) / 255
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        r = Double(c.redComponent)
        g = Double(c.greenComponent)
        b = Double(c.blueComponent)
    }

    var hex: String {
        String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

extension NSColor {
    nonisolated convenience init?(hex: String) {
        guard let c = RGB(hex: hex) else { return nil }
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

/// What Option does in a terminal.
enum OptionKey: String, CaseIterable, Identifiable {
    /// The keyboard layout's characters, Meta on keys that type nothing
    /// (arrows, Return, Backspace): like Ghostty and iTerm2's "Normal".
    case auto
    /// Meta on every key.
    case meta
    /// Always the keyboard layout's characters.
    case characters

    var id: String { rawValue }
}

/// How long an idle agent out of sight stays awake before Swiftr puts it to sleep.
enum SleepAfter: Int, CaseIterable, Identifiable {
    case never = 0
    case oneHour = 1
    case twoHours = 2
    case fourHours = 4
    case eightHours = 8
    case oneDay = 24

    var id: Int { rawValue }
    var seconds: TimeInterval { Double(rawValue) * 3600 }

    var title: String {
        switch self {
        case .never: "Never"
        case .oneHour: "After 1 hour"
        case .oneDay: "After 1 day"
        default: "After \(rawValue) hours"
        }
    }
}

/// Where the sidebar lists the agents: under the machines or above them.
enum AgentsPlace: String, CaseIterable, Identifiable {
    case bottom
    case top

    var id: String { rawValue }
}

/// Which look of the app icon the Dock shows while Swiftr runs.
enum AppIconStyle: String, CaseIterable, Identifiable {
    /// The system's own icon, light or dark with the Mac's appearance.
    case automatic
    /// The light and dark looks of AppIcon.icon, drawn as macOS draws app
    /// icons (AppIconLooks.xcassets).
    case light
    case dark

    static let defaultsKey = "appIcon"

    var id: String { rawValue }

    static var saved: AppIconStyle {
        AppIconStyle(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
    }

    /// Shows this look in the Dock and the app switcher. It lasts while Swiftr
    /// runs: the Finder, and a Dock tile kept after quitting, show the system's.
    func apply() {
        NSApp.applicationIconImage = switch self {
        case .automatic: nil
        case .light: NSImage(named: "AppIconLight")
        case .dark: NSImage(named: "AppIconDark")
        }
    }
}

/// Light or dark for every Swiftr window: the Mac's, or one of them always.
/// Swiftr's theme follows it.
enum Appearance: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    static let defaultsKey = "appearance"

    var id: String { rawValue }

    static var saved: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
    }

    func apply() {
        NSApp.appearance = switch self {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Whether windows will be dark, before AppKit can be asked.
    var expectsDark: Bool {
        switch self {
        case .automatic: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        case .light: false
        case .dark: true
        }
    }
}

/// Swiftr's own settings. Themes are read once from herdr-app on first launch
/// and then belong to Swiftr.
@Observable
final class Preferences {
    static let defaultFontSize = 13.0
    /// The terminal font until another is picked; it ships inside the app.
    static let defaultFontName = "JetBrains Mono"
    /// The built-in theme: herdr's colors, light or dark with the app.
    static let swiftrThemeName = "swiftr"

    var fontName: String { didSet { defaults.set(fontName, forKey: "fontName") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    var themeName: String { didSet { defaults.set(themeName, forKey: "themeName") } }
    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Appearance.defaultsKey)
            appearance.apply()
        }
    }
    /// Whether the app is dark now (under Automatic, as macOS is).
    private(set) var looksDark: Bool
    var optionKey: OptionKey { didSet { defaults.set(optionKey.rawValue, forKey: "optionKey") } }
    var blinkCursor: Bool { didSet { defaults.set(blinkCursor, forKey: "blinkCursor") } }
    var scrollback: Int { didSet { defaults.set(scrollback, forKey: "scrollback") } }
    /// Idle agents out of sight go to sleep after this long (`AgentSleep`).
    var sleepAfter: SleepAfter { didSet { defaults.set(sleepAfter.rawValue, forKey: "sleepAfter") } }
    /// Notifications when an agent needs you or finished.
    var agentNotifications: Bool { didSet { defaults.set(agentNotifications, forKey: "agentNotifications") } }
    /// Sound names (macOS sounds, or one in ~/Library/Sounds); "" for none.
    var needsYouSound: String { didSet { defaults.set(needsYouSound, forKey: "needsYouSound") } }
    var finishedSound: String { didSet { defaults.set(finishedSound, forKey: "finishedSound") } }
    /// How each agent's panes show unless chosen pane by pane.
    var claudePanes: PaneMode { didSet { defaults.set(claudePanes.rawValue, forKey: "claudePanes") } }
    var codexPanes: PaneMode { didSet { defaults.set(codexPanes.rawValue, forKey: "codexPanes") } }
    var opencodePanes: PaneMode { didSet { defaults.set(opencodePanes.rawValue, forKey: "opencodePanes") } }
    var geminiPanes: PaneMode { didSet { defaults.set(geminiPanes.rawValue, forKey: "geminiPanes") } }
    /// The usage under each agent's field, by `ChatAgent` raw value.
    private var usageByAgent: [String: UsageSettings] {
        didSet { defaults.set(usageByAgent.mapValues(\.plist), forKey: "agentUsage") }
    }
    /// Each agent's status line under the Messages field, by `ChatAgent` raw value.
    private var statusLineByAgent: [String: Bool] {
        didSet { defaults.set(statusLineByAgent, forKey: "agentStatusLine") }
    }
    var agentsPlace: AgentsPlace { didSet { defaults.set(agentsPlace.rawValue, forKey: "agentsPlace") } }
    /// The tab bar above the panes. Without it, the sidebar lists the tabs.
    var showsTabBar: Bool { didSet { defaults.set(showsTabBar, forKey: "showsTabBar") } }
    /// Ask before closing a tab where a program still runs. The prompt's
    /// "Don't ask again" box turns it off.
    var confirmsTabClose: Bool { didSet { defaults.set(confirmsTabClose, forKey: "confirmsTabClose") } }
    var appIcon: AppIconStyle {
        didSet {
            defaults.set(appIcon.rawValue, forKey: AppIconStyle.defaultsKey)
            appIcon.apply()
        }
    }
    /// Agents with a button beside the tabs' +, by `Programs` key, in the
    /// order starred; the first starts with ⌥⌘T.
    private(set) var favoriteAgents: [String] { didSet { defaults.set(favoriteAgents, forKey: "favoriteAgents") } }
    /// How many times each agent was started: the + menu lists the most
    /// picked first, as herdr-app's does.
    private(set) var agentPicks: [String: Int] { didSet { defaults.set(agentPicks, forKey: "agentPicks") } }
    private(set) var themes: [String: TerminalTheme] = [:]

    /// Swiftr never ran on this Mac before this launch.
    @ObservationIgnored let isFirstLaunch: Bool
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var appearanceWatch: NSKeyValueObservation?

    init() {
        // Every launch so far wrote this key (`importFromHerdrOnce`).
        isFirstLaunch = UserDefaults.standard.object(forKey: "importedHerdrTheme") == nil
        fontName = defaults.string(forKey: "fontName") ?? Self.defaultFontName
        let size = defaults.double(forKey: "fontSize")
        fontSize = size >= 6 ? size : Self.defaultFontSize
        themeName = defaults.string(forKey: "themeName") ?? Self.swiftrThemeName
        let appearance = Appearance.saved
        self.appearance = appearance
        looksDark = appearance.expectsDark
        optionKey = OptionKey(rawValue: defaults.string(forKey: "optionKey") ?? "") ?? .auto
        blinkCursor = defaults.bool(forKey: "blinkCursor")
        let lines = defaults.integer(forKey: "scrollback")
        scrollback = lines > 0 ? lines : 10_000
        agentNotifications = defaults.object(forKey: "agentNotifications") as? Bool ?? true
        sleepAfter = SleepAfter(rawValue: defaults.integer(forKey: "sleepAfter")) ?? .never
        needsYouSound = defaults.string(forKey: "needsYouSound") ?? "Funk"
        finishedSound = defaults.string(forKey: "finishedSound") ?? "Glass"
        // On a new Mac agents open as Messages, which the welcome sheet shows
        // chosen; someone who ran Swiftr before keeps Terminal.
        if isFirstLaunch, defaults.object(forKey: "claudePanes") == nil {
            defaults.set(PaneMode.messages.rawValue, forKey: "claudePanes")
        }
        let claude = PaneMode(rawValue: defaults.string(forKey: "claudePanes") ?? "") ?? .terminal
        claudePanes = claude
        // The other agents had Claude's setting until they had their own.
        func panes(_ key: String) -> PaneMode {
            let defaults = UserDefaults.standard
            if let mode = PaneMode(rawValue: defaults.string(forKey: key) ?? "") { return mode }
            defaults.set(claude.rawValue, forKey: key)
            return claude
        }
        codexPanes = panes("codexPanes")
        opencodePanes = panes("opencodePanes")
        geminiPanes = panes("geminiPanes")
        let saved = defaults.dictionary(forKey: "agentUsage") as? [String: [String: Any]] ?? [:]
        usageByAgent = Dictionary(uniqueKeysWithValues: ChatAgent.allCases.map { agent in
            (agent.rawValue, saved[agent.rawValue].map { UsageSettings(plist: $0, agent: agent) } ?? UsageSettings())
        })
        // One switch for every agent until each had its own.
        let statusLine = defaults.object(forKey: "messagesShowStatusLine") as? Bool ?? true
        let ownLines = defaults.dictionary(forKey: "agentStatusLine") as? [String: Bool] ?? [:]
        statusLineByAgent = Dictionary(uniqueKeysWithValues: ChatAgent.allCases.map { ($0.rawValue, ownLines[$0.rawValue] ?? statusLine) })
        agentsPlace = AgentsPlace(rawValue: defaults.string(forKey: "agentsPlace") ?? "") ?? .bottom
        showsTabBar = defaults.object(forKey: "showsTabBar") as? Bool ?? true
        confirmsTabClose = defaults.object(forKey: "confirmsTabClose") as? Bool ?? true
        appIcon = .saved
        favoriteAgents = defaults.stringArray(forKey: "favoriteAgents") ?? []
        agentPicks = defaults.dictionary(forKey: "agentPicks") as? [String: Int] ?? [:]
        importFromHerdrOnce()
        showSwiftrThemeOnce()
        loadThemes()
        // Once the app runs: NSApp may not be there yet.
        Task { [weak self] in self?.followAppearance() }
    }

    var theme: TerminalTheme {
        if themeName != Self.swiftrThemeName, let theme = themes[themeName] { return theme }
        return .swiftr(dark: looksDark)
    }

    /// The other themes: herdr-app's, and those in the themes folder.
    var themeNames: [String] {
        themes.keys.filter { $0 != Self.swiftrThemeName }.sorted()
    }

    /// Follows the app's light or dark, which macOS changes under Automatic.
    private func followAppearance() {
        appearanceWatch = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.looksDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }
        }
    }

    /// The terminal font: the chosen one, JetBrains Mono at first.
    var font: NSFont { Self.font(family: fontName, size: fontSize) }

    /// A family at a size, as terminals and code in Messages use it: SF Mono
    /// for "" or a font the Mac doesn't have.
    static func font(family: String, size: Double) -> NSFont {
        let size = CGFloat(size)
        if !family.isEmpty,
           let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? NSFont(name: family, size: size)
        {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func zoom(by step: Double) {
        fontSize = min(48, max(7, fontSize + step))
    }

    func resetZoom() {
        fontSize = Self.defaultFontSize
    }

    // MARK: Agents

    /// How `agent`'s panes show unless chosen pane by pane.
    func panes(of agent: ChatAgent) -> PaneMode {
        switch agent {
        case .claude: claudePanes
        case .codex: codexPanes
        case .opencode: opencodePanes
        case .gemini: geminiPanes
        }
    }

    func setPanes(_ mode: PaneMode, of agent: ChatAgent) {
        switch agent {
        case .claude: claudePanes = mode
        case .codex: codexPanes = mode
        case .opencode: opencodePanes = mode
        case .gemini: geminiPanes = mode
        }
    }

    func usage(of agent: ChatAgent) -> UsageSettings {
        usageByAgent[agent.rawValue] ?? UsageSettings()
    }

    func setUsage(_ settings: UsageSettings, of agent: ChatAgent) {
        usageByAgent[agent.rawValue] = settings
    }

    /// The agent's status line shows under the Messages field.
    func showsStatusLine(of agent: ChatAgent) -> Bool {
        statusLineByAgent[agent.rawValue] ?? true
    }

    func setShowsStatusLine(_ shown: Bool, of agent: ChatAgent) {
        statusLineByAgent[agent.rawValue] = shown
    }

    func isFavorite(agent key: String) -> Bool {
        favoriteAgents.contains(key)
    }

    /// Stars an agent, last of the favorites, or takes its star away.
    func setFavorite(_ favorite: Bool, agent key: String) {
        if favorite, !favoriteAgents.contains(key) { favoriteAgents.append(key) }
        if !favorite { favoriteAgents.removeAll { $0 == key } }
    }

    /// Moves a favorite one place left (-1) or right (1).
    func moveFavorite(_ key: String, by step: Int) {
        guard let i = favoriteAgents.firstIndex(of: key), favoriteAgents.indices.contains(i + step) else { return }
        favoriteAgents.swapAt(i, i + step)
    }

    func picked(agent key: String) {
        agentPicks[key, default: 0] += 1
    }

    /// Sounds a person can pick: macOS's, then their own.
    static var soundNames: [String] {
        let fm = FileManager.default
        var names: Set<String> = []
        let folders = [URL(filePath: "/System/Library/Sounds"), URL(filePath: "/Library/Sounds"),
                       fm.homeDirectoryForCurrentUser.appending(path: "Library/Sounds")]
        for folder in folders {
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                where ["aiff", "aif", "wav", "caf", "mp3", "m4a"].contains(file.pathExtension.lowercased())
            {
                names.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        return names.sorted()
    }

    // MARK: Themes

    static var themesFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Swiftr").appending(path: "themes")
    }

    private static var herdrFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/herdr-app")
    }

    func loadThemes() {
        var found: [String: TerminalTheme] = ["catppuccin-mocha": .catppuccinMocha]
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.themesFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let theme = try? JSONDecoder().decode(TerminalTheme.self, from: data), theme.ansi.count >= 16 {
                found[file.deletingPathExtension().lastPathComponent] = theme
            }
        }
        themes = found
    }

    /// Copies herdr-app's themes once, to pick from: Swiftr starts with its own.
    private func importFromHerdrOnce() {
        guard !defaults.bool(forKey: "importedHerdrTheme") else { return }
        defaults.set(true, forKey: "importedHerdrTheme")
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.themesFolder, withIntermediateDirectories: true)
        let source = Self.herdrFolder.appending(path: "themes")
        for file in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            let target = Self.themesFolder.appending(path: file.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: file, to: target) }
        }
    }

    /// Swiftr's theme came after herdr-app's chosen one was copied: it takes
    /// that one's place once. Settings › Appearance gives it back.
    private func showSwiftrThemeOnce() {
        guard !defaults.bool(forKey: "showedSwiftrTheme") else { return }
        defaults.set(true, forKey: "showedSwiftrTheme")
        themeName = Self.swiftrThemeName
    }
}
