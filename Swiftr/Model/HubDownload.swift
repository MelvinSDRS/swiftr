import Foundation

/// A model's repository on Hugging Face, the commit Swiftr downloads from
/// it, and the files it leaves out.
nonisolated struct HubRepo: Sendable {
    let repo: String
    let revision: String
    var skip: [String] = []
}

/// A file of a model's repository.
nonisolated struct RemoteFile: Equatable, Sendable {
    let path: String
    let size: Int64
    /// Git's id for its content: another id, other content.
    var oid = ""
}

/// Downloads models from Hugging Face's public repositories, without an
/// account: voices for Read Aloud, speech models for dictation.
@MainActor
enum HubDownload {
    /// ~/Library/Application Support/Swiftr, where the models go. In Debug
    /// builds `SWIFTR_MODELS` moves it, so tests leave the real ones alone.
    nonisolated static var root: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SWIFTR_MODELS"], !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Swiftr")
    }

    /// The files of `repo` at its commit, but those it skips.
    nonisolated static func files(_ repo: HubRepo) async throws -> [RemoteFile] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo.repo)/tree/\(repo.revision)?recursive=true") else {
            throw HubError.badList
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 404 { throw HubError.noRevision }
        guard status == 200, let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HubError.badList }
        return entries.compactMap { entry in
            guard entry["type"] as? String == "file", let path = entry["path"] as? String,
                  let size = (entry["size"] as? NSNumber)?.int64Value,
                  !path.contains(".."), !repo.skip.contains(where: { fnmatch($0, path, 0) == 0 }) else { return nil }
            return RemoteFile(path: path, size: size, oid: entry["oid"] as? String ?? "")
        }
    }

    /// The latest commit of `repo`, and when it was made.
    nonisolated static func head(_ repo: String) async throws -> (revision: String, date: Date?) {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)?expand%5B%5D=sha&expand%5B%5D=lastModified") else {
            throw HubError.badList
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = info["sha"] as? String, !sha.isEmpty else { throw HubError.noHead }
        let date = (info["lastModified"] as? String).flatMap {
            (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0)) ?? (try? Date.ISO8601FormatStyle().parse($0))
        }
        return (sha, date)
    }

    /// Downloads into `folder` the files of `files` not there whole yet, a
    /// few at a time, telling the bytes in so far a few times a second.
    /// Files a failed try brought in whole stay.
    static func fetch(_ files: [RemoteFile], of repo: HubRepo, into folder: URL,
                      progress: @escaping @MainActor (_ done: Int64, _ total: Int64) -> Void) async throws {
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let missing = files.filter { size(of: folder.appending(path: $0.path)) != $0.size }
        try checkSpace(missing.reduce(Int64(0)) { $0 + $1.size }, at: folder.deletingLastPathComponent())
        let tally = Tally(total: total, done: total - missing.reduce(Int64(0)) { $0 + $1.size }, progress: progress)
        progress(tally.done, total)
        // A few at a time: each small file costs a round trip.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = missing.makeIterator()
            for _ in 0 ..< parallel {
                guard let file = next.next() else { break }
                group.addTask { try await get(file, of: repo, into: folder, tally: tally) }
            }
            while try await group.next() != nil {
                guard let file = next.next() else { continue }
                group.addTask { try await get(file, of: repo, into: folder, tally: tally) }
            }
        }
    }

    private static let parallel = 4

    /// Readies `update` in `folder.next`: the files it keeps copied from the
    /// folder (APFS shares their blocks, so they take no room), the others
    /// downloaded from `repo`, at the update's commit.
    static func stage(_ update: ModelUpdate, of repo: HubRepo, from folder: ModelFolder,
                      progress: @escaping @MainActor (_ done: Int64, _ total: Int64) -> Void) async throws {
        let manager = FileManager.default
        folder.dropNext()
        try manager.createDirectory(at: folder.next, withIntermediateDirectories: true)
        var download = update.files
        for file in update.kept {
            let from = folder.url.appending(path: file.path)
            let to = folder.next.appending(path: file.path)
            do {
                guard size(of: from) == file.size else { throw CocoaError(.fileNoSuchFile) }
                try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: from, to: to)
            } catch {
                // Gone from this Mac: it downloads too.
                download.append(file)
            }
        }
        try await fetch(download, of: HubRepo(repo: repo.repo, revision: update.revision, skip: repo.skip), into: folder.next, progress: progress)
        try ModelFolder.mark(folder.next, revision: update.revision)
    }

    private static func get(_ file: RemoteFile, of repo: HubRepo, into folder: URL, tally: Tally) async throws {
        let destination = folder.appending(path: file.path)
        try await FileDownload.run(url(repo, file.path), to: destination) { written in
            guard !tally.finished.contains(file.path) else { return }
            tally.underway[file.path] = written
            tally.show()
        }
        guard size(of: destination) == file.size else { throw HubError.incomplete(file.path) }
        tally.finished.insert(file.path)
        tally.underway[file.path] = nil
        tally.done += file.size
        tally.show()
    }

    /// The download was stopped, not broken.
    nonisolated static func stopped(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private nonisolated static func url(_ repo: HubRepo, _ path: String) -> URL {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://huggingface.co/\(repo.repo)/resolve/\(repo.revision)/\(escaped)")!
    }

    nonisolated static func size(of file: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
    }

    /// Bytes the files in `folder` take on this Mac.
    nonisolated static func used(_ folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func checkSpace(_ needed: Int64, at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        // Room to spare after it, for the rest of the Mac.
        if needed + 1_000_000_000 > free { throw HubError.noSpace(needed) }
    }

    enum HubError: LocalizedError {
        case badList
        case noRevision
        case noHead
        case incomplete(String)
        case noSpace(Int64)

        var errorDescription: String? {
            switch self {
            case .badList: "Hugging Face didn't list the model's files."
            case .noRevision: "Hugging Face no longer has that version of the model."
            case .noHead: "Hugging Face didn't say which version of the model is the latest."
            case .incomplete(let file): "\(file) came in incomplete."
            case .noSpace(let bytes): "This Mac needs \(ByteCountFormatter.string(fromByteCount: bytes + 1_000_000_000, countStyle: .file)) free."
            }
        }
    }
}

/// What a download brought in so far.
@MainActor
private final class Tally {
    let total: Int64
    /// Bytes of the files that came in whole.
    var done: Int64
    /// Bytes so far of the files on their way, by path.
    var underway: [String: Int64] = [:]
    var finished: Set<String> = []
    private var shown = Date.distantPast
    private let progress: @MainActor (Int64, Int64) -> Void

    init(total: Int64, done: Int64, progress: @escaping @MainActor (Int64, Int64) -> Void) {
        self.total = total
        self.done = done
        self.progress = progress
    }

    /// Moves the bar, a few times a second rather than at each packet.
    func show() {
        guard Date().timeIntervalSince(shown) > 0.2 else { return }
        shown = Date()
        progress(done + underway.values.reduce(0, +), total)
    }
}

/// One file downloaded to `destination`, telling the bytes written so far.
private nonisolated final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @MainActor (Int64) -> Void
    private var done: CheckedContinuation<Void, any Error>?
    private let lock = NSLock()

    private init(destination: URL, progress: @escaping @MainActor (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func run(_ url: URL, to destination: URL, progress: @escaping @MainActor (Int64) -> Void) async throws {
        let download = FileDownload(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                download.lock.withLock { download.done = done }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ error: (any Error)?) {
        let done = lock.withLock {
            let done = self.done
            self.done = nil
            return done
        }
        if let error { done?.resume(throwing: error) } else { done?.resume() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = progress
        DispatchQueue.main.async { MainActor.assumeIsolated { progress(totalBytesWritten) } }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status == 200 else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            finish(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Hugging Face answered \(status)."]))
            return
        }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: location, to: destination)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(error) }
    }
}
