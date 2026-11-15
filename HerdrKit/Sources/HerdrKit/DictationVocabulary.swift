import Foundation

/// The names dictation writes as they're spelled: the person's own list,
/// Swiftr's, and those the conversation uses (files, types, functions).
/// A speech model hears "swifter" or "composer field"; a second pass
/// checks these names against the sound and puts them back.
public enum DictationVocabulary {
    /// Swiftr's own names. Not the agents': the speech model writes them
    /// well, and "code" would risk turning into "Codex".
    public static let builtIn = ["Swiftr", "herdr"]

    /// The names in `list`, as Settings keeps it: one a line, or between
    /// commas.
    public static func parse(_ list: String) -> [String] {
        list.split { $0 == "\n" || $0 == "," }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The names written in `messages` (oldest first), the most used and
    /// the latest first: file names, types, functions, settings. At most
    /// `limit`, as a long list makes wrong replacements likelier.
    public static func names(in messages: [String], limit: Int = 30) -> [String] {
        var score: [String: Double] = [:]
        var spelling: [String: String] = [:]
        for (index, message) in messages.enumerated() {
            // Later messages count more: the talk is about them now.
            let weight = 1 + Double(index) / Double(max(messages.count, 1))
            for name in candidates(in: message) {
                let key = name.lowercased()
                score[key, default: 0] += weight
                spelling[key] = name
            }
        }
        return score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .compactMap { spelling[$0.key] }
    }

    /// The names a message writes: code spans that are one word, file
    /// names without their extension, and words in camelCase or
    /// snake_case.
    static func candidates(in text: String) -> [String] {
        var found: [String] = []
        for match in text.matches(of: #/`([^`\n]+)`/#) {
            let span = String(match.1).trimmingCharacters(in: .whitespaces)
            guard !span.contains(" ") else { continue }
            // A path: its last part.
            let last = span.split(separator: "/").last.map(String.init) ?? span
            if let name = name(last) { found.append(name) }
        }
        let prose = text.replacing(#/```[\s\S]*?```|`[^`\n]*`|https?:\/\/\S+/#, with: " ")
        for match in prose.matches(of: #/[A-Za-z_][A-Za-z0-9_.]*[A-Za-z0-9]/#) {
            let word = String(match.output)
            let parts = word.split(separator: ".")
            let stem = String(parts.first ?? "")
            // `ComposerField.swift`, `readAloudSpeed`, `voice_helper`.
            if parts.count == 2, isFileExtension(parts[1]), let name = name(word) {
                found.append(name)
            } else if parts.count == 1, isCamel(stem) || stem.contains("_"), let name = name(stem) {
                found.append(name)
            }
        }
        return found
    }

    /// `token` as a name to listen for: a file's name without its
    /// extension, nothing when it's too short, too long or mostly signs.
    static func name(_ token: String) -> String? {
        var t = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}<>.,;:!?'\"*"))
        let parts = t.split(separator: ".")
        if parts.count >= 2, isFileExtension(parts.last!) {
            t = parts.dropLast().joined(separator: ".")
        }
        // `foo()` is the function foo.
        if t.hasSuffix("()") { t.removeLast(2) }
        let letters = t.filter(\.isLetter).count
        guard t.count >= 4, t.count <= 40, letters * 2 > t.count,
              t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else { return nil }
        // Plain words ("Settings", "return") the speech model writes well.
        guard isCamel(t) || t.contains("_") || t.contains("-") || t.contains(".") || t.uppercased() == t || t.first!.isUppercase else { return nil }
        return t
    }

    static func isCamel(_ word: String) -> Bool {
        // A capital after a small letter: `readAloud`, `ComposerField`.
        zip(word, word.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
    }

    static func isFileExtension(_ ext: Substring) -> Bool {
        ["swift", "md", "json", "yml", "yaml", "toml", "ts", "tsx", "js", "jsx", "py", "rs", "go", "kt", "java", "rb",
         "sh", "css", "scss", "html", "plist", "txt", "c", "h", "m", "mm", "cpp", "lock", "sql"].contains(ext.lowercased())
    }

    /// How `name` is said, when its writing joins words: "Composer Field"
    /// for `ComposerField`, "read aloud speed" for `readAloudSpeed` or
    /// `read_aloud_speed`. Nil when it's said as written.
    public static func spoken(_ name: String) -> String? {
        var words: [String] = []
        var current = ""
        let chars = Array(name)
        for (i, c) in chars.enumerated() {
            if c == "_" || c == "-" || c == "." {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            let previous = i > 0 ? chars[i - 1] : nil
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            // A new word at a capital after a small letter, or at the last
            // capital of a run before a small one (`HTMLParser`).
            if c.isUppercase, let previous, previous.isLowercase || previous.isNumber
                || (previous.isUppercase && next?.isLowercase == true), !current.isEmpty
            {
                words.append(current)
                current = ""
            }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        guard words.count > 1 else { return nil }
        return words.joined(separator: " ")
    }

    /// How `name` may come out of the speech model, when not as written:
    /// its words apart ("Composer Field"), and with the vowel its writing
    /// drops ("swifter" for `Swiftr`, "herder kit" for `HerdrKit`). The
    /// pass checks the sound and writes the name.
    public static func heardAs(_ name: String) -> [String] {
        let words = (spoken(name) ?? name).split(separator: " ").map(String.init)
        var forms: [String] = []
        if words.count > 1 { forms.append(words.joined(separator: " ")) }
        let filled = words.map(withVowel)
        if filled != words { forms.append(filled.joined(separator: " ")) }
        return forms
    }

    /// `word` with an "e" before its last "r" when a consonant comes
    /// before it: "Swiftr" → "Swifter".
    static func withVowel(_ word: String) -> String {
        let chars = Array(word.lowercased())
        guard chars.count >= 3, chars.last == "r", let before = chars.dropLast().last,
              before.isLetter, !"aeiouy".contains(before) else { return word }
        return String(word.dropLast()) + "er"
    }

    /// The names to listen for: the person's, Swiftr's, then the
    /// conversation's, each once, at most `limit`. The conversation's plain
    /// words (`Options`, `Branch`), those `isWord` knows, are left out: the
    /// speech model writes them well, and they'd turn "option" or
    /// "branche" into them.
    public static func terms(mine: [String], conversation: [String], isWord: (String) -> Bool = { _ in false },
                             limit: Int = 50) -> [String] {
        let names = conversation.filter { !($0.allSatisfy(\.isLetter) && !isCamel($0) && isWord($0)) }
        var seen: Set<String> = []
        var out: [String] = []
        for term in mine + builtIn + names where out.count < limit {
            if seen.insert(term.lowercased()).inserted { out.append(term) }
        }
        return out
    }
}
