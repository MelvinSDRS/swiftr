import AppKit
import HerdrKit
import Observation
import Sparkle

/// Swiftr's own updates. A release carries a feed of the latest version
/// (`SUFeedURL`, set by scripts/release.sh): Sparkle reads it, and installs
/// the new version, unless Homebrew installed this copy; then `brew upgrade`
/// does, so that Homebrew still knows what it has. A copy built from source
/// has no feed and updates with the source.
@Observable
final class AppUpdate: NSObject, SPUUpdaterDelegate {
    /// How this copy of Swiftr gets a newer one.
    enum Way: Equatable {
        case sparkle
        case homebrew(HomebrewCask)
        /// Built from source.
        case source
    }

    enum Step: Equatable {
        /// brew is at work.
        case updating
        /// The new version is in place: Swiftr quits and opens it.
        case restarting
        case failed(String)
    }

    let way: Way
    /// The newer version out, from the last check.
    private(set) var latest: String?
    private(set) var checking = false
    private(set) var checkError: String?
    /// Why this Mac can't take the latest version, when it can't.
    private(set) var blocked: String?
    private(set) var step: Step?

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var driver: SPUStandardUserDriver?
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []

    /// "0.1.1", as About shows it.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    override init() {
        let feed = Self.feed
        if feed == nil {
            way = .source
        } else if let cask = HomebrewCask.owning(app: Bundle.main.bundleURL, token: "swiftr", prefixes: Self.brewPrefixes) {
            way = .homebrew(cask)
        } else {
            way = .sparkle
        }
        super.init()
    }

    /// Starts Sparkle, once the app runs. It reads the feed for a Homebrew
    /// copy too; only brew installs there.
    func start() {
        guard way != .source, updater == nil else { return }
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
            self.driver = driver
            self.updater = updater
        } catch {
            checkError = error.localizedDescription
        }
    }

    /// Whether a newer version can go in from here.
    var canInstall: Bool {
        latest != nil && blocked == nil && step != .updating && step != .restarting
    }

    // MARK: Checking

    /// Reads the feed, without a window. Returns once the answer is in.
    func check() async {
        guard let updater else { return }
        // A window of Sparkle's is up (an update on offer or on its way): it stays.
        guard !updater.sessionInProgress else { return }
        if !checking {
            checking = true
            updater.checkForUpdateInformation()
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feed
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        latest = item.displayVersionString
        blocked = nil
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        latest = nil
        blocked = nil
        // A release this Mac can't run is still worth a word.
        let info = (error as NSError).userInfo
        guard let item = info[SPULatestAppcastItemFoundKey] as? SUAppcastItem,
              let reason = (info[SPUNoUpdateFoundReasonKey] as? NSNumber).flatMap({ SPUNoUpdateFoundReason(rawValue: OSStatus($0.int32Value)) }) else { return }
        switch reason {
        case .systemIsTooOld:
            latest = item.displayVersionString
            blocked = "Swiftr \(item.displayVersionString) needs macOS \(item.minimumSystemVersion ?? "newer than this Mac's")."
        case .systemIsTooNew:
            latest = item.displayVersionString
            blocked = "Swiftr \(item.displayVersionString) doesn't run on this macOS."
        default:
            break
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if updateCheck == .updateInformation {
            let failure = error.map { $0 as NSError }.flatMap { $0.domain == SUSparkleErrorDomain && $0.code == Int(SUError.noUpdateError.rawValue) ? nil : $0 }
            checkError = failure?.localizedDescription
        }
        checking = false
        let waiting = waiting
        self.waiting = []
        for one in waiting { one.resume() }
    }

    // MARK: Updating

    /// Installs the newer version: Sparkle shows it and asks; brew upgrades
    /// at once. Swiftr then opens again; terminals keep running in herdr-core.
    func install() {
        switch way {
        case .source:
            return
        case .sparkle:
            guard let updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdates()
        case .homebrew(let cask):
            guard step != .updating, step != .restarting else { return }
            step = .updating
            Task { await upgrade(cask) }
        }
    }

    private func upgrade(_ cask: HomebrewCask) async {
        for arguments in cask.commands {
            let (output, status) = await Self.run(cask.brew, arguments)
            // A failed `brew update` (no network, a broken tap of another's)
            // may still leave an upgrade to do.
            if status != 0, arguments.first != "update" {
                step = .failed(HomebrewCask.problem(in: output))
                return
            }
        }
        guard let now = Self.buildOnDisk, now != Self.build else {
            step = .failed("Homebrew has no newer Swiftr yet. Try again in a moment.")
            return
        }
        step = .restarting
        relaunch()
    }

    /// The build in the app's folder now: brew may have changed it under
    /// the Swiftr that runs.
    private static var buildOnDisk: String? {
        let plist = Bundle.main.bundleURL.appending(path: "Contents/Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleVersion"] as? String
    }

    /// Opens the app again once this one has quit.
    private func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(filePath: "/bin/sh")
        waiter.arguments = ["-c", #"while /bin/kill -0 "$0" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open "$1""#,
                            String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        waiter.standardInput = FileHandle.nullDevice
        waiter.standardOutput = FileHandle.nullDevice
        waiter.standardError = FileHandle.nullDevice
        do {
            try waiter.run()
        } catch {
            step = .failed("The new Swiftr is in place. Quit Swiftr and open it again.")
            return
        }
        NSApp.terminate(nil)
    }

    /// Runs brew and waits for it without holding a thread.
    nonisolated private static func run(_ path: String, _ arguments: [String]) async -> (output: String, status: Int32) {
        let log = FileManager.default.temporaryDirectory.appending(path: "swiftr-brew-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil), let file = try? FileHandle(forWritingTo: log) else {
            return ("Swiftr couldn't make a file for brew's output.", -1)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = file
        process.standardError = file
        return await withCheckedContinuation { done in
            process.terminationHandler = { process in
                try? file.close()
                let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: log)
                done.resume(returning: (output, process.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                try? file.close()
                try? FileManager.default.removeItem(at: log)
                done.resume(returning: ("Swiftr couldn't run \(path): \(error.localizedDescription)", -1))
            }
        }
    }

    #if DEBUG
    /// Tests of an update: the copy an update opens again has lost the
    /// test's environment and would join the person's own herdr-core. A
    /// file named `.swiftr-quit-on-launch` beside the app makes it quit at
    /// once instead, and notes that it was opened.
    static func quitIfTestRelaunch() {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.appending(path: ".swiftr-quit-on-launch").path) else { return }
        try? Data("\(version) (\(build))\n".utf8).write(to: folder.appending(path: ".swiftr-relaunched"))
        exit(0)
    }

    /// Tests: a version on offer, without a feed.
    func debugOffer(_ version: String?) {
        latest = version
        blocked = nil
    }
    #endif

    // MARK: Where things are

    /// The feed of releases, nil in a copy built from source. In Debug
    /// builds `SWIFTR_FEED_URL` names one for tests.
    private static var feed: String? {
        #if DEBUG
        if let feed = ProcessInfo.processInfo.environment["SWIFTR_FEED_URL"], !feed.isEmpty { return feed }
        #endif
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty else { return nil }
        return feed
    }

    /// Where Homebrew may be; in Debug builds `SWIFTR_BREW_PREFIX` names a
    /// stand-in for tests.
    private static var brewPrefixes: [String] {
        #if DEBUG
        if let prefix = ProcessInfo.processInfo.environment["SWIFTR_BREW_PREFIX"], !prefix.isEmpty { return [prefix] }
        #endif
        return HomebrewCask.prefixes
    }
}
