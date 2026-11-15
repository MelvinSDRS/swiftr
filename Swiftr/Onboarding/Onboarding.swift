import AppKit
import HerdrKit
import Observation

/// A folder the welcome sheet offers to open as a space.
struct ProjectFolder: Identifiable, Equatable {
    let path: String
    /// One of the person's agents worked there; else they added it.
    let suggested: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    /// With ~ for home, as a shell shows it.
    var shownPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

/// The welcome sheet's state: the step shown, whether herdr-core may be
/// installed, and the folders to open as spaces. The model holds it while
/// the sheet shows.
@Observable
final class Onboarding: Identifiable {
    enum Step: String {
        case welcome
        /// Only on a Mac that had no herdr-core.
        case core
        case projects
        case agents
        /// Dictation and voice models need Apple silicon.
        case dictation
        case voice
    }

    /// What the herdr-core step shows.
    enum CoreState: Equatable {
        case missing
        case installing
        case failed(String)
        case ready
    }

    /// False until the sheet ended once; absent on a Mac that ran Swiftr
    /// before the sheet existed.
    static let defaultsKey = "onboarded"

    let id = UUID()
    private(set) var step = Step.welcome
    /// The last move went forward: the next step slides in from the right.
    private(set) var forward = true
    /// This Mac has no herdr-core: the step that installs it shows, and
    /// stays once it's installed.
    var needsCore = false
    /// The person asked for herdr-core, which `AppModel` waits for.
    private(set) var installAllowed = false

    /// Folders to pick from: the suggested ones, then those added.
    private(set) var folders: [ProjectFolder] = []
    private(set) var picked: Set<String> = []
    /// Folders this sheet opened as spaces.
    private(set) var opened: Set<String> = []
    private(set) var opening = false
    /// Why the last folders didn't open.
    private(set) var problem: String?
    /// Each folder's logo, as its space will show it; `.none` once looked for.
    private(set) var logos: [String: FolderLogo] = [:]
    @ObservationIgnored private var suggestionsAsked = false

    #if DEBUG
    /// Tests: what the herdr-core step shows, whatever the link.
    var debugCore: CoreState?
    #endif

    /// Whether this launch opens the sheet: the first one, and later ones
    /// until the sheet ended.
    static func wanted(firstLaunch: Bool) -> Bool {
        let defaults = UserDefaults.standard
        #if DEBUG
        if ProcessInfo.processInfo.environment["SWIFTR_ONBOARDING"] == "1" { return true }
        #endif
        if let done = defaults.object(forKey: defaultsKey) as? Bool { return !done }
        // Someone who ran Swiftr before has set it up already.
        defaults.set(!firstLaunch, forKey: defaultsKey)
        return firstLaunch
    }

    var steps: [Step] {
        var steps: [Step] = [.welcome]
        if needsCore { steps.append(.core) }
        steps += [.projects, .agents]
        if SpeechModels.supported { steps += [.dictation, .voice] }
        return steps
    }

    var isLast: Bool { step == steps.last }

    func coreState(_ model: AppModel) -> CoreState {
        #if DEBUG
        if let debugCore { return debugCore }
        #endif
        switch model.link {
        case .missing: return .missing
        case .installing: return .installing
        case .installFailed(let why): return .failed(why)
        case .connecting, .connected, .failed: return .ready
        }
    }

    /// Folders picked and not open yet.
    var toOpen: [ProjectFolder] {
        folders.filter { picked.contains($0.path) && !opened.contains($0.path) }
    }

    // MARK: Steps

    /// The main button: what the step asks for, then the next step.
    func proceed(_ model: AppModel) {
        switch step {
        case .core:
            switch coreState(model) {
            case .missing: installAllowed = true
            case .failed:
                installAllowed = true
                model.retryNow()
            case .installing: break
            case .ready: advance(model)
            }
        case .projects:
            guard !toOpen.isEmpty else { return advance(model) }
            Task {
                await open(in: model)
                if problem == nil { advance(model) }
            }
        case .agents:
            // In its place: the step that sets notifications.
            model.alerts.askPermission()
            advance(model)
        case .welcome, .dictation, .voice:
            advance(model)
        }
    }

    private func advance(_ model: AppModel) {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else {
            model.endOnboarding()
            return
        }
        forward = true
        step = steps[i + 1]
    }

    func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        forward = false
        step = steps[i - 1]
    }

    func show(_ step: Step) {
        guard steps.contains(step), let from = steps.firstIndex(of: self.step), let to = steps.firstIndex(of: step) else { return }
        forward = to >= from
        self.step = step
    }

    // MARK: Projects

    /// Lists the folders the person's agents worked in lately, once.
    func suggest(_ model: AppModel) async {
        guard !suggestionsAsked else { return }
        suggestionsAsked = true
        let open = Set(model.spaces(on: "").map { $0.space.folder })
        let found = await Task.detached(priority: .userInitiated) { ProjectSuggestions.recent() }.value
        let known = Set(folders.map(\.path))
        folders.insert(contentsOf: found.filter { !open.contains($0) && !known.contains($0) }.map { ProjectFolder(path: $0, suggested: true) }, at: 0)
        for folder in folders { findLogo(folder.path) }
    }

    /// Folders from the open panel or dropped on the list: added, picked.
    func add(_ paths: [String]) {
        for raw in paths {
            let path = URL(filePath: raw).standardizedFileURL.path
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            if !folders.contains(where: { $0.path == path }) {
                folders.append(ProjectFolder(path: path, suggested: false))
                findLogo(path)
            }
            picked.insert(path)
        }
        problem = nil
    }

    func toggle(_ folder: ProjectFolder) {
        guard !opened.contains(folder.path), !opening else { return }
        if picked.contains(folder.path) { picked.remove(folder.path) } else { picked.insert(folder.path) }
        problem = nil
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose your projects' folders"
        guard panel.runModal() == .OK else { return }
        add(panel.urls.map(\.path))
    }

    private func findLogo(_ path: String) {
        guard logos[path] == nil else { return }
        Task {
            let found = await Task.detached(priority: .utility) { await ProjectLogo.find(in: path) }.value
            if let found, let image = NSImage(data: found.png) {
                logos[path] = .image(image, file: found.file)
            } else {
                logos[path] = FolderLogo.none
            }
        }
    }

    /// What a folder's space will show in the sidebar: its logo, else its
    /// first letter.
    func look(of folder: ProjectFolder) -> SpaceLook {
        if case .image(let image, _)? = logos[folder.path] { return .image(image) }
        guard let first = folder.name.first(where: { $0.isLetter || $0.isNumber }) else { return .symbol(SpaceIcons.standard) }
        return .letter(String(first).uppercased(), hash: ProjectLogo.hash(of: folder.name))
    }

    /// Opens each picked folder as a space, then shows the first.
    private func open(in model: AppModel) async {
        opening = true
        problem = nil
        defer { opening = false }
        let wanted = toOpen
        do {
            for folder in wanted {
                try await model.addSpace(on: "", folder: folder.path, at: nil)
                opened.insert(folder.path)
            }
        } catch {
            problem = (error as? CoreError)?.message ?? error.localizedDescription
        }
        if let first = wanted.first(where: { opened.contains($0.path) }),
           let space = model.spaces(on: "").last(where: { $0.space.folder == first.path })
        {
            model.select(space: space)
        }
    }

    #if DEBUG
    func debugSummary(_ model: AppModel) -> [String: Any] {
        ["step": step.rawValue, "steps": steps.map(\.rawValue), "needsCore": needsCore, "installAllowed": installAllowed,
         "core": "\(coreState(model))", "folders": folders.map(\.path), "picked": picked.sorted(), "opened": opened.sorted(),
         "opening": opening, "problem": problem ?? "", "asked": suggestionsAsked, "logos": logos.compactMap { if case .image = $0.value { $0.key } else { nil } }.sorted()]
    }
    #endif
}

/// Folders the person's agents worked in lately, to offer as spaces:
/// those Claude Code and Codex keep in their own settings.
nonisolated enum ProjectSuggestions {
    /// The latest first, at most `limit`. It reads the disk: call it off
    /// the main thread.
    static func recent(limit: Int = 6, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       claude: [URL] = ClaudeWatch.configFolders,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var paths: Set<String> = []
        // Claude Code: the folders in .claude.json, beside each of its
        // configuration folders or in it.
        for file in [home.appending(path: ".claude.json")] + claude.map({ $0.appending(path: ".claude.json") }) {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let projects = json["projects"] as? [String: Any]
            else { continue }
            paths.formUnion(projects.keys)
        }
        // Codex: the folders it trusts, `[projects."/path"]` in config.toml.
        let codex = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) } ?? home.appending(path: ".codex")
        if let text = try? String(contentsOf: codex.appending(path: "config.toml"), encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let line = line.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("[projects.\""), line.hasSuffix("\"]") else { continue }
                paths.insert(String(line.dropFirst(11).dropLast(2)))
            }
        }
        // The latest first: by Claude Code's last new conversation there,
        // or git's last change.
        let dated = paths.filter { isProject($0, home: home.path) }.map { path -> (path: String, date: Date) in
            let name = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            let dates = claude.map { modified($0.appending(path: "projects").appending(path: name).path) } + [modified(path + "/.git/index")]
            return (path, dates.compactMap { $0 }.max() ?? .distantPast)
        }
        return dated.sorted { $0.date != $1.date ? $0.date > $1.date : $0.path < $1.path }.prefix(limit).map(\.path)
    }

    /// A folder that's still there and is a project of the person's: a
    /// git repository, not home, and not in a temporary or hidden place
    /// (agents' own worktrees and scratch folders live in those).
    static func isProject(_ path: String, home: String) -> Bool {
        guard path.hasPrefix("/"), path != home, !home.hasPrefix(path + "/") else { return false }
        let parts = path.split(separator: "/")
        guard let first = parts.first, !["tmp", "private", "var", "Volumes"].contains(String(first)) else { return false }
        guard !parts.contains(where: { $0.hasPrefix(".") }) else { return false }
        return FileManager.default.fileExists(atPath: path + "/.git")
    }

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
