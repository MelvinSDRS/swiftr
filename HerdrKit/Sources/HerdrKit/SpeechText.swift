import Foundation

/// An agent's Markdown as the words a voice reads: its sentences without
/// the marks, code blocks left out, a path said by its file's name, a web
/// address by its site. Every line ends on a stop, so the voice pauses
/// where the eye would.
public enum SpeechText {
    /// What a voice reads of `markdown`, a line per sentence or table row;
    /// empty when nothing is left to read. In a `language` Swiftr writes
    /// the words of, signs and units are words too (`SpeechWords`).
    public static func make(_ markdown: String, language: String = "") -> String {
        var lines: [String] = []
        for block in MarkdownBlock.parse(markdown) {
            switch block {
            case .paragraph(let text), .quote(let text):
                lines += joinWrapped(text).map { sentence(inline($0, language: language)) }
            case .heading(_, let text):
                lines.append(sentence(inline(text, language: language)))
            case .list(let items):
                for item in items {
                    var said = joinWrapped(item.text).map { sentence(inline($0, language: language)) }.filter { !$0.isEmpty }
                    if let number = item.number, !said.isEmpty { said[0] = "\(number). " + said[0] }
                    lines += said
                }
            case .table(let header, _, let rows):
                for row in [header] + rows {
                    lines.append(sentence(row.map { inline($0, language: language) }.filter { !$0.isEmpty }.joined(separator: ", ")))
                }
            case .code, .rule:
                break
            }
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A block's lines, the pieces of a hard-wrapped sentence joined back: a
    /// line that starts in lower case goes on the one before when that one
    /// hasn't ended.
    static func joinWrapped(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let last = out.last, !ends(last), line.first?.isLowercase == true {
                out[out.count - 1] = last + " " + line
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// Whether `s` ends a sentence, marks aside.
    static func ends(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: CharacterSet(charactersIn: " *_`")).last else { return false }
        return ".!?…:;".contains(last)
    }

    /// `s` with a stop at its end, unless it has one or a comma.
    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return "" }
        return ".!?…:;,".contains(last) ? t : t + "."
    }

    /// One line's inline Markdown as plain words: marks dropped, a link by
    /// its words, code said short.
    static func inline(_ text: String, language: String = "") -> String {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let a = try? AttributedString(markdown: text, options: options) else {
            return SpeechWords.say(plain(text), language: language)
        }
        var out = ""
        for run in a.runs {
            let piece = String(a[run.range].characters)
            if run.inlinePresentationIntent?.contains(.code) == true {
                out += SpeechWords.code(code(piece), language: language)
            } else if run.link != nil, let site = site(piece) {
                // A link whose words are its address.
                out += site
            } else {
                out += piece
            }
        }
        return SpeechWords.say(plain(out), language: language)
    }

    /// Code inside a line, as it's said: a web address by its site, a long
    /// command by its program's name, a path by its file's name, a name
    /// written in camelCase, snake_case or kebab-case as words.
    static func code(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if let site = site(t) { return site }
        if t.count > 40, let program = t.split(separator: " ").first { t = String(program) }
        t = fileName(t)
        // --safe-mode: the dashes aren't said.
        t = String(t.drop { $0 == "-" })
        t = t.replacing(#/(\p{L})[_-]+(?=\p{L})/#) { m in "\(m.1) " }
        t = t.replacing(#/([\p{Ll}0-9])(\p{Lu})/#) { m in "\(m.1) \(m.2)" }
        t = t.replacing(#/(\p{Lu})(\p{Lu}\p{Ll})/#) { m in "\(m.1) \(m.2)" }
        return t
    }

    /// A web address's site, without `www.`; nil when `text` isn't one.
    static func site(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("http://") || t.hasPrefix("https://"), !t.contains(" "),
              let host = URL(string: t)?.host(), !host.isEmpty
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A path's last part, without the line after a file (`Rows.swift:335`).
    /// A path has two slashes at least, or starts at `/`, `~/`, `./` or `../`:
    /// `fr/en` stays as it is, and so does a date.
    static func fileName(_ path: String) -> String {
        var s = path
        if let m = s.wholeMatch(of: #/(.*[\p{L}\d_-]\.[A-Za-z][A-Za-z0-9]{0,9})(?::\d+){1,2}/#) { s = String(m.1) }
        let slashes = s.count(where: { $0 == "/" })
        let rooted = s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("./") || s.hasPrefix("../")
        guard slashes >= 2 || (rooted && slashes >= 1), !s.contains(" "), s.contains(where: \.isLetter),
              let last = s.split(separator: "/").last
        else { return s }
        return String(last)
    }

    /// What's left of the marks and of the things a voice reads badly,
    /// on plain words: web addresses, paths, arrows, tags, spaces.
    static func plain(_ text: String) -> String {
        var s = text
        s = s.replacing(#/https?:\/\/[^\s<>"'`]+/#) { m in
            var address = String(m.output)
            var after = ""
            // A sentence's last mark isn't the address's.
            while let last = address.last, ".,;:!?)]}".contains(last) {
                after = String(last) + after
                address.removeLast()
            }
            return (site(address) ?? address) + after
        }
        s = s.replacing(#/(?:~|\.{1,2})?\/?[\p{L}\d_.@+-]+(?:\/[\p{L}\d_.@+-]+)+\/?(?::\d+){0,2}/#) { m in
            fileName(String(m.output))
        }
        s = s.replacing(#/\b([\p{L}\d_-]+\.[A-Za-z][A-Za-z0-9]{0,9}):\d+(?::\d+)?\b/#) { m in String(m.1) }
        s = s.replacing(#/\s*(?:→|⇒|⟶|->)\s*/#, with: ", ")
        s = s.replacing(#/\s+·\s+/#, with: ", ")
        s = s.replacing(#/<\/?[A-Za-z][^>]*>/#, with: "")
        s = s.replacing(#/\*\*|__|~~|`/#, with: "")
        s = s.replacing(#/\s{2,}/#, with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }
}
