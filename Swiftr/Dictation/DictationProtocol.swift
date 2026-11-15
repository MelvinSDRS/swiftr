import Foundation

/// What Swiftr asks of its dictation helper (`DictationHelper`), a line of
/// JSON on the helper's standard input.
nonisolated struct DictationRequest: Codable, Sendable {
    enum Op: String, Codable, Sendable {
        /// Load the models named, so the next dictation starts at once;
        /// the first time, it readies them for the Neural Engine.
        case prepare
        /// Turn `audio` into text.
        case transcribe
    }

    var op: Op
    var job: Int
    /// The folders of the models to use: speech's, and those of the passes
    /// asked for.
    var speech: String?
    var vocabularyModel: String?
    var tidyModel: String?
    /// The sound, as mono 32-bit float samples at 16 kHz.
    var audio: Data?
    /// Names to write as they're spelled (`DictationVocabulary`).
    var terms: [String]?
}

/// What the helper answers, a line of JSON on its standard output.
nonisolated struct DictationEvent: Codable, Sendable {
    var job: Int
    /// What the speech model wrote, for tests and the log.
    var raw: String?
    /// The text as heard, after the vocabulary pass, without "um"s.
    var heard: String?
    /// The text to insert: tidied up when asked, else as heard.
    var text: String?
    /// How the tidy-up went, for tests and the log: "kept", "late",
    /// "changed too much: " and what the model wrote, or "off".
    var tidy: String?
    /// Milliseconds each step took, by name.
    var timings: [String: Double]?
    /// The job is over.
    var done: Bool?
    var error: String?

    init(job: Int, raw: String? = nil, heard: String? = nil, text: String? = nil, tidy: String? = nil, timings: [String: Double]? = nil,
         done: Bool? = nil, error: String? = nil) {
        self.job = job
        self.raw = raw
        self.heard = heard
        self.text = text
        self.tidy = tidy
        self.timings = timings
        self.done = done
        self.error = error
    }
}
