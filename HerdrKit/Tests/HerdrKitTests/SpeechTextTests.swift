import Testing
@testable import HerdrKit

/// An agent's Markdown as the words read aloud.
@Suite struct SpeechTextTests {
    @Test func marksGoAndCodeBlocksAreLeftOut() {
        let markdown = """
        ## Le plan

        Voici **le plan** pour `HoverActions` :

        ```swift
        let x = 1
        ```

        - Ajouter un bouton
        - Lire le *texte*
        """
        #expect(SpeechText.make(markdown) == """
        Le plan.
        Voici le plan pour Hover Actions :
        Ajouter un bouton.
        Lire le texte.
        """)
    }

    @Test func onlyCodeLeavesNothing() {
        #expect(SpeechText.make("```sh\nls -la\n```") == "")
        #expect(SpeechText.make("---") == "")
    }

    @Test func pathsAreSaidByTheirFileName() {
        #expect(SpeechText.make("Voir `Swiftr/Messages/MessageRows.swift:335`.") == "Voir Message Rows.swift.")
        #expect(SpeechText.make("Le fichier /Users/me/Projects/swiftr/project.yml change") == "Le fichier project.yml change.")
        #expect(SpeechText.make("Dans ~/Applications/Swiftr.app") == "Dans Swiftr.app.")
        #expect(SpeechText.make("Ligne MessageRows.swift:335 et 12:30") == "Ligne MessageRows.swift et 12:30.")
        // Not paths.
        #expect(SpeechText.make("En fr/en, le 14/11/2026") == "En fr/en, le 14/11/2026.")
    }

    @Test func webAddressesAreSaidByTheirSite() {
        #expect(SpeechText.make("Source : https://github.com/FluidInference/FluidAudio.") == "Source : github.com.")
        #expect(SpeechText.make("Lire [la doc](https://code.claude.com/docs/en/voice-dictation)") == "Lire la doc.")
        #expect(SpeechText.make("Voir <https://www.apple.com/fr/>") == "Voir apple.com.")
    }

    @Test func longCommandsAreSaidByTheirProgram() {
        #expect(SpeechText.make("Lance `xcodebuild -project Swiftr.xcodeproj -scheme Swiftr build` pour compiler")
            == "Lance xcodebuild pour compiler.")
        #expect(SpeechText.make("Puis `git status`.") == "Puis git status.")
    }

    @Test func namesInCodeAreSaidAsWords() {
        #expect(SpeechText.make("`voice_stream`, `--safe-mode`, `NSTextView`") == "voice stream, safe mode, NS Text View.")
    }

    @Test func tablesAreReadRowByRow() {
        let markdown = """
        | Option | Coût |
        |---|---|
        | Apple | gratuit |
        | Cloud | `0,015 $/min` |
        """
        #expect(SpeechText.make(markdown) == "Option, Coût.\nApple, gratuit.\nCloud, 0,015 $/min.")
    }

    @Test func numberedItemsKeepTheirNumber() {
        #expect(SpeechText.make("1. Lire\n2. Dicter") == "1. Lire.\n2. Dicter.")
    }

    @Test func aHardWrappedSentenceIsReadAsOne() {
        #expect(SpeechText.make("Ceci est une phrase\ncoupée en deux.\nEt une autre") == "Ceci est une phrase coupée en deux.\nEt une autre.")
        // A line Claude ended on purpose stays a sentence of its own.
        #expect(SpeechText.make("**Fichier** : un\n**Ligne** : deux") == "Fichier : un.\nLigne : deux.")
    }

    @Test func arrowsAndTagsAreNotSaid() {
        #expect(SpeechText.make("Fichier → Nouveau · Onglet<br>") == "Fichier, Nouveau, Onglet.")
    }
}
