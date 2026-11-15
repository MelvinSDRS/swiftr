import Foundation
import Testing
@testable import HerdrKit

/// The key held to dictate, and when it means a dictation.
@Suite struct DictationHoldTests {
    // Raw flags as flagsChanged events carry them.
    static let rightOption = DictationKey.option | 0x40
    static let leftOption = DictationKey.option | 0x20
    static let shift = DictationKey.shift | 0x02

    @Test func holdingRightOptionDictates() {
        var hold = DictationHold(key: .rightOption)
        #expect(hold.flagsChanged(code: 61, flags: Self.rightOption, at: 0) == .start)
        #expect(hold.held)
        #expect(hold.flagsChanged(code: 61, flags: 0, at: 2.5) == .finish)
        #expect(!hold.held)
    }

    @Test func aTapWritesNothing() {
        var hold = DictationHold(key: .rightOption)
        #expect(hold.flagsChanged(code: 61, flags: Self.rightOption, at: 10) == .start)
        #expect(hold.flagsChanged(code: 61, flags: 0, at: 10.2) == .cancel)
    }

    @Test func aShortcutWithTheKeyIsNoDictation() {
        // ⌥⇧( types `[` on a French keyboard.
        var hold = DictationHold(key: .rightOption)
        #expect(hold.flagsChanged(code: 61, flags: Self.rightOption, at: 0) == .start)
        #expect(hold.flagsChanged(code: 56, flags: Self.rightOption | Self.shift, at: 0.1) == .cancel)
        #expect(hold.flagsChanged(code: 61, flags: Self.shift, at: 0.4) == .none)
        // ⌥( alone: the key goes through, the dictation goes.
        #expect(hold.flagsChanged(code: 61, flags: Self.rightOption, at: 1) == .start)
        let (action, swallow) = hold.keyDown(code: 23, flags: DictationKey.option, isRepeat: false, at: 1.5)
        #expect(action == .cancel)
        #expect(!swallow)
    }

    @Test func theOtherSideOrAnotherModifierHeldFirstStartsNothing() {
        var hold = DictationHold(key: .rightOption)
        // Left Option is the dictation key's own flag, not its side.
        #expect(hold.flagsChanged(code: 58, flags: Self.leftOption, at: 0) == .none)
        #expect(hold.flagsChanged(code: 61, flags: Self.leftOption | 0x40, at: 0.1) == .none)
        #expect(!hold.held)
        var withShift = DictationHold(key: .rightOption)
        #expect(withShift.flagsChanged(code: 61, flags: Self.rightOption | Self.shift, at: 0) == .none)
    }

    @Test func aClickDropsIt() {
        var hold = DictationHold(key: .rightOption)
        _ = hold.flagsChanged(code: 61, flags: Self.rightOption, at: 0)
        #expect(hold.interrupted() == .cancel)
        #expect(hold.flagsChanged(code: 61, flags: 0, at: 3) == .none)
    }

    @Test func fnHasNoSideBit() {
        var hold = DictationHold(key: DictationKey(code: 63))
        #expect(hold.flagsChanged(code: 63, flags: DictationKey.function, at: 0) == .start)
        #expect(hold.flagsChanged(code: 63, flags: 0, at: 1) == .finish)
    }

    @Test func aKeyWithModifiersDictatesAndIsKept() {
        // ⌃Space
        var hold = DictationHold(key: DictationKey(code: 49, modifiers: DictationKey.control, label: "Space"))
        #expect(hold.keyDown(code: 49, flags: DictationKey.option, isRepeat: false, at: 0) == (.none, false))
        #expect(hold.keyDown(code: 49, flags: DictationKey.control | 0x01, isRepeat: false, at: 0) == (.start, true))
        #expect(hold.keyDown(code: 49, flags: DictationKey.control, isRepeat: true, at: 0.5) == (.none, true))
        // Letting go of ⌃ before Space changes nothing.
        #expect(hold.flagsChanged(code: 59, flags: 0, at: 1) == .none)
        #expect(hold.keyUp(code: 49, at: 2) == (.finish, true))
        #expect(hold.keyUp(code: 49, at: 2.1) == (.none, false))
    }

    @Test func namesAndSettings() throws {
        #expect(DictationKey.rightOption.name == "Right Option")
        #expect(DictationKey(code: 63).name == "Fn")
        #expect(DictationKey(code: 49, modifiers: DictationKey.control | DictationKey.option, label: "Space").name == "⌃⌥Space")
        let key = DictationKey(code: 96, label: "F5")
        let kept = try JSONDecoder().decode(DictationKey.self, from: JSONEncoder().encode(key))
        #expect(kept == key)
        #expect(!kept.isModifier)
    }
}

/// The words heard, before they go in the field.
@Suite struct DictationTextTests {
    @Test func fillerSoundsGo() {
        #expect(DictationText.withoutFillers("Euh, je pense que, euh, le test passe.") == "Je pense que, le test passe.")
        #expect(DictationText.withoutFillers("Alors euh je regarde hum le fichier.") == "Alors je regarde le fichier.")
        #expect(DictationText.withoutFillers("Um, can you check the build, uh?") == "Can you check the build?")
        #expect(DictationText.withoutFillers("Je pense euh.") == "Je pense.")
        // Words that only look like them stay.
        #expect(DictationText.withoutFillers("Eh bien, l'humeur du serveur est bonne.") == "Eh bien, l'humeur du serveur est bonne.")
        #expect(DictationText.withoutFillers("Pourquoi ? Parce que !") == "Pourquoi ? Parce que !")
    }

    @Test func stumblesGo() {
        // What melvin dictated, as Parakeet wrote it.
        #expect(DictationText.withoutStumbles("Le le La sélection de du shortcut c'est c'est pas joli non plus il ya trop de texte faut faut arranger tout ça.")
            == "La sélection du shortcut c'est pas joli non plus il y a trop de texte faut arranger tout ça.")
        #expect(DictationText.withoutStumbles("Je veux quelque chose de beaucoup plus beaucoup plus joli.") == "Je veux quelque chose de beaucoup plus joli.")
        #expect(DictationText.withoutStumbles("C'est pas intuitif. le la sélection de du shortcut c c'est pas joli.")
            == "C'est pas intuitif. La sélection du shortcut c'est pas joli.")
        #expect(DictationText.withoutStumbles("Il ya un bug, c'est, c'est dans le le fichier.") == "Il y a un bug, c'est dans le fichier.")
        #expect(DictationText.withoutStumbles("je pense que je pense que ça marche") == "je pense que ça marche")
        #expect(DictationText.withoutStumbles("Corrige le La fonction et un une variable.") == "Corrige la fonction et une variable.")
        #expect(DictationText.withoutStumbles("Can you check the the build? I I think it t the tests fail.")
            == "Can you check the build? I think it the tests fail.")
        #expect(DictationText.withoutStumbles("C'est trop de texte. Où par exemple le champ, où bien la barre. Où alors on enlève tout.")
            == "C'est trop de texte. Ou par exemple le champ, ou bien la barre. Ou alors on enlève tout.")
        // Where it asks where, or tells where, "où" stays.
        #expect(DictationText.withoutStumbles("Où alors ? Dans le cas où par exemple le fichier manque. Où est le bug ?")
            == "Où alors ? Dans le cas où par exemple le fichier manque. Où est le bug ?")
    }

    @Test func wordsSaidTwiceOnPurposeStay() {
        let kept = [
            "Nous nous sommes trompés, vous vous en doutez.",
            "Non, non, c'est très très bien.",
            "I know that that is wrong, and he had had enough.",
            "Il a donné le la. On parle de la branche et de l'API.",
            "Un des fichiers, une des branches.",
            "La version 2 2 est sortie.",
            "Merci. Merci.",
            "Il y a a et b, la variable x vaut 2.",
            "Swiftr, Glane, Glane+ et herdr.",
            "Pourquoi ? Pourquoi pas.",
        ]
        for text in kept {
            #expect(DictationText.withoutStumbles(text) == text)
        }
    }

    @Test func aLongDictationGoesInPieces() {
        let text = "Alors, je veux quelque chose de plus joli. Là, c'est un peu boring. Pareil, les réglages ne sont pas bien agencés. Pourquoi ? Le truc de vocabulaire, c'est pas intuitif"
        let pieces = DictationTidy.pieces(text, limit: 80)
        #expect(pieces == [
            "Alors, je veux quelque chose de plus joli. Là, c'est un peu boring.",
            "Pareil, les réglages ne sont pas bien agencés. Pourquoi ?",
            "Le truc de vocabulaire, c'est pas intuitif",
        ])
        #expect(pieces.joined(separator: " ") == text)
        // About as long as each other: no small piece at the end.
        #expect(DictationTidy.pieces(text, limit: 120).map(\.count) == [67, 100])
        #expect(DictationTidy.pieces("Une phrase bien trop longue pour la limite.", limit: 10) == ["Une phrase bien trop longue pour la limite."])
        #expect(DictationTidy.pieces(text).count == 1)
    }

    @Test func eachPieceIsTidiedAndCheckedAlone() {
        let heard = "alors je regarde le code de Swiftr. est-ce que tu peux corriger le bug. merci beaucoup"
        var asked: [(piece: String, names: [String])] = []
        let outcome = DictationTidy.tidy(heard, terms: ["Swiftr", "herdr"], limit: 40) { piece, names in
            asked.append((piece, names))
            switch asked.count {
            case 1: return "Alors, je regarde le code de Swiftr."
            case 2: return "Est-ce que tu peux corriger le bug ?"
            default: return "Oui, je corrige le bug tout de suite dans le fichier qui pose problème."
            }
        }
        #expect(asked.map(\.piece) == ["alors je regarde le code de Swiftr.", "est-ce que tu peux corriger le bug.", "merci beaucoup"])
        #expect(asked.map(\.names) == [["Swiftr"], [], []])
        // The answer to "merci beaucoup" isn't a tidy-up: those words stay.
        #expect(outcome.text == "Alors, je regarde le code de Swiftr. Est-ce que tu peux corriger le bug ? merci beaucoup")
        #expect(outcome.note.hasPrefix("changed too much: Oui"))
        let long = "Une phrase. " + String(repeating: "Encore une phrase assez longue. ", count: 10)
        var calls = 0
        let late = DictationTidy.tidy(long, terms: []) { _, _ in
            calls += 1
            return nil
        }
        #expect(calls == 1)
        #expect(late.note == "late")
        #expect(late.text == long.trimmingCharacters(in: .whitespaces))
    }

    @Test func aFrenchQuestionKeepsItsSpace() {
        let french = DictationTidy.tidy("tu peux corriger le bug ? merci !", terms: []) { _, _ in "Tu peux corriger le bug? Merci!" }
        #expect(french.text == "Tu peux corriger le bug ? Merci !")
        let english = DictationTidy.tidy("can you fix it", terms: []) { _, _ in "Can you fix it?" }
        #expect(english.text == "Can you fix it?")
        #expect(DictationTidy.spaced("Pourquoi?! Voir https://a.com/?q=1", like: "pourquoi ?!") == "Pourquoi ?! Voir https://a.com/?q=1")
    }

    @Test func aTidyUpKeepsTheWords() {
        let heard = "euh alors je voudrais que tu corriges le le bug dans composer field"
        #expect(DictationText.isTidied("Alors, je voudrais que tu corriges le bug dans ComposerField.", from: heard))
        #expect(DictationText.isTidied("Can you tell me why the build fails?", from: "um can you tell me why the build fails"))
    }

    @Test func anAnswerOrATranslationIsNoTidyUp() {
        let heard = "est-ce que tu peux me dire pourquoi le build échoue"
        #expect(!DictationText.isTidied("Le build échoue parce que le fichier project.yml a une erreur de syntaxe à la ligne 12.", from: heard))
        #expect(!DictationText.isTidied("Can you tell me why the build fails?", from: heard))
        #expect(!DictationText.isTidied("Pourquoi ?", from: heard))
        #expect(!DictationText.isTidied("", from: heard))
    }

    @Test func aSentenceLeftOutIsNoTidyUp() {
        let heard = "Alors, je veux quelque chose de beaucoup plus joli, peut-être un peu futuriste. Tu vois, on reste dans la sobriété. Mais genre un truc qui va chercher un peu les codes du design. Tu vois, là, c'est un peu boring."
        #expect(!DictationText.isTidied("Alors, je veux quelque chose de beaucoup plus joli, peut-être un peu futuriste. Tu vois, on reste dans la sobriété. Mais genre un truc qui va chercher un peu les codes du design.", from: heard))
        #expect(!DictationText.isTidied("Alors, je veux quelque chose de beaucoup plus joli, peut-être un peu futuriste. Tu vois, on reste dans la sobriété. Mais genre un truc qui va chercher un peu les codes du design. C'est un peu boring.", from: heard))
        // A word or two in this many may change.
        #expect(DictationText.isTidied("Alors, je veux quelque chose de beaucoup plus joli, peut-être un peu futuriste. Tu vois, on reste dans la sobriété, mais un truc qui va chercher un peu les codes du design. Tu vois, là, c'est un peu boring.", from: heard))
    }

    @Test func insertingAddsSpacesWhereWordsWouldTouch() {
        #expect(DictationText.insert("Le bug est là.", into: "", at: 0) == ("Le bug est là.", 14))
        #expect(DictationText.insert("corrige le bug", into: "Merci,", at: 6) == ("Merci, corrige le bug", 21))
        #expect(DictationText.insert("dans le fichier", into: "Regarde  ensuite", at: 8) == ("Regarde dans le fichier ensuite", 23))
        #expect(DictationText.insert(", puis teste.", into: "Corrige", at: 7) == ("Corrige, puis teste.", 20))
        #expect(DictationText.insert("ComposerField", into: "Voir ()", at: 6) == ("Voir (ComposerField)", 19))
        #expect(DictationText.insert("  ", into: "abc", at: 1) == ("abc", 1))
    }
}

/// The names dictation writes as they're spelled.
@Suite struct DictationVocabularyTests {
    @Test func namesComeFromCodeAndCamelCase() {
        let messages = [
            "I changed `Swiftr/Messages/ComposerField.swift` and the `readAloudSpeed` default.",
            "The `DictationEngine` now starts the helper; see voice_helper and README.md. Run `swift test`.",
            "Look at https://example.com/SomePath and ```let fooBar = 1```.",
        ]
        let names = DictationVocabulary.names(in: messages)
        #expect(names.contains("ComposerField"))
        #expect(names.contains("readAloudSpeed"))
        #expect(names.contains("DictationEngine"))
        #expect(names.contains("voice_helper"))
        #expect(names.contains("README"))
        #expect(!names.contains("swift test"))
        #expect(!names.contains("SomePath"))
        #expect(!names.contains("fooBar"))
        #expect(!names.contains { $0.lowercased() == "the" || $0 == "and" })
    }

    @Test func theLatestAndMostUsedComeFirst() {
        let messages = ["`OldThing` and `OldThing`", "`NewThing`", "`NewThing` again, `OtherThing`"]
        let names = DictationVocabulary.names(in: messages, limit: 2)
        #expect(names == ["NewThing", "OldThing"])
    }

    @Test func joinedNamesAreSaidAsWords() {
        #expect(DictationVocabulary.spoken("ComposerField") == "Composer Field")
        #expect(DictationVocabulary.spoken("readAloudSpeed") == "read Aloud Speed")
        #expect(DictationVocabulary.spoken("voice_helper") == "voice helper")
        #expect(DictationVocabulary.spoken("HTMLParser") == "HTML Parser")
        #expect(DictationVocabulary.spoken("Swiftr") == nil)
        #expect(DictationVocabulary.heardAs("Swiftr") == ["Swifter"])
        #expect(DictationVocabulary.heardAs("HerdrKit") == ["Herdr Kit", "Herder Kit"])
        #expect(DictationVocabulary.heardAs("ComposerField") == ["Composer Field"])
        #expect(DictationVocabulary.heardAs("Parser").isEmpty)
    }

    @Test func theListMixesEachNameOnce() {
        #expect(DictationVocabulary.parse("Lessss, Glane\nherdr\n\n") == ["Lessss", "Glane", "herdr"])
        let terms = DictationVocabulary.terms(mine: ["Glane", "swiftr"], conversation: ["ComposerField", "Glane"])
        #expect(terms == ["Glane", "swiftr", "herdr", "ComposerField"])
        let words: Set = ["options", "branch"]
        let named = DictationVocabulary.terms(mine: ["Branch"], conversation: ["Options", "ComposerField", "MicCapture"],
                                              isWord: { words.contains($0.lowercased()) })
        #expect(named == ["Branch", "Swiftr", "herdr", "ComposerField", "MicCapture"])
    }

    @Test func theTidyUpPromptEndsWithTheText() {
        let messages = DictationTidy.messages(heard: "euh corrige composer field", names: ["ComposerField"])
        #expect(messages.first?.role == "system")
        #expect(messages.last == DictationTidy.Message("user", "Names: ComposerField\nDictated text: euh corrige composer field"))
        #expect(DictationTidy.clean("<think>\n\n</think>\n\n\"Corrige ComposerField.\"") == "Corrige ComposerField.")
        #expect(DictationTidy.clean("Corrected text: Corrige ComposerField.") == "Corrige ComposerField.")
    }
}
