import Testing
@testable import HerdrKit

/// When a voice model's lines start playing.
@Suite struct SpeechPaceTests {
    typealias Piece = (time: Double, seconds: Double, line: Int)

    /// A model making `rate` seconds of sound per second, in pieces of
    /// 0.64 s, after `prefill` seconds at the start of each line.
    static func pieces(lines: [Double], rate: Double, prefill: Double = 0.3) -> [Piece] {
        var out: [Piece] = []
        var time = 0.0
        for (line, duration) in lines.enumerated() {
            time += prefill
            var left = duration
            while left > 0.001 {
                let seconds = min(0.64, left)
                time += seconds / rate
                out.append((time, seconds, line))
                left -= seconds
            }
        }
        return out
    }

    /// Plays `pieces` as ModelReader's player does: a line's sound goes out
    /// once it may start, the next line's once this one is made and it may
    /// start. Returns when the first sound came, and the silences in the
    /// middle of a line and between lines.
    static func play(_ pieces: [Piece], lengths: [Int], speed: Double, rate: Double = 1.2) -> (first: Double, gaps: [Double], gapLines: [Int], pauses: [Double]) {
        var pace = SpeechPace(lengths: lengths, speed: speed, rate: rate, secondsPerCharacter: SpeechPace.firstSecondsPerCharacter)
        var waiting: [Int: [Double]] = [:]
        var line = 0
        var started = false
        var holding = false
        var first: Double?
        var end: Double?
        var lastLine = -1
        var gaps: [Double] = []
        var gapLines: [Int] = []
        var pauses: [Double] = []
        func handOut(_ seconds: Double, of piece: Int, at time: Double) {
            if let end, end < time - 0.001 {
                if piece == lastLine {
                    gaps.append(time - end)
                    gapLines.append(piece)
                } else {
                    pauses.append(time - end)
                }
            }
            if first == nil { first = time }
            end = max(end ?? time, time) + seconds / speed
            lastLine = piece
        }
        func advance(at time: Double) {
            while line < lengths.count {
                if !started || holding {
                    let ready = (waiting[line] ?? []).reduce(0, +)
                    guard pace.mayPlay(line, ready: ready, resuming: holding, at: time) else { return }
                    started = true
                    holding = false
                    for seconds in waiting.removeValue(forKey: line) ?? [] { handOut(seconds, of: line, at: time) }
                }
                guard line < pace.finished else { return }
                line += 1
                started = false
            }
        }
        for piece in pieces {
            // The player sees it ran out in the middle of a line when its
            // last sound ends, and holds the line.
            if let end, end < piece.time, started, lastLine == line { holding = true }
            pace.add(piece.seconds, line: piece.line, at: piece.time)
            if piece.line == line, started, !holding {
                handOut(piece.seconds, of: piece.line, at: piece.time)
            } else {
                waiting[piece.line, default: []].append(piece.seconds)
            }
            advance(at: piece.time)
        }
        pace.finishAll()
        advance(at: pieces.last?.time ?? 0)
        return (first ?? 0, gaps, gapLines, pauses)
    }

    /// Three lines as SpeechChunks cuts an agent's message, and how long
    /// Voxtral's French voice reads them (0.054 s a character).
    static let lengths = [78, 186, 136]
    static let durations = lengths.map { Double($0) * 0.054 }

    @Test func aModelFasterThanPlaybackPlaysWithoutSilence() {
        let pieces = Self.pieces(lines: Self.durations, rate: 1.9)
        for speed in [1.0, 1.25, 1.5] {
            // As fast as the last reading measured it: half a second of
            // sound is enough to start.
            let result = Self.play(pieces, lengths: Self.lengths, speed: speed, rate: 1.9)
            #expect(result.gaps.isEmpty, "speed \(speed)")
            #expect(result.pauses.isEmpty, "speed \(speed)")
            #expect(result.first < 1.2, "speed \(speed): \(result.first)")
            // The very first reading guesses a slower model: it may start
            // later, never with a silence inside a line.
            #expect(Self.play(pieces, lengths: Self.lengths, speed: speed).gaps.isEmpty, "speed \(speed)")
        }
    }

    /// Voxtral with 8 steps on an M3 Pro makes 1.32 s of sound a second:
    /// at 1.5× and 2×, the old player cut in the middle of words. Now
    /// lines wait, and play through.
    @Test func aSlowerModelPausesBetweenLinesNeverWithin() {
        for speed in [1.5, 1.75, 2.0] {
            let result = Self.play(Self.pieces(lines: Self.durations, rate: 1.32), lengths: Self.lengths, speed: speed)
            #expect(result.gaps.isEmpty, "speed \(speed): \(result.gaps)")
            #expect(!result.pauses.isEmpty, "speed \(speed)")
        }
    }

    @Test func aGuessTooHighCutsOnlyTheFirstLine() {
        // The last reading went faster (a quieter Mac): the first line
        // starts too soon, then the measure takes over after a second.
        let result = Self.play(Self.pieces(lines: Self.durations, rate: 1.32), lengths: Self.lengths, speed: 1.5, rate: 1.9)
        #expect(result.gapLines.allSatisfy { $0 == 0 }, "\(result.gapLines)")
        #expect(result.gaps.count <= 3, "\(result.gaps)")
        #expect(!result.pauses.isEmpty)
    }

    /// A busy Mac stops the model for 6 s in the middle of a line: one
    /// pause there, then the rest of the line plays through.
    @Test func aModelThatStallsPausesOnceThenPlaysThrough() {
        var pieces = Self.pieces(lines: Self.durations, rate: 1.4)
        let stall = pieces.firstIndex { $0.line == 1 }! + 5
        for i in stall ..< pieces.count { pieces[i].time += 6 }
        // The model was fast at first: the line had started at once.
        let result = Self.play(pieces, lengths: Self.lengths, speed: 1, rate: 1.4)
        #expect(result.gaps.count == 1, "\(result.gaps)")
        #expect(result.pauses.isEmpty)
    }

    @Test func theFirstLineWaitsForHalfASecondOfSound() {
        var pace = SpeechPace(lengths: [100, 100], speed: 1, rate: 2, secondsPerCharacter: 0.06)
        pace.add(0.4, line: 0, at: 0.5)
        #expect(!pace.mayStart(0, at: 0.5))
        pace.add(0.64, line: 0, at: 0.8)
        #expect(pace.mayStart(0, at: 0.8))
        // A later line of a fast model starts before any of it is made.
        #expect(pace.mayStart(1, at: 0.8))
    }

    @Test func aFinishedLineMayAlwaysStart() {
        var pace = SpeechPace(lengths: [300, 300], speed: 2, rate: 0.5, secondsPerCharacter: 0.06)
        pace.add(0.2, line: 0, at: 1)
        #expect(!pace.mayStart(0, at: 1))
        pace.add(0.2, line: 1, at: 2)
        #expect(pace.mayStart(0, at: 2))
        #expect(!pace.mayStart(1, at: 2))
        pace.finishAll()
        #expect(pace.mayStart(1, at: 2))
    }

    @Test func itMeasuresTheModelAndTheVoice() {
        var pace = SpeechPace(lengths: [50, 50], speed: 1, rate: 1, secondsPerCharacter: 0.06)
        #expect(pace.measuredRate == nil)
        // 0.64 s pieces every 0.5 s: 1.28 s of sound a second.
        for i in 0 ..< 5 { pace.add(0.64, line: 0, at: 1 + Double(i) * 0.5) }
        #expect(abs((pace.measuredRate ?? 0) - 1.28) < 0.001)
        #expect(abs(pace.rate(at: 3) - 1.28) < 0.001)
        #expect(pace.measuredSecondsPerCharacter == nil)
        pace.add(0.64, line: 1, at: 3.5)
        #expect(abs((pace.measuredSecondsPerCharacter ?? 0) - 3.2 / 50) < 0.001)
    }
}
