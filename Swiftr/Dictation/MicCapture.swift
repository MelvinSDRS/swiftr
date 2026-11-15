import AVFoundation

/// The microphone's sound while dictating, as the speech model takes it:
/// mono samples at 16 kHz, with its loudness for the meter.
@MainActor
final class MicCapture {
    nonisolated static let rate = 16_000.0
    private nonisolated static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    private var engine: AVAudioEngine?
    private let store = SampleStore()

    /// Starts listening; `level` hears the loudness, 0 to 1, about twenty
    /// times a second.
    func start(level: @escaping @MainActor (Float) -> Void) throws {
        stopEngine()
        store.reset()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.format) else { throw MicError.noMicrophone }
        converter.downmix = true
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat, block: Self.tap(converter, store, level))
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops listening and gives what was heard.
    func stop() -> [Float] {
        stopEngine()
        return store.take()
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// What the microphone's buffers go to, on the audio thread: made
    /// outside the main actor, which the audio thread isn't on.
    private nonisolated static func tap(_ converter: AVAudioConverter, _ store: SampleStore,
                                        _ level: @escaping @MainActor (Float) -> Void) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let converter = converter
        return { buffer, _ in
            guard let samples = convert(buffer, with: converter) else { return }
            if let loudness = store.append(samples) {
                DispatchQueue.main.async { MainActor.assumeIsolated { level(loudness) } }
            }
        }
    }

    /// `buffer` at 16 kHz, mono.
    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float]? {
        let ratio = rate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    /// The samples of an audio file, as the speech model takes them: for
    /// tests, which dictate recordings.
    nonisolated static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { throw MicError.unreadable }
        try file.read(into: buffer)
        converter.downmix = true
        guard let samples = convert(buffer, with: converter) else { throw MicError.unreadable }
        return samples
    }

    enum MicError: LocalizedError {
        case noMicrophone
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noMicrophone: "This Mac has no microphone to listen with."
            case .unreadable: "The recording couldn't be read."
            }
        }
    }
}

/// The samples heard so far, filled on the audio thread.
private nonisolated final class SampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sinceLevel = 0
    private var sum: Float = 0

    func reset() {
        lock.withLock {
            samples = []
            sinceLevel = 0
            sum = 0
        }
    }

    /// Adds `more`; once a thirtieth of a second has come, returns its
    /// loudness: about once a buffer, twenty-odd times a second.
    func append(_ more: [Float]) -> Float? {
        lock.withLock {
            samples += more
            for s in more { sum += s * s }
            sinceLevel += more.count
            guard sinceLevel >= Int(MicCapture.rate) / 30 else { return nil }
            let rms = (sum / Float(sinceLevel)).squareRoot()
            sinceLevel = 0
            sum = 0
            // Speech sits around -30 dB: from -55 dB to -15 dB on the meter.
            let db = 20 * log10(max(rms, 1e-6))
            return min(1, max(0, (db + 55) / 40))
        }
    }

    func take() -> [Float] {
        lock.withLock {
            defer { samples = [] }
            return samples
        }
    }
}
