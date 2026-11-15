import Testing
@testable import HerdrKit

/// A release's notes, as the Updates pane reads them from the feed.
@Suite struct ReleaseNotesTests {
    @Test func readsTheFeedsMarkdown() {
        let notes = ReleaseNotes("""
        ## What's New
        - Swiftr › Check for Updates… updates Swiftr, herdr-core and your models.
        - A second line.

        ## Bug Fixes
        - A long paste no longer loses its last line.
        """)
        #expect(notes.sections == [
            .init(title: "What's New", items: ["Swiftr › Check for Updates… updates Swiftr, herdr-core and your models.", "A second line."]),
            .init(title: "Bug Fixes", items: ["A long paste no longer loses its last line."]),
        ])
    }

    @Test func readsTheNotesFileAsWritten() {
        let notes = ReleaseNotes("What's New\n• One\n\nImprovements\n• Two\n• Three\n")
        #expect(notes.sections == [
            .init(title: "What's New", items: ["One"]),
            .init(title: "Improvements", items: ["Two", "Three"]),
        ])
    }

    @Test func keepsWhatItDoesNotKnow() {
        // GitHub's own notes: a heading, items with "*", then a bare line.
        let notes = ReleaseNotes("## What's Changed\r\n* A change by @someone\r\n\r\n**Full Changelog**: https://example.com/compare/a...b\r\n")
        #expect(notes.sections == [
            .init(title: "What's Changed", items: ["A change by @someone"]),
            .init(title: "**Full Changelog**: https://example.com/compare/a...b", items: []),
        ])
    }

    @Test func itemsBeforeAnyHeadingStay() {
        let notes = ReleaseNotes("- One\n- Two")
        #expect(notes.sections == [.init(title: "", items: ["One", "Two"])])
    }

    @Test func nothingGivesNothing() {
        #expect(ReleaseNotes("").isEmpty)
        #expect(ReleaseNotes(" \n\n#\n- \n").isEmpty)
    }
}
