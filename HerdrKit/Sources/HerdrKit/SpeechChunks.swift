import Foundation

/// What a voice model reads in one go, cut from `SpeechText`'s lines: whole
/// sentences, a short first piece so the voice starts soon, then pieces of
/// up to `limit` characters. A sentence longer than that is cut at a comma,
/// else at a space.
public enum SpeechChunks {
    public static func make(_ text: String, first: Int = 160, limit: Int = 320) -> [String] {
        var chunks: [String] = []
        var current = ""
        for sentence in sentences(text).flatMap({ cut($0, limit: limit) }) {
            let cap = chunks.isEmpty ? first : limit
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= cap {
                current += " " + sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// The sentences of `text`: each line, cut after a stop that a space
    /// and a capital or a digit follow.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n") {
            var start = line.startIndex
            var i = line.startIndex
            while i < line.endIndex {
                let next = line.index(after: i)
                if ".!?…".contains(line[i]), next < line.endIndex, line[next] == " " {
                    let after = line.index(after: next)
                    if after < line.endIndex, line[after].isUppercase || line[after].isNumber {
                        out.append(String(line[start ..< next]))
                        start = after
                        i = after
                        continue
                    }
                }
                i = next
            }
            out.append(String(line[start...]))
        }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `sentence` in pieces of at most `limit` characters, cut after the
    /// last comma that fits, else the last space.
    static func cut(_ sentence: String, limit: Int) -> [String] {
        var rest = Substring(sentence)
        var out: [String] = []
        while rest.count > limit {
            let head = rest.prefix(limit)
            let end = head.lastIndex(of: ",").map { head.index(after: $0) }
                ?? head.lastIndex(of: " ")
                ?? head.endIndex
            out.append(String(rest[..<end]).trimmingCharacters(in: .whitespaces))
            rest = rest[end...].drop { $0 == " " }
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }
}
