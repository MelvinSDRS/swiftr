import FluidAudio
import Foundation
import HerdrKit

/// Swiftr's dictation helper: this same program started with
/// `--dictation-helper`, turning speech into text with the downloaded
/// models in a process of its own, so their memory goes back when it quits
/// and their crash can't take Swiftr along. Requests come in on standard
/// input and answers go out on standard output, a line of JSON each
/// (`DictationRequest`, `DictationEvent`). It quits when Swiftr closes its
/// input, or after ten idle minutes, as Lavoi keeps its models.
nonisolated enum DictationHelper {
    static let flag = "--dictation-helper"

    static func run() -> Never {
        // Answers go out on a copy of standard output; what the models
        // print goes to standard error, where it can't garble them.
        let out = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        // Swiftr downloads the models: FluidAudio never fetches anything.
        ModelHub.offlineMode = true
        let listener = DictationListener(answers: DictationAnswers(fd: out))
        // A dictation's sound is a long line: read in big pieces, not byte
        // by byte.
        Thread.detachNewThread {
            var buffer = Data()
            let input = FileHandle.standardInput
            while true {
                let chunk = input.availableData
                // Swiftr closed the pipe: it quit, or crashed.
                if chunk.isEmpty { exit(0) }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex ..< newline])
                    buffer.removeSubrange(buffer.startIndex ... newline)
                    guard let request = try? JSONDecoder().decode(DictationRequest.self, from: line) else { continue }
                    Task { await listener.handle(request) }
                }
            }
        }
        dispatchMain()
    }
}

/// Writes answers whole, one at a time.
private nonisolated final class DictationAnswers: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(fd: Int32) {
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func send(_ event: DictationEvent) {
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0A)
        lock.withLock { try? handle.write(contentsOf: data) }
    }
}

/// Runs one job at a time, keeping the models it loaded.
private actor DictationListener {
    private let answers: DictationAnswers
    private var speech: (folder: String, manager: AsrManager)?
    private var ctc: (folder: String, models: CtcModels)?
    private var boosting: (key: [String], session: VocabularyBoostingSession)?
    private var tidier: DictationTidier?
    private var idle: Task<Void, Never>?
    /// Jobs run in the order they came.
    private var last: Task<Void, Never>?
    private static let idleLimit = Duration.seconds(600)
    private static let rate = 16_000

    init(answers: DictationAnswers) {
        self.answers = answers
    }

    func handle(_ request: DictationRequest) {
        idle?.cancel()
        let previous = last
        last = Task {
            await previous?.value
            await self.run(request)
        }
    }

    private func run(_ request: DictationRequest) async {
        do {
            switch request.op {
            case .prepare:
                try await prepare(request)
                answers.send(DictationEvent(job: request.job, done: true))
            case .transcribe:
                answers.send(try await transcribe(request))
            }
        } catch {
            answers.send(DictationEvent(job: request.job, done: true, error: Self.describe(error)))
        }
        waitIdle()
    }

    /// Loads the models and runs each once on a second of silence: the
    /// first time ever, the Neural Engine compiles them then.
    private func prepare(_ request: DictationRequest) async throws {
        let silence = [Float](repeating: 0, count: Self.rate)
        if let folder = request.speech {
            let manager = try await speechManager(folder)
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            _ = try await manager.transcribe(silence, decoderState: &state)
        }
        if let folder = request.vocabularyModel {
            _ = try await boostingSession(DictationVocabulary.builtIn, folder: folder)
        }
        if let folder = request.tidyModel {
            _ = try await tidyModel(folder).tidy("ok", names: [], deadline: .now + .seconds(5))
        }
    }

    private func transcribe(_ request: DictationRequest) async throws -> DictationEvent {
        guard let folder = request.speech, let audio = request.audio else { throw HelperError.nothingToHear }
        var timings: [String: Double] = [:]
        var clock = ContinuousClock.now
        func lap(_ name: String) {
            timings[name] = (ContinuousClock.now - clock).milliseconds
            clock = .now
        }
        var samples = audio.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // Parakeet wants a second at least.
        if samples.count < Self.rate { samples += [Float](repeating: 0, count: Self.rate - samples.count) }
        let manager = try await speechManager(folder)
        lap("load")
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        lap("speech")
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var heard = raw
        if let ctcFolder = request.vocabularyModel, let terms = request.terms, !terms.isEmpty,
           let timingsOfTokens = result.tokenTimings, !timingsOfTokens.isEmpty
        {
            let session = try await boostingSession(terms, folder: ctcFolder)
            // Only when a word looks like a name: the pass costs a second
            // model's run.
            if session.hasCTCRescoringCandidates(text: heard, tokenTimings: timingsOfTokens),
               let rescored = await session.rescore(text: heard, tokenTimings: timingsOfTokens, audioSamples: samples), rescored.wasModified
            {
                heard = rescored.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            lap("vocabulary")
        }
        heard = DictationText.withoutStumbles(DictationText.withoutFillers(heard))
        var text = heard
        var tidy = "off"
        if let folder = request.tidyModel, !heard.isEmpty {
            let tidier = try await tidyModel(folder)
            lap("tidy load")
            // Past this the person waits too long: the rest goes as heard.
            let deadline = ContinuousClock.now + .milliseconds(1500 + heard.utf8.count * 5)
            let outcome = try DictationTidy.tidy(heard, terms: request.terms ?? []) { piece, names in
                try tidier.tidy(piece, names: names, deadline: deadline)
            }
            text = outcome.text
            tidy = outcome.note
            lap("tidy")
        }
        return DictationEvent(job: request.job, raw: raw, heard: heard, text: text, tidy: tidy, timings: timings, done: true)
    }

    // MARK: Models

    private func speechManager(_ folder: String) async throws -> AsrManager {
        if let speech, speech.folder == folder { return speech.manager }
        speech = nil
        let models = try await AsrModels.load(from: URL(filePath: folder, directoryHint: .isDirectory), version: .ultra)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        speech = (folder, manager)
        return manager
    }

    /// The vocabulary pass for `terms`, kept while they stay the same.
    private func boostingSession(_ terms: [String], folder: String) async throws -> VocabularyBoostingSession {
        if ctc?.folder != folder {
            ctc = (folder, try await CtcModels.loadDirect(from: URL(filePath: folder, directoryHint: .isDirectory)))
            boosting = nil
        }
        if let boosting, boosting.key == terms { return boosting.session }
        guard let models = ctc?.models else { throw HelperError.nothingToHear }
        // "Composer Field", "swifter": how the speech model writes them.
        let vocabulary = CustomVocabularyContext(terms: terms.map { term in
            let forms = DictationVocabulary.heardAs(term)
            return CustomVocabularyTerm(text: term, aliases: forms.isEmpty ? nil : forms)
        })
        // Only words written close to a name are checked (FluidAudio's
        // check by sound alone is off: Parakeet CTC knows only English, and
        // took French words for names). A word heard with confidence that
        // isn't spelled close gets no help: a word heard right changed costs
        // more than a name missed.
        let session = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: models,
                                                          config: VocabularyRescorer.Config(spotterRescueEnabled: false),
                                                          thresholds: .init(minSimilarity: 0.7))
        boosting = (terms, session)
        return session
    }

    private func tidyModel(_ folder: String) async throws -> DictationTidier {
        if let tidier, tidier.folder == folder { return tidier }
        tidier = nil
        let loaded = try await DictationTidier(folder: folder)
        tidier = loaded
        return loaded
    }

    /// Quits once nothing was asked for a while: the next dictation starts
    /// a helper again, and loads its models again.
    private func waitIdle() {
        idle?.cancel()
        idle = Task {
            guard (try? await Task.sleep(for: Self.idleLimit)) != nil else { return }
            exit(0)
        }
    }

    /// The error's own sentence when it has one, else what Swift prints.
    private static func describe(_ error: any Error) -> String {
        if let text = (error as? LocalizedError)?.errorDescription { return text }
        if let text = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String { return text }
        return String(describing: error)
    }

    enum HelperError: LocalizedError {
        case nothingToHear

        var errorDescription: String? {
            switch self {
            case .nothingToHear: "Nothing came to transcribe."
            }
        }
    }
}

private extension Duration {
    nonisolated var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
