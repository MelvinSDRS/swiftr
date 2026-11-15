import Testing
@testable import HerdrKit

/// Claude Code 2.1.325's `/effort` and `/resume` screens, read live in a
/// 200-column test terminal.
@Suite struct ClaudeMenusTests {
    static let effort = """

        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
           Effort

                                                                             Faster                             Smarter
                                                                             ──────────▲───────────────────────────────      Ultracode  off
                                                                             low     medium     high     xhigh      max      Tab to toggle

                                                                                            The default effort for this model


           ←/→ to adjust · Enter to confirm · s for this session only · Esc to cancel
        """

    static let xhigh = """

        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
           Effort

                                                                             Faster                             Smarter
                                                                             ──────────────────────────────▲───────────      Ultracode  on
                                                                             low     medium     high     xhigh      max      Tab to toggle
                                                                             Ultracode: dynamic workflows on every task
                                                                                    ~3.9x the estimated cost of medium (the default)


           ←/→ to adjust · Enter to confirm · s for this session only · Esc to cancel
        """

    static let max = """

        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
           Effort

                                                                             Faster                             Smarter
                                                                             ────────────────────────────────────────▲─      Ultracode  on
                                                                             low     medium     high     xhigh      max      Tab to toggle
                                                                             Ultracode: dynamic workflows on every task
                                                 May use excessive tokens resulting in long response times or overthinking. Use sparingly for the hardest tasks. (~8.3x)


           ←/→ to adjust · Enter to confirm · s for this session only · Esc to cancel
        """

    @Test func effortAtTheDefault() throws {
        let p = try #require(ScreenPrompt.parse(screen: Self.effort))
        let e = try #require(p.effortMenu)
        #expect(p.options.isEmpty)
        #expect(e.title == "Effort")
        #expect(e.levels == ["low", "medium", "high", "xhigh", "max"])
        #expect(e.current == 1)
        #expect(e.lowEnd == "Faster")
        #expect(e.highEnd == "Smarter")
        #expect(e.ultracode == false)
        #expect(e.ultracodeNote == nil)
        #expect(e.caption == ["The default effort for this model"])
        #expect(e.takesSession)
        #expect(e.hint.hasPrefix("←/→ to adjust"))
        #expect(e.moves(to: 3) == ["right", "right"])
        #expect(e.moves(to: 0) == ["left"])
        #expect(e.moves(to: 1).isEmpty)
    }

    @Test func effortWithUltracodeOn() throws {
        let e = try #require(ScreenPrompt.parse(screen: Self.xhigh)?.effortMenu)
        #expect(e.current == 3)
        #expect(e.ultracode == true)
        #expect(e.ultracodeNote == "dynamic workflows on every task")
        #expect(e.caption == ["~3.9x the estimated cost of medium (the default)"])
        let m = try #require(ScreenPrompt.parse(screen: Self.max)?.effortMenu)
        #expect(m.current == 4)
        #expect(m.caption.first?.hasPrefix("May use excessive tokens") == true)
    }

    @Test func effortIsNotTheModelPickersLine() {
        // The model picker's own effort line isn't the effort menu.
        let picker = ModelPickerTests.head + ModelPickerTests.firstModels + """
          ❯ 5.  Haiku 5.5 ✔            Fastest for quick answers

          ◐ Medium effort (default) ←/→ to adjust

          Enter to set as default · s to use this session only · Esc to cancel
        """
        let p = ScreenPrompt.parse(screen: picker)
        #expect(p?.effortMenu == nil)
        #expect(p?.modelPicker != nil)
    }

    static let resume = """
        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
           Resume session
           ╭────────────────────────────────────────────────────────────╮
           │ ⌕ Search…                                                  │
           ╰────────────────────────────────────────────────────────────╯
             cctest

           ❯ AskUserQuestion button color and pets
             11 minutes ago · HEAD · 281.4KB

             Ctrl+A to show all projects · Ctrl+B to only show current branch · Space to preview · Ctrl+R to rename · Type to search · Esc to cancel
        """

    static let noMatch = """
        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
           Resume session
           ╭────────────────────────────────────────────────────────────╮
           │ ⌕ x                                                        │
           ╰────────────────────────────────────────────────────────────╯

            No sessions match "x".

             Type to Search · Enter to select · Esc to clear
        """

    static let allProjects = """
        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
           Resume session (1 of 12)
           ╭────────────────────────────────────────────────────────────╮
           │ ⌕ Search…                                                   │
           ╰────────────────────────────────────────────────────────────╯

           ❯ Fix the login page
             8 seconds ago · main · 12.1MB · /Users/me/Projects/shop

             TICKET-12 · Check the import status
             42 seconds ago · TICKET-12 · 830KB · /Users/me/Projects/shop

             (session)
             2 minutes ago · feat/where-to-watch · 3.6KB · /Users/me/Projects/films

           ↓ Plan the next release
             1 day ago · HEAD · 444.6KB · /Users/me/Projects/films

             Ctrl+A to only show current repo · Ctrl+B to only show current branch · Space to preview · Ctrl+R to rename · Type to search · Esc to cancel
        """

    @Test func resumeThisProject() throws {
        let p = try #require(ScreenPrompt.parse(screen: Self.resume))
        let r = try #require(p.resumeMenu)
        #expect(p.options.isEmpty)
        #expect(r.project == "cctest")
        #expect(r.search == "")
        #expect(r.position == nil)
        #expect(r.entries.count == 1)
        #expect(r.entries[0].title == "AskUserQuestion button color and pets")
        #expect(r.entries[0].details == "11 minutes ago · HEAD · 281.4KB")
        #expect(r.entries[0].when == "11 minutes ago")
        #expect(r.entries[0].folder == nil)
        #expect(r.entries[0].focused)
        #expect(!r.allProjects)
        #expect(r.canSwitchProjects)
        #expect(r.branchOnly == false)
        #expect(!r.searching)
        #expect(r.empty == nil)
    }

    @Test func resumeSearchWithNoMatch() throws {
        let r = try #require(ScreenPrompt.parse(screen: Self.noMatch)?.resumeMenu)
        #expect(r.search == "x")
        #expect(r.entries.isEmpty)
        #expect(r.empty == "No sessions match \"x\".")
        #expect(r.project == nil)
        #expect(r.searching)
    }

    @Test func resumeEveryProject() throws {
        let r = try #require(ScreenPrompt.parse(screen: Self.allProjects)?.resumeMenu)
        #expect(r.position == 1)
        #expect(r.total == 12)
        #expect(r.allProjects)
        #expect(r.project == nil)
        #expect(r.entries.map(\.title) == ["Fix the login page", "TICKET-12 · Check the import status", "(session)", "Plan the next release"])
        #expect(r.entries[1].details == "42 seconds ago · TICKET-12 · 830KB")
        #expect(r.entries[1].folder == "/Users/me/Projects/shop")
        #expect(r.entries.map(\.focused) == [true, false, false, false])
        #expect(r.moreBelow)
        #expect(!r.moreAbove)
        #expect(r.moves(to: 2) == ["down", "down"])
    }

    @Test func resumeSearchingEveryProject() throws {
        // The search's hint names no scope: the rows' folders tell.
        let screen = Self.allProjects
            .replacingOccurrences(of: "Ctrl+A to only show current repo · Ctrl+B to only show current branch · Space to preview · Ctrl+R to rename · Type to search · Esc to cancel",
                                  with: "Type to Search · Enter to select · Esc to clear")
            .replacingOccurrences(of: "❯ Fix", with: "  Fix")
        let r = try #require(ScreenPrompt.parse(screen: screen)?.resumeMenu)
        #expect(r.searching)
        #expect(r.allProjects)
        #expect(!r.canSwitchProjects)
        #expect(r.entries.allSatisfy { !$0.focused })
    }

    @Test func resumeFromTheSearch() throws {
        var r = try #require(ScreenPrompt.parse(screen: Self.allProjects)?.resumeMenu)
        for i in r.entries.indices { r.entries[i].focused = false }
        // ↓ leaves the search for the first row.
        #expect(r.moves(to: 0) == ["down"])
        #expect(r.moves(to: 2) == ["down", "down", "down"])
    }

    @Test func resumeNotFromTheConversation() {
        // `Resume session` in the conversation, a menu of another kind under it.
        let screen = """
          Resume session
          The list shows the conversations to go back to.
        ────────────────────────────────────────────────────────────────────────────────
         Bash command
           rm -rf build

         Do you want to proceed?
         ❯ 1. Yes
           2. No

         Esc to cancel
        """
        let p = ScreenPrompt.parse(screen: screen)
        #expect(p?.resumeMenu == nil)
        #expect(p?.options.map(\.label) == ["Yes", "No"])
    }

    @Test func resumeNotFromTheTranscript() {
        // Words in the conversation, Claude at work: no list to resume from.
        #expect(ScreenPrompt.parse(screen: """
        ⏺ Here is what the list shows:
          Resume session
          11 minutes ago · HEAD · 281.4KB

        ✻ Thinking… (esc to interrupt)
        ────────────────────────────────────────────────────────────────────────────────
        ❯ 
        ────────────────────────────────────────────────────────────────────────────────
        """)?.resumeMenu == nil)
    }

    @Test func frontMatterOverSeveralLines() {
        let text = """
        ---
        name: aws-cdk
        description: >-
          Authors, deploys, and troubleshoots AWS infrastructure
          using CDK.

          Second paragraph.
        notes: |
          one
          two
        allowed-tools:
          - Bash
          - Read
        argument-hint: [stack]
        summary: Goes on
          over two lines
        ---
        Body
        """
        let f = SlashCommand.frontMatter(text)
        #expect(f["description"] == "Authors, deploys, and troubleshoots AWS infrastructure using CDK.\nSecond paragraph.")
        #expect(f["notes"] == "one\ntwo")
        #expect(f["allowed-tools"] == "")
        #expect(f["argument-hint"] == "[stack]")
        #expect(f["summary"] == "Goes on over two lines")
        #expect(f["name"] == "aws-cdk")
    }

    @Test func claudeCodesOwnCommandsFirst() {
        let all = SlashCommand.builtIns + [SlashCommand("aws-cdk", "CDK", source: .personal, isSkill: true), SlashCommand("review", "Mine", source: .project)]
        let bare = SlashCommand.matching("", in: all)
        #expect(bare.first?.source == .builtIn)
        #expect(bare.last?.name == "aws-cdk")
        // Nothing typed: all of them, the person's own too.
        #expect(bare.count == all.count)
    }
}
