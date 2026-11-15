import Foundation

/// When each line a voice model reads may start playing. A model that makes
/// sound more slowly than it plays at the chosen speed would run out in the
/// middle of a word; instead a line waits until enough of it is made to
/// play through, so the silences fall between lines.
///
/// Times are seconds on any one clock; sound is counted in seconds at the
/// voice's own speed.
public struct SpeechPace: Sendable {
    /// Characters in each line, in order.
    public let lengths: [Int]
    /// How fast the sound plays: 1 at the voice's own speed.
    public let speed: Double
    /// Sound always waited for before the first line plays.
    public static let lead = 0.5
    /// Sound waited for on top of what a slow model needs: pieces come
    /// unevenly.
    public static let margin = 0.5
    /// The share of the measured speed relied on.
    static let safety = 0.9
    /// A guess for a voice not heard yet: about what Voxtral takes in
    /// French and English, a little more.
    public static let firstSecondsPerCharacter = 0.06

    /// Seconds of sound made for each line.
    public private(set) var made: [Double]
    /// Lines the model finished: every line before this one.
    public private(set) var finished = 0
    private let guessRate: Double
    private let guessSecondsPerCharacter: Double
    private var first: (time: Double, seconds: Double)?
    private var last = 0.0
    private var total = 0.0

    /// `rate` and `secondsPerCharacter` are guesses, from an earlier
    /// reading, until this one measures its own.
    public init(lengths: [Int], speed: Double, rate: Double, secondsPerCharacter: Double) {
        self.lengths = lengths
        self.speed = speed
        guessRate = rate
        guessSecondsPerCharacter = secondsPerCharacter
        made = Array(repeating: 0, count: lengths.count)
    }

    /// Counts `seconds` of sound the model made for `line` at `time`. The
    /// model reads in order, so the lines before are finished.
    public mutating func add(_ seconds: Double, line: Int, at time: Double) {
        guard made.indices.contains(line) else { return }
        if first == nil { first = (time, seconds) }
        last = time
        total += seconds
        made[line] += seconds
        finished = max(finished, line)
    }

    /// The model made every line.
    public mutating func finishAll() {
        finished = lengths.count
    }

    /// Seconds of sound the model makes per second, measured from its first
    /// piece once a second went by, else the guess.
    public func rate(at time: Double) -> Double {
        guard let first, time - first.time >= 1 else { return guessRate }
        return (total - first.seconds) / (time - first.time)
    }

    /// The rate measured up to the last piece, for the next reading's guess.
    public var measuredRate: Double? {
        guard let first, last - first.time >= 1 else { return nil }
        return (total - first.seconds) / (last - first.time)
    }

    /// Seconds of sound per character, measured on the finished lines once
    /// they hold a few words.
    public var measuredSecondsPerCharacter: Double? {
        let characters = lengths.prefix(finished).reduce(0, +)
        guard characters >= 40 else { return nil }
        return made.prefix(finished).reduce(0, +) / Double(characters)
    }

    /// Whether `line` may start playing at `time`: the model finished it, or
    /// made enough of it that playing it through won't catch up with the
    /// model.
    public func mayStart(_ line: Int, at time: Double) -> Bool {
        guard made.indices.contains(line) else { return true }
        return mayPlay(line, ready: made[line], resuming: false, at: time)
    }

    /// Whether `line` may play on from silence with `ready` seconds of it
    /// waiting: when it starts, or `resuming` after the model fell behind
    /// in its middle (a busy Mac). Yes once the model finished it, or once
    /// what's ready lasts until the model makes the rest: one pause rather
    /// than a cut at every piece.
    public func mayPlay(_ line: Int, ready: Double, resuming: Bool, at time: Double) -> Bool {
        guard made.indices.contains(line), line >= finished else { return true }
        let rate = rate(at: time) * Self.safety
        var needed = line == 0 || resuming ? Self.lead : 0
        if speed > rate {
            let expected = Double(lengths[line]) * (measuredSecondsPerCharacter ?? guessSecondsPerCharacter)
            let left = max(0, expected - made[line])
            needed = max(needed, left * (speed / max(rate, 0.01) - 1) + Self.margin)
        }
        return ready >= needed
    }
}
