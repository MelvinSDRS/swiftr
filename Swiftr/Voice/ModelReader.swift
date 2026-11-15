import AVFoundation
import Foundation
import HerdrKit

/// Reads aloud with a downloaded voice model: the voice helper (this same
/// program, started with `VoiceHelper.flag`) makes the sound, piece by
/// piece, and this plays it as it comes, at the speed chosen in Settings.
@MainActor
final class ModelReader {
    static let shared = ModelReader()

    private var helper: Process?
    private var input: FileHandle?
    private var jobs = 0
    /// The reading under way: its job, what to call when it ends (with an
    /// error when the model couldn't read), and where its measures go.
    private var current: Reading?
    /// Models being prepared, by job.
    private var preparing: [Int: CheckedContinuation<Void, any Error>] = [:]
    private let player = StreamPlayer()
    /// What earlier readings measured, as the next one's first guesses:
    /// how fast each model makes sound at each speed, and how long each
    /// voice takes per character.
    private var rates: [String: Double] = [:]
    private var secondsPerCharacter: [String: Double] = [:]

    private struct Reading {
        let job: Int
        let end: (_ error: String?, _ heard: Bool) -> Void
        let gain: Float
        let rateKey: String
        let voiceKey: String
        var heard = false
    }

    #if DEBUG
    /// Seconds of sound received for the reading under way, for tests.
    private(set) var debugSeconds = 0.0
    /// The silences of the last reading and what it measured, for tests.
    var debugPace: [String: Any] { player.debugPace }
    #endif

    /// Reads `chunks` in `voice`, then calls `end`: with no error once all
    /// was heard, else with what went wrong and whether any sound came.
    /// Not called when stopped.
    func read(_ chunks: [String], voice: ModelVoice, model: VoiceModel, speed: Double, quiet: Bool, end: @escaping (_ error: String?, _ heard: Bool) -> Void) {
        stop()
        jobs += 1
        let job = jobs
        let rateKey = "\(model.id)@\(speed)"
        current = Reading(job: job, end: end, gain: Float(pow(10, voice.gain / 20)), rateKey: rateKey, voiceKey: voice.key)
        #if DEBUG
        debugSeconds = 0
        #endif
        // Until the reading measures its own, the model is guessed a little
        // slower than the sound plays: the first line waits a bit more.
        let pace = SpeechPace(lengths: chunks.map(\.count), speed: speed, rate: rates[rateKey] ?? 1.2,
                              secondsPerCharacter: secondsPerCharacter[voice.key] ?? SpeechPace.firstSecondsPerCharacter)
        player.begin(speed: speed, quiet: quiet, pace: pace)
        let lines = chunks.map { VoiceRequest.Line(text: $0, voice: voice.id, language: voice.hint) }
        do {
            try send(VoiceRequest(op: .say, job: job, model: VoiceLibrary.folder(model).path, lines: lines, speed: speed,
                                  cleaned: SpeechWords.languages.contains(voice.language)))
        } catch {
            finish(job, error: error.localizedDescription)
        }
    }

    /// Stops the reading under way, without calling its `end`.
    func stop() {
        guard let reading = current else { return }
        current = nil
        player.stop()
        try? send(VoiceRequest(op: .stop, job: reading.job))
    }

    /// Loads `model` and says a few words in each of `voices`, sound off:
    /// fetches what the model needs besides its own files.
    func prepare(_ model: VoiceModel, voices: [ModelVoice]) async throws {
        jobs += 1
        let job = jobs
        let lines = voices.map { VoiceRequest.Line(text: Self.warmUp($0.language), voice: $0.id, language: $0.hint) }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            preparing[job] = done
            do {
                try send(VoiceRequest(op: .prepare, job: job, model: VoiceLibrary.folder(model).path, lines: lines))
            } catch {
                preparing[job] = nil
                done.resume(throwing: error)
            }
        }
    }

    /// Quits the helper, giving its model's memory back: before a model is
    /// deleted.
    func quitHelper() {
        stop()
        try? input?.close()
        input = nil
        helper?.terminate()
        helper = nil
    }

    private static func warmUp(_ language: String) -> String {
        switch language {
        case "fr": "Bonjour."
        case "es": "Hola."
        case "de": "Hallo."
        case "it": "Ciao."
        case "pt": "Olá."
        case "nl": "Hallo."
        default: "Hello."
        }
    }

    // MARK: The helper

    private func send(_ request: VoiceRequest) throws {
        try startHelper()
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        guard let input else { throw ReaderError.helperGone }
        try input.write(contentsOf: data)
    }

    private func startHelper() throws {
        if let helper, helper.isRunning, input != nil { return }
        let process = Process()
        guard let program = Bundle.main.executableURL else { throw ReaderError.helperGone }
        process.executableURL = program
        process.arguments = [VoiceHelper.flag]
        var environment = ProcessInfo.processInfo.environment
        environment[VoiceHelper.cacheVariable] = VoiceLibrary.hubFolder.path
        process.environment = environment
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
    /// thread in order. An old helper's answers name old jobs, which
    /// `received` drops.
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
                guard let event = try? decoder.decode(VoiceEvent.self, from: line) else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { ModelReader.shared.received(event) } }
            }
        }
    }

    private func received(_ event: VoiceEvent) {
        if let done = preparing.removeValue(forKey: event.job) {
            if let error = event.error {
                done.resume(throwing: ReaderError.model(error))
            } else if event.done == true {
                done.resume()
            } else {
                preparing[event.job] = done
            }
            return
        }
        guard let reading = current, reading.job == event.job else { return }
        if let audio = event.audio, let rate = event.rate {
            #if DEBUG
            debugSeconds += Double(audio.count / MemoryLayout<Float>.size) / Double(rate)
            #endif
            current?.heard = true
            player.play(audio, rate: rate, gain: reading.gain, line: event.line ?? 0)
        }
        if let error = event.error {
            finish(event.job, error: error)
        } else if event.done == true {
            player.finish { [weak self] in self?.finish(event.job, error: nil) }
            // All made: what it measured guides the next reading.
            if let rate = player.pace.measuredRate { rates[reading.rateKey] = rate }
            if let seconds = player.pace.measuredSecondsPerCharacter { secondsPerCharacter[reading.voiceKey] = seconds }
        }
    }

    private func finish(_ job: Int, error: String?) {
        guard let reading = current, reading.job == job else { return }
        current = nil
        player.stop()
        reading.end(error, reading.heard)
    }

    private func helperQuit(_ process: Process) {
        guard process === helper else { return }
        helper = nil
        input = nil
        for (_, done) in preparing { done.resume(throwing: ReaderError.helperGone) }
        preparing = [:]
        if let reading = current {
            // It quit mid-reading: it crashed, or the model ran out of memory.
            finish(reading.job, error: ReaderError.helperGone.localizedDescription)
        }
    }

    /// The helper's standard error, kept for the last run only.
    private static func logHandle() -> FileHandle? {
        let folder = URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Swiftr", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appending(path: "voice-helper.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        return try? FileHandle(forWritingTo: log)
    }

    enum ReaderError: LocalizedError {
        case helperGone
        case model(String)

        var errorDescription: String? {
            switch self {
            case .helperGone: "The voice model stopped."
            case .model(let message): message
            }
        }
    }
}

/// Plays sound as it comes, at the chosen speed without changing the pitch.
/// Each line starts once `SpeechPace` says it can play through: a model
/// slower than the sound plays pauses between lines, not in a word.
@MainActor
private final class StreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private var format: AVAudioFormat?
    /// The reading's lines and what the model made of them.
    private(set) var pace = SpeechPace(lengths: [], speed: 1, rate: 1, secondsPerCharacter: SpeechPace.firstSecondsPerCharacter)
    /// The line playing, or the next to start.
    private var line = 0
    /// Whether `line` started: its sound goes to the node as it comes,
    /// unless `holding` it after the model fell behind in its middle.
    private var lineStarted = false
    private var holding = false
    /// Sound of the lines not started yet.
    private var waiting: [Int: [AVAudioPCMBuffer]] = [:]
    /// Pieces handed to the node and not heard yet, and the line of the last.
    private var scheduled = 0
    private var lastLine = -1
    private var started = false
    private var drained: (() -> Void)?
    /// Grows at each stop, so pieces of a stopped reading don't count.
    private var generation = 0
    private var idle: DispatchWorkItem?
    /// When the node ran out of sound, and whether in the middle of a line.
    private var ranOut: (time: Double, inLine: Bool)?
    #if DEBUG
    private var gaps: [Double] = []
    private var pauses: [Double] = []
    private var firstSound: Double?
    private var begun = 0.0
    #endif
    /// Above it, peaks bend towards full scale instead of clipping.
    private static let knee: Float = 0.8

    init() {
        engine.attach(node)
        engine.attach(pitch)
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    func begin(speed: Double, quiet: Bool, pace: SpeechPace) {
        stop()
        idle?.cancel()
        self.pace = pace
        pitch.rate = Float(speed)
        node.volume = quiet ? 0 : 1
        #if DEBUG
        gaps = []
        pauses = []
        firstSound = nil
        begun = Self.now
        #endif
    }

    /// Plays `audio` (mono 32-bit floats) of `line` louder by `gain`, its
    /// peaks rounded off rather than clipped.
    func play(_ audio: Data, rate: Int, gain: Float, line pieceLine: Int) {
        let frames = audio.count / MemoryLayout<Float>.size
        guard frames > 0 else { return }
        if format?.sampleRate != Double(rate) { connect(rate: rate) }
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        audio.withUnsafeBytes { raw in
            for i in 0 ..< frames {
                let x = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<Float>.size, as: Float.self) * gain
                let size = abs(x)
                channel[i] = size <= Self.knee ? x : copysign(Self.knee + (1 - Self.knee) * tanh((size - Self.knee) / (1 - Self.knee)), x)
            }
        }
        pace.add(Double(frames) / Double(rate), line: pieceLine, at: Self.now)
        if pieceLine == line, lineStarted, !holding {
            schedule(buffer)
        } else {
            waiting[pieceLine, default: []].append(buffer)
        }
        advance()
    }

    /// The model made everything: calls `then` once all of it was heard.
    func finish(then: @escaping () -> Void) {
        drained = then
        pace.finishAll()
        advance()
        if line >= pace.lengths.count, scheduled == 0 { drain() }
    }

    func stop() {
        generation += 1
        if started || scheduled > 0 { node.stop() }
        scheduled = 0
        waiting = [:]
        line = 0
        lineStarted = false
        holding = false
        lastLine = -1
        ranOut = nil
        started = false
        drained = nil
        // The sound hardware goes back a moment later, unless a reading starts.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.started else { return }
            self.engine.stop()
        }
        idle?.cancel()
        idle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Starts the lines that may start, the next one as soon as the model
    /// finished the one before, and plays on a held line once it may.
    private func advance() {
        let now = Self.now
        while line < pace.lengths.count {
            if !lineStarted || holding {
                let ready = (waiting[line] ?? []).reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
                guard pace.mayPlay(line, ready: ready, resuming: holding, at: now) else { return }
                lineStarted = true
                holding = false
                for buffer in waiting.removeValue(forKey: line) ?? [] { schedule(buffer) }
            }
            guard line < pace.finished else { return }
            line += 1
            lineStarted = false
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        #if DEBUG
        if let ranOut {
            if ranOut.inLine { gaps.append(Self.now - ranOut.time) } else { pauses.append(Self.now - ranOut.time) }
        }
        if firstSound == nil { firstSound = Self.now - begun }
        #endif
        ranOut = nil
        scheduled += 1
        lastLine = line
        let generation = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.played(generation) } }
        }
        if !started { start() }
    }

    private func played(_ generation: Int) {
        guard generation == self.generation else { return }
        scheduled -= 1
        guard scheduled == 0 else { return }
        if line >= pace.lengths.count {
            drain()
        } else {
            // Out of sound: between two lines, or in the middle of one the
            // model is still making, which waits until it can play through.
            ranOut = (Self.now, lastLine == line)
            if lastLine == line { holding = true }
        }
    }

    private func drain() {
        guard let drained else { return }
        self.drained = nil
        drained()
    }

    private func start() {
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { return }
        }
        node.play()
        started = true
    }

    private func connect(rate: Int) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1) else { return }
        if started { node.stop() }
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(pitch)
        engine.connect(node, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        self.format = format
        started = false
    }

    #if DEBUG
    var debugPace: [String: Any] {
        ["gaps": gaps, "pauses": pauses, "firstSound": firstSound ?? -1,
         "rate": pace.measuredRate ?? -1, "secondsPerCharacter": pace.measuredSecondsPerCharacter ?? -1,
         "lines": pace.lengths.count, "made": pace.made]
    }
    #endif
}
