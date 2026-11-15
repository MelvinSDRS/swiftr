import Foundation

/// What a Swiftr release brings, as its notes tell it: a few sections
/// ("What's New", "Improvements", "Bug Fixes"), each a few short lines.
/// scripts/release.sh takes them from release-notes/<version>.txt and puts
/// them, as Markdown, in the GitHub release and in the feed installed
/// copies read:
///
///     ## What's New
///     - Swiftr › Check for Updates… updates Swiftr, herdr-core and your models.
///
///     ## Bug Fixes
///     - A long paste no longer loses its last line.
public struct ReleaseNotes: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        /// Empty for lines that come before any heading.
        public var title: String
        public var items: [String]

        public init(title: String, items: [String]) {
            self.title = title
            self.items = items
        }
    }

    public var sections: [Section]

    public var isEmpty: Bool { sections.isEmpty }

    /// Reads the notes, as Markdown or as the plain text of the notes file
    /// (headings alone on their line, items after "• "). Other notes, such
    /// as the ones GitHub writes, come out as well as they can: a line that
    /// is neither a heading nor an item heads a section of its own.
    public init(_ text: String) {
        var sections: [Section] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            // An empty line, or a list's mark with nothing after it.
            if line.isEmpty || ["•", "-", "*"].contains(line) { continue }
            if let item = Self.item(line) {
                if sections.isEmpty { sections.append(Section(title: "", items: [])) }
                sections[sections.count - 1].items.append(item)
            } else {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { sections.append(Section(title: title, items: [])) }
            }
        }
        self.sections = sections
    }

    /// The words of a list's line, nil for any other line.
    private static func item(_ line: String) -> String? {
        for mark in ["• ", "- ", "* "] where line.hasPrefix(mark) {
            return line.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
