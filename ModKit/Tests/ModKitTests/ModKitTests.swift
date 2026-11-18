import AppKit
import Foundation
import Testing
@testable import ModKit

/// A host that runs nothing: it notes what mods ask for.
final class NotingHost: ModHost {
    var asked: [String] = []
    var commands: [String] = []
    var opened: [String] = []
    var clipboard: [String] = []

    func modExec(_ request: ModExecRequest) async throws -> ModExecResult {
        asked.append(([request.command] + request.arguments).joined(separator: " "))
        return ModExecResult(code: 0, stdout: "stand-in\n", stderr: "")
    }

    func modRun(command: String, arguments: [String: Any], from copy: ModCopy?) { commands.append(command) }
    func modOpen(_ url: URL) { opened.append(url.absoluteString) }
    func modClipboard() -> String? { nil }
    func modSetClipboard(_ text: String) { clipboard.append(text) }
}

/// A mods home in a temporary folder, with the mods given as source.
struct Home {
    let root: URL
    let host = NotingHost()
    let center: ModCenter

    init(_ mods: [String: String]) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "modkit-tests-\(UUID().uuidString)")
        for (name, source) in mods {
            let folder = root.appending(path: "mods/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(source.utf8).write(to: folder.appending(path: "main.js"))
        }
        center = ModCenter(home: root, host: host, userHome: root.appending(path: "home").path)
        center.jail = [root.path]
        center.setData("theme", ModTheme.colors(from: ["background": "#1f2126", "foreground": "#d7dae0"]))
    }

    func view(_ name: String, granted: ModCapabilities = [], props: [String: Any] = [:], width: CGFloat = 360, height: CGFloat = 400) throws -> ModView {
        let runtime = try center.runtime(folder: root.appending(path: "mods/\(name)"), granted: granted)
        let view = ModView(copy: try runtime.makeCopy(props: props, slot: "test"))
        view.setFrameSize(CGSize(width: width, height: height))
        view.renderNow()
        return view
    }

    /// Lets what a mod asked for come back: the answers land on the main
    /// queue, which a test only frees by waiting.
    func settle(_ seconds: TimeInterval = 0.2) async { try? await Task.sleep(for: .seconds(seconds)) }
}

private let counter = """
import { View, div } from "gpui-kit";
import { v_flex } from "gpui-base";
export default class Counter extends View {
  init() { this.n = 0; }
  render() {
    return v_flex().size_full().p(10).gap(8)
      .child(div().child("Count " + this.n))
      .child(div().id("go").h(32).w(80).bg("#335577").on_click((_e, cx) => { this.n++; cx.notify(); }).child("Add"));
  }
}
"""

private let runner = """
import { View, div } from "gpui-kit";
import { exec } from "herdr";
export default class Runner extends View {
  init(_props, cx) {
    this.out = "waiting";
    exec("git", ["status"]).then((r) => { this.out = "ran: " + r.stdout.trim(); cx.notify(); }, (e) => { this.out = "refused"; cx.notify(); });
  }
  render() { return div().child(this.out); }
}
"""

/// Tries each thing a mod must be allowed, and shows how each went.
private let gates = """
import { View, div } from "gpui-kit";
import { readTextFile, writeTextFile, hc, run } from "herdr";
export default class Gates extends View {
  init(props, cx) {
    this.r = {};
    const t = (k, p) => p.then(() => { this.r[k] = "ok"; cx.notify(); }, () => { this.r[k] = "refused"; cx.notify(); });
    t("read", readTextFile(props.out + "/secret.txt"));
    t("link", readTextFile(props.own + "/link.txt"));
    t("write", writeTextFile(props.out + "/made.txt", "x"));
    t("hc", hc(["ls"]));
    if (props.net) t("net", fetch("https://example.invalid/"));
    run("tab.new", {});
    cx.write_to_clipboard("taken");
    cx.open_url("https://example.invalid/");
    this.r.end = "reached";
  }
  render() { return div().child(Object.keys(this.r).sort().map((k) => k + ":" + this.r[k]).join(" ")); }
}
"""

private let spinner = """
import { View, div } from "gpui-kit";
export default class Spinner extends View {
  render() { for (;;) {} }
}
"""

@Suite(.serialized) struct ModKitTests {
    @Test func aModDrawsAndAnswersAClick() throws {
        let home = try Home(["counter": counter])
        let view = try home.view("counter")
        #expect(view.texts() == ["Count 0", "Add"])
        #expect(view.click(text: "Add"))
        view.renderNow()
        #expect(view.texts().first == "Count 1")
        #expect(view.copy.runtime.errors.isEmpty)
    }

    @Test func aRowLaysItsChildrenSideBySide() throws {
        let home = try Home(["row": """
        import { View, div } from "gpui-kit";
        export default class Row extends View {
          render() { return div().flex().size_full().child(div().w(100).child("left")).child(div().flex_1().child("right")); }
        }
        """])
        let view = try home.view("row", width: 300)
        let left = try #require(view.frame(ofText: "left")), right = try #require(view.frame(ofText: "right"))
        #expect(left.minX == 0)
        #expect(right.minX == 100)
    }

    @Test func aProgramRunsOnlyWhenAllowed() async throws {
        let home = try Home(["runner": runner])
        let refused = try home.view("runner")
        await home.settle()
        refused.renderNow()
        #expect(refused.texts() == ["refused"])
        #expect(home.host.asked.isEmpty)

        let other = try Home(["runner": runner])
        let allowed = try other.view("runner", granted: [.programs])
        await other.settle()
        allowed.renderNow()
        #expect(allowed.texts() == ["ran: stand-in"])
        #expect(other.host.asked == ["git status"])
    }

    /// A home with the gates mod, a file outside its folder, and a link to
    /// that file from inside it.
    private func gatesHome() throws -> (home: Home, props: [String: Any]) {
        let home = try Home(["gates": gates])
        let out = home.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: out.appending(path: "secret.txt"))
        let own = home.root.appending(path: "mods/gates")
        try FileManager.default.createSymbolicLink(at: own.appending(path: "link.txt"), withDestinationURL: out.appending(path: "secret.txt"))
        return (home, ["out": out.path, "own": own.path])
    }

    @Test func aModAllowedNothingIsRefusedEverything() async throws {
        var (home, props) = try gatesHome()
        props["net"] = true
        let view = try home.view("gates", props: props)
        await home.settle(0.4)
        view.renderNow()
        // The link inside its own folder leads outside: refused like the file itself.
        #expect(view.texts() == ["end:reached hc:refused link:refused net:refused read:refused write:refused"])
        #expect(home.host.asked.isEmpty)
        #expect(home.host.commands.isEmpty)
        #expect(home.host.clipboard.isEmpty)
        #expect(home.host.opened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.root.appending(path: "outside/made.txt").path))
    }

    @Test func eachLeaveOpensItsOwnDoorOnly() async throws {
        // Reading: the files, and nothing else.
        var (home, props) = try gatesHome()
        var view = try home.view("gates", granted: [.readFiles], props: props)
        await home.settle(0.4)
        view.renderNow()
        #expect(view.texts() == ["end:reached hc:refused link:ok read:ok write:refused"])
        #expect(home.host.commands.isEmpty)

        // Commands: `run`, and nothing else.
        (home, props) = try gatesHome()
        view = try home.view("gates", granted: [.commands], props: props)
        await home.settle(0.4)
        view.renderNow()
        #expect(view.texts() == ["end:reached hc:refused link:refused read:refused write:refused"])
        #expect(home.host.commands == ["tab.new"])
        #expect(home.host.clipboard.isEmpty)

        // Writing: the file is made; programs stay shut.
        (home, props) = try gatesHome()
        view = try home.view("gates", granted: [.writeFiles], props: props)
        await home.settle(0.4)
        view.renderNow()
        #expect(view.texts() == ["end:reached hc:refused link:refused read:refused write:ok"])
        #expect(FileManager.default.fileExists(atPath: home.root.appending(path: "outside/made.txt").path))
        #expect(home.host.asked.isEmpty)
    }

    @Test func theClipboardAndPagesNeedAPress() async throws {
        let home = try Home(["presser": """
        import { View, div } from "gpui-kit";
        export default class Presser extends View {
          render() {
            return div().id("go").w(80).h(30).on_click((_e, cx) => { cx.write_to_clipboard("pressed"); cx.open_url("https://example.invalid/"); }).child("Go");
          }
        }
        """])
        let view = try home.view("presser")
        #expect(home.host.clipboard.isEmpty)
        #expect(view.click(text: "Go"))
        #expect(home.host.clipboard == ["pressed"])
        #expect(home.host.opened == ["https://example.invalid/"])
    }

    @Test func aModThatNeverEndsIsCut() throws {
        let home = try Home(["spinner": spinner])
        home.center.scriptTimeLimit = 0.3
        let started = Date()
        let view = try home.view("spinner")
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(!view.copy.runtime.errors.isEmpty)
    }

    @Test func theScanTellsWhatAModDoes() throws {
        let home = try Home(["counter": counter, "runner": runner])
        let plain = ModScan.report(folder: home.root.appending(path: "mods/counter"))
        #expect(plain.needs.isEmpty)
        let runs = ModScan.report(folder: home.root.appending(path: "mods/runner"))
        #expect(runs.needs.contains(.programs))
        #expect(runs.programs == ["git"])
    }

    @Test func selectedTextIsWhatADragCovers() throws {
        let home = try Home(["counter": counter])
        let view = try home.view("counter")
        #expect(view.select(fromText: "Count 0", toText: "Add"))
        #expect(view.selectedText == "Count 0\nAdd")
    }

    @Test func aLayoutHidesSelectsAndResizes() throws {
        let json: [String: Any] = [
            "type": "row", "children": [
                ["type": "block", "id": "main", "content": ["tab": "active"]],
                ["type": "column", "id": "panel", "size": ["px": 300], "children": [
                    ["type": "stack", "id": "body", "active": "a", "children": [
                        ["type": "block", "id": "a", "content": ["mod": "one"]],
                        ["type": "block", "id": "b", "content": ["mod": "two"]],
                    ]],
                ]],
            ],
        ]
        let layout = try #require(WindowLayout(name: "test", json: json))
        #expect(layout.mods == ["one", "two"])
        #expect(layout.run("layout.hide", ["id": "panel"]))
        #expect(layout.find("panel")?.hidden == true)
        #expect(layout.run("layout.select", ["stack": "body", "child": "b"]))
        #expect(layout.find("body")?.shownChild?.id == "b")
        #expect(layout.run("layout.resize", ["id": "panel", "px": 420]))
        #expect(layout.find("panel")?.px == 420)
        // What the person did comes back on the shared file.
        let again = try #require(WindowLayout(name: "test", json: json))
        again.restore(layout.state)
        #expect(again.find("panel")?.hidden == true)
        #expect(again.find("panel")?.px == 420)
        #expect(again.find("body")?.shownChild?.id == "b")
    }

    @Test func modsWithoutALayoutShareAPanel() throws {
        #expect(WindowLayout.own(mods: []) == nil)
        let own = try #require(WindowLayout.own(mods: ["vault", "contexte"]))
        #expect(own.isOwn)
        #expect(own.mods == ["vault", "contexte"])
        #expect(own.find("panel")?.px == 340)
        #expect(own.find("panel-body")?.shownChild?.id == "vault")
        // herdr-app's own commands for its side panel work on it.
        #expect(own.run("layout.select", ["stack": "panel-body", "child": "contexte"]))
        #expect(own.run("layout.toggle", ["id": "panel"]))
        // A mod added later: the panel keeps what the person chose.
        let more = try #require(WindowLayout.own(mods: ["vault", "contexte", "alertes"]))
        more.restore(own.state)
        #expect(more.find("panel")?.hidden == true)
        #expect(more.find("panel-body")?.shownChild?.id == "contexte")
    }

    @Test func aLayoutWithoutItsBarIsToldApart() throws {
        let json: [String: Any] = [
            "type": "column", "children": [
                ["type": "block", "id": "tabs", "content": ["mod": "tabs-vault"]],
                ["type": "block", "id": "brand", "content": ["mod": "workspace-chrome"]],
                ["type": "stack", "id": "body", "children": [
                    ["type": "block", "id": "vault", "content": ["mod": "vault"]],
                    ["type": "block", "id": "alertes", "content": ["mod": "alertes"]],
                ]],
            ],
        ]
        let layout = try #require(WindowLayout(name: "shared", json: json))
        // The bar is missing; herdr-app's own blocks and stacked mods don't count.
        #expect(layout.lacksLooseMod { $0 == "vault" })
        #expect(!layout.lacksLooseMod { $0 == "vault" || $0 == "tabs-vault" })
    }

    @Test func aStackOpensOnAModThePersonHas() throws {
        let json: [String: Any] = [
            "type": "row", "children": [
                ["type": "block", "id": "main", "content": ["tab": "active"]],
                ["type": "stack", "id": "body", "active": "files", "children": [
                    ["type": "block", "id": "files", "content": ["mod": "files"]],
                    ["type": "block", "id": "vault", "content": ["mod": "vault"]],
                    ["type": "block", "id": "contexte", "content": ["mod": "contexte"]],
                ]],
            ],
        ]
        let layout = try #require(WindowLayout(name: "shared", json: json))
        // No mod outside the stack is missing: the layout switches it itself.
        #expect(!layout.lacksLooseMod { $0 == "contexte" })
        layout.settle { $0 == "contexte" }
        #expect(layout.find("body")?.shownChild?.id == "contexte")
        // With none of its mods, it stays as its file has it.
        let bare = try #require(WindowLayout(name: "shared", json: json))
        bare.settle { _ in false }
        #expect(bare.find("body")?.shownChild?.id == "files")
    }
}
