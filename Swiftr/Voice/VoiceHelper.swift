import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS

/// Swiftr's voice helper: this same program started with `--voice-helper`,
/// reading aloud with a voice model in a process of its own, so the model's
/// memory goes back when it quits and its crash can't take Swiftr along.
/// Requests come in on standard input and answers go out on standard
/// output, a line of JSON each (`VoiceRequest`, `VoiceEvent`). It quits
/// when Swiftr closes its input, or after a few idle minutes.
nonisolated enum VoiceHelper {
    static let flag = "--voice-helper"
    /// Where the models' other downloads go (dictionaries, codecs), which
    /// `VoiceLibrary` sets for the helper.
    static let cacheVariable = "HF_HUB_CACHE"

    static func run() -> Never {
        // Answers go out on a copy of standard output; what the models
        // print goes to standard error, where it can't garble them.
        let out = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        Memory.cacheLimit = 256 * 1024 * 1024
        let speaker = HelperSpeaker(answers: Answers(fd: out))
        Task.detached {
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    guard let request = try? JSONDecoder().decode(VoiceRequest.self, from: Data(line.utf8)) else { continue }
                    await speaker.handle(request)
                }
            } catch {}
            // Swiftr closed the pipe: it quit, or crashed.
            exit(0)
        }
        dispatchMain()
    }
}

/// Writes answers whole, one at a time.
private nonisolated final class Answers: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(fd: Int32) {
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func send(_ event: VoiceEvent) {
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0A)
        lock.withLock { try? handle.write(contentsOf: data) }
    }
}

/// Runs one job at a time with one model loaded, the last one asked for.
private actor HelperSpeaker {
    private let answers: Answers
    private var model: (any SpeechGenerationModel)?
    private var modelFolder = ""
    private var current: (job: Int, task: Task<Void, Never>)?
    /// A stopped job's model may run a moment longer: the next waits.
    private var quietUntil = ContinuousClock.now
    private var idle: Task<Void, Never>?
    private static let idleLimit = Duration.seconds(300)

    init(answers: Answers) {
        self.answers = answers
    }

    func handle(_ request: VoiceRequest) {
        idle?.cancel()
        switch request.op {
        case .stop:
            if current?.job == request.job { stopCurrent() }
            waitIdle()
        case .say, .prepare:
            let previous = current?.task
            if current != nil { stopCurrent() }
            let task = Task { [weak self] in
                await previous?.value
                await self?.run(request)
            }
            current = (request.job, task)
        }
    }

    private func stopCurrent() {
        current?.task.cancel()
        current = nil
        quietUntil = .now + .milliseconds(300)
    }

    private func run(_ request: VoiceRequest) async {
        do {
            try await Task.sleep(until: quietUntil)
            let model = try await load(request.model)
            if let voxtral = model as? VoxtralTTSModel {
                voxtral.generationOptions.denoisingSteps = Self.denoisingSteps(speed: request.speed ?? 1)
                // Its cleanup writes English words: "about 40 milliseconds"
                // in a French voice.
                voxtral.generationOptions.sanitizeText = request.cleaned != true
            }
            for (index, line) in request.lines.enumerated() {
                let stream = model.generateStream(
                    text: line.text, voice: line.voice, refAudio: nil, refText: nil, language: line.language,
                    generationParameters: model.defaultGenerationParameters, streamingInterval: 0.64)
                for try await event in stream {
                    try Task.checkCancellation()
                    guard request.op == .say, case .audio(let samples) = event else { continue }
                    let floats = samples.asArray(Float.self)
                    guard !floats.isEmpty else { continue }
                    let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
                    answers.send(VoiceEvent(job: request.job, audio: data, rate: model.sampleRate, line: index))
                }
                try Task.checkCancellation()
            }
            answers.send(VoiceEvent(job: request.job, done: true))
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled {
                answers.send(VoiceEvent(job: request.job, error: Self.describe(error)))
            }
        }
        finished(request.job)
    }

    /// Voxtral refines each piece of sound in 8 steps. Fewer make it faster
    /// than the sound plays at higher speeds: on an M3 Pro it makes sound
    /// about 1.3 times as fast as it speaks with 8 steps, 1.6 with 6 and 1.9
    /// with 4, every word still right (with 3, words start to slip).
    static func denoisingSteps(speed: Double) -> Int {
        speed <= 1.2 ? 8 : speed <= 1.3 ? 6 : 4
    }

    private func finished(_ job: Int) {
        if current?.job == job { current = nil }
        waitIdle()
    }

    /// Quits once nothing was asked for a while: the next reading starts
    /// a helper again, and loads its model again.
    private func waitIdle() {
        guard current == nil else { return }
        idle?.cancel()
        idle = Task {
            guard (try? await Task.sleep(for: Self.idleLimit)) != nil else { return }
            exit(0)
        }
    }

    private func load(_ folder: String) async throws -> any SpeechGenerationModel {
        if let model, modelFolder == folder { return model }
        model = nil
        modelFolder = ""
        Memory.clearCache()
        let loaded = try await TTS.loadModel(modelRepo: folder)
        model = loaded
        modelFolder = folder
        return loaded
    }

    /// The error's own sentence when it has one, else what Swift prints.
    private static func describe(_ error: any Error) -> String {
        if let text = (error as? LocalizedError)?.errorDescription { return text }
        if let text = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String { return text }
        return String(describing: error)
    }
}
