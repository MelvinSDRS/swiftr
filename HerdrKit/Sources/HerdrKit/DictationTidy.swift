import Foundation

/// What a small language model is asked to tidy a dictation up: the
/// rules, a few examples, the names to spell, and the text. As Lavoi asks
/// Qwen3: the words and their order kept, spelling, capitals and
/// punctuation put right, "um"s and stumbles left out, never an answer.
public enum DictationTidy {
    public struct Message: Equatable, Sendable {
        public let role: String
        public let content: String

        init(_ role: String, _ content: String) {
            self.role = role
            self.content = content
        }
    }

    static let rules = """
    You correct dictated text. The person spoke it to write a message to a coding assistant; you are not that assistant.
    Fix spelling, capitals and punctuation. Remove filler sounds (um, uh, euh, hum) and stumbles: a word said twice, a sentence started again.
    Keep every other word, in the same order and the same language. Never translate, shorten, explain or answer it: a question stays a question, an order stays an order.
    Write the names in the list as they are written there.
    Reply with the corrected text only.
    """

    /// Examples the model follows better than rules: a French request with
    /// a name, an English question it must not answer.
    static let examples: [(names: [String], heard: String, tidied: String)] = [
        (["ComposerField", "Swiftr"],
         "euh alors je voudrais que tu corriges le le bug dans composer field de swifter",
         "Alors, je voudrais que tu corriges le bug dans ComposerField de Swiftr."),
        (["README"],
         "um can you tell me why the build fails after you changed the readme",
         "Can you tell me why the build fails after you changed the README?"),
    ]

    static func ask(_ heard: String, names: [String]) -> String {
        let list = names.isEmpty ? "(none)" : names.joined(separator: ", ")
        return "Names: \(list)\nDictated text: \(heard)"
    }

    /// The conversation to give the model: rules, examples, then `heard`
    /// with the names to spell.
    public static func messages(heard: String, names: [String]) -> [Message] {
        var out = [Message("system", rules)]
        for example in examples {
            out.append(Message("user", ask(example.heard, names: example.names)))
            out.append(Message("assistant", example.tidied))
        }
        out.append(Message("user", ask(heard, names: names)))
        return out
    }

    /// Tokens the answer may take: a little more than the text heard.
    public static func tokenLimit(for heard: String) -> Int {
        max(32, heard.utf8.count / 2 + 24)
    }

    // MARK: Long dictations

    /// `text` in pieces the model tidies one at a time: whole sentences, a
    /// few together, about as long as each other and up to `limit`
    /// characters if they can. Given a long text, a small model gives it
    /// back as it was, or stops after its first sentence.
    public static func pieces(_ text: String, limit: Int = 240) -> [String] {
        var sentences: [String] = []
        var sentence = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            sentence += sentence.isEmpty ? word : " " + word
            // ". ! ? …", maybe in quotes; "Pourquoi ?" ends at its "?".
            let end = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"”»)]}’"))
            if let last = end.last, ".!?…".contains(last) {
                sentences.append(sentence)
                sentence = ""
            }
        }
        if !sentence.isEmpty { sentences.append(sentence) }
        // 250 characters: two pieces of about 125, not 240 and 10.
        let length = sentences.reduce(-1) { $0 + 1 + $1.count }
        let target = length / max(1, (length + limit - 1) / limit)
        var pieces: [String] = []
        for sentence in sentences {
            // A sentence joins the piece if most of it fits in the length aimed at.
            if let last = pieces.last, last.count + 1 + sentence.count <= limit, last.count + (1 + sentence.count) / 2 <= target {
                pieces[pieces.count - 1] = last + " " + sentence
            } else {
                pieces.append(sentence)
            }
        }
        return pieces
    }

    /// How tidying a dictation went: the text, and for tests and the log,
    /// "kept" when each piece was, else what went wrong with each.
    public struct Outcome: Equatable, Sendable {
        public let text: String
        public let note: String
    }

    /// `heard` tidied up piece by piece by `model`, which takes a piece and
    /// the names it holds, and answers nil once it's too late. A piece the
    /// model changed too much stays as heard; once one is late, the rest
    /// stay as heard too.
    public static func tidy(_ heard: String, terms: [String], limit: Int = 240, model: (String, [String]) throws -> String?) rethrows -> Outcome {
        var out: [String] = []
        var notes: [String] = []
        var late = false
        for piece in pieces(heard, limit: limit) {
            guard !late else {
                out.append(piece)
                continue
            }
            // The names written, for the model to keep as they are.
            let names = terms.filter { piece.localizedCaseInsensitiveContains($0) }
            guard let answer = try model(piece, names) else {
                late = true
                notes.append("late")
                out.append(piece)
                continue
            }
            let tidied = spaced(clean(answer), like: piece)
            if DictationText.isTidied(tidied, from: piece) {
                out.append(tidied)
            } else {
                notes.append("changed too much: \(tidied)")
                out.append(piece)
            }
        }
        return Outcome(text: out.joined(separator: " "), note: notes.isEmpty ? "kept" : notes.joined(separator: " | "))
    }

    /// `tidied` with a space before its ? and ! when `heard` has one, as
    /// French writes them: the model leaves it out.
    static func spaced(_ tidied: String, like heard: String) -> String {
        guard heard.contains(#/\s[?!]/#) else { return tidied }
        return tidied.replacing(#/([^\s?!])([?!]+)(?=\s|$)/#) { m in "\(m.1) \(m.2)" }
    }

    /// The model's answer without what it adds around the text: a
    /// thinking block, quotes, a "Corrected text:" label.
    public static func clean(_ answer: String) -> String {
        var s = answer.replacing(#/<think>[\s\S]*?<\/think>/#, with: "")
        s = s.replacing(#/^\s*(?i:corrected text|dictated text|text)\s*:\s*/#, with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let first = s.first, let last = s.last, "\"“«".contains(first), "\"”»".contains(last) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
