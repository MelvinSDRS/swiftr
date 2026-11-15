import Foundation
import Testing
@testable import HerdrKit

@Suite struct JSONTests {
    @Test func roundTripKeepsTypesAndUnknownFields() throws {
        let text = #"{"a":1,"b":1.5,"c":true,"d":null,"e":"x","f":[1,"y"],"g":{"h":0.25}}"#
        let json = try JSON(text: text)
        #expect(json["a"] == .int(1))
        #expect(json["b"] == .double(1.5))
        #expect(json["c"] == .bool(true))
        #expect(json["d"] == .null)
        #expect(json.text == text)
    }

    @Test func subscriptSetCreatesAndRemoves() {
        var j: JSON = ["a": 1]
        j["b"] = "x"
        j["a"] = nil
        #expect(j == ["b": "x"])
    }
}

@Suite struct FrameTests {
    @Test func framesSurviveAnySplit() throws {
        var stream = Data()
        stream += FrameCodec.encode(channel: 0, kind: .data, payload: Data(#"{"id":1}"#.utf8))
        stream += FrameCodec.encode(channel: 7, kind: .data, payload: Data([1, 2, 3]))
        stream += FrameCodec.encode(channel: 7, kind: .close, payload: Data())
        stream += FrameCodec.encode(channel: 9, kind: .resize, payload: Data([80, 0, 24, 0]))
        for chunk in [1, 2, 5, 9, 64] {
            var reader = FrameReader()
            var got: [(UInt32, UInt8, [UInt8])] = []
            var i = 0
            while i < stream.count {
                let piece = stream[i ..< min(i + chunk, stream.count)]
                piece.withUnsafeBytes { reader.append($0) }
                while let f = try reader.next() { got.append((f.channel, f.kind, Array(f.payload))) }
                i += chunk
            }
            #expect(got.count == 4)
            #expect(got[0].0 == 0 && got[0].2 == Array(#"{"id":1}"#.utf8))
            #expect(got[1].0 == 7 && got[1].1 == FrameKind.data.rawValue && got[1].2 == [1, 2, 3])
            #expect(got[2].1 == FrameKind.close.rawValue && got[2].2.isEmpty)
            #expect(got[3].0 == 9 && got[3].2 == [80, 0, 24, 0])
        }
    }

    @Test func linesSurviveAnySplit() {
        let text = Array("{\"a\":1}\n{\"b\":2}\n\n{\"c\":3}\n".utf8)
        for chunk in [1, 3, 7, 100] {
            var splitter = LineSplitter()
            var lines: [String] = []
            var i = 0
            while i < text.count {
                let piece = Array(text[i ..< min(i + chunk, text.count)])
                piece.withUnsafeBytes { raw in
                    splitter.push(raw) { lines.append(String(decoding: $0, as: UTF8.self)) }
                }
                i += chunk
            }
            #expect(lines == [#"{"a":1}"#, #"{"b":2}"#, "", #"{"c":3}"#])
        }
    }
}

@Suite struct LayoutTests {
    func doc(_ root: JSON) -> LayoutDocument {
        LayoutDocument(["spaces": [["id": "s", "name": "work", "folder": "/w", "color": "teal", "tabs": [["id": "t", "name": "", "root": root, "floating": ["x"]]]]]])
    }

    let onePane: JSON = ["id": "t", "type": "row", "children": [["id": "p", "type": "block", "content": ["terminal": "t1"]]]]

    @Test func splitAlongTheParentHalvesTheShare() {
        var d = doc(onePane)
        let ok = d.split("p", axis: .row, newPane: LayoutDocument.pane(id: "p2", terminal: "t2"), containerID: "s1")
        #expect(ok)
        let root = d.spaces[0].tabs[0].root
        #expect(root.children.map(\.id) == ["p", "p2"])
        #expect(root.children.map(\.size) == [.weight(0.5), .weight(0.5)])
        // Again on p2: p2's half is shared.
        d.split("p2", axis: .row, newPane: LayoutDocument.pane(id: "p3", terminal: "t3"), containerID: "s2")
        #expect(d.spaces[0].tabs[0].root.children.map(\.size) == [.weight(0.5), .weight(0.25), .weight(0.25)])
    }

    @Test func splitAcrossWrapsTheTarget() {
        var d = doc(onePane)
        d.split("p", axis: .column, newPane: LayoutDocument.pane(id: "p2", terminal: "t2"), containerID: "s1")
        let root = d.spaces[0].tabs[0].root
        #expect(root.children.count == 1)
        guard case .split(let id, .column, let children, _, _) = root.children[0] else {
            Issue.record("expected a column")
            return
        }
        #expect(id == "s1")
        #expect(children.map(\.id) == ["p", "p2"])
    }

    @Test func removingGivesTheShareBackAndCollapses() {
        var d = doc(onePane)
        d.split("p", axis: .row, newPane: LayoutDocument.pane(id: "p2", terminal: "t2"), containerID: "s1")
        d.split("p2", axis: .column, newPane: LayoutDocument.pane(id: "p3", terminal: "t3"), containerID: "s2")
        let r1 = d.removePane("p3")
        #expect(r1 == .pane)
        let root = d.spaces[0].tabs[0].root
        // The column s2 had one child left: p2 takes its place and its size.
        #expect(root.children.map(\.id) == ["p", "p2"])
        #expect(root.children[1].size == .weight(0.5))
        let r2 = d.removePane("p")
        #expect(r2 == .pane)
        #expect(d.spaces[0].tabs[0].root.children.map(\.id) == ["p2"])
        #expect(d.spaces[0].tabs[0].root.children[0].size == .weight(1.0))
    }

    @Test func lastPaneClosesTabThenSpace() {
        var d = doc(onePane)
        d.addTab(LayoutDocument.tab(id: "t2", name: "", pane: LayoutDocument.pane(id: "q", terminal: "t9")), toSpace: "s", after: "t")
        let r3 = d.removePane("q")
        #expect(r3 == .tab("t2"))
        let r4 = d.removePane("p")
        #expect(r4 == .space("s"))
        #expect(d.spaces.isEmpty)
    }

    @Test func unknownFieldsSurviveEdits() {
        var d = doc(onePane)
        d.split("p", axis: .row, newPane: LayoutDocument.pane(id: "p2", terminal: "t2"), containerID: "s1")
        d.renameTab("t", to: "Build")
        let space = d.raw["spaces"]?[0]
        #expect(space?["color"] == "teal")
        #expect(space?["tabs"]?[0]?["floating"] == ["x"])
        #expect(space?["tabs"]?[0]?["name"] == "Build")
    }

    @Test func findsPanesAndTerminals() {
        let d = doc(onePane)
        #expect(d.pane(showing: "t1") == "p")
        #expect(d.location(of: "p")?.tab == "t")
        #expect(d.location(of: "p")?.space == "s")
        #expect(d.pane(showing: "t404") == nil)
    }
}

@Suite struct EventTests {
    @Test func finishedAndLost() {
        var r: JSON = ["address": "t1", "state": "live", "pid": 42, "foreground": ["pid": 43, "name": "claude", "argv": ["claude"], "cwd": "/"]]
        var lost = r
        TerminalEvents.apply(type: "lost", data: ["reason": "signaled", "exit_code": nil, "signal": 9, "finished_ms": nil], to: &lost)
        #expect(lost["state"] == "live")
        #expect(lost["pid"] == .null)
        #expect(lost["foreground"] == nil)
        TerminalEvents.apply(type: "finished", data: ["reason": "exited", "exit_code": 0, "signal": nil, "finished_ms": 5], to: &r)
        #expect(r["state"] == "finished")
        #expect(r["reason"] == "exited")
    }

    @Test func statusTimeMovesWithTheWordOnly() {
        var r: JSON = ["address": "t1", "state": "live", "status": ["state": "working", "msg": "a"], "status_ms": 100]
        TerminalEvents.apply(type: "status", data: ["status": ["state": "working", "msg": "b"], "records": [:], "reported": true], to: &r, nowMs: 200)
        #expect(r["status_ms"] == 100)
        TerminalEvents.apply(type: "status", data: ["status": ["state": "done"], "records": [:], "reported": true], to: &r, nowMs: 300)
        #expect(r["status_ms"] == 300)
        // A core that sends the time is believed.
        TerminalEvents.apply(type: "status", data: ["status": ["state": "working"], "status_ms": 250], to: &r, nowMs: 400)
        #expect(r["status_ms"] == 250)
        TerminalEvents.apply(type: "status", data: ["status": nil, "records": [:], "reported": true], to: &r, nowMs: 500)
        #expect(r["status_ms"] == 500)
    }

    @MainActor @Test func storeAppliesInOrderAndSkipsOld() {
        let store = TerminalStore()
        store.reset(seq: 10, terminals: [["address": "t1", "state": "live", "title": "a", "turn": 1, "labels": ["herdr.seen": "1"], "status": ["state": "idle"]]])
        store.apply([
            ["method": "event", "params": ["seq": 9, "type": "title", "terminal": "t1", "data": ["title": "old"]]],
            ["method": "event", "params": ["seq": 11, "type": "title", "terminal": "t1", "data": ["title": "new"]]],
            ["method": "event", "params": ["seq": 12, "type": "turn", "terminal": "t1", "data": ["turn": 2, "state": "done"]]],
            ["method": "event", "params": ["seq": 13, "type": "created", "terminal": "t2", "data": ["address": "t2", "state": "live"]]],
        ])
        #expect(store.model("t1")?.title == "new")
        #expect(store.model("t1")?.attention == .done)
        #expect(store.order == ["t1", "t2"])
        store.apply([["method": "event", "params": ["seq": 14, "type": "removed", "terminal": "t2", "data": [:]]]])
        #expect(store.order == ["t1"])
    }

    /// A moment of work never shows (Claude Code says working as /model's
    /// menu closes); work that lasts shows once the hold is over, a message's
    /// turn at once.
    @MainActor @Test func aMomentOfWorkDoesNotShow() async throws {
        let store = TerminalStore()
        store.workingHold = .milliseconds(150)
        store.reset(seq: 1, terminals: [["address": "t1", "state": "live", "status": ["state": "idle"]]])
        var shown: [String] = []
        store.onChange = { change in
            if case .event("status", _, _, _) = change { shown.append(store.model("t1")?.status?.state ?? "-") }
        }
        var seq: Int64 = 1
        func say(_ word: String) {
            seq += 1
            store.apply([["method": "event", "params": ["seq": .int(seq), "type": "status", "terminal": "t1",
                                                        "data": ["status": ["state": .string(word)], "reported": true]]]])
        }
        say("working")
        say("idle")
        try await Task.sleep(for: .milliseconds(300))
        #expect(shown == ["idle"])
        say("working")
        #expect(store.model("t1")?.status?.state == "idle")
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.model("t1")?.status?.state == "working")
        say("idle")
        store.expectWork("t1")
        say("working")
        #expect(store.model("t1")?.status?.state == "working")
        // From a question, work shows at once too.
        say("blocked")
        say("working")
        #expect(shown.suffix(2) == ["blocked", "working"])
    }

    /// A moment of work still ends a turn, as the core counts them: the row
    /// keeps its place and its time, and once that turn is seen, its state.
    @MainActor @Test func aMomentOfWorkLeavesTheRowInPlace() async throws {
        let store = TerminalStore()
        store.workingHold = .milliseconds(150)
        store.reset(seq: 1, terminals: [["address": "t1", "state": "live", "status": ["state": "done"], "status_ms": 1000,
                                         "turn": 3, "labels": ["herdr.space": "s1", "herdr.seen": "3"]]])
        var seq: Int64 = 1
        func event(_ type: String, _ data: JSON) {
            seq += 1
            store.apply([["method": "event", "params": ["seq": .int(seq), "type": .string(type), "terminal": "t1", "data": data]]])
        }
        func say(_ word: String) { event("status", ["status": ["state": .string(word)], "reported": true]) }
        // As the core sends them: the word back at rest, then the turn.
        say("working")
        say("idle")
        event("turn", ["state": "live", "turn": 4])
        let m = try #require(store.model("t1"))
        #expect(m.status?.state == "idle")
        #expect(m.statusMs == 1000)
        #expect(m.attention == .done)
        store.noteSeen("t1", turn: 4)
        #expect(m.seen == 4)
        #expect(m.labels["herdr.space"] == "s1")
        #expect(m.attention == .idle)
        store.noteSeen("t1", turn: 2)
        #expect(m.seen == 4)
        // A question within the hold shows, from when it came.
        say("working")
        say("blocked")
        #expect(m.status?.state == "blocked")
        #expect((m.statusMs ?? 0) > 1000)
    }
}

import Synchronization

final class CollectSink: StreamSink, @unchecked Sendable {
    let bytes = Mutex(0)
    let opened = Mutex<UInt32?>(nil)
    func streamOpened(channel: UInt32, connection: CoreConnection, result: JSON) {
        opened.withLock { $0 = channel }
        connection.credit(channel, 0)
    }
    func streamData(_ data: UnsafeRawBufferPointer) { bytes.withLock { $0 += data.count } }
    func streamResize(cols: Int, rows: Int) {}
    func streamClosed(reason: JSON?) {}
}

/// Against the real core, read-only: HERDRKIT_LIVE=1 swift test. With
/// HERDRKIT_LIVE_MACHINE=<name>, it reads that machine's layout too.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERDRKIT_LIVE"] != nil))
struct LiveTests {
    @Test func connectListSubscribeObserve() async throws {
        let c = try await CoreConnection.connect(to: .local())
        defer { c.close() }
        #expect(c.features.contains("automatic_input"))
        let list = try await c.call("terminal.list")
        let terminals = list["terminals"]?.array ?? []
        #expect(!terminals.isEmpty)
        let local = try await c.call("doc.get", ["name": "herdr-app"])
        #expect(!LayoutDocument(local["value"]).spaces.isEmpty)
        if let machine = ProcessInfo.processInfo.environment["HERDRKIT_LIVE_MACHINE"], !machine.isEmpty {
            let remote = try await c.call("doc.get", ["name": "herdr-app", "on": .string(machine)])
            #expect(!LayoutDocument(remote["value"]).spaces.isEmpty)
        }

        let got = Mutex(0)
        let feed = EventFeed(deliver: { messages in got.withLock { $0 += messages.count } }, ended: { _ in })
        let snapshot = try await c.subscribe(sink: feed)
        let snapTerminals: [JSON] = snapshot["terminals"]?.array ?? []
        print("SNAPSHOT count", snapTerminals.count, snapshot["terminals"]?.array?.count as Any)
        #expect(!snapTerminals.isEmpty)
        #expect(snapshot["seq"]?.int64 != nil)

        let live = try #require(terminals.first { $0["state"]?.string == "live" && !($0["address"]?.string ?? "/").contains("/") })
        let sink = CollectSink()
        let a = try await c.attach(live["address"]!.string!, cols: 80, rows: 24, history: 50, observe: true, sink: sink)
        try await Task.sleep(for: .milliseconds(600))
        #expect(sink.bytes.withLock { $0 } > 0)
        #expect(sink.opened.withLock { $0 } == a.channel)
        c.detach(a.channel)

        let failed = await #expect(throws: CoreError.self) { try await c.call("terminal.get", ["terminal": "t999999"]) }
        #expect(failed?.kind == "not_found")
    }
}
