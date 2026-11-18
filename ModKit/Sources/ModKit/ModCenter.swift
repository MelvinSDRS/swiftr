import AppKit
import Foundation
import JavaScriptCore

/// Every mod of this app: where they live, the data they read, what they
/// share.
///
/// The home is laid out like herdr-app's (`~/.config/herdr-app`), so a mod
/// or a layout made for it drops in:
///
///     mods/<name>/main.js, mod.json, *.svg     the mods
///     layouts/<name>.json                      the layouts
///     themes/<name>.json                       the themes
///     shared.json, data/                       the mods' own state
public final class ModCenter {
    /// `~/.config/swiftr`, or a test's folder.
    public let home: URL
    public let userHome: String
    public weak var host: ModHost?
    /// Where `svg("mods/files/chevron-down.svg")` is looked for: this home,
    /// then herdr-app's, whose shipped mods other mods borrow icons from.
    public var assetRoots: [URL]
    /// What a mod not asked about may do: everything in checks and tests,
    /// nothing in the app, where the person agrees mod by mod.
    public var defaultGrant: ModCapabilities = []
    /// What each mod was given when it was added.
    public var grants: [String: ModCapabilities] = [:]

    /// The theme's text color: what a mod's text is drawn in where it sets none.
    public private(set) var foreground: NSColor?
    /// The theme's color behind selected text.
    public private(set) var selection: NSColor?

    let machine = JSVirtualMachine()!
    private var runtimes: [String: ModRuntime] = [:]
    private(set) var dataSnapshot: [String: String] = [:]
    private var shared: [String: Any] = [:]
    private var sharedSave: DispatchWorkItem?
    private var watches: [String: FolderWatch] = [:]
    /// Called when a mod's files changed and its script was loaded again:
    /// its views start over.
    public var onReload: ((String) -> Void)?

    /// Seconds one call into a script may take before it is cut.
    public var scriptTimeLimit: Double = 3

    /// Checks and tests: files outside these folders read as absent, and
    /// nothing is written outside them. Nil in the app.
    public var jail: [String]?

    func inJail(_ path: String) -> Bool {
        guard let jail else { return true }
        let real = ModFiles.canonical(path)
        return jail.contains { root in
            let folder = ModFiles.canonical(root)
            return real == folder || real.hasPrefix(folder + "/")
        }
    }

    public init(home: URL, host: ModHost? = nil, userHome: String? = nil) {
        self.home = home
        self.host = host
        let person = userHome ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.userHome = person
        assetRoots = [home, URL(fileURLWithPath: person).appending(path: ".config/herdr-app")]
        if let data = try? Data(contentsOf: home.appending(path: "shared.json")),
           let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            shared = stored
        }
        dataSnapshot["home"] = ModJSON.text(userHome)
        dataSnapshot["appHome"] = ModJSON.text(home.path)
        // Not `ProcessInfo.hostName`: that asks the network and can hold
        // the app's start for many seconds.
        var name = [CChar](repeating: 0, count: 256)
        gethostname(&name, 255)
        dataSnapshot["hostname"] = ModJSON.text(String(cString: name))
        dataSnapshot["shared"] = ModJSON.text(shared)
    }

    public var modsFolder: URL { home.appending(path: "mods") }

    /// The mods in the home, by name.
    public func installed() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: modsFolder.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: modsFolder.appending(path: "\($0)/main.js").path) }.sorted()
    }

    /// The mod, its script loaded on first use.
    public func runtime(for name: String) throws -> ModRuntime {
        if let runtime = runtimes[name] { return runtime }
        let folder = modsFolder.appending(path: name)
        let runtime = try ModRuntime(name: name, folder: folder, center: self, granted: grants[name] ?? defaultGrant)
        runtimes[name] = runtime
        return runtime
    }

    public func loaded(_ name: String) -> ModRuntime? { runtimes[name] }

    /// Whether any mod's script is loaded: the app has nothing to tell
    /// mods otherwise.
    public var isRunning: Bool { !runtimes.isEmpty }

    /// A mod from a folder that isn't in the home: for a look before it is
    /// added.
    public func runtime(folder: URL, granted: ModCapabilities) throws -> ModRuntime {
        let name = folder.lastPathComponent
        if let runtime = runtimes[name] { return runtime }
        let runtime = try ModRuntime(name: name, folder: folder, center: self, granted: granted)
        runtimes[name] = runtime
        return runtime
    }

    /// Loads the mod's files again. Its views start over (`onReload`).
    public func reload(_ name: String) {
        runtimes.removeValue(forKey: name)?.shutDown()
        onReload?(name)
    }

    public func setGrant(_ grant: ModCapabilities, for name: String) {
        grants[name] = grant
        runtimes[name]?.granted = grant
    }

    // MARK: Live data

    /// One of the lists a mod reads (`spaces`, `agents`, `panes`,
    /// `terminals`, `focused`, `machines`, `layout`, `layouts`, `window`,
    /// `theme`, `themes`, `settings`, `keys`, `commands`, `fonts`): every
    /// mod draws again when it changes.
    public func setData(_ key: String, _ value: Any) {
        let json = ModJSON.text(value)
        guard dataSnapshot[key] != json else { return }
        dataSnapshot[key] = json
        if key == "theme" {
            let theme = value as? [String: Any]
            foreground = (theme?["foreground"] as? String).flatMap(ModColor.parse)
            selection = (theme?["selection"] as? String).flatMap(ModColor.parse)
        }
        changes[key, default: 0] += 1
        for runtime in runtimes.values where runtime.setData(key, json: json) {
            runtime.invalidateAll()
        }
    }

    /// How many times each list changed: to find one that changes for nothing.
    public private(set) var changes: [String: Int] = [:]

    // MARK: State mods share

    public func sharedValue(_ key: String) -> Any? { shared[key] }

    /// `setShared(key, value)`: every mod sees it, and draws again.
    public func setShared(_ key: String, _ value: Any?, from source: ModRuntime? = nil) {
        if let value, !(value is NSNull) { shared[key] = value } else { shared.removeValue(forKey: key) }
        let json = ModJSON.text(shared)
        dataSnapshot["shared"] = json
        for runtime in runtimes.values {
            // The mod that set it already holds the value.
            if runtime !== source { runtime.setData("shared", json: json) }
            runtime.invalidateAll()
        }
        // Saved a moment later, the latest change winning.
        sharedSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveShared() }
        sharedSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func saveShared() {
        guard let data = try? JSONSerialization.data(withJSONObject: shared, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? data.write(to: home.appending(path: "shared.json"), options: .atomic)
    }

    /// Writes what waits to be saved. Before quitting.
    public func flush() {
        if let work = sharedSave, !work.isCancelled {
            work.cancel()
            sharedSave = nil
            saveShared()
        }
    }

    private func storageFile(mod: String, slot: String) -> URL {
        let safe = slot.isEmpty ? "storage" : slot.replacingOccurrences(of: "/", with: "_")
        return home.appending(path: "data/\(mod)/\(safe).json")
    }

    func storage(mod: String, slot: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: storageFile(mod: mod, slot: slot)),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return stored
    }

    func setStorage(_ all: [String: Any], mod: String, slot: String) {
        let file = storageFile(mod: mod, slot: slot)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: Commands for mods

    /// `<mod>.<command>` (a key, or another mod's `run`): to that mod's shown
    /// copies. False when the name isn't a loaded mod's.
    @discardableResult
    public func deliver(command: String) -> Bool {
        guard let dot = command.firstIndex(of: ".") else { return false }
        guard let runtime = runtimes[String(command[..<dot])] else { return false }
        _ = runtime.deliver(command: String(command[command.index(after: dot)...]))
        return true
    }

    // MARK: Files

    /// A mod's picture, from its path in the home (`mods/vault/vault.svg`).
    public func asset(_ path: String) -> URL? {
        if path.hasPrefix("/") { return inJail(path) && FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil }
        guard !path.split(separator: "/").contains("..") else { return nil }
        for root in assetRoots {
            let url = root.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path), inJail(url.path) { return url }
        }
        return nil
    }

    /// `watchFolder(path)`: answers once, the next time something under the
    /// folder changes.
    func watch(_ path: String, _ answer: @escaping ([String]) -> Void) {
        let key = (path as NSString).standardizingPath
        let watch = watches[key] ?? {
            let made = FolderWatch(path: key)
            watches[key] = made
            return made
        }()
        watch.waiters.append(answer)
    }

    /// Watches the mods folder: a saved file loads its mod again.
    public func watchMods() {
        try? FileManager.default.createDirectory(at: modsFolder, withIntermediateDirectories: true)
        // The real path: the one changes are reported under.
        let root = ModFiles.canonical(modsFolder.path)
        let watch = FolderWatch(path: root)
        watches["\u{0}mods"] = watch
        func arm() {
            watch.waiters.append { [weak self] paths in
                guard let self else { return }
                var names = Set<String>()
                for path in paths where path.hasPrefix(root + "/") {
                    let rest = path.dropFirst(root.count + 1)
                    guard let name = rest.split(separator: "/").first else { continue }
                    let file = (path as NSString).lastPathComponent
                    // The mod's code and its manifest, not what the mod or
                    // an editor writes beside them: a mod that saved a file
                    // in its own folder would start over without end.
                    guard file.hasSuffix(".js") || file.hasSuffix(".mjs") || file == "mod.json" else { continue }
                    if file.hasPrefix(".") || path.contains("/node_modules/") { continue }
                    names.insert(String(name))
                }
                // A mod that isn't running is read again too: what it asks
                // for may have changed.
                for name in names {
                    if self.runtimes[name] != nil { self.reload(name) } else { self.onReload?(name) }
                }
                arm()
            }
        }
        arm()
    }
}

/// Changes under a folder, in batches.
final class FolderWatch {
    var waiters: [([String]) -> Void] = []
    private var stream: FSEventStreamRef?
    private var pending: Set<String> = []

    init(path: String) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { watch.changed(Array(list.prefix(count))) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    private func changed(_ paths: [String]) {
        pending.formUnion(paths)
        guard !waiters.isEmpty else {
            // Bounded while nobody waits: past that, "everything changed".
            if pending.count > 512 { pending = [] }
            return
        }
        let batch = Array(pending).sorted()
        pending = []
        let answer = waiters
        waiters = []
        for waiter in answer { waiter(batch) }
    }

    isolated deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
