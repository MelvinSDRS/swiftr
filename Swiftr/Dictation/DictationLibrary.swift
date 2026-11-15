import Foundation
import Observation

/// The dictation models on this Mac: which are downloaded, which are on
/// their way, and where each lives. `ModelUpdates` brings them to a later
/// commit than `DictationCatalog`'s.
@MainActor @Observable
final class DictationLibrary {
    static let shared = DictationLibrary()

    enum State: Equatable {
        case absent
        case downloading(done: Int64, total: Int64)
        /// Downloaded; the helper loads it once, which readies it for the
        /// Neural Engine.
        case preparing
        case installed
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    private init() {
        for model in DictationCatalog.models {
            Self.place(model).recover()
            if Self.isComplete(model) { states[model.id] = .installed }
        }
    }

    func state(_ model: DictationModel) -> State {
        states[model.id] ?? .absent
    }

    func isInstalled(_ model: DictationModel) -> Bool {
        state(model) == .installed
    }

    /// ~/Library/Application Support/Swiftr/dictation
    static var folder: URL {
        HubDownload.root.appending(path: "dictation")
    }

    static func folder(_ model: DictationModel) -> URL {
        folder.appending(path: model.folderName, directoryHint: .isDirectory)
    }

    /// Bytes `model` takes on this Mac.
    static func used(_ model: DictationModel) -> Int64 {
        HubDownload.used(folder(model))
    }

    // MARK: Download

    func download(_ model: DictationModel) {
        guard tasks[model.id] == nil else { return }
        states[model.id] = .downloading(done: 0, total: model.size)
        tasks[model.id] = Task { [weak self] in await self?.fetch(model) }
    }

    /// Stops a download or an update and takes away what came in.
    func cancel(_ model: DictationModel) {
        tasks[model.id]?.cancel()
        ModelUpdates.shared.cancel(Self.key(model))
    }

    func delete(_ model: DictationModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        ModelUpdates.shared.forget(Self.key(model))
        // The helper may hold its files, and its memory.
        DictationEngine.shared.quitHelper()
        Self.place(model).remove()
        states[model.id] = .absent
    }

    private func fetch(_ model: DictationModel) async {
        do {
            let files = try await HubDownload.files(model.hub)
            try await HubDownload.fetch(files, of: model.hub, into: Self.folder(model)) { [weak self] done, total in
                guard case .downloading = self?.states[model.id] else { return }
                self?.states[model.id] = .downloading(done: done, total: total)
            }
            try ModelFolder.mark(Self.folder(model), revision: model.hub.revision)
            states[model.id] = .preparing
            try await DictationEngine.shared.prepare(model)
            states[model.id] = .installed
        } catch where Task.isCancelled || HubDownload.stopped(error) {
            // Stopped: nothing stays but a whole model.
            if Self.isComplete(model) {
                states[model.id] = .installed
            } else {
                try? FileManager.default.removeItem(at: Self.folder(model))
                states[model.id] = .absent
            }
        } catch {
            states[model.id] = .failed(error.localizedDescription)
        }
        tasks[model.id] = nil
    }

    private static func place(_ model: DictationModel) -> ModelFolder {
        ModelFolder(url: folder(model))
    }

    /// Its files are all there, from whichever commit.
    private static func isComplete(_ model: DictationModel) -> Bool {
        place(model).revision != nil
    }

    // MARK: Updates

    /// How `ModelUpdates` knows `model`: "dictation/parakeet-ultra".
    static func key(_ model: DictationModel) -> String {
        "dictation/" + model.id
    }

    func update(_ model: DictationModel) {
        ModelUpdates.shared.update(target(model))
    }

    /// The downloaded models, for `ModelUpdates` to check.
    var updateTargets: [ModelUpdates.Target] {
        DictationCatalog.models.filter { isInstalled($0) }.map(target)
    }

    private func target(_ model: DictationModel) -> ModelUpdates.Target {
        ModelUpdates.Target(key: Self.key(model), repo: model.hub.repo, skip: model.hub.skip, folder: Self.place(model),
                            release: { DictationEngine.shared.quitHelper() },
                            load: { try await DictationEngine.shared.prepare(model) })
    }
}
