import Foundation

/// `@` in the Messages field: a file or folder of the project, named in the
/// message as Claude Code, Codex and OpenCode take it (`@Sources/App.swift`).
public enum FileMention {
    /// The word typed at the end of `text` when it starts with `@`, after a
    /// space, a new line or at the start: what follows the `@`. Nil when the
    /// text doesn't end with one (`me@mail` is no mention).
    public static func typed(_ text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let word = text[text.index(after: at)...]
        guard !word.contains(where: { $0.isWhitespace || $0 == "@" }) else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            guard before.isWhitespace || before == "(" else { return nil }
        }
        return String(word)
    }

    /// `text` with the `@word` at its end made `@path`, in quotes when the
    /// path has spaces. A file gets a space after it; a folder doesn't, so
    /// its own files come next.
    public static func complete(_ text: String, with path: String) -> String {
        guard let at = text.lastIndex(of: "@") else { return text }
        let name = path.contains(" ") ? "\"\(path)\"" : path
        return String(text[..<at]) + "@" + name + (path.hasSuffix("/") ? "" : " ")
    }

    /// A project's files and folders (folders end with `/`), ready to search.
    public struct Index: Sendable {
        public let paths: [String]
        /// Every path in lower case, as bytes, end to end; `starts[i]` is
        /// where path `i` begins, `starts[i + 1]` where it ends. A search
        /// runs at each key typed after `@`, on tens of thousands of paths:
        /// bytes compare many times faster than Strings.
        private let bytes: [UInt8]
        private let starts: [Int]
        /// Where each path's last part starts, in characters.
        private let nameStart: [Int]
        private let depth: [Int]
        /// Each path's length in characters, as the order of the results counts it.
        private let counts: [Int]
        /// The paths with letters beyond ASCII, in lower case: bytes are not
        /// characters there, so these go the slow way, as Strings.
        private let wide: [Int: String]
        private let isWide: [Bool]

        /// `files`: paths relative to the project's folder. Their folders join them.
        public init(files: [String]) {
            var seen = Set<String>()
            var all: [String] = []
            for file in files where !file.isEmpty {
                var parts = file.split(separator: "/", omittingEmptySubsequences: true)
                guard !parts.isEmpty else { continue }
                if seen.insert(file).inserted { all.append(file) }
                parts.removeLast()
                var folder = ""
                for part in parts {
                    folder += part + "/"
                    if seen.insert(folder).inserted { all.append(folder) }
                }
            }
            paths = all
            var bytes: [UInt8] = []
            var starts: [Int] = []
            var wide: [Int: String] = [:]
            starts.reserveCapacity(all.count + 1)
            for (i, path) in all.enumerated() {
                let lowered = path.lowercased()
                starts.append(bytes.count)
                bytes.append(contentsOf: lowered.utf8)
                if !lowered.utf8.allSatisfy({ $0 < 0x80 }) { wide[i] = lowered }
            }
            starts.append(bytes.count)
            self.bytes = bytes
            self.starts = starts
            self.wide = wide
            isWide = all.indices.map { wide[$0] != nil }
            nameStart = all.map { path in
                let trimmed = path.hasSuffix("/") ? path.dropLast() : Substring(path)
                return trimmed.lastIndex(of: "/").map { trimmed.distance(from: trimmed.startIndex, to: $0) + 1 } ?? 0
            }
            depth = all.map { path in path.dropLast(path.hasSuffix("/") ? 1 : 0).filter { $0 == "/" }.count }
            counts = all.map(\.count)
        }

        public var isEmpty: Bool { paths.isEmpty }

        /// The paths that best match `query`, best first: a name that is it,
        /// then one that starts with it, holds it, a path that starts with
        /// it or holds it, then one that holds its letters in order. With no
        /// query, the project's top: folders first.
        public func matching(_ query: String, limit: Int = 12) -> [String] {
            guard limit > 0 else { return [] }
            let q = query.lowercased()
            let needle = Array(q.utf8)
            let plain = needle.allSatisfy { $0 < 0x80 }
            // The best `limit` so far, best first: most paths match a short
            // query, and sorting them all cost more than finding them.
            var best: [(score: Int, i: Int)] = []
            best.reserveCapacity(limit + 1)
            bytes.withUnsafeBufferPointer { all in
                needle.withUnsafeBufferPointer { needle in
                    for i in paths.indices {
                        let score: Int?
                        if isWide[i] {
                            score = self.score(q, wide[i] ?? "", i)
                        } else if plain {
                            score = self.score(needle, UnsafeBufferPointer(rebasing: all[starts[i] ..< starts[i + 1]]), i)
                        } else {
                            // Letters beyond ASCII are in no ASCII path.
                            score = nil
                        }
                        guard let score else { continue }
                        let found = (score: score, i: i)
                        if best.count == limit, !before(found, best[limit - 1]) { continue }
                        let at = best.firstIndex { before(found, $0) } ?? best.count
                        best.insert(found, at: at)
                        if best.count > limit { best.removeLast() }
                    }
                }
            }
            return best.map { paths[$0.i] }
        }

        /// The order of the results: the best score, then the shortest path, then by name.
        private func before(_ a: (score: Int, i: Int), _ b: (score: Int, i: Int)) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if counts[a.i] != counts[b.i] { return counts[a.i] < counts[b.i] }
            return paths[a.i] < paths[b.i]
        }

        /// An ASCII path's score for an ASCII query, both in lower case:
        /// what the String way below gives, on bytes.
        private func score(_ q: UnsafeBufferPointer<UInt8>, _ path: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int? {
            let n = q.count
            let length = path.count
            let slash = UInt8(ascii: "/")
            if n == 0 {
                guard depth[i] == 0 else { return nil }
                return path.last == slash ? 2 : 1
            }
            guard n <= length, let start = path.baseAddress, let word = q.baseAddress else { return nil }
            if let at = Self.find(word, n, in: start, length) {
                let nameAt = min(nameStart[i], length)
                let nameLength = length - nameAt
                let bareLength = path.last == slash ? nameLength - 1 : nameLength
                if nameLength >= n {
                    if Self.find(word, n, in: start + nameAt, n) != nil {
                        return n == bareLength || n == nameLength ? 1000 : 900 - min(nameLength, 99)
                    }
                    if at >= nameAt || Self.find(word, n, in: start + nameAt, nameLength) != nil { return 700 - min(nameLength, 99) }
                }
                return at == 0 ? 650 - min(length / 4, 99) : 500 - min(length / 4, 99)
            }
            // Its letters in order, the closer together the better.
            var at = 0
            var first = -1
            for c in q {
                while at < length, start[at] != c { at += 1 }
                guard at < length else { return nil }
                if first < 0 { first = at }
                at += 1
            }
            return 300 - min(at - first - n, 200) - min(length / 8, 50)
        }

        /// Where `word` first is in `length` bytes, if it is. A plain loop:
        /// on paths this short, it runs many times faster than `memmem`.
        @inline(__always)
        private static func find(_ word: UnsafePointer<UInt8>, _ n: Int, in bytes: UnsafePointer<UInt8>, _ length: Int) -> Int? {
            guard n > 0, n <= length else { return nil }
            let first = word[0]
            var i = 0
            while i <= length - n {
                if bytes[i] == first {
                    var k = 1
                    while k < n, bytes[i + k] == word[k] { k += 1 }
                    if k == n { return i }
                }
                i += 1
            }
            return nil
        }

        /// The same for a path with letters beyond ASCII, on Strings.
        private func score(_ q: String, _ path: String, _ i: Int) -> Int? {
            if q.isEmpty {
                guard depth[i] == 0 else { return nil }
                return path.hasSuffix("/") ? 2 : 1
            }
            let name = path.dropFirst(nameStart[i])
            let bare = name.hasSuffix("/") ? name.dropLast() : name
            if bare == q || name == q { return 1000 }
            if name.hasPrefix(q) { return 900 - min(name.count, 99) }
            if name.contains(q) { return 700 - min(name.count, 99) }
            if path.hasPrefix(q) { return 650 - min(path.count / 4, 99) }
            if path.contains(q) { return 500 - min(path.count / 4, 99) }
            // Its letters in order, the closer together the better.
            var at = path.startIndex
            var first: String.Index?
            for c in q {
                guard let hit = path[at...].firstIndex(of: c) else { return nil }
                if first == nil { first = hit }
                at = path.index(after: hit)
            }
            let span = path.distance(from: first ?? path.startIndex, to: at)
            return 300 - min(span - q.count, 200) - min(path.count / 8, 50)
        }
    }

    /// A shell line that prints the files of the folder it runs in, one a
    /// line: git's (tracked, and new ones not ignored) in a repository,
    /// else what `find` sees a few levels down, without hidden ones and
    /// heavy build folders. At most `limit`.
    public static func listing(folder: String, limit: Int = 50_000) -> String {
        let quoted = "'" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        cd \(quoted) 2>/dev/null || exit 0; \
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git ls-files --cached --others --exclude-standard 2>/dev/null; \
        else find . -mindepth 1 -maxdepth 6 \\( -name '.*' -o -name node_modules -o -name build -o -name DerivedData -o -name Library -o -name target \\) -prune -o -type f -print 2>/dev/null | sed 's|^\\./||'; \
        fi | head -n \(limit)
        """
    }
}
