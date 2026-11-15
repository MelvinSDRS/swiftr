import Foundation
import Observation

/// The voice models on this Mac: which are downloaded, which are on their
/// way, and where each lives. A model downloads only when asked, from
/// Hugging Face, at the commit `VoiceCatalog` names; `ModelUpdates` brings
/// it to a later one.
@MainActor @Observable
final class VoiceLibrary {
    static let shared = VoiceLibrary()

    enum State: Equatable {
        case absent
        case downloading(done: Int64, total: Int64)
        /// Downloaded; the helper loads it once and fetches what it needs
        /// besides its own files.
        case preparing
        case installed
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    private init() {
        for model in VoiceCatalog.models {
            Self.place(model).recover()
            if Self.isComplete(model) { states[model.id] = .installed }
        }
    }

    func state(_ model: VoiceModel) -> State {
        states[model.id] ?? .absent
    }

    func isInstalled(_ model: VoiceModel) -> Bool {
        state(model) == .installed
    }

    /// ~/Library/Application Support/Swiftr/voices
    static var folder: URL {
        HubDownload.root.appending(path: "voices")
    }

    static func folder(_ model: VoiceModel) -> URL {
        folder.appending(path: model.id, directoryHint: .isDirectory)
    }

    /// What models fetch besides their own files: dictionaries, tokenizers.
    static var hubFolder: URL {
        folder.appending(path: ".hub", directoryHint: .isDirectory)
    }

    /// Bytes `model` takes on this Mac.
    static func used(_ model: VoiceModel) -> Int64 {
        HubDownload.used(folder(model))
    }

    // MARK: Download

    func download(_ model: VoiceModel) {
        guard tasks[model.id] == nil else { return }
        states[model.id] = .downloading(done: 0, total: model.size)
        tasks[model.id] = Task { [weak self] in await self?.fetch(model) }
    }

    /// Stops a download or an update and takes away what came in.
    func cancel(_ model: VoiceModel) {
        tasks[model.id]?.cancel()
        ModelUpdates.shared.cancel(Self.key(model))
    }

    func delete(_ model: VoiceModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        ModelUpdates.shared.forget(Self.key(model))
        // The helper may hold its files, and its memory.
        ModelReader.shared.quitHelper()
        Self.place(model).remove()
        states[model.id] = .absent
        // The last one gone: what the models fetched goes too.
        if !VoiceCatalog.models.contains(where: { isInstalled($0) }) {
            try? FileManager.default.removeItem(at: Self.hubFolder)
        }
    }

    private func fetch(_ model: VoiceModel) async {
        do {
            let repo = HubRepo(repo: model.repo, revision: model.revision, skip: model.skip)
            let files = try await HubDownload.files(repo)
            try await HubDownload.fetch(files, of: repo, into: Self.folder(model)) { [weak self] done, total in
                guard case .downloading = self?.states[model.id] else { return }
                self?.states[model.id] = .downloading(done: done, total: total)
            }
            try ModelFolder.mark(Self.folder(model), revision: model.revision)
            states[model.id] = .preparing
            try await Self.prepare(model)
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

    /// Loads `model` in the helper with the voices of Settings' languages,
    /// so the first reading starts sooner, and to see it works.
    private static func prepare(_ model: VoiceModel) async throws {
        let voices = ReadAloud.settingsLanguages.compactMap { model.voices(for: $0).first }
        try await ModelReader.shared.prepare(model, voices: voices.isEmpty ? Array(model.voices.prefix(1)) : voices)
    }

    private static func place(_ model: VoiceModel) -> ModelFolder {
        ModelFolder(url: folder(model))
    }

    /// Its files are all there, from whichever commit.
    private static func isComplete(_ model: VoiceModel) -> Bool {
        place(model).revision != nil
    }

    // MARK: Updates

    /// How `ModelUpdates` knows `model`: "voices/voxtral".
    static func key(_ model: VoiceModel) -> String {
        "voices/" + model.id
    }

    func update(_ model: VoiceModel) {
        ModelUpdates.shared.update(target(model))
    }

    /// The downloaded models, for `ModelUpdates` to check.
    var updateTargets: [ModelUpdates.Target] {
        VoiceCatalog.models.filter { isInstalled($0) }.map(target)
    }

    private func target(_ model: VoiceModel) -> ModelUpdates.Target {
        ModelUpdates.Target(key: Self.key(model), repo: model.repo, skip: model.skip, folder: Self.place(model),
                            release: { ModelReader.shared.quitHelper() },
                            load: { try await Self.prepare(model) })
    }
}
