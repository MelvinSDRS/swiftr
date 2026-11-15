import Foundation
import Observation

/// A newer version of a downloaded model, on Hugging Face.
nonisolated struct ModelUpdate: Equatable, Sendable {
    /// The commit it comes from.
    let revision: String
    /// When that commit was made.
    let date: Date?
    /// The files it changes or adds: what downloads.
    let files: [RemoteFile]
    /// The files it leaves as they are, copied from the folder.
    let kept: [RemoteFile]

    var bytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }
}

/// A downloaded model's folder, and the two an update puts beside it:
/// `.<name>.next` while the new version comes in, `.<name>.old` while
/// Swiftr tries it.
nonisolated struct ModelFolder: Sendable {
    let url: URL

    var next: URL { sibling("next") }
    var old: URL { sibling("old") }

    private func sibling(_ suffix: String) -> URL {
        url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(suffix)", directoryHint: .isDirectory)
    }

    /// The commit its files come from, once they are all there.
    var revision: String? {
        guard let text = try? String(contentsOf: url.appending(path: Self.marker), encoding: .utf8) else { return nil }
        let revision = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return revision.isEmpty ? nil : revision
    }

    /// A small file says the download finished, and for which commit.
    static func mark(_ folder: URL, revision: String) throws {
        try Data(revision.utf8).write(to: folder.appending(path: marker))
    }

    private static let marker = ".swiftr-model"

    // MARK: Updates

    /// Moves the new version in, and the one there was aside.
    func swapIn() throws {
        let manager = FileManager.default
        try? manager.removeItem(at: old)
        try manager.moveItem(at: url, to: old)
        do {
            try manager.moveItem(at: next, to: url)
        } catch {
            try? manager.moveItem(at: old, to: url)
            throw error
        }
    }

    /// The version there was comes back.
    func swapBack() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: old.path) else { return }
        try? manager.removeItem(at: url)
        try? manager.moveItem(at: old, to: url)
    }

    /// An update cut short when Swiftr quit: the version there was comes
    /// back, and what came in goes.
    func recover() {
        swapBack()
        dropNext()
    }

    func dropOld() {
        try? FileManager.default.removeItem(at: old)
    }

    func dropNext() {
        try? FileManager.default.removeItem(at: next)
    }

    /// Delete: the folder and what an update left beside it.
    func remove() {
        for folder in [url, next, old] {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // A version this Swiftr couldn't load isn't offered again, until
    // Swiftr itself changes.
    private var refusal: URL { url.appending(path: ".swiftr-refused") }

    func refuse(_ revision: String) {
        try? Data("\(revision) \(Self.thisSwiftr)".utf8).write(to: refusal)
    }

    func refuses(_ revision: String) -> Bool {
        (try? String(contentsOf: refusal, encoding: .utf8)) == "\(revision) \(Self.thisSwiftr)"
    }

    /// This Swiftr: when its program was built.
    private static let thisSwiftr: String = {
        guard let program = Bundle.main.executableURL,
              let date = try? program.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return "" }
        return String(Int(date.timeIntervalSince1970))
    }()
}

/// Newer versions of the models downloaded for Read Aloud and dictation:
/// Swiftr asks Hugging Face, and updates a model when the person asks. The
/// new version comes in beside the one there is, which stays in use until
/// the new one loads.
@MainActor @Observable
final class ModelUpdates {
    static let shared = ModelUpdates()

    /// A downloaded model, as an update sees it.
    struct Target {
        /// "voices/voxtral", "dictation/parakeet-ultra".
        let key: String
        /// As Settings names it: "Voxtral".
        let name: String
        let repo: String
        let skip: [String]
        let folder: ModelFolder
        /// Takes it out of use: its helper quits and lets go of its files.
        let release: @MainActor () -> Void
        /// Loads it once from its folder; throws when it doesn't work.
        let load: @MainActor () async throws -> Void
    }

    enum Step: Equatable {
        case downloading(done: Int64, total: Int64)
        /// The new version is in place: Swiftr loads it once to see it works.
        case installing
    }

    /// The update each model can take, by key.
    private(set) var available: [String: ModelUpdate] = [:]
    /// Each update under way, by key.
    private(set) var steps: [String: Step] = [:]
    /// Why the last update of a model failed, by key: a sentence, and the
    /// error behind it.
    private(set) var failures: [String: (said: String, detail: String)] = [:]
    /// When the last check worked; a failed one clears it.
    private(set) var checkedAt: Date?
    private(set) var checking = false
    private(set) var checkError: String?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    #if DEBUG
    /// Commits tests take for a repository's latest, by key.
    @ObservationIgnored var debugHeads: [String: String] = [:]
    #endif

    /// The downloaded models.
    var targets: [Target] {
        VoiceLibrary.shared.updateTargets + DictationLibrary.shared.updateTargets
    }

    /// An update runs.
    var busy: Bool { !steps.isEmpty }

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

    /// Looks now, and returns once the answers are in.
    func check() async {
        guard !checking else {
            while checking { try? await Task.sleep(for: .milliseconds(100)) }
            return
        }
        // Models on their way to a new version keep the update they take.
        let targets = targets.filter { tasks[$0.key] == nil }
        guard !targets.isEmpty else { return }
        checking = true
        var found: [String: ModelUpdate] = [:]
        var error: String?
        await withTaskGroup(of: (String, Result<ModelUpdate?, any Error>).self) { group in
            for target in targets {
                let (key, repo, skip, folder, head) = (target.key, target.repo, target.skip, target.folder, debugHead(target.key))
                group.addTask {
                    do {
                        return (key, .success(try await Self.look(repo, skip: skip, folder: folder, head: head)))
                    } catch {
                        return (key, .failure(error))
                    }
                }
            }
            for await (key, outcome) in group {
                switch outcome {
                case .success(let update): found[key] = update
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
        for target in targets {
            available[target.key] = found[target.key]
            // A failure says why the last try didn't work; a newer offer replaces it.
            if found[target.key] != nil { failures[target.key] = nil }
        }
        checkError = error
        checkedAt = error == nil ? Date() : nil
        checking = false
    }

    /// The update a model in `folder` can take, nil when it has the latest
    /// files. `head` stands for the latest commit in tests.
    nonisolated private static func look(_ repo: String, skip: [String], folder: ModelFolder, head: String?) async throws -> ModelUpdate? {
        guard let installed = folder.revision else { return nil }
        let latest = if let head { (revision: head, date: Date?.none) } else { try await HubDownload.head(repo) }
        guard latest.revision != installed, !folder.refuses(latest.revision) else { return nil }
        let new = try await HubDownload.files(HubRepo(repo: repo, revision: latest.revision, skip: skip))
        var old: [String: String] = [:]
        do {
            for file in try await HubDownload.files(HubRepo(repo: repo, revision: installed, skip: skip)) {
                old[file.path] = file.oid
            }
        } catch HubDownload.HubError.noRevision {
            // Its commit is gone from the repository: every file downloads again.
        }
        let changed = new.filter { old[$0.path] != $0.oid }
        let paths = Set(new.map(\.path))
        guard !changed.isEmpty || old.keys.contains(where: { !paths.contains($0) }) else {
            // A commit that left its files alone, such as a README's.
            try? ModelFolder.mark(folder.url, revision: latest.revision)
            return nil
        }
        return ModelUpdate(revision: latest.revision, date: latest.date, files: changed, kept: new.filter { old[$0.path] == $0.oid })
    }

    private func debugHead(_ key: String) -> String? {
        #if DEBUG
        return debugHeads[key]
        #else
        return nil
        #endif
    }

    // MARK: Updating

    func update(_ target: Target) {
        guard tasks[target.key] == nil, let update = available[target.key] else { return }
        failures[target.key] = nil
        steps[target.key] = .downloading(done: 0, total: update.bytes)
        tasks[target.key] = Task { [weak self] in await self?.install(update, into: target) }
    }

    /// Every update on offer.
    func updateAll() {
        for target in targets where available[target.key] != nil { update(target) }
    }

    /// Stops an update while it downloads; the model stays as it was.
    func cancel(_ key: String) {
        guard case .downloading = steps[key] else { return }
        tasks[key]?.cancel()
    }

    /// The model is deleted: nothing more to offer it.
    func forget(_ key: String) {
        tasks[key]?.cancel()
        available[key] = nil
        failures[key] = nil
    }

    private func install(_ update: ModelUpdate, into target: Target) async {
        let key = target.key
        let folder = target.folder
        do {
            try await HubDownload.stage(update, of: HubRepo(repo: target.repo, revision: update.revision, skip: target.skip),
                                        from: folder) { [weak self] done, total in
                guard case .downloading = self?.steps[key] else { return }
                self?.steps[key] = .downloading(done: done, total: total)
            }
            try Task.checkCancellation()
            steps[key] = .installing
            target.release()
            try folder.swapIn()
            do {
                try await target.load()
            } catch {
                // It doesn't load in this Swiftr: the version there was comes back.
                target.release()
                folder.swapBack()
                folder.refuse(update.revision)
                available[key] = nil
                failures[key] = ("This Swiftr can't load the new version, so it kept the one you had.", error.localizedDescription)
                steps[key] = nil
                tasks[key] = nil
                return
            }
            folder.dropOld()
            available[key] = nil
        } catch where Task.isCancelled || HubDownload.stopped(error) {
            folder.dropNext()
        } catch {
            folder.dropNext()
            failures[key] = ("The update failed: \(error.localizedDescription)", "")
        }
        steps[key] = nil
        tasks[key] = nil
    }
}
