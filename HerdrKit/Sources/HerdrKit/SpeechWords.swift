import Foundation

/// Signs, units and developers' English words as a voice says them, in the
/// languages Swiftr writes them for: French so far. Left alone, Voxtral's
/// French voice skips "40 ms", "#42" or "x = 3 + 1", says `git` "jit" and
/// takes the `main` branch for a hand; its own cleanup says "about" and
/// "number" instead, in English.
public enum SpeechWords {
    /// The languages Swiftr writes the words of.
    public static let languages: Set<String> = ["fr"]

    /// `text` as a voice reading `language` says it; unchanged in a language
    /// Swiftr doesn't write the words of.
    public static func say(_ text: String, language: String) -> String {
        language == "fr" ? french(text) : text
    }

    /// Code inside a line, before `say`: there `main` is a branch or a
    /// function, never a hand.
    public static func code(_ text: String, language: String) -> String {
        guard language == "fr" else { return text }
        return text.replacing(#/(?i)\bmain\b/#.wordBoundaryKind(.simple), with: "mayne")
    }

    // MARK: French

    /// The spellings were checked on Voxtral's French voice, by ear and
    /// with Whisper.
    static func french(_ text: String) -> String {
        var s = text
        // `main` is the branch only where a branch goes: "à la main" and
        // "main-d'œuvre" stay hands.
        s = s.replacing(#/((?i:\b(?:branch(?:es?)?|sur|vers|dans|depuis|avec|checkout|merge|rebase|pull|push|switch|origin|upstream)\s+|\b(?:origin|upstream)/))main\b(?![-'’])/#.wordBoundaryKind(.simple)) { m in m.1 + "mayne" }
        s = s.replacing(#/(?i)\bgit\b/#.wordBoundaryKind(.simple), with: "guite")
        s = s.replacing(#/(?i)\bpull\b/#.wordBoundaryKind(.simple), with: "poule")
        s = s.replacing(#/(?i)\breadme\b/#.wordBoundaryKind(.simple), with: "ridmi")
        // Versions and addresses: 2.1.322 is "2 point 1 point 322".
        s = s.replacing(#/\d+(?:\.\d+){2,}/#) { m in m.output.split(separator: ".").joined(separator: " point ") }
        // 10:30 is "10 heures 30"; 14h05 the voice reads well.
        s = s.replacing(#/(^|[^\d:])([01]?\d|2[0-3]):([0-5]\d)(?![\d:])/#) { m in
            let minutes = Int(m.3) ?? 0
            return m.1 + m.2 + " " + unit("h", after: m.2) + (minutes == 0 ? "" : " \(minutes)")
        }
        // Units and money after a number, the number left as it is.
        s = s.replacing(#/([$€])\s?(\d+(?:[.,]\d+)?)/#) { m in m.2 + (m.1 == "$" ? " $" : " €") }
        s = s.replacing(#/(\d+(?:\s\d{3})*(?:[.,]\d+)?)\s?(ms|s|min|h|[kK][oB]|Mo|MB|Go|GB|To|TB|px|pt|%|\$|€)(?![\p{L}\d])/#) { m in
            m.1 + " " + unit(String(m.2), after: m.1)
        }
        s = s.replacing(#/(^|[^\p{L}\d_&])#(\d+)/#) { m in m.1 + "numéro " + m.2 }
        s = s.replacing(#/[~≈]\s?(?=\d)/#, with: "environ ")
        // Signs between two things.
        s = s.replacing(#/\s*=>\s*/#, with: ", ")
        s = s.replacing(#/\s*(?:±|\+\/-)\s*/#, with: " plus ou moins ")
        s = s.replacing(#/\s*(?:≥|>=)\s*/#, with: " supérieur ou égal à ")
        s = s.replacing(#/\s*(?:≤|<=)\s*/#, with: " inférieur ou égal à ")
        s = s.replacing(#/\s*(?:≠|!=)\s*/#, with: " différent de ")
        // `Settings > Voice` isn't a comparison: only before a number.
        s = s.replacing(#/\s*>\s*(?=[-−]?\d)/#, with: " supérieur à ")
        s = s.replacing(#/\s*<\s*(?=[-−]?\d)/#, with: " inférieur à ")
        s = s.replacing(#/\s*={1,3}\s*/#, with: " égale ")
        // `C++` keeps its signs.
        s = s.replacing(#/([\p{L}\d)\]])\s*\+\s*(?=[\p{L}\d(])/#) { m in m.1 + " plus " }
        s = s.replacing(#/\s*×\s*/#, with: " fois ")
        s = s.replacing(#/(^|[\s(\[])[-−](?=\d)/#) { m in m.1 + "moins " }
        // A dash between words is a pause, as Voxtral's own cleanup has it;
        // 5 - 3 stays.
        s = s.replacing(#/([^\d\s])\s+[-–]\s+/#) { m in m.1 + " — " }
        s = s.replacing(#/\(\s+/#, with: "(")
        s = s.replacing(#/\s+\)/#, with: ")")
        s = s.replacing(#/ {2,}/#, with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A unit's French words after `number`: the plural from 2 on.
    static func unit(_ sign: String, after number: Substring) -> String {
        let singular = switch sign {
        case "ms": "milliseconde"
        case "s": "seconde"
        case "min": "minute"
        case "h": "heure"
        case "Ko", "ko", "KB", "kB": "kilooctet"
        case "Mo", "MB": "mégaoctet"
        case "Go", "GB": "gigaoctet"
        case "To", "TB": "téraoctet"
        case "px": "pixel"
        case "pt": "point"
        case "$": "dollar"
        case "€": "euro"
        default: "pour cent"
        }
        let value = Double(number.filter { !$0.isWhitespace }.replacing(",", with: ".")) ?? 2
        return value < 2 || sign == "%" ? singular : singular + "s"
    }
}
