import AppKit
import Foundation

/// What a program run for a mod answered.
public nonisolated struct ModExecResult: Sendable {
    public var code: Int32
    public var stdout: String
    public var stderr: String

    public init(code: Int32, stdout: String, stderr: String) {
        self.code = code
        self.stdout = stdout
        self.stderr = stderr
    }

    var json: [String: Any] { ["code": Int(code), "stdout": stdout, "stderr": stderr] }
}

public nonisolated struct ModExecRequest: Sendable {
    public var command: String
    public var arguments: [String]
    public var cwd: String?
    /// The machine to run on (a space's `machine`), nil for this Mac.
    public var machine: String?
    /// Milliseconds: 30 s unless the mod says, 10 minutes at most.
    public var timeout: Int

    public init(command: String, arguments: [String], cwd: String? = nil, machine: String? = nil, timeout: Int = 30_000) {
        self.command = command
        self.arguments = arguments
        self.cwd = cwd
        self.machine = machine
        self.timeout = min(max(timeout, 1), 600_000)
    }
}

public nonisolated struct ModError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// What a mod may do beyond drawing. Found by reading its files before it
/// is installed, shown to the person, and held to at run time.
public nonisolated struct ModCapabilities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Runs programs (`exec`, `hc`, `process.run`).
    public static let programs = ModCapabilities(rawValue: 1 << 0)
    /// Reads files outside its own folder.
    public static let readFiles = ModCapabilities(rawValue: 1 << 1)
    /// Writes files outside its own folder. Worth as much as running
    /// programs: a line in `~/.zshrc` runs at the next terminal.
    public static let writeFiles = ModCapabilities(rawValue: 1 << 2)
    /// Reaches the network (`fetch`, and sockets: `net`, `websocket`).
    public static let network = ModCapabilities(rawValue: 1 << 3)
    /// Runs Swiftr's commands (`run`): new tabs, splits, closing things.
    public static let commands = ModCapabilities(rawValue: 1 << 4)

    public static let all: ModCapabilities = [.programs, .readFiles, .writeFiles, .network, .commands]

    /// For people, in the order they matter.
    public var sentences: [String] {
        var out: [String] = []
        if contains(.programs) { out.append("Runs programs on your Mac and your machines") }
        if contains(.writeFiles) { out.append("Writes files anywhere you can, which lets it run programs too") }
        if contains(.readFiles) { out.append("Reads files outside its own folder") }
        if contains(.network) { out.append("Reaches the network, and this Mac's own ports") }
        if contains(.commands) { out.append("Runs Swiftr commands: tabs, panes, spaces") }
        return out
    }
}

/// The app a mod runs in: Swiftr, or a stand-in for checks and tests.
///
/// Live data goes the other way: the app hands `ModCenter` JSON for
/// `spaces`, `agents`, `panes`… whenever they change.
public protocol ModHost: AnyObject {
    /// `run(name, args)`: one of the app's commands. `view`: the copy that asked.
    func modRun(command: String, arguments: [String: Any], from copy: ModCopy?)
    /// `openOverlay(spec)`: answers the overlay's id.
    func modOpenOverlay(_ spec: [String: Any], from copy: ModCopy?) -> String
    func modCloseOverlay(_ id: String?)
    /// `notify({title, body, level, …})`: answers the notification's id.
    func modNotify(_ notification: [String: Any]) -> String
    func modSetAgentOrder(_ addresses: [String])
    func modPlaySound(_ sound: String)
    /// A program, here or on a machine. The default runs it on this Mac.
    func modExec(_ request: ModExecRequest) async throws -> ModExecResult
    /// `hc <args>`.
    func modCore(_ arguments: [String]) async throws -> ModExecResult
    func modKnownAgents(on machine: String?) async throws -> [[String: Any]]
    func modPickFolder(prompt: String?) async -> String?
    /// A file on another machine. Nil when absent.
    func modReadRemoteFile(_ path: String, on machine: String) async throws -> String?
    /// A web page, in the person's browser.
    func modOpen(_ url: URL)
    func modClipboard() -> String?
    func modSetClipboard(_ text: String)
}

public extension ModHost {
    func modRun(command: String, arguments: [String: Any], from copy: ModCopy?) {}
    func modOpenOverlay(_ spec: [String: Any], from copy: ModCopy?) -> String { "" }
    func modCloseOverlay(_ id: String?) {}
    func modNotify(_ notification: [String: Any]) -> String { "" }
    func modSetAgentOrder(_ addresses: [String]) {}
    func modPlaySound(_ sound: String) {}
    func modExec(_ request: ModExecRequest) async throws -> ModExecResult { try await ModProcess.run(request) }
    func modCore(_ arguments: [String]) async throws -> ModExecResult {
        try await modExec(ModExecRequest(command: "hc", arguments: arguments))
    }
    func modKnownAgents(on machine: String?) async throws -> [[String: Any]] { [] }
    func modPickFolder(prompt: String?) async -> String? { nil }
    func modOpen(_ url: URL) { NSWorkspace.shared.open(url) }
    func modClipboard() -> String? { NSPasteboard.general.string(forType: .string) }
    func modSetClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func modReadRemoteFile(_ path: String, on machine: String) async throws -> String? {
        let result = try await modExec(ModExecRequest(command: "cat", arguments: ["--", path], machine: machine))
        return result.code == 0 ? result.stdout : nil
    }
}

/// Programs on this Mac, for mods.
public nonisolated enum ModProcess {
    /// The environment programs get: the person's own (PATH, HOME, logins),
    /// which an app started from the Dock lacks. Set once by the app.
    nonisolated(unsafe) public static var environment: [String: String] = ProcessInfo.processInfo.environment

    static let outputLimit = 8 * 1024 * 1024

    public static func run(_ request: ModExecRequest) async throws -> ModExecResult {
        if let machine = request.machine, !machine.isEmpty {
            throw ModError("no way to run programs on \(machine) here")
        }
        let environment = environment
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try runBlocking(request, environment: environment)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func resolve(_ command: String, path: String) -> String? {
        if command.contains("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        for folder in path.split(separator: ":") {
            let candidate = "\(folder)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func runBlocking(_ request: ModExecRequest, environment: [String: String]) throws -> ModExecResult {
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        guard let executable = resolve(request.command, path: path) else {
            throw ModError("\(request.command): not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = request.arguments
        process.environment = environment
        if let cwd = request.cwd, !cwd.isEmpty {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isFolder), isFolder.boolValue else {
                throw ModError("\(cwd): no such folder")
            }
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Both pipes are drained while the program runs: one full pipe
        // would stop it.
        let group = DispatchGroup()
        let box = OutputBox()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var data = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    if data.count < outputLimit { data.append(chunk.prefix(outputLimit - data.count)) }
                }
                box.set(data, isOut: isOut)
                group.leave()
            }
        }
        let deadline = DispatchTime.now() + .milliseconds(request.timeout)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        if exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + .seconds(2)) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw ModError("\(request.command): timed out after \(request.timeout) ms")
        }
        group.wait()
        let (stdout, stderr) = box.both
        return ModExecResult(
            code: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func set(_ data: Data, isOut: Bool) { lock.lock(); if isOut { out = data } else { err = data }; lock.unlock() }
        var both: (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
    }
}

/// Files, for mods: text, on this Mac.
public nonisolated enum ModFiles {
    static let readLimit = 1024 * 1024

    /// The path with `..` and links resolved, so two spellings of one file
    /// compare equal (`/tmp/x` is `/private/tmp/x`). The part that doesn't
    /// exist yet is kept as written.
    public static func canonical(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let real = existing.resolvingSymlinksInPath().path
        let resolved = realpath(real, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? real
        return rest.isEmpty ? resolved : (resolved == "/" ? "" : resolved) + "/" + rest.joined(separator: "/")
    }

    public static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    public static func read(_ path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: readLimit) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The most bytes a script reads from one file.
    nonisolated(unsafe) static var bytesLimit = 16 * 1024 * 1024

    /// A file's bytes, as they are (a picture, an archive).
    public static func readBytes(_ path: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        // One byte more than allowed tells a long file from one that fits:
        // half a file handed over as the whole would be copied short.
        let data = try handle.read(upToCount: bytesLimit + 1) ?? Data()
        guard data.count <= bytesLimit else { throw ModError("\(path): more than \(bytesLimit >> 20) MB") }
        return data
    }

    /// Writes only if the file still holds `expected` (nil: only if absent).
    public static func write(_ path: String, text: String, expected: String?) throws {
        let current = try read(path)
        guard current == expected else { throw ModError("\(path) changed since it was read") }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
