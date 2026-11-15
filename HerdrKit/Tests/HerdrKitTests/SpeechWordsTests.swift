import Testing
@testable import HerdrKit

/// Signs, units and developers' words as a French voice says them.
@Suite struct SpeechWordsTests {
    static func fr(_ text: String) -> String { SpeechWords.say(text, language: "fr") }

    @Test func developersWordsAreSpelledAsTheySound() {
        let markdown = "J'ai poussé sur la branche main, puis lancé `git rebase main` et mis à jour le README.md. La pull request est prête."
        #expect(SpeechText.make(markdown, language: "fr") == "J'ai poussé sur la branche mayne, puis lancé guite rebase mayne et mis à jour le ridmi.md. La poule request est prête.")
        #expect(Self.fr("Fusionné dans main, puis git pull origin main et origin/main.") == "Fusionné dans mayne, puis guite poule origin mayne et origin/mayne.")
    }

    @Test func mainInCodeIsTheBranchOrTheFunction() {
        #expect(SpeechText.make("Voir `main.swift` et `mainWindow`.", language: "fr") == "Voir mayne.swift et mayne Window.")
    }

    @Test func mainInFrenchStaysAHand() {
        let text = "Je l'ai corrigé à la main, avec de la main-d'œuvre et un coup de main."
        #expect(SpeechText.make(text, language: "fr") == text)
        #expect(Self.fr("Garde-le sous la main, dans ta main.") == "Garde-le sous la main, dans ta main.")
    }

    @Test func unitsAndSignsAreWords() {
        #expect(Self.fr("Le build prend ~40 ms au lieu de 2 h (85 %).") == "Le build prend environ 40 millisecondes au lieu de 2 heures (85 pour cent).")
        #expect(Self.fr("J'ai corrigé le bug #42 : x = 3 + 1 dépassait la limite (>= 10).") == "J'ai corrigé le bug numéro 42 : x égale 3 plus 1 dépassait la limite (supérieur ou égal à 10).")
        #expect(Self.fr("Ça coûte $5 par mois, ou 4,50 € ; le modèle pèse 1,5 Go.") == "Ça coûte 5 dollars par mois, ou 4,50 euros ; le modèle pèse 1,5 gigaoctet.")
        #expect(Self.fr("2 500 000 Ko, 3s, 1 s, 16px, une marge de ±2 ms et 5 minutes.") == "2 500 000 kilooctets, 3 secondes, 1 seconde, 16 pixels, une marge de plus ou moins 2 millisecondes et 5 minutes.")
        #expect(Self.fr("x != y, a ≤ 3, b < 4 et 2× plus vite.") == "x différent de y, a inférieur ou égal à 3, b inférieur à 4 et 2 fois plus vite.")
    }

    @Test func timesVersionsAndNegativeNumbers() {
        #expect(Self.fr("À 10:30, la version 2.1.322 renvoyait -1 au lieu de 0.") == "À 10 heures 30, la version 2 point 1 point 322 renvoyait moins 1 au lieu de 0.")
        #expect(Self.fr("Lancé à 1:00, fini à 14h05.") == "Lancé à 1 heure, fini à 14h05.")
    }

    @Test func whatIsNoSignStays() {
        let text = "Ouvre Settings > Voice, en C++, de 5 - 3 lignes, le 14/11/2026."
        #expect(Self.fr(text) == text)
        #expect(Self.fr("Le test - qui passe - est bon.") == "Le test — qui passe — est bon.")
    }

    @Test func otherLanguagesAreLeftToTheVoice() {
        let markdown = "Pushed `git` to the main branch, ~40 ms faster (#42)."
        #expect(SpeechText.make(markdown, language: "en") == SpeechText.make(markdown))
        #expect(SpeechText.make(markdown, language: "fr") != SpeechText.make(markdown))
        #expect(SpeechWords.code("main", language: "en") == "main")
    }
}
