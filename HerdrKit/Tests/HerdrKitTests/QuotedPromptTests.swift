import Testing
@testable import HerdrKit

@Suite struct QuotedPromptTests {
    @Test func oneQuoteThenTheQuestion() {
        let p = QuotedPrompt(quotes: ["  The cache keeps rows for 5 minutes.\n"], request: " Why 5? \n")
        #expect(p.text == """
        # Selected text:

        ## Selection 1
        The cache keeps rows for 5 minutes.

        ## My request:
        Why 5?
        """)
        #expect(QuotedPrompt(parsing: p.text) == QuotedPrompt(quotes: ["The cache keeps rows for 5 minutes."], request: "Why 5?"))
    }

    @Test func severalQuotesKeepTheirLines() {
        let p = QuotedPrompt(quotes: ["func a() {\n    b()\n}", "Second\n\npassage"], request: "Line one\nline two")
        let back = QuotedPrompt(parsing: p.text)
        #expect(back?.quotes == ["func a() {\n    b()\n}", "Second\n\npassage"])
        #expect(back?.request == "Line one\nline two")
        #expect(p.text.contains("\n## Selection 2\nSecond\n\npassage\n"))
    }

    @Test func codeKeepsItsIndent() {
        // Selected from a line's start: the first line's indent lines up with the rest.
        let code = "\n    if ready {\n        go()\n    }   \n\n"
        #expect(QuotedPrompt.tidy(code) == "    if ready {\n        go()\n    }")
        #expect(QuotedPrompt.tidy("  one line  ") == "one line")
        let back = QuotedPrompt(parsing: QuotedPrompt(quotes: [code], request: "Why?").text)
        #expect(back?.quotes == ["    if ready {\n        go()\n    }"])
    }

    @Test func aQuoteAloneHasNoRequest() {
        let p = QuotedPrompt(quotes: ["Only this"], request: "  ")
        #expect(p.text == "# Selected text:\n\n## Selection 1\nOnly this\n")
        #expect(QuotedPrompt(parsing: p.text) == QuotedPrompt(quotes: ["Only this"], request: ""))
    }

    @Test func nothingQuotedIsTheRequestAlone() {
        #expect(QuotedPrompt(quotes: [" ", ""], request: "Hello").text == "Hello")
    }

    @Test func codexAppMessages() {
        // As the Codex app sends one: a line break first; older ones name Codex.
        let codex = "\n# Selected text:\n\n## Selection 1\nUse a lock here.\n\n## My request for Codex:\nWhich lock?\n"
        #expect(QuotedPrompt(parsing: codex) == QuotedPrompt(quotes: ["Use a lock here."], request: "Which lock?"))
        let file = "# Selected text:\n\n## Selection 1 (file)\n{\"path\":\"a.swift\",\"startLine\":3,\"endLine\":4,\"text\":\"let x = 1\\n\\u0023if DEBUG\"}\n\n## My request:\nExplain"
        #expect(QuotedPrompt(parsing: file) == QuotedPrompt(quotes: ["let x = 1\n#if DEBUG"], request: "Explain"))
        let lines = "# Selected text:\n\n## Selection 1: a.swift (lines 3-4)\nlet x = 1\n\n## My request:\nWhy?"
        #expect(QuotedPrompt(parsing: lines)?.quotes == ["let x = 1"])
    }

    @Test func otherMessagesAreNotQuotes() {
        #expect(QuotedPrompt(parsing: "Hello") == nil)
        #expect(QuotedPrompt(parsing: "# Selected text: inline") == nil)
        #expect(QuotedPrompt(parsing: "# Selected text:\n\nNo passage heading") == nil)
        #expect(QuotedPrompt(parsing: "Look:\n# Selected text:\n\n## Selection 1\nx") == nil)
    }

    @Test func aPassageMayHoldTheHeadings() {
        // The request is under the last heading; a passage's own stays in it.
        let p = QuotedPrompt(quotes: ["## My request:\nnot this"], request: "This one")
        let back = QuotedPrompt(parsing: p.text)
        #expect(back?.request == "This one")
        #expect(back?.quotes == ["## My request:\nnot this"])
    }

    @Test func markdownForACopy() {
        let p = QuotedPrompt(quotes: ["One\n\nTwo"], request: "Why?")
        #expect(p.markdown == "> One\n>\n> Two\n\nWhy?")
        #expect(QuotedPrompt(quotes: ["A"], request: "").markdown == "> A")
    }
}
