import Foundation
import HerdrKit
import Observation

/// The files of the folders the Messages field names with `@`, read once
/// and again after a while: git's list in a repository, else a walk a few
/// levels down. On another machine, the core runs the same listing there.
@MainActor @Observable
final class FileIndex {
    static let shared = FileIndex()

    private struct Entry {
        var index: FileMention.Index
        var readAt: Date
    }

    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var reading: Set<String> = []

    /// How long a list stays good before it is read again.
    private static let fresh: TimeInterval = 30

    /// The folder's list as last read (nil until read), reading it when old.
    func index(folder: String, machine: String?, connection: CoreConnection?) -> FileMention.Index? {
        guard !folder.isEmpty else { return nil }
        let key = (machine ?? "") + "|" + folder
        let entry = entries[key]
        if entry == nil || Date().timeIntervalSince(entry!.readAt) > Self.fresh {
            read(key: key, folder: folder, machine: machine, connection: connection)
        }
        return entry?.index
    }

    private func read(key: String, folder: String, machine: String?, connection: CoreConnection?) {
        guard !reading.contains(key) else { return }
        reading.insert(key)
        let line = FileMention.listing(folder: folder)
        Task {
            defer { reading.remove(key) }
            let output: String?
            if let machine {
                let r = try? await connection?.call("machine.exec", ["on": .string(machine), "line": .string(line), "timeout": 15], timeout: .seconds(20))
                output = r?["stdout"]?.string.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
            } else {
                output = await Task.detached(priority: .userInitiated) { Self.run(line) }.value
            }
            guard let output else { return }
            let files = output.split(separator: "\n").map(String.init)
            let index = await Task.detached(priority: .userInitiated) { FileMention.Index(files: files) }.value
            entries[key] = Entry(index: index, readAt: Date())
        }
    }

    /// Runs `line` in `sh` here; its output, or nil if it couldn't start.
    nonisolated private static func run(_ line: String) -> String? {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", line]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
