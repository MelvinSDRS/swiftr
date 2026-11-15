import Foundation
import HerdrKit

/// Puts herdr-core on a Mac that has none, with herdr's own installer, as
/// a person would in a terminal: it checks the download and its Apple
/// signature, installs Herdr Core.app and `hc` in ~/.local/bin, and starts
/// no core. `AppModel` runs it when no core answers and no `hc` is found.
nonisolated enum CoreInstall {
    /// The same, to type in a terminal.
    static func command(environment: [String: String]) -> String {
        "curl -fsSL \(CoreRelease.installerURL(environment: environment).absoluteString) | sh"
    }

    /// Fetches the installer and runs it; throws what it said last when it
    /// fails.
    static func run(environment: [String: String]) async throws {
        let url = CoreRelease.installerURL(environment: environment)
        let server = url.host() ?? url.absoluteString
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CoreError(kind: "install", message: "\(server) answered \(http.statusCode).")
        }
        let script = FileManager.default.temporaryDirectory.appending(path: "herdr-core-install-\(UUID().uuidString).sh")
        try data.write(to: script)
        defer { try? FileManager.default.removeItem(at: script) }
        let (output, status) = await shell(script, environment: environment, limit: .seconds(600))
        guard status == 0 else {
            // Its own failures end on a line of their own: "hc: download failed: …".
            let last = output.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            throw CoreError(kind: "install", message: last.map(String.init) ?? "The installer stopped (\(status)).")
        }
    }

    /// Runs a script with /bin/sh, its output to a file, and stops it after
    /// `limit`: a download that hangs mustn't keep Swiftr installing forever.
    private static func shell(_ script: URL, environment: [String: String], limit: Duration) async -> (output: String, status: Int32) {
        let log = FileManager.default.temporaryDirectory.appending(path: "herdr-core-install-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil), let file = try? FileHandle(forWritingTo: log) else {
            return ("Swiftr couldn't make a file for the installer's output.", -1)
        }
        defer {
            try? file.close()
            try? FileManager.default.removeItem(at: log)
        }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = file
        process.standardError = file
        let watchdog = Task {
            try? await Task.sleep(for: limit)
            if !Task.isCancelled, process.isRunning { process.terminate() }
        }
        var launchError: String?
        let status: Int32 = await withCheckedContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                launchError = error.localizedDescription
                done.resume(returning: -1)
            }
        }
        watchdog.cancel()
        if let launchError { return ("Swiftr couldn't run the installer: \(launchError)", -1) }
        if process.terminationReason == .uncaughtSignal { return ("The installer took too long, and Swiftr stopped it.", status) }
        return ((try? String(contentsOf: log, encoding: .utf8)) ?? "", status)
    }
}
