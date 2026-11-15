import Testing
@testable import HerdrKit

/// A table's columns sharing its width, and the table on the pasteboard.
@Suite struct MarkdownTableTests {
    @Test func roomToSpareGoesWithTheText() {
        // 700 wide, one 20-point gap: 680 for 340 of text; each column doubles.
        let widths = MarkdownTable.widths(widest: [40, 300], narrowest: [30, 100], width: 700, gap: 20)
        #expect(widths == [80, 600])
    }

    @Test func theLongestTextWrapsFirst() {
        // 400 for 650 of text: the short columns keep their width.
        let widths = MarkdownTable.widths(widest: [50, 500, 100], narrowest: [50, 80, 100], width: 400, gap: 0)
        #expect(widths == [50, 250, 100])
    }

    @Test func narrowerThanTheWidestWordsAllShrink() {
        let widths = MarkdownTable.widths(widest: [100, 200], narrowest: [60, 140], width: 100, gap: 0)
        #expect(widths == [30, 70])
    }

    @Test func noWidthMeansTheWidestLines() {
        #expect(MarkdownTable.widths(widest: [10, 20], narrowest: [5, 5], width: nil, gap: 8) == [10, 20])
        // A word measured wider than its line counts as the line.
        #expect(MarkdownTable.widths(widest: [10, 20], narrowest: [50, 5], width: 30, gap: 0) == [10, 20])
        #expect(MarkdownTable.widths(widest: [], narrowest: [], width: 30, gap: 0) == [])
    }

    @Test func markdownReadsBackAsTheSameTable() {
        let header = ["a | b", "Total"]
        let alignments: [MarkdownAlignment] = [.leading, .trailing]
        let rows = [["`x | y`", "2"], ["", "1,024"]]
        let text = MarkdownTable.markdown(header: header, alignments: alignments, rows: rows)
        #expect(text == "| a \\| b | Total |\n| --- | ---: |\n| `x \\| y` | 2 |\n|  | 1,024 |")
        #expect(MarkdownBlock.parse(text) == [.table(header: header, alignments: alignments, rows: rows)])
    }

    @Test func htmlKeepsTheMarks() {
        let html = MarkdownTable.html(header: ["Item", "Detail"], alignments: [.leading, .center],
                                      rows: [["**Docs**", "see [site](https://a.b)<br>`x<y`"]])
        #expect(html == "<table><thead><tr><th>Item</th><th align=\"center\">Detail</th></tr></thead><tbody><tr>"
            + "<td><strong>Docs</strong></td><td align=\"center\">see <a href=\"https://a.b\">site</a><br><code>x&lt;y</code></td>"
            + "</tr></tbody></table>")
    }

    @Test func breaksInCells() {
        #expect(MarkdownTable.shown("one<br>two<BR/>three<br />four") == "one\ntwo\nthree\nfour")
    }

    @Test func quoteAsHTML() {
        // As `MarkdownBlock.parse` gives a quote: its lines without `>`, a blank one between paragraphs.
        let text = "We **checked**: no records for `SPA`.\n- one\n- two\n\nTo fix: see [it](https://a.b)."
        #expect(MarkdownBlock.parse("> " + text.replacingOccurrences(of: "\n", with: "\n> ")) == [.quote(text)])
        #expect(MarkdownQuote.html(text) == "<p>We <strong>checked</strong>: no records for <code>SPA</code>.<br>- one<br>- two</p>"
            + "<p>To fix: see <a href=\"https://a.b\">it</a>.</p>")
        #expect(MarkdownQuote.html("") == "")
    }
}
