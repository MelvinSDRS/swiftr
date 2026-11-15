import Foundation
import Testing
@testable import HerdrKit

/// AskUserQuestion when its options have previews, as Claude Code 2.1.325
/// drew it (200 columns, 2026-11-14): the options beside the previews,
/// notes in place of `Type something`, `Chat about this` with no digit.
@Suite struct PreviewQuestionTests {
    private let rule = String(repeating: "─", count: 200)
    private let layout = AskQuestion(header: "Layout", question: "Which card layout do you prefer for the effort picker?",
                                     options: [.init(label: "Stacked"), .init(label: "Side by side (Recommended)"), .init(label: "Compact")])
    private let color = AskQuestion(header: "Color", question: "Which accent color?", options: [.init(label: "Blue"), .init(label: "Orange")])

    private func screen(_ options: [String], notes: String, chat: String = "  Chat about this", hint: String? = nil, tabs: String = "←  ☐ Layout  ☐ Color  ✔ Submit  →") -> String {
        ([rule, tabs, "", "Which card layout do you prefer for the effort picker?", ""] + options + [
            "", "                                  Notes: \(notes)", "", rule, chat, "",
            hint ?? "Enter to select · ↑/↓ to navigate · n to add notes · Tab to switch questions · Esc to cancel",
        ]).joined(separator: "\n")
    }

    private let fresh = [
        "❯ 1. Stacked                      ┌──────────────────────────────────────────┐",
        "  2. Side by side                 │ +----------------------+                 │",
        "    (Recommended)                 │ | Low                  |                 │",
        "  3. Compact                      │ | Medium               |                 │",
        "                                  │ | High                 |                 │",
        "                                  │ +----------------------+                 │",
        "                                  └──────────────────────────────────────────┘",
    ]

    @Test func optionsBesideThePreviews() throws {
        let p = try #require(ScreenPrompt.parse(screen: screen(fresh, notes: "press n to add notes")))
        #expect(p.previews)
        #expect(p.options.map(\.label) == ["Stacked", "Side by side (Recommended)", "Compact"])
        #expect(p.options.map(\.focused) == [true, false, false])
        #expect(p.questionText == "Which card layout do you prefer for the effort picker?")
        #expect(p.tabs.map(\.title) == ["Layout", "Color", "Submit"])
        #expect(p.notes == "")
        #expect(p.notesOpen == false)
        #expect(!p.chatFocused)
        #expect(p.questionIndex(in: [layout, color]) == 0)
        #expect(p.shownAnswer(for: layout).isEmpty)
    }

    @Test func notesOpenAndClosed() throws {
        let hint = "Enter to select · ↑/↓ to navigate · n to add notes · Tab to switch questions · ctrl+g to edit in VS Code · Esc to cancel"
        let empty = try #require(ScreenPrompt.parse(screen: screen(fresh, notes: "Add notes on this design…", hint: hint)))
        #expect(empty.notesOpen == true)
        #expect(empty.notes == "")
        let typing = try #require(ScreenPrompt.parse(screen: screen(fresh, notes: "abc", hint: hint)))
        #expect(typing.notesOpen == true)
        #expect(typing.shownAnswer(for: layout) == AskAnswer(other: "abc"))
        // Without an editor named, only the colors tell.
        let closed = try #require(ScreenPrompt.parse(screen: screen(fresh, notes: "abc")))
        #expect(closed.notesOpen == nil)
        #expect(closed.notes == "abc")
    }

    @Test func theAnswerMarkedAndTheChat() throws {
        let answered = [
            "  1. Stacked                      ┌──────────────────────────────────────────┐",
            "❯ 2. Side by side            ✔    │ +-----+ +-----+ +-----+                  │",
            "    (Recommended)                 │ | Low | | Med | | High|                  │",
            "  3. Compact                      │ |     | |     | |     |                  │",
            "                                  │ +-----+ +-----+ +-----+                  │",
            "                                  └──────────────────────────────────────────┘",
        ]
        let p = try #require(ScreenPrompt.parse(screen: screen(answered, notes: "abc", tabs: "←  ☒ Layout  ☐ Color  ✔ Submit  →")))
        #expect(p.options.map(\.label) == ["Stacked", "Side by side (Recommended) ✔", "Compact"])
        #expect(p.options.first(where: \.focused)?.number == 2)
        #expect(p.shownAnswer(for: layout) == AskAnswer(chosen: ["Side by side (Recommended)"], other: "abc"))
        #expect(p.tabs.map(\.answered) == [true, false, false])

        let onChat = [
            "  1. Stacked                      ┌──────────────────────────────────────────┐",
            "  2. Side by side            ✔    │ [ Low ] [ Medium ] [ High ]              │",
            "    (Recommended)                 │   fast    balanced    thorough           │",
            "❯ 3. Compact                      └──────────────────────────────────────────┘",
        ]
        let c = try #require(ScreenPrompt.parse(screen: screen(onChat, notes: "abc", chat: "❯ Chat about this")))
        #expect(c.chatFocused)
        #expect(c.options.count == 3)
        #expect(c.options.first(where: \.focused) == nil)
    }

    /// A lone question, its text in a gutter, its labels in French, a
    /// preview of emoji and box drawing (melvin's, 193 columns).
    @Test func aLoneQuestionInAGutter() throws {
        let text = "Pour les puces modèle/effort en bas à droite du champ (aujourd'hui un simple menu macOS qui envoie `/effort high` et enregistre le choix par défaut) : que doit faire un clic ?"
        let lines = [
            String(repeating: "─", count: 193),
            " ☐ Puces",
            "",
            "│ " + text,
            "",
            "❯ 1. Ouvrir la carte              ┌────────────────────────────────────────────┐",
            "    (Recommandé)                  │ ╭ ◔ Effort ──────────── Show in Terminal ╮ │",
            "  2. Carte dans un popover        │ │ 🐇 Faster                  Smarter 🧠 │  │",
            "  3. Sélecteur rapide             │ │     ▁   ▃   ▅   ▇   █                  │ │",
            "                                  │ │    low med high xhigh max              │ │",
            "                                  │ ╰────────────────────────────────────────╯ │",
            "                                  └────────────────────────────────────────────┘",
            "",
            "                                  Notes: press n to add notes",
            "",
            String(repeating: "─", count: 193),
            "  Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel",
        ]
        let q = AskQuestion(header: "Puces", question: text, options: [.init(label: "Ouvrir la carte (Recommandé)"), .init(label: "Carte dans un popover"), .init(label: "Sélecteur rapide")])
        let p = try #require(ScreenPrompt.parse(screen: lines.joined(separator: "\n")))
        #expect(p.previews)
        #expect(p.options.map(\.label) == q.options.map(\.label))
        #expect(p.asks(q))
        #expect(p.questionIndex(in: [q]) == 0)
        #expect(p.tabs.map(\.title) == ["Puces"])
    }

    /// More options than the preview is tall: the notes beside one.
    @Test func notesBesideAnOption() throws {
        let lines = [
            "❯ 1. Stacked                      ┌─────────┐",
            "  2. Side by side                 │ 一二三  │",
            "  3. Compact 📦 箱                └─────────┘",
            "  4. Wide                         ",
            "  5. Tall                         Notes: abc",
        ]
        let text = ([rule, "←  ☐ Layout  ✔ Submit  →", "", "Which card layout do you prefer for the effort picker?", ""] + lines + ["", rule, "  Chat about this", "", "Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel"]).joined(separator: "\n")
        let p = try #require(ScreenPrompt.parse(screen: text))
        #expect(p.options.map(\.label) == ["Stacked", "Side by side", "Compact 📦 箱", "Wide", "Tall"])
        #expect(p.notes == "abc")
    }

    @Test func cellsCountWideCharacters() {
        #expect(ScreenPrompt.cells("abc") == 3)
        #expect(ScreenPrompt.cells("箱🐇") == 4)
        #expect(ScreenPrompt.cut("ab箱cd", at: 4) == ("ab箱", "cd"))
    }
}
