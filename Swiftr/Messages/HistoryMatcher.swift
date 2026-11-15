import Foundation

/// Finds the messages that hold the words searched (⌃R), at each key typed.
/// `range(of:options:)` on every message of a long history took tens of
/// milliseconds a key. Here each message is folded once (case and accents
/// off) and searched as bytes; the list is kept while the history stays
/// the same.
@MainActor
final class HistoryMatcher {
    static let shared = HistoryMatcher()

    private enum Text {
        /// Not looked at yet.
        case unread
        /// Folded, all ASCII: a byte search finds what `range(of:)` would.
        case plain([UInt8])
        /// Folded, letters beyond ASCII stay (œ, emoji…) or one letter became
        /// two (ß, ﬁ): there `range(of:)` knows more than bytes do, so it is asked.
        case wide
    }

    private var conversation: [String] = []
    private var folder: [String] = []
    /// Each message once, newest first: this conversation's, then the folder's.
    private var entries: [String] = []
    private var texts: [Text] = []

    /// The messages that hold `query`, newest first, 60 at most.
    func matches(_ query: String, conversation: [String], folder: [String]) -> [String] {
        if conversation != self.conversation || folder != self.folder {
            self.conversation = conversation
            self.folder = folder
            var seen = Set<String>()
            entries = (conversation.reversed() + folder).filter { seen.insert($0).inserted }
            texts = Array(repeating: .unread, count: entries.count)
        }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return Array(entries.prefix(60)) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let needle = Self.fold(words)
        var out: [String] = []
        for i in entries.indices {
            if case .unread = texts[i] {
                let folded = Self.fold(entries[i])
                texts[i] = folded.map { .plain($0) } ?? .wide
            }
            let found: Bool
            if case .plain(let text) = texts[i], let needle {
                found = Self.holds(text, needle)
            } else {
                found = entries[i].range(of: words, options: options) != nil
            }
            if found {
                out.append(entries[i])
                if out.count == 60 { break }
            }
        }
        return out
    }

    /// `s` without case or accents, as bytes: one ASCII byte for each of
    /// its letters, else nil.
    private static func fold(_ s: String) -> [UInt8]? {
        let bytes = Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf8)
        return bytes.allSatisfy { $0 < 0x80 } && bytes.count == s.count ? bytes : nil
    }

    private static func holds(_ text: [UInt8], _ word: [UInt8]) -> Bool {
        let n = word.count, length = text.count
        guard n > 0 else { return true }
        guard n <= length else { return false }
        return text.withUnsafeBufferPointer { t in
            word.withUnsafeBufferPointer { w in
                let first = w[0]
                var i = 0
                while i <= length - n {
                    if t[i] == first {
                        var k = 1
                        while k < n, t[i + k] == w[k] { k += 1 }
                        if k == n { return true }
                    }
                    i += 1
                }
                return false
            }
        }
    }
}
