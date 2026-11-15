import Foundation

/// What a Markdown quote gives the pasteboard: often a draft (a comment,
/// a message) to paste elsewhere.
public enum MarkdownQuote {
    /// The quote's words as HTML, for apps that paste formatted text
    /// (Jira, Mail, Notes): a paragraph for each run of lines between blank
    /// ones, its lines broken as written, its bold, italics, code, struck
    /// text and links kept.
    public static func html(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { "<p>" + MarkdownTable.html($0.joined(separator: "\n")) + "</p>" }
            .joined()
    }
}
