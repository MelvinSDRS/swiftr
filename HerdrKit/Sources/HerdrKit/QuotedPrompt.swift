import Foundation

/// A message that quotes the conversation: the passages the person picked
/// in it, then what they ask about them. Written as the Codex app writes
/// one: `# Selected text:`, a `## Selection N` heading over each passage,
/// then `## My request:` over the question. The passages come first and
/// the question last, under headings that keep each part apart, as
/// Anthropic's and OpenAI's prompt guides advise; and a Codex session
/// reads back in the Codex app as it would there.
public struct QuotedPrompt: Equatable, Sendable {
    /// The passages, in the order picked.
    public var quotes: [String]
    /// What the person asks about them; empty when they ask nothing.
    public var request: String

    public static let quotesHeading = "# Selected text:"
    public static let requestHeading = "## My request:"

    public init(quotes: [String], request: String) {
        self.quotes = quotes
        self.request = request
    }

    /// A passage as it goes in a message: without the blank lines around it,
    /// nor the spaces it ends with. Several lines keep the first one's
    /// indent, which code needs to line up; one line loses it.
    public static func tidy(_ passage: String) -> String {
        var lines = passage.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        lines = lines.map { String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) }
        if lines.count == 1 { lines[0] = lines[0].trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n")
    }

    /// The message to send; just the request when nothing is quoted.
    public var text: String {
        let asked = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let passages = quotes.map(Self.tidy).filter { !$0.isEmpty }
        guard !passages.isEmpty else { return asked }
        var out = Self.quotesHeading + "\n"
        for (i, passage) in passages.enumerated() {
            out += "\n## Selection \(i + 1)\n\(passage)\n"
        }
        if !asked.isEmpty { out += "\n\(Self.requestHeading)\n\(asked)" }
        return out
    }

    /// A message read back; nil when it quotes nothing. Codex's own start
    /// with a line break, its older ones say `## My request for Codex:`,
    /// and a passage from a file comes as JSON under `## Selection N (file)`.
    public init?(parsing message: String) {
        var lines = message.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == Self.quotesHeading else { return nil }
        lines.removeFirst()
        // The last such heading: a passage may hold one of its own.
        var request = ""
        if let at = lines.lastIndex(where: Self.isRequestHeading) {
            request = lines[(at + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.removeSubrange(at...)
        }
        var passages: [String] = []
        var current: [String]?
        var fromFile = false
        func close() {
            guard let body = current.map({ Self.tidy($0.joined(separator: "\n")) }), !body.isEmpty else { return }
            if fromFile, let data = body.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["text"] as? String
            {
                passages.append(Self.tidy(text))
            } else {
                passages.append(body)
            }
        }
        for line in lines {
            if let file = Self.selectionHeading(line) {
                close()
                current = []
                fromFile = file
            } else {
                current?.append(line)
            }
        }
        close()
        passages.removeAll { $0.isEmpty }
        guard !passages.isEmpty else { return nil }
        self.init(quotes: passages, request: request)
    }

    /// As Markdown, for a copy: each passage as a quote, then the request.
    public var markdown: String {
        let quoted = quotes.map { passage in
            passage.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        }
        let asked = request.trimmingCharacters(in: .whitespacesAndNewlines)
        return (quoted + (asked.isEmpty ? [] : [asked])).joined(separator: "\n\n")
    }

    private static func isRequestHeading(_ line: String) -> Bool {
        let l = line.trimmingCharacters(in: .whitespaces)
        return l == requestHeading || l == "## My request for Codex:"
    }

    /// `## Selection 2`: false; Codex's `## Selection 2 (file)`, whose
    /// passage is JSON: true; not a passage's heading: nil.
    private static func selectionHeading(_ line: String) -> Bool? {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard l.hasPrefix("## Selection ") else { return nil }
        let rest = l.dropFirst("## Selection ".count)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let tail = rest.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        if tail.isEmpty { return false }
        if tail == "(file)" || tail == "(annotated file)" { return true }
        // `## Selection 1: Sources/App.swift (lines 4-9)`: the lines as they are.
        if tail.hasPrefix(":") { return false }
        return nil
    }
}
