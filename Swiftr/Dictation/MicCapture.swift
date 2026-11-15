import AVFoundation
import QuartzCore

/// The microphone's sound while dictating, as the speech model takes it:
/// mono samples at 16 kHz, with its loudness for the meter.
@MainActor
final class MicCapture {
    nonisolated static let rate = 16_000.0
    /// The meter hears each fiftieth of a second: this many samples.
    nonisolated static let moment = 320
    private nonisolated static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    private var engine: AVAudioEngine?
    private let store = SampleStore()

    /// Starts listening; `heard` gets the loudness of each fiftieth of a
    /// second, 0 to 1, and when the last of them ended, on Core Animation's
    /// clock. They come in bunches, as macOS gives the sound: a tenth of a
    /// second at a time, however small a buffer is asked for.
    func start(heard: @escaping @MainActor (_ levels: [Float], _ end: CFTimeInterval) -> Void) throws {
        stopEngine()
        store.reset()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.format) else { throw MicError.noMicrophone }
        converter.downmix = true
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat, block: Self.tap(converter, store, heard))
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
                                        _ heard: @escaping @MainActor ([Float], CFTimeInterval) -> Void) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let converter = converter
        return { buffer, when in
            // When the buffer's last sound came in.
            let now = CACurrentMediaTime()
            var end = now
            if when.isHostTimeValid {
                let told = AVAudioTime.seconds(forHostTime: when.hostTime) + Double(buffer.frameLength) / buffer.format.sampleRate
                if abs(told - now) < 1 { end = told }
            }
            guard let samples = convert(buffer, with: converter) else { return }
            let (levels, left) = store.append(samples)
            guard !levels.isEmpty else { return }
            let last = end - Double(left) / rate
            DispatchQueue.main.async { MainActor.assumeIsolated { heard(levels, last) } }
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
    /// The samples since the last fiftieth of a second ended, and their
    /// squares added up.
    private var count = 0
    private var sum: Float = 0

    func reset() {
        lock.withLock {
            samples = []
            count = 0
            sum = 0
        }
    }

    /// Adds `more`, and gives the loudness of each fiftieth of a second it
    /// ends, and how many samples came after the last.
    func append(_ more: [Float]) -> (levels: [Float], left: Int) {
        lock.withLock {
            samples += more
            var levels: [Float] = []
            for s in more {
                sum += s * s
                count += 1
                guard count == MicCapture.moment else { continue }
                // Speech sits around -30 dB: from -55 dB to -15 dB on the meter.
                let db = 10 * log10(max(sum / Float(count), 1e-12))
                levels.append(min(1, max(0, (db + 55) / 40)))
                count = 0
                sum = 0
            }
            return (levels, count)
        }
    }

    func take() -> [Float] {
        lock.withLock {
            defer { samples = [] }
            return samples
        }
    }
}
