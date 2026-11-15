import Foundation

/// Turns speech into text with the downloaded models: the dictation helper
/// (this same program, started with `DictationHelper.flag`) holds them and
/// answers each request.
@MainActor
final class DictationEngine {
    static let shared = DictationEngine()

    private var helper: Process?
    private var input: FileHandle?
    private var jobs = 0
    private var waiting: [Int: CheckedContinuation<DictationEvent, any Error>] = [:]

    /// The folders of the models the next dictation uses: speech's, and
    /// those of the passes Settings keeps on whose model is here.
    struct Models: Equatable {
        var speech: String
        var vocabulary: String?
        var tidy: String?
    }

    static var models: Models? {
        let library = DictationLibrary.shared
        guard library.isInstalled(DictationCatalog.speech) else { return nil }
        func folder(_ model: DictationModel) -> String? {
            library.isInstalled(model) ? DictationLibrary.folder(model).path : nil
        }
        return Models(speech: DictationLibrary.folder(DictationCatalog.speech).path,
                      vocabulary: folder(DictationCatalog.vocabulary),
                      tidy: Dictation.tidies ? folder(DictationCatalog.tidy) : nil)
    }

    /// Loads `model` and runs it once: the first time, the Neural Engine
    /// readies it, which can take a while.
    func prepare(_ model: DictationModel) async throws {
        var request = DictationRequest(op: .prepare, job: 0)
        let folder = DictationLibrary.folder(model).path
        switch model.role {
        case .speech: request.speech = folder
        case .vocabulary: request.vocabularyModel = folder
        case .tidy: request.tidyModel = folder
        }
        _ = try await ask(request)
    }

    /// Loads what the next dictation uses, without waiting for it: when
    /// the key goes down, so the models are ready when it comes up.
    func warmUp() {
        guard let models = Self.models else { return }
        jobs += 1
        try? send(DictationRequest(op: .prepare, job: jobs, speech: models.speech, vocabularyModel: models.vocabulary, tidyModel: models.tidy))
    }

    /// The text `samples` (mono, 16 kHz) say, written as `terms` spell
    /// names, and tidied up when Settings asks.
    func transcribe(_ samples: [Float], terms: [String]) async throws -> DictationEvent {
        guard let models = Self.models else { throw EngineError.noModel }
        let audio = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return try await ask(DictationRequest(op: .transcribe, job: 0, speech: models.speech, vocabularyModel: models.vocabulary,
                                              tidyModel: models.tidy, audio: audio, terms: terms))
    }

    /// Quits the helper, giving its models' memory back: before a model is
    /// deleted.
    func quitHelper() {
        try? input?.close()
        input = nil
        helper?.terminate()
        helper = nil
    }

    // MARK: The helper

    /// Sends `request` as a new job and waits for its answer.
    private func ask(_ request: DictationRequest) async throws -> DictationEvent {
        jobs += 1
        var request = request
        request.job = jobs
        let event = try await withCheckedThrowingContinuation { (done: CheckedContinuation<DictationEvent, any Error>) in
            waiting[request.job] = done
            do {
                try send(request)
            } catch {
                waiting[request.job] = nil
                done.resume(throwing: error)
            }
        }
        if let error = event.error { throw EngineError.model(error) }
        return event
    }

    private func send(_ request: DictationRequest) throws {
        try startHelper()
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        guard let input else { throw EngineError.helperGone }
        try input.write(contentsOf: data)
    }

    private func startHelper() throws {
        if let helper, helper.isRunning, input != nil { return }
        let process = Process()
        guard let program = Bundle.main.executableURL else { throw EngineError.helperGone }
        process.executableURL = program
        process.arguments = [DictationHelper.flag]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Self.logHandle() ?? FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        // Writing to a helper that quit must not end Swiftr.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.helperQuit(process) } }
        }
        try process.run()
        helper = process
        self.input = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        Thread.detachNewThread { Self.readAnswers(reader) }
    }

    /// Reads the helper's answers until it quits, handing each to the main
    /// thread in order.
    private nonisolated static func readAnswers(_ reader: FileHandle) {
        var buffer = Data()
        let decoder = JSONDecoder()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex ..< newline]
                buffer.removeSubrange(buffer.startIndex ... newline)
                guard let event = try? decoder.decode(DictationEvent.self, from: line) else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { DictationEngine.shared.received(event) } }
            }
        }
    }

    private func received(_ event: DictationEvent) {
        waiting.removeValue(forKey: event.job)?.resume(returning: event)
    }

    private func helperQuit(_ process: Process) {
        guard process === helper else { return }
        helper = nil
        input = nil
        // It quit with jobs under way: it crashed, or ran out of memory.
        for (_, done) in waiting { done.resume(throwing: EngineError.helperGone) }
        waiting = [:]
    }

    /// The helper's standard error, kept for the last run only.
    private static func logHandle() -> FileHandle? {
        let folder = URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Swiftr", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appending(path: "dictation-helper.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        return try? FileHandle(forWritingTo: log)
    }

    enum EngineError: LocalizedError {
        case noModel
        case helperGone
        case model(String)

        var errorDescription: String? {
            switch self {
            case .noModel: "Download the speech model in Settings › Dictation first."
            case .helperGone: "The speech model stopped."
            case .model(let message): message
            }
        }
    }
}
