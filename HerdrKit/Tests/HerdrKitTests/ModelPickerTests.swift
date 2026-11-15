import Testing
@testable import HerdrKit

/// Claude Code 2.1.322's model picker, from screens read live (⌥P in a test Claude).
struct ModelPickerTests {
    static let head = """
     ▝▝   ▝▝   /private/tmp/cctest · /rc
    ⚠ Safe mode: all customizations are disabled (CLAUDE.md, skills, plugins, hooks, MCP, agents, and more)
      Restart without --safe-mode to re-enable
    ────────────────────────────────────────────────────────────────────────────────────────────────
      Select model
      Switch between Claude models. Your pick becomes the default for new sessions. For other/previous model names, specify with --model.

    """

    static let firstModels = """
        1.  Default (recommended)  Opus 5.5 · Best for everyday, complex tasks
        2.  Opus 5.5               For complex work and everyday tasks
        3.  Fable 5.2              For your toughest challenges
        4.  Sonnet 5.5             Most efficient for simpler tasks

    """

    @Test func closedWithTheCursorOnTheModelInUse() throws {
        let screen = Self.head + Self.firstModels + """
          ❯ 5.  Haiku 5.5 ✔            Fastest for quick answers
            ▸   More models

          ◐ Medium effort (default) ←/→ to adjust

          Enter to set as default · s to use this session only · Esc to cancel
        """
        let p = try #require(ScreenPrompt.parse(screen: screen))
        let m = try #require(p.modelPicker)
        #expect(p.options.map(\.number) == [1, 2, 3, 4, 5])
        #expect(p.options[0].label == "Default (recommended)")
        #expect(p.options[0].detail == "Opus 5.5 · Best for everyday, complex tasks")
        #expect(p.options[4].label == "Haiku 5.5")
        #expect(p.options[4].checked == true)
        #expect(p.options[4].focused)
        #expect(p.options[4].detail == "Fastest for quick answers")
        #expect(p.footer == "Enter to set as default · s to use this session only · Esc to cancel")
        #expect(m.moreShown && !m.moreOpen && !m.moreFocused && m.moreAfter == 5)
        #expect(!m.hiddenAbove && m.hiddenBelow == 0)
        #expect(m.effortMark == "◐" && m.effort == "Medium" && m.effortIsDefault)
        #expect(m.notes.isEmpty)
        // Its advice for the command line goes: a card can't follow it.
        #expect(m.about == "Switch between Claude models. Your pick becomes the default for new sessions.")
        #expect(p.pickerMoves(to: 1) == ["up", "up", "up", "up"])
        #expect(p.pickerMoves(to: nil) == ["down"])
        #expect(TranscriptFeedMenu.isMenu(p))
    }

    @Test func closedWithTheCursorOnMoreModels() throws {
        let screen = Self.head + Self.firstModels + """
            5.  Haiku 5.5 ✔            Fastest for quick answers
          ❯ ▸   More models

          Enter to expand · Esc to cancel
        """
        let p = try #require(ScreenPrompt.parse(screen: screen))
        let m = try #require(p.modelPicker)
        #expect(m.moreFocused && !m.moreOpen)
        #expect(m.effort == nil)
        #expect(p.footer == "Enter to expand · Esc to cancel")
        let focused = p.options.filter(\.focused)
        #expect(focused.isEmpty)
        #expect(p.pickerMoves(to: 5) == ["up"])
        #expect(p.pickerMoves(to: nil) == [])
    }

    @Test func openWithMoreModelsBelowTheWindow() throws {
        let screen = Self.head + Self.firstModels + """
            5.  Haiku 5.5 ✔            Fastest for quick answers
          ❯ ▾   More models
            6.  Fable 5.1              Most capable for your hardest and longest-running tasks
            7.  Haiku 4.5              Fastest for quick answers
            8.  Sonnet 5               Efficient for routine tasks
          ↓ 9.  Opus 5                 Best for everyday, complex tasks
             … +5 models
          Enter to collapse · Esc to cancel
        """
        let p = try #require(ScreenPrompt.parse(screen: screen))
        let m = try #require(p.modelPicker)
        #expect(p.options.map(\.number) == Array(1 ... 9))
        #expect(p.options[4].detail == "Fastest for quick answers")
        #expect(m.moreOpen && m.moreFocused && m.moreAfter == 5)
        #expect(m.hiddenBelow == 5 && !m.hiddenAbove)
        #expect(p.pickerMoves(to: 9) == Array(repeating: "down", count: 4))
        #expect(p.pickerMoves(to: 14) == Array(repeating: "down", count: 9))
        #expect(p.pickerMoves(to: 2) == Array(repeating: "up", count: 4))
    }

    @Test func scrolledToTheOlderModels() throws {
        let screen = Self.head + """
          ↑ 5.  Haiku 5.5 ✔            Fastest for quick answers
            ▾   More models
            6.  Fable 5.1              Most capable for your hardest and longest-running tasks
            7.  Haiku 4.5              Fastest for quick answers
            8.  Sonnet 5               Efficient for routine tasks
            9.  Opus 5                 Best for everyday, complex tasks
            10. Fable 5                Most capable for your hardest and longest-running tasks
            11. Opus 4.8               Best for everyday, complex tasks
            12. Opus 4.7               Best for everyday, complex tasks
          ❯ 13. Opus 4.6               Best for everyday, complex tasks
             … +1 model
          ● High effort (default) ←/→ to adjust
          Enter to set as default · s to use this session only · Esc to cancel
        """
        let p = try #require(ScreenPrompt.parse(screen: screen))
        let m = try #require(p.modelPicker)
        #expect(p.options.map(\.number) == Array(5 ... 13))
        #expect(p.options.last?.focused == true)
        #expect(p.options.last?.label == "Opus 4.6")
        #expect(m.hiddenAbove && m.hiddenBelow == 1)
        #expect(m.moreShown && m.moreOpen && !m.moreFocused && m.moreAfter == 5)
        #expect(m.effortMark == "●" && m.effort == "High" && m.effortIsDefault)
        #expect(p.pickerMoves(to: 14) == ["down"])
        #expect(p.pickerMoves(to: 1) == Array(repeating: "up", count: 13))
        #expect(p.pickerMoves(to: nil) == Array(repeating: "up", count: 8))
        #expect(p.pickerStep(toward: 1) == "up")
        #expect(p.pickerStep(toward: nil) == "up")
    }

    /// The window past `More models`: the rows shown all sit under it.
    @Test func scrolledPastMoreModels() throws {
        let screen = Self.head + """
          ↑ 6.  Fable 5.1              Most capable for your hardest and longest-running tasks
            7.  Haiku 4.5              Fastest for quick answers
            8.  Sonnet 5               Efficient for routine tasks
          ❯ 14. Opus 4.5               Best for everyday, complex tasks
          ◉ xHigh effort ←/→ to adjust
          May use excessive tokens resulting in long response times or overthinking. Use sparingly for the hardest tasks.
          Enter to set as default · s to use this session only · Esc to cancel
        """
        let p = try #require(ScreenPrompt.parse(screen: screen))
        let m = try #require(p.modelPicker)
        #expect(!m.moreShown && m.hiddenAbove)
        #expect(m.effort == "xHigh" && !m.effortIsDefault)
        #expect(m.notes == ["May use excessive tokens resulting in long response times or overthinking. Use sparingly for the hardest tasks."])
        #expect(p.pickerMoves(to: nil) == nil)
        #expect(p.pickerStep(toward: nil) == "up")
        #expect(p.pickerStep(toward: 7) == "up")
        #expect(p.pickerStep(toward: 14) == nil)
    }

    /// `More models` first in the window: the cursor came up to it from below.
    @Test func moreModelsAtTheWindowsTop() throws {
        let screen = Self.head + """
          ❯ ▾   More models
            6.  Fable 5.1              Most capable for your hardest and longest-running tasks
            7.  Haiku 4.5              Fastest for quick answers
          Enter to collapse · Esc to cancel
        """
        let p = try #require(ScreenPrompt.parse(screen: screen))
        let m = try #require(p.modelPicker)
        #expect(m.moreAfter == 5 && m.moreFocused && m.hiddenAbove)
        #expect(p.pickerMoves(to: 7) == ["down", "down"])
    }

    /// Other pickers and prompts are not this one.
    @Test func otherScreensAreNot() {
        let permission = """
         Bash command
           ls -la
         Do you want to proceed?
         ❯ 1. Yes
           2. No
         Esc to cancel · Tab to amend
        """
        #expect(ScreenPrompt.parse(screen: permission)?.modelPicker == nil)
    }
}

/// `TranscriptFeed.isMenu` lives in the app; its rule, for the picker's sake.
enum TranscriptFeedMenu {
    static func isMenu(_ p: ScreenPrompt) -> Bool {
        let hint = p.footer.lowercased()
        return p.options.count >= 2 && (hint.contains("esc") || hint.contains("enter") || p.options.contains(where: \.focused))
    }
}
