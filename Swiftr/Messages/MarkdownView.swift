import AppKit
import HerdrKit
import SwiftUI

/// Claude's Markdown, block by block.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    let size: Double
    /// Tables may take the room beside the conversation's column.
    var wideTables = false

    init(_ text: String, size: Double, wideTables: Bool = false) {
        blocks = MarkdownCache.blocks(text)
        self.size = size
        self.wideTables = wideTables
    }

    var body: some View {
        // Spaced as the Codex app's answers: loose lines, a line's room between blocks.
        VStack(alignment: .leading, spacing: size * 0.9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, size: size, wideTables: wideTables)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { PathLink.open($0) })
    }
}

extension EnvironmentValues {
    /// Paths in the agent's words link to Finder; off when the agent runs
    /// on another machine, whose files aren't this Mac's.
    @Entry var linksPaths = true
}

/// A path link's click: Finder opens a folder, and shows a file, an app
/// or another bundle selected in its folder.
@MainActor
enum PathLink {
    static func open(_ url: URL) -> OpenURLAction.Result {
        guard url.isFileURL else { return .systemAction }
        let path = url.path(percentEncoded: false)
        var folder: ObjCBool = false
        // Gone since the answer named it.
        guard FileManager.default.fileExists(atPath: path, isDirectory: &folder) else {
            NSSound.beep()
            return .handled
        }
        if folder.boolValue, !NSWorkspace.shared.isFilePackage(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return .handled
    }
}

private struct BlockView: View {
    @Environment(\.codeFamily) private var codeFamily
    @Environment(\.linksPaths) private var linksPaths
    let block: MarkdownBlock
    let size: Double
    let wideTables: Bool

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(MarkdownCache.inline(text, size: size, code: codeFamily, paths: linksPaths))
                .lineSpacing(size * 0.4)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            // The size goes in the styled text: a .font on the Text loses to it.
            Text(MarkdownCache.inline(text, size: size * (level == 1 ? 1.35 : level == 2 ? 1.2 : 1.05), weight: .semibold, code: codeFamily, paths: linksPaths))
                .padding(.top, size * 0.4)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text):
            CodeBlock(language: language, text: text, size: size)
        case .list(let items):
            VStack(alignment: .leading, spacing: size * 0.4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                            } else if let n = item.number {
                                Text("\(n).").monospacedDigit()
                            } else {
                                Text(item.level == 0 ? "•" : "◦")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(minWidth: size, alignment: .trailing)
                        Text(MarkdownCache.inline(item.text, size: size, code: codeFamily, paths: linksPaths))
                            .lineSpacing(size * 0.4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.level) * size * 1.4)
                }
            }
        case .quote(let text):
            QuoteBlock(text: text, size: size)
        case .table(let header, let alignments, let rows):
            TableBlock(header: header, alignments: alignments, rows: rows, size: size, reachesOut: wideTables)
        case .rule:
            Divider()
        }
    }
}

/// A quote: a bar beside words softer than the answer's. Often a draft to
/// paste elsewhere (a comment, a message): Copy shows on hover, and gives
/// its words without the `>`, as text and as HTML.
private struct QuoteBlock: View {
    @Environment(\.codeFamily) private var codeFamily
    @Environment(\.linksPaths) private var linksPaths
    let text: String
    let size: Double
    @State private var hovering = false
    @State private var copied = false

    private var showsCopy: Bool {
        #if DEBUG
        if HoverActions.debugShown { return true }
        #endif
        return hovering || copied
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.tertiary)
                .frame(width: 3)
            Text(MarkdownCache.inline(text, size: size, code: codeFamily, paths: linksPaths))
                .lineSpacing(size * 0.4)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                // Kept free for Copy.
                .padding(.trailing, size * 2.2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            if showsCopy {
                // Its middle on the first line's.
                BlockCopyButton(size: size, help: "Copy Quote", copied: $copied) {
                    BlockCopy.put(text: text, html: MarkdownQuote.html(text))
                }
                .offset(y: -size * 0.3)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A block of code: its language and Copy over it, as the Codex app has
/// them; Copy shows on hover when no language is named.
struct CodeBlock: View {
    @Environment(\.codeFamily) private var codeFamily
    let language: String
    let text: String
    let size: Double
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                HStack {
                    Text(language)
                        .font(.system(size: size * 0.82))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    copyButton
                }
                .padding(.leading, size)
                .padding(.trailing, size * 0.4)
                .padding(.top, size * 0.4)
            }
            SideScroll {
                Text(text)
                    .font(CodeFont.font(size * 0.92, family: codeFamily))
                    .lineSpacing(size * 0.25)
                    .fixedSize()
                    .padding(.horizontal, size)
                    .padding(.top, language.isEmpty ? size * 0.85 : size * 0.3)
                    .padding(.bottom, size * 0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: size))
        .overlay(alignment: .topTrailing) {
            if language.isEmpty, hovering {
                copyButton.padding(size * 0.3)
            }
        }
        .onHover { hovering = $0 }
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: size * 0.88))
                .frame(width: size * 1.9, height: size * 1.7)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Copy")
    }
}

/// Parsed Markdown, kept so scrolling doesn't parse it again.
@MainActor
enum MarkdownCache {
    private struct InlineKey: Hashable {
        let text: String
        let size: Double
        let weight: Font.Weight
        let code: String
        let digits: Bool
        let paths: Bool
    }

    private static var blockCache: [String: [MarkdownBlock]] = [:]
    private static var inlineCache: [InlineKey: AttributedString] = [:]

    static func blocks(_ text: String) -> [MarkdownBlock] {
        if let b = blockCache[text] { return b }
        let b = MarkdownBlock.parse(text)
        if blockCache.count > 3000 { blockCache.removeAll(keepingCapacity: true) }
        blockCache[text] = b
        return b
    }

    /// Web addresses Markdown leaves as text: in code (`http://localhost:8003`),
    /// and a local server's without its scheme (localhost:8003).
    private static let looseLink = /https?:\/\/[^\s<>`'"]+|\b(?:localhost|127\.0\.0\.1):\d{2,5}\b[^\s<>`'"]*/

    /// Makes those addresses links; a local server's opens over http.
    static func addLinks(_ a: inout AttributedString) {
        let text = String(a.characters)
        for match in text.matches(of: looseLink) {
            var found = String(match.output)
            // A sentence's last mark isn't the address's.
            while let last = found.last, ".,;:!?)]}".contains(last) { found.removeLast() }
            guard let url = URL(string: found.hasPrefix("http") ? found : "http://" + found), url.host() != nil else { continue }
            let start = a.characters.index(a.startIndex, offsetBy: text.distance(from: text.startIndex, to: match.range.lowerBound))
            let end = a.characters.index(start, offsetBy: found.count)
            // Markdown's own links stay as they are.
            guard !a[start ..< end].runs.contains(where: { $0.link != nil }) else { continue }
            a[start ..< end].link = url
        }
    }

    /// A path from `/` or `~/`, after a space, a quote or a bracket.
    private static let loosePath = /(?:^|[\s(\[{=:>"'])(~?\/[^\/\s<>"'`][^\s<>"'`]*)/
    /// A path between quotes, which may hold spaces.
    private static let quotedPath = /"(~?\/[^"\n]+)"|'(~?\/[^'\n]+)'/

    /// Makes paths to files and folders on this Mac links, which `PathLink`
    /// opens in Finder. A code span that is all path, or a quoted one, may
    /// hold spaces; what doesn't exist here stays text.
    static func addPathLinks(_ a: inout AttributedString) {
        let text = String(a.characters)
        // As character offsets: the same in the text and in `a`.
        var candidates: [(start: Int, words: Substring)] = []
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            let words = String(a[run.range].characters)
            let trimmed = words.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else { continue }
            let start = a.characters.distance(from: a.startIndex, to: run.range.lowerBound) + words.prefix { $0 == " " }.count
            candidates.append((start, Substring(trimmed)))
        }
        for match in text.matches(of: quotedPath) {
            guard let inner = match.output.1 ?? match.output.2 else { continue }
            candidates.append((text.distance(from: text.startIndex, to: inner.startIndex), inner))
        }
        for match in text.matches(of: loosePath) {
            candidates.append((text.distance(from: text.startIndex, to: match.output.1.startIndex), match.output.1))
        }
        var taken: [Range<Int>] = []
        for candidate in candidates {
            guard let (count, url) = pathTarget(candidate.words) else { continue }
            let span = candidate.start ..< candidate.start + count
            guard !taken.contains(where: { $0.overlaps(span) }) else { continue }
            let start = a.characters.index(a.startIndex, offsetBy: span.lowerBound)
            let end = a.characters.index(start, offsetBy: count)
            // Web addresses stay as they are.
            guard !a[start ..< end].runs.contains(where: { $0.link != nil }) else { continue }
            a[start ..< end].link = url
            taken.append(span)
        }
    }

    /// The file or folder `words` name on this Mac, and how many characters
    /// to link: without a sentence's last mark, with a `:line` the path
    /// itself drops.
    private static func pathTarget(_ words: Substring) -> (count: Int, url: URL)? {
        var shown = words
        while let last = shown.last, ".,;:!?)]}".contains(last) { shown.removeLast() }
        func full(_ s: Substring) -> String { s.hasPrefix("~") ? NSString(string: String(s)).expandingTildeInPath : String(s) }
        var path = full(shown)
        if !FileManager.default.fileExists(atPath: path), let line = shown.firstMatch(of: /(?::\d+){1,2}$/) {
            path = full(shown[..<line.range.lowerBound])
        }
        guard path.count > 1, FileManager.default.fileExists(atPath: path) else { return nil }
        return (shown.count, URL(filePath: path))
    }

    /// Inline marks (bold, italics, code, links) as styled text; code in the
    /// `code` family (see `CodeFont`). `digits`: all as wide, for tables.
    /// `paths`: paths on this Mac link to Finder (see `addPathLinks`).
    static func inline(_ text: String, size: Double, weight: Font.Weight = .regular, code: String, digits: Bool = false, paths: Bool = false) -> AttributedString {
        let key = InlineKey(text: text, size: size, weight: weight, code: code, digits: digits, paths: paths)
        if let a = inlineCache[key] { return a }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var a = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let base = Font.system(size: size, weight: weight)
        a.font = digits ? base.monospacedDigit() : base
        let strong: Font.Weight = weight == .regular ? .semibold : .bold
        for run in a.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let bold = intent.contains(.stronglyEmphasized)
            let italic = intent.contains(.emphasized)
            if intent.contains(.code) {
                a[run.range].font = CodeFont.font(size * 0.92, family: code, bold: bold || weight != .regular)
                a[run.range].backgroundColor = Color.primary.opacity(0.11)
            } else if bold || italic {
                var font = Font.system(size: size, weight: bold ? strong : weight)
                if italic { font = font.italic() }
                a[run.range].font = digits ? font.monospacedDigit() : font
            }
            if intent.contains(.strikethrough) { a[run.range].strikethroughStyle = .single }
        }
        addLinks(&a)
        if paths { addPathLinks(&a) }
        if inlineCache.count > 6000 { inlineCache.removeAll(keepingCapacity: true) }
        inlineCache[key] = a
        return a
    }
}
