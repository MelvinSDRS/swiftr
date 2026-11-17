import Foundation
import Testing
@testable import HerdrKit

@Suite struct TabHistoryTests {
    private func history(_ tabs: String..., limit: Int = 50) -> TabHistory {
        var h = TabHistory(limit: limit)
        for tab in tabs { h.visit(tab) }
        return h
    }

    private let all: (String) -> Bool = { _ in true }

    @Test func goesBackAndForward() {
        var h = history("a", "b", "c")
        #expect(h.current == "c")
        #expect(h.target(1, where: all) == nil)
        #expect(h.go(-1, where: all) == "b")
        #expect(h.go(-1, where: all) == "a")
        #expect(h.go(-1, where: all) == nil)
        #expect(h.current == "a")
        #expect(h.go(1, where: all) == "b")
        #expect(h.stops == ["a", "b", "c"])
    }

    @Test func aNewTabReplacesTheWayForward() {
        var h = history("a", "b", "c")
        _ = h.go(-1, where: all)
        _ = h.go(-1, where: all)
        h.visit("d")
        #expect(h.stops == ["a", "d"])
        #expect(h.target(1, where: all) == nil)
        #expect(h.go(-1, where: all) == "a")
    }

    @Test func theShownTabAgainIsNoNewStop() {
        var h = history("a", "b")
        h.visit("b")
        #expect(h.stops == ["a", "b"])
        // After Back, the tab it showed is the current stop: Forward stays.
        _ = h.go(-1, where: all)
        h.visit("a")
        #expect(h.stops == ["a", "b"])
        #expect(h.go(1, where: all) == "b")
    }

    @Test func skipsTabsThatCannotShow() {
        var h = history("a", "x", "b")
        #expect(h.go(-1, where: { $0 != "x" }) == "a")
        #expect(h.index == 0)
        // A tab between two visits of the shown one leads nowhere.
        var same = history("a", "x", "a")
        #expect(same.target(-1, where: { $0 != "x" }) == nil)
        #expect(same.go(-1, where: all) == "x")
        var none = TabHistory()
        #expect(none.go(-1, where: all) == nil)
    }

    @Test func forgetsClosedTabs() {
        var h = history("a", "x", "b", "c")
        h.forget { $0 == "x" }
        #expect(h.stops == ["a", "b", "c"])
        #expect(h.current == "c")
        // The shown tab closes: the one before it is the current stop, and
        // the tab shown next comes after it.
        h.forget { $0 == "c" }
        #expect(h.current == "b")
        h.visit("d")
        #expect(h.stops == ["a", "b", "d"])
        #expect(h.go(-1, where: all) == "b")
    }

    @Test func mergesVisitsLeftSideBySide() {
        var h = history("a", "x", "a", "b")
        h.forget { $0 == "x" }
        #expect(h.stops == ["a", "b"])
        #expect(h.current == "b")
        var back = history("a", "x", "a", "b")
        _ = back.go(-1, where: all)
        back.forget { $0 == "x" }
        #expect(back.stops == ["a", "b"])
        #expect(back.current == "a")
        var first = history("x", "a")
        _ = first.go(-1, where: all)
        first.forget { $0 == "x" }
        #expect(first.stops == ["a"])
        #expect(first.index == 0)
        var empty = history("x")
        empty.forget { _ in true }
        #expect(empty.stops == [])
        #expect(empty.current == nil)
        empty.visit("a")
        #expect(empty.current == "a")
    }

    @Test func keepsTheLastStops() {
        var h = history("a", "b", "c", "d", limit: 3)
        #expect(h.stops == ["b", "c", "d"])
        #expect(h.current == "d")
        #expect(h.go(-1, where: all) == "c")
    }
}
