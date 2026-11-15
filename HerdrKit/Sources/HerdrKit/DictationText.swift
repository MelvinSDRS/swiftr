import Foundation

/// What dictation does to the words it heard before they go in the field:
/// the sounds that aren't words left out, the tidy-up checked, the text
/// put in at the cursor.
public enum DictationText {
    /// Sounds people make while they think, in the languages people dictate
    /// to Swiftr in: never words of the message.
    static let fillers: Set<String> = ["euh", "euhm", "heu", "hum", "hmm", "hm", "mmh", "mh", "um", "umm", "uh", "uhm", "erm"]

    /// `text` without its filler sounds, and the commas they leave behind.
    public static func withoutFillers(_ text: String) -> String {
        var s = text
        let words = fillers.sorted { $0.count > $1.count }.joined(separator: "|")
        // "Alors, euh, je…" and "euh… je": the filler and its comma go.
        s = s.replacing(try! Regex("(?i)(^|[\\s,;])(?:\(words))(?:…|\\.\\.\\.|,)?(?=[\\s,.!?;…]|$)").wordBoundaryKind(.simple)) { m in
            String(m.output[1].substring ?? "")
        }
        s = s.replacing(#/\s+([,.…])/#) { m in m.1 }
        s = s.replacing(#/([,;])\s*([,;.!?…])/#) { m in m.2 }
        s = s.replacing(#/^\s*[,;]\s*/#, with: "")
        s = s.replacing(#/ {2,}/#, with: " ")
        s = s.trimmingCharacters(in: .whitespaces)
        // The first word after a dropped "Euh," starts the sentence.
        if text.first?.isUppercase == true, let first = s.first, first.isLowercase {
            s = first.uppercased() + s.dropFirst()
        }
        return s
    }

    // MARK: Stumbles

    /// `text` without the stumbles the speech model writes down as said: a
    /// word or a few said twice ("c'est c'est", "beaucoup plus beaucoup
    /// plus"), an article started again ("le la sélection", "de du"), a
    /// word's first letter said alone ("c c'est"). And words it writes
    /// wrong that can only be one thing: "il ya", "où bien", a sentence
    /// that starts "Où par exemple" or "Où alors".
    public static func withoutStumbles(_ text: String) -> String {
        var s = text.replacing(#/(?i)\b(il) ya\b/#) { m in "\(m.1) y a" }
        s = s.replacing(#/\b([Oo])ù bien\b/#) { m in "\(m.1)u bien" }
        // "Où alors ?" asks where.
        s = s.replacing(#/(^|[.!?…]\s+)Où (par exemple|alors)\b(?!\s*\?)/#) { m in "\(m.1)Ou \(m.2)" }
        var tokens = Token.split(s)
        var i = 0
        while i < tokens.count {
            guard let (count, article) = stumble(at: i, in: tokens) else {
                i += 1
                continue
            }
            let dropped = tokens[i]
            var kept = tokens[i + count]
            // The sentence started with what goes: it starts with what stays.
            let starts = i == 0 ? dropped.text.first?.isUppercase == true : tokens[i - 1].endsSentence
            if starts {
                kept.text = kept.text.prefix(1).uppercased() + kept.text.dropFirst()
            } else if article, dropped.text.first?.isLowercase == true {
                // "le La sélection": the article in a sentence is small.
                kept.text = kept.text.prefix(1).lowercased() + kept.text.dropFirst()
            }
            // An opening bracket or quote before what goes stays.
            let opening = dropped.text.prefix { "([{\"“«‘".contains($0) }
            if !opening.isEmpty, !kept.text.hasPrefix(opening) { kept.text = opening + kept.text }
            tokens[i + count] = kept
            tokens.removeSubrange(i ..< i + count)
            // What came before may now repeat what follows.
            i = max(0, i - 3)
        }
        return tokens.map { $0.text + $0.space }.joined().trimmingCharacters(in: .whitespaces)
    }

    /// The stumble that starts at token `i`, if any: how many tokens go,
    /// and whether they are an article started again.
    private static func stumble(at i: Int, in tokens: [Token]) -> (Int, article: Bool)? {
        // The same words twice: the first time goes. Not across sentences,
        // nor numbers, which may well repeat.
        for n in [3, 2, 1] where i + 2 * n <= tokens.count {
            let first = tokens[i ..< i + n]
            let second = tokens[i + n ..< i + 2 * n]
            guard !first.contains(where: \.endsSentence),
                  zip(first, second).allSatisfy({ !$0.word.isEmpty && $0.word == $1.word }),
                  !first.contains(where: { $0.word.contains(where: \.isNumber) })
            else { continue }
            // "a a" may be a variable; "I I" is a stumble.
            if n == 1, doubles.contains(first[i].word) || (first[i].word.count == 1 && first[i].word != "i") { continue }
            return (n, false)
        }
        guard i + 1 < tokens.count, !tokens[i].endsSentence else { return nil }
        let word = tokens[i].word
        let next = tokens[i + 1]
        // "le la sélection": an article, then another before a noun. A
        // comma or nothing after the second, and it isn't one: "donner le la".
        if let others = restarts[word], others.contains(next.word), next.text == next.text.trimmingCharacters(in: Token.punctuation),
           i + 2 < tokens.count, !tokens[i + 2].word.isEmpty
        {
            return (1, true)
        }
        // "c c'est": a word's first letter alone, small, before it.
        if word.count == 1, tokens[i].text == word, word.first?.isLetter == true, !letters.contains(word),
           next.word.count > 1, next.word.hasPrefix(word)
        {
            return (1, false)
        }
        return nil
    }

    /// Words people say twice on purpose: "nous nous sommes", "vous vous
    /// trompez", "that that", "had had", "non non", "very very".
    static let doubles: Set<String> = [
        "nous", "vous", "très", "trop", "non", "oui", "si", "bon", "ah", "oh", "ha", "bla", "vite", "allez", "toc",
        "that", "had", "is", "do", "very", "really", "so", "no", "yes", "bye", "now", "well", "hey", "go", "ok", "okay",
        "far", "long", "many", "much", "way", "blah",
    ]

    /// Letters that are words, never taken for a word's first letter
    /// said alone: "il a à faire", "il y a", "ô", "i".
    static let letters: Set<String> = ["a", "à", "y", "o", "ô", "i"]

    /// An article or preposition, and those that, said right after it,
    /// take its place.
    static let restarts: [String: Set<String>] = [
        "le": ["la", "les"], "la": ["le", "les"], "les": ["le", "la"],
        "un": ["une"], "une": ["un"],
        "de": ["du", "des"],
    ]

    /// A word as dictation reads it, and the spaces after it.
    struct Token {
        var text: String
        let space: String
        /// The word, small, without the punctuation around it.
        let word: String
        /// It ends with . ! ? or …, or is one of them alone.
        let endsSentence: Bool

        static let punctuation = CharacterSet(charactersIn: ",.;:!?…\"“”«»()[]{}‘’").union(.whitespaces)

        init(_ text: String, space: String) {
            self.text = text
            self.space = space
            word = text.trimmingCharacters(in: Self.punctuation).lowercased()
            let end = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"”»)]}’"))
            endsSentence = end.last.map { ".!?…".contains($0) } ?? false
        }

        static func split(_ text: String) -> [Token] {
            var tokens: [Token] = []
            var word = ""
            var space = ""
            for c in text {
                if c.isWhitespace {
                    space.append(c)
                } else {
                    if !space.isEmpty {
                        if !word.isEmpty { tokens.append(Token(word, space: space)) }
                        word = ""
                        space = ""
                    }
                    word.append(c)
                }
            }
            if !word.isEmpty { tokens.append(Token(word, space: space)) }
            return tokens
        }
    }

    /// The words of `text`, lowercased and without accents, for comparing
    /// two versions of a dictation.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !fillers.contains($0) }
    }

    /// Whether `tidied` is `heard` tidied up, not something else: a small
    /// model asked to tidy a question may answer it, or translate it, or
    /// cut it short, or leave a sentence out. Read in order, the words of
    /// each are those of the other, but for one in ten at most, never three
    /// in a row; and the length is about the same.
    public static func isTidied(_ tidied: String, from heard: String) -> Bool {
        let before = words(heard)
        let after = words(tidied)
        guard !after.isEmpty else { return before.isEmpty }
        guard !before.isEmpty else { return false }
        let ratio = Double(after.count) / Double(before.count)
        guard ratio >= 0.6, ratio <= 1.3 else { return false }
        let (inBefore, inAfter) = matched(before, after)
        // A name joined or split ("composer field", "ComposerField") is in
        // the other's words left over.
        func left(_ list: [String], _ found: [Bool]) -> String {
            zip(list, found).filter { !$0.1 }.map(\.0).joined()
        }
        func fits(_ list: [String], _ found: [Bool], others: String) -> Bool {
            var missing = 0
            var run = 0
            for (word, found) in zip(list, found) {
                if found || (word.count > 3 && others.contains(word)) {
                    run = 0
                } else {
                    missing += 1
                    run += 1
                    if run == 3 { return false }
                }
            }
            return missing <= max(1, list.count / 10)
        }
        return fits(before, inBefore, others: left(after, inAfter)) && fits(after, inAfter, others: left(before, inBefore))
    }

    /// Which words of `a` and of `b` the two have in common, in the same
    /// order: their longest common sequence.
    static func matched(_ a: [String], _ b: [String]) -> ([Bool], [Bool]) {
        // longest[i][j]: the longest common sequence of a[i...] and b[j...].
        var longest = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in a.indices.reversed() {
            for j in b.indices.reversed() {
                longest[i][j] = a[i] == b[j] ? longest[i + 1][j + 1] + 1 : max(longest[i + 1][j], longest[i][j + 1])
            }
        }
        var inA = Array(repeating: false, count: a.count)
        var inB = Array(repeating: false, count: b.count)
        var (i, j) = (0, 0)
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                (inA[i], inB[j]) = (true, true)
                (i, j) = (i + 1, j + 1)
            } else if longest[i + 1][j] >= longest[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (inA, inB)
    }

    /// `text` with `dictated` put in at `offset` (UTF-16, a selection's
    /// end), a space on each side where words would touch. Returns the new
    /// text and where the cursor goes: after what was put in.
    public static func insert(_ dictated: String, into text: String, at offset: Int) -> (text: String, caret: Int) {
        let ns = text as NSString
        let at = max(0, min(offset, ns.length))
        let before = ns.substring(to: at)
        let after = ns.substring(from: at)
        var piece = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return (text, at) }
        if let last = before.last, !last.isWhitespace, !"([{\"'“‘«/".contains(last),
           let first = piece.first, !",.;:!?)]}…".contains(first)
        {
            piece = " " + piece
        }
        if let next = after.first, next.isLetter || next.isNumber || "([{\"“«".contains(next) {
            piece += " "
        }
        return (before + piece + after, at + (piece as NSString).length)
    }
}
