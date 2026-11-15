import Foundation

/// What Swiftr asks of its voice helper (`VoiceHelper`), a line of JSON on
/// the helper's standard input.
nonisolated struct VoiceRequest: Codable, Sendable {
    enum Op: String, Codable, Sendable {
        /// Read `lines` aloud, in order, as job `job`.
        case say
        /// Stop job `job`.
        case stop
        /// Load the model and say each of `lines` without sending the sound:
        /// fetches what the model needs besides its own files, and readies it.
        case prepare
    }

    struct Line: Codable, Sendable {
        var text: String
        var voice: String
        var language: String?
    }

    var op: Op
    var job: Int
    /// The model's folder.
    var model: String = ""
    var lines: [Line] = []
    /// How fast the sound will play: a model may then make it faster, at
    /// some cost in quality.
    var speed: Double?
    /// Swiftr wrote the lines' signs and units as words of their language
    /// (`SpeechWords`): the model's own cleanup, English in Voxtral's case,
    /// stays off.
    var cleaned: Bool?
}

/// What the helper answers, a line of JSON on its standard output.
nonisolated struct VoiceEvent: Codable, Sendable {
    var job: Int
    /// Sound, as mono 32-bit float samples at `rate` per second.
    var audio: Data?
    var rate: Int?
    /// The line of the request the sound belongs to.
    var line: Int?
    /// The job is over: every sound of it was sent.
    var done: Bool?
    var error: String?

    init(job: Int, audio: Data? = nil, rate: Int? = nil, line: Int? = nil, done: Bool? = nil, error: String? = nil) {
        self.job = job
        self.audio = audio
        self.rate = rate
        self.line = line
        self.done = done
        self.error = error
    }
}
