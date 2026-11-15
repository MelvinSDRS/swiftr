import Foundation
import HerdrKit

/// herdr-core's updates: the latest release, and `hc update` (this Mac) or
/// `hc machine update` (another machine) when the person asks. Terminals
/// keep running through both: the core restarts and Swiftr connects again.
@Observable
final class CoreUpdates {
    enum Step: Equatable {
        /// hc is at work.
        case updating
        /// hc is done: the core restarts and Swiftr connects again.
        case restarting
        case failed(String, hint: String?)
    }

    /// What this Mac's core can do about the latest release.
    enum Offer: Equatable {
        /// Not looked yet, or the last look failed.
        case unknown
        case upToDate
        case update(to: String)
        /// The release speaks a later protocol than this Swiftr.
        case needsNewerSwiftr(String)
        /// A package manager installed hc (homebrew, nix…): it updates hc,
        /// `hc update` won't.
        case managed(by: String)
    }

    /// The latest release, from the last check that worked.
    private(set) var latest: CoreRelease?
    /// When the last check worked; a failed one clears it, as herdr-app does.
    private(set) var checkedAt: Date?
    private(set) var checking = false
    private(set) var checkError: String?
    /// Each update under way or failed, by machine ("" is this Mac).
    private(set) var steps: [String: Step] = [:]
    /// The package manager this Mac's hc came from, nil for a plain install.
    private(set) var installedBy: String?

    @ObservationIgnored private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// An update runs somewhere: one at a time, as a machine gets this Mac's hc.
    var busy: Bool {
        steps.values.contains { $0 == .updating || $0 == .restarting }
    }

    /// The version this Mac's core runs, while Swiftr is connected to it.
    var thisMac: String? {
        guard model.link == .connected, let version = model.connection?.version, !version.isEmpty else { return nil }
        return version
    }

    var offer: Offer {
        if let installedBy { return .managed(by: installedBy) }
        guard checkError == nil, let latest, let now = thisMac.flatMap(CoreVersion.init),
              let next = CoreVersion(latest.version) else { return .unknown }
        guard now < next else { return .upToDate }
        if latest.generation > CoreConnection.generation { return .needsNewerSwiftr(latest.version) }
        return .update(to: latest.version)
    }

    /// The version to give a machine whose core runs `version`, or nil when
    /// it runs this Mac's or a newer one.
    func machineUpdate(from version: String) -> String? {
        guard let mine = thisMac, let ours = CoreVersion(mine) else { return nil }
        guard let theirs = CoreVersion(version) else { return mine }
        return theirs < ours ? mine : nil
    }

    // MARK: Checking

    /// Looks again unless the last look worked less than an hour ago.
    func checkIfStale() {
        if let checkedAt, checkError == nil, Date().timeIntervalSince(checkedAt) < 3600 { return }
        checkNow()
    }

    func checkNow() {
        guard !checking else { return }
        Task { await check() }
    }

    /// Looks now, and returns once the answer is in.
    func check() async {
        guard !checking else {
            while checking { try? await Task.sleep(for: .milliseconds(100)) }
            return
        }
        checking = true
        await readInstall()
        do {
            latest = try await CoreRelease.latest(environment: model.endpoint.environment)
            checkedAt = Date()
            checkError = nil
        } catch {
            checkedAt = nil
            checkError = error.localizedDescription
        }
        checking = false
    }

    private func readInstall() async {
        guard let c = model.connection, let status = try? await c.call("server.status") else { return }
        installedBy = status["installed_by"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Updating

    /// `hc update`: the latest release of this generation, and a restart of
    /// the core onto it.
    func updateThisMac() {
        guard !busy else { return }
        steps[""] = .updating
        let before = model.connection
        Task {
            let outcome = await Self.run(hcPath, ["update", "--json"], environment: environment)
            if let error = outcome.error {
                steps[""] = .failed(error.message, hint: error.hint)
                return
            }
            if outcome.updated || outcome.restarted {
                steps[""] = .restarting
                // The core restarts: wait up to 30 s for Swiftr's next connection to it.
                for _ in 0 ..< 60 {
                    if model.link == .connected, model.connection !== before { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            steps[""] = nil
            await readInstall()
        }
    }

    /// `hc machine update`: this Mac's hc copied there, and its core restarted.
    func update(machine name: String) {
        guard !busy else { return }
        steps[name] = .updating
        let before = model.remotes.first { $0.name == name }?.version
        Task {
            let outcome = await Self.run(hcPath, ["machine", "update", name, "--json"], environment: environment)
            if let error = outcome.error {
                steps[name] = .failed(error.message, hint: error.hint)
                await model.refreshMachines()
                return
            }
            // Its core restarts: wait up to 30 s for this core to see the new version there.
            steps[name] = .restarting
            for _ in 0 ..< 30 {
                await model.refreshMachines()
                if let machine = model.remotes.first(where: { $0.name == name }), machine.isConnected, machine.version != before { break }
                try? await Task.sleep(for: .seconds(1))
            }
            steps[name] = nil
        }
    }

    /// The endpoint's hc; in Debug builds `SWIFTR_HC` puts a stand-in there
    /// for tests.
    private var hcPath: String {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SWIFTR_HC"], !path.isEmpty { return path }
        #endif
        return model.endpoint.hcPath
    }

    /// The endpoint's environment, less what says hc runs in a terminal: a
    /// Swiftr opened from one has them, and hc would then work on that
    /// terminal's core instead of Swiftr's.
    private var environment: [String: String] {
        model.endpoint.environment.filter { !["HC_TERMINAL_ID", "HC_TERMINAL_SOCKET", "HC_SCOPE"].contains($0.key) }
    }

    /// Runs hc and waits for it without holding a thread. Its output goes to
    /// a file, not a pipe: the core it restarts must not keep Swiftr waiting
    /// for the pipe to close.
    nonisolated private static func run(_ path: String, _ arguments: [String], environment: [String: String]) async -> CoreUpdateOutcome {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftr-hc-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let file = try? FileHandle(forWritingTo: url) else {
            return CoreUpdateOutcome(output: "Swiftr couldn't make a file for hc's answer.", status: -1)
        }
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
                let output = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: url)
                done.resume(returning: CoreUpdateOutcome(output: output, status: process.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                try? file.close()
                try? FileManager.default.removeItem(at: url)
                done.resume(returning: CoreUpdateOutcome(output: "Swiftr couldn't run \(path): \(error.localizedDescription)", status: -1))
            }
        }
    }
}
