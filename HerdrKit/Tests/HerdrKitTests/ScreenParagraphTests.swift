import Foundation
import Testing
@testable import HerdrKit

@Suite struct ScreenParagraphTests {
    /// Claude Code's folder trust dialog, as a wide terminal draws it.
    @Test func trustDialogReadsAsParagraphs() {
        let lines = [
            "/tmp/swiftr-cctest-976d",
            "",
            "Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take a moment to review what's in this",
            "folder first.",
            "",
            "Claude Code'll be able to read, edit, and execute files here.",
            "",
            "Security guide",
        ]
        #expect(ScreenParagraph.split(lines) == [
            ScreenParagraph("/tmp/swiftr-cctest-976d", prose: false),
            ScreenParagraph("Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take a moment to review what's in this folder first.", prose: true),
            ScreenParagraph("Claude Code'll be able to read, edit, and execute files here.", prose: true),
            ScreenParagraph("Security guide", prose: true),
        ])
    }

    @Test func shortLinesAndListsKeepTheirBreaks() {
        let lines = [
            "Bash command",
            "List files",
            "",
            "Before you go on, check these points about the folder you picked to work in:",
            "• it holds your own code",
            "• nobody else writes to it",
        ]
        #expect(ScreenParagraph.split(lines) == [
            ScreenParagraph("Bash command\nList files", prose: true),
            ScreenParagraph("Before you go on, check these points about the folder you picked to work in:\n• it holds your own code\n• nobody else writes to it", prose: true),
        ])
    }

    @Test func columnsCommandsAndIndentedLinesKeepTheirLayout() {
        #expect(ScreenParagraph.split(["Model    Opus", "Effort   high"]) == [ScreenParagraph("Model    Opus\nEffort   high", prose: false)])
        #expect(ScreenParagraph.split(["$ ls -la", "  total 8"]) == [ScreenParagraph("$ ls -la\n  total 8", prose: false)])
        // The box's own margin is not an indent.
        #expect(ScreenParagraph.split(["  Plain words here.", "  More words."]) == [ScreenParagraph("Plain words here.\nMore words.", prose: true)])
        #expect(ScreenParagraph.split(["HOME=/root"]) == [ScreenParagraph("HOME=/root", prose: false)])
        #expect(ScreenParagraph.split(["", "  ", ""]).isEmpty)
    }
}

@Suite struct LineDiffTests {
    @Test func keptLinesStayAsTheyAre() {
        #expect(LineDiff.lines(old: "hi", new: "hi\nbye") == [LineDiff.Line(.same, "hi"), LineDiff.Line(.added, "bye")])
        #expect(LineDiff.lines(old: "a\nb\nc", new: "a\nB\nc") == [
            LineDiff.Line(.same, "a"), LineDiff.Line(.removed, "b"), LineDiff.Line(.added, "B"), LineDiff.Line(.same, "c"),
        ])
        #expect(LineDiff.lines(old: "", new: "new file") == [LineDiff.Line(.added, "new file")])
        #expect(LineDiff.lines(old: "gone", new: "") == [LineDiff.Line(.removed, "gone")])
    }

    @Test func changesApartKeepTheirPlaces() {
        #expect(LineDiff.lines(old: "p\nq\nr", new: "p2\nq\nr2") == [
            LineDiff.Line(.removed, "p"), LineDiff.Line(.added, "p2"), LineDiff.Line(.same, "q"),
            LineDiff.Line(.removed, "r"), LineDiff.Line(.added, "r2"),
        ])
    }
}

@Suite struct ScreenDiffTests {
    /// Claude Code 2.1.317's edit prompt, before the call reaches the transcript.
    @Test func editBoxReadsAsADiff() throws {
        let rule = String(repeating: "─", count: 60), dashes = String(repeating: "╌", count: 60)
        let screen = """
        ❯ Change the line bye to goodbye in swiftr-made.txt, with the Edit tool.

        ● Update(swiftr-made.txt)

        \(rule)
         Edit file
         swiftr-made.txt
        \(dashes)
         1  hi
         2 -bye
         2   No newline at end of file
         3 +goodbye
         4   No newline at end of file
        \(dashes)
         Do you want to make this edit to swiftr-made.txt?
         ❯ 1. Yes
           2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this session (shift+tab)
           3. No

         Esc to cancel · Tab to amend
        """
        let p = try #require(ScreenPrompt.parse(screen: screen))
        #expect(p.options.count == 3)
        let diff = try #require(p.screenDiff)
        #expect(diff.file == "swiftr-made.txt")
        #expect(diff.lines == [LineDiff.Line(.same, "hi"), LineDiff.Line(.removed, "bye"), LineDiff.Line(.added, "goodbye")])
    }

    @Test func aCommandIsNoDiff() throws {
        let rule = String(repeating: "─", count: 60), dashes = String(repeating: "╌", count: 60)
        let screen = """
        \(rule)
         Bash command
        \(dashes)
         2 + 2
        \(dashes)
         Do you want to proceed?
         ❯ 1. Yes
           2. No
        """
        let p = try #require(ScreenPrompt.parse(screen: screen))
        #expect(p.screenDiff == nil)
    }
}

@Suite struct RemoteHistoryTests {
    @Test func lineReadsTheFoldersMessagesThere() {
        let line = PromptHistory.remoteLine(config: ".claude", project: "/tmp/it's here", tailBytes: 100)
        #expect(line == #"tail -c 100 '.claude/history.jsonl' 2>/dev/null | grep -F '"project":"/tmp/it'\''s here"' | tail -n 500"#)
    }
}
