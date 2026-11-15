import Foundation

/// An edit's text before and after, compared line by line, as a diff shows
/// it: lines kept, removed and added, in order.
public enum LineDiff {
    public enum Kind: Sendable, Equatable { case same, removed, added }

    public struct Line: Sendable, Equatable {
        public var kind: Kind
        public var text: String

        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Past this many lines, all of `old` is shown removed and all of
    /// `new` added, without comparing them.
    static let maxCompared = 4000

    public static func lines(old: String, new: String) -> [Line] {
        let a = split(old), b = split(new)
        guard a.count + b.count <= maxCompared else {
            return a.map { Line(.removed, $0) } + b.map { Line(.added, $0) }
        }
        var removed = Set<Int>(), added = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                out.append(Line(.removed, a[i]))
                i += 1
            } else if j < b.count, added.contains(j) {
                out.append(Line(.added, b[j]))
                j += 1
            } else if i < a.count, j < b.count {
                out.append(Line(.same, b[j]))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return out
    }

    private static func split(_ s: String) -> [String] {
        s.isEmpty ? [] : s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
