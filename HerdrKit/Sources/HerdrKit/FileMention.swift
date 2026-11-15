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
        /// Each path in lower case, and where its last part starts.
        private let lowered: [String]
        private let nameStart: [Int]
        private let depth: [Int]

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
            lowered = all.map { $0.lowercased() }
            nameStart = all.map { path in
                let trimmed = path.hasSuffix("/") ? path.dropLast() : Substring(path)
                return trimmed.lastIndex(of: "/").map { trimmed.distance(from: trimmed.startIndex, to: $0) + 1 } ?? 0
            }
            depth = all.map { path in path.dropLast(path.hasSuffix("/") ? 1 : 0).filter { $0 == "/" }.count }
        }

        public var isEmpty: Bool { paths.isEmpty }

        /// The paths that best match `query`, best first: a name that is it,
        /// then one that starts with it, holds it, a path that starts with
        /// it or holds it, then one that holds its letters in order. With no
        /// query, the project's top: folders first.
        public func matching(_ query: String, limit: Int = 12) -> [String] {
            let q = query.lowercased()
            var found: [(score: Int, i: Int)] = []
            for i in paths.indices {
                if let s = score(q, i) { found.append((s, i)) }
            }
            found.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                if paths[a.i].count != paths[b.i].count { return paths[a.i].count < paths[b.i].count }
                return paths[a.i] < paths[b.i]
            }
            return found.prefix(limit).map { paths[$0.i] }
        }

        private func score(_ q: String, _ i: Int) -> Int? {
            let path = lowered[i]
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
