import Testing
@testable import HerdrKit

/// The pieces a voice model reads in one go.
@Suite struct SpeechChunksTests {
    @Test func sentencesSplitAtStopsBeforeACapital() {
        #expect(SpeechChunks.sentences("Bonjour. Ça va ? Oui!\nFin… 2 tests.") == ["Bonjour.", "Ça va ?", "Oui!", "Fin…", "2 tests."])
        // Not after a stop inside a word or before lower case.
        #expect(SpeechChunks.sentences("Voir README.md et e.g. ceci.") == ["Voir README.md et e.g. ceci."])
    }

    @Test func theFirstPieceIsShortTheNextOnesLonger() {
        let text = (1 ... 12).map { "Phrase numéro \($0) de ce texte." }.joined(separator: "\n")
        let chunks = SpeechChunks.make(text, first: 60, limit: 120)
        #expect(chunks.first == "Phrase numéro 1 de ce texte. Phrase numéro 2 de ce texte.")
        #expect(chunks.dropFirst().allSatisfy { $0.count <= 120 })
        #expect(chunks.count > 2)
        // Nothing lost or added.
        #expect(chunks.joined(separator: " ") == (1 ... 12).map { "Phrase numéro \($0) de ce texte." }.joined(separator: " "))
    }

    @Test func aLongSentenceIsCutAtACommaElseASpace() {
        let long = "un, deux trois, quatre cinq six"
        #expect(SpeechChunks.cut(long, limit: 16) == ["un, deux trois,", "quatre cinq six"])
        #expect(SpeechChunks.cut("abcdef ghijkl mnopqr", limit: 10) == ["abcdef", "ghijkl", "mnopqr"])
        // A word longer than the limit is cut where it ends up.
        #expect(SpeechChunks.cut("abcdefghijkl", limit: 5) == ["abcde", "fghij", "kl"])
    }

    @Test func emptyTextHasNoPieces() {
        #expect(SpeechChunks.make("") == [])
        #expect(SpeechChunks.make("\n \n") == [])
    }
}
