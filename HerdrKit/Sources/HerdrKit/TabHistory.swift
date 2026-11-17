import Foundation

/// The tabs shown one after the other, for Back and Forward, as a browser
/// keeps its pages: going back keeps the way forward, until another tab is
/// picked from there.
public struct TabHistory: Equatable, Sendable {
    /// The tabs' keys, oldest first, no two alike side by side.
    public private(set) var stops: [String] = []
    /// The stop shown now.
    public private(set) var index = 0
    /// The oldest stops go past this many.
    public var limit: Int

    public init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    /// The tab shown now, nil before the first one.
    public var current: String? {
        stops.indices.contains(index) ? stops[index] : nil
    }

    /// `tab` shows now: a new stop after the current one, in place of the
    /// way forward. Nothing when it is the current stop already, as after
    /// Back or Forward.
    public mutating func visit(_ tab: String) {
        guard tab != current else { return }
        if index + 1 < stops.count { stops.removeSubrange((index + 1)...) }
        stops.append(tab)
        if stops.count > limit { stops.removeFirst(stops.count - limit) }
        index = stops.count - 1
    }

    /// The stop Back (`step` -1) or Forward (1) leads to: the nearest that
    /// way which `exists` and isn't the tab shown.
    public func target(_ step: Int, where exists: (String) -> Bool) -> Int? {
        guard step != 0, let current else { return nil }
        var i = index + step
        while stops.indices.contains(i) {
            if stops[i] != current, exists(stops[i]) { return i }
            i += step
        }
        return nil
    }

    /// Moves to that stop and returns its tab, to show.
    public mutating func go(_ step: Int, where exists: (String) -> Bool) -> String? {
        guard let to = target(step, where: exists) else { return nil }
        index = to
        return stops[to]
    }

    /// Forgets the stops that are `gone` (closed tabs). When the current one
    /// goes, the stop before it becomes the current one.
    public mutating func forget(where gone: (String) -> Bool) {
        var kept: [String] = []
        var at = 0
        for (i, stop) in stops.enumerated() {
            // Two visits of a tab, once what lay between them is gone, are one.
            if !gone(stop), kept.last != stop { kept.append(stop) }
            if i == index { at = max(0, kept.count - 1) }
        }
        guard kept != stops else { return }
        stops = kept
        index = at
    }
}
