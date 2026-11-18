import AppKit
import Foundation
import Testing
@testable import ModKit

/// What lets a person get a mod: the guide written for their agent, and a
/// mod or layout added from a link.
@Suite(.serialized) struct ModSharingTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "modkit-sharing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private let draws = "import { View, div } from 'gpui-kit';\nexport default class A extends View { render() { return div().child('hi'); } }\n"
    private let runs = "import { View, div } from 'gpui-kit';\nimport { exec } from 'herdr';\nexport default class A extends View { init(_p, cx) { cx.spawn(async () => { await exec('git', ['status']); }); } render() { return div(); } }\n"

    // MARK: Links

    @Test func aLinkIsReadFromWhatWasPasted() {
        #expect(ModFetch.link(in: "herdr.dev/mods/herdrdev/tmux-prefix") == .gallery(kind: "mods", owner: "herdrdev", name: "tmux-prefix"))
        #expect(ModFetch.link(in: "Read ~/.config/herdr-app/AGENTS.md, then add this mod: herdr.dev/mods/a-b/c.d") == .gallery(kind: "mods", owner: "a-b", name: "c.d"))
        #expect(ModFetch.link(in: "https://herdr.dev/layouts/someone/wide/") == .gallery(kind: "layouts", owner: "someone", name: "wide"))
        #expect(ModFetch.link(in: "https://github.com/owner/repo") == .github(.init(owner: "owner", name: "repo", ref: nil, path: "")))
        #expect(ModFetch.link(in: "github.com/owner/repo.git") == .github(.init(owner: "owner", name: "repo", ref: nil, path: "")))
        #expect(ModFetch.link(in: "https://github.com/owner/repo/tree/main/mods/one") == .github(.init(owner: "owner", name: "repo", ref: "main", path: "mods/one")))
    }

    @Test func otherSitesAndOddPathsAreNotLinks() {
        #expect(ModFetch.link(in: "https://example.com/owner/repo") == nil)
        #expect(ModFetch.link(in: "https://evilgithub.com/owner/repo") == nil)
        #expect(ModFetch.link(in: "https://github.com.evil.io/owner/repo") == nil)
        #expect(ModFetch.link(in: "notherdr.dev/mods/a/b") == nil)
        #expect(ModFetch.link(in: "https://github.com/owner/repo/tree/main/../../etc") == nil)
        #expect(ModFetch.link(in: "") == nil)
    }

    @Test func aGalleryPageNamesItsFolder() {
        let nav = "<a href=\"https://github.com/herdrdev/herdr\">app</a> <a href=\"https://github.com/other/thing/tree/main/x\">ad</a> "
        let folder = nav + "<a href=\"https://github.com/Someone\">them</a> <img src=\"https://github.com/someone.png\"> <a href=\"https://github.com/Someone/shared/tree/main/tmux-prefix\">source</a>"
        #expect(ModFetch.repo(inPage: folder, owner: "someone") == .init(owner: "Someone", name: "shared", ref: "main", path: "tmux-prefix"))
        // A whole repository: the page links it, and a file of it.
        let whole = nav + "<a href=\"https://github.com/someone\">them</a> <a href=\"https://github.com/someone/departures\">source</a> <a href=\"https://github.com/someone/departures/blob/main/RECIPE.md\">recipe</a>"
        #expect(ModFetch.repo(inPage: whole, owner: "someone") == .init(owner: "someone", name: "departures", ref: nil, path: ""))
        #expect(ModFetch.repo(inPage: nav, owner: "someone") == nil)
    }

    // MARK: Copying in

    @Test func aSharedFolderIsCopiedAndStaysMarked() throws {
        let shared = try folder(), home = try folder()
        try write(runs, shared.appending(path: "mods/git-status/main.js"))
        try write("{}", shared.appending(path: "mods/git-status/mod.json"))
        try write("{\"type\":\"row\",\"children\":[]}", shared.appending(path: "layouts/wide.json"))
        try write("{}", shared.appending(path: "keys.json"))
        let added = try ModFetch.install(from: shared, named: "shared", link: "github.com/someone/shared", to: home)
        #expect(added.mods == ["git-status"])
        #expect(added.layouts == ["wide"])
        #expect(added.reports["git-status"]?.needs.contains(.programs) == true)
        #expect(added.skipped.contains { $0.hasPrefix("keys.json") })
        #expect(added.summary.contains("stays off until you allow it"))
        let mod = home.appending(path: "mods/git-status")
        #expect(FileManager.default.fileExists(atPath: mod.appending(path: "mod.json").path))
        #expect(ModFetch.origin(of: mod) == "github.com/someone/shared")
        #expect(ModFetch.token(of: mod) != nil)
        // The person's keys are theirs to change.
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "keys.json").path))
    }

    @Test func aFolderWithMainIsOneMod() throws {
        let shared = try folder(), home = try folder()
        try write(draws, shared.appending(path: "main.js"))
        let added = try ModFetch.install(from: shared, named: "clock", link: "github.com/someone/clock", to: home)
        #expect(added.mods == ["clock"])
        #expect(added.reports["clock"]?.needs.isEmpty == true)
    }

    @Test func nothingThePersonHasIsReplaced() throws {
        let shared = try folder(), home = try folder()
        try write(runs, shared.appending(path: "mods/notes/main.js"))
        try write("{\"type\":\"row\"}", shared.appending(path: "layouts/wide.json"))
        try write(draws, home.appending(path: "mods/notes/main.js"))
        try write("{\"mine\":true}", home.appending(path: "layouts/wide.json"))
        let added = try ModFetch.install(from: shared, named: "shared", link: "github.com/someone/shared", to: home)
        #expect(added.mods.isEmpty && added.layouts.isEmpty)
        #expect(added.skipped.count == 2)
        #expect(try String(contentsOf: home.appending(path: "mods/notes/main.js"), encoding: .utf8) == draws)
        #expect(try String(contentsOf: home.appending(path: "layouts/wide.json"), encoding: .utf8) == "{\"mine\":true}")
        // The person's own mod carries no mark.
        #expect(ModFetch.token(of: home.appending(path: "mods/notes")) == nil)
    }

    @Test func aSecondCopyHasAnotherMark() throws {
        let shared = try folder(), home = try folder()
        try write(draws, shared.appending(path: "main.js"))
        _ = try ModFetch.install(from: shared, named: "clock", link: "l", to: home)
        let first = try #require(ModFetch.token(of: home.appending(path: "mods/clock")))
        try FileManager.default.removeItem(at: home.appending(path: "mods/clock"))
        _ = try ModFetch.install(from: shared, named: "clock", link: "l", to: home)
        #expect(ModFetch.token(of: home.appending(path: "mods/clock")) != first)
    }

    @Test func linksAndSwiftrsOwnNamesAreLeftOut() throws {
        let shared = try folder(), home = try folder(), outside = try folder()
        try write("secret", outside.appending(path: "secret.txt"))
        try write(draws, shared.appending(path: "mods/clock/main.js"))
        try FileManager.default.createSymbolicLink(at: shared.appending(path: "mods/clock/leak.txt"), withDestinationURL: outside.appending(path: "secret.txt"))
        try FileManager.default.createSymbolicLink(at: shared.appending(path: "mods/clock/away"), withDestinationURL: outside)
        try write("x", shared.appending(path: "mods/clock/.git/config"))
        // herdr-app's own parts ride along with its layouts.
        try write(draws, shared.appending(path: "mods/tabs/main.js"))
        try write(draws, shared.appending(path: "mods/changes/main.js"))
        // A mod whose main.js is a link is no mod.
        try FileManager.default.createDirectory(at: shared.appending(path: "mods/linked"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shared.appending(path: "mods/linked/main.js"), withDestinationURL: outside.appending(path: "secret.txt"))
        let added = try ModFetch.install(from: shared, named: "shared", link: "l", to: home)
        #expect(added.mods == ["clock"])
        let copied = try FileManager.default.contentsOfDirectory(atPath: home.appending(path: "mods/clock").path).sorted()
        #expect(copied == [".source.json", "main.js"])
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "mods/tabs").path))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "mods/linked").path))
    }

    @Test func aFolderWithNoModSaysSo() throws {
        let shared = try folder(), home = try folder()
        try write("# hello", shared.appending(path: "README.md"))
        #expect(throws: ModFetch.Failure.self) { try ModFetch.install(from: shared, named: "x", link: "l", to: home) }
    }

    // MARK: The guide

    @Test func theGuideIsWrittenForThisHome() throws {
        let home = try folder()
        ModGuide.write(home: home, program: "/Applications/Swiftr's.app/Contents/MacOS/Swiftr", version: "9.9")
        let guide = try String(contentsOf: home.appending(path: "AGENTS.md"), encoding: .utf8)
        #expect(guide.contains(home.path + "/bin/swiftr-mod check"))
        #expect(guide.contains("Swiftr 9.9"))
        #expect(!guide.contains("{{"))
        let launcher = try String(contentsOf: home.appending(path: "bin/swiftr-mod"), encoding: .utf8)
        #expect(launcher.contains("exec '/Applications/Swiftr'\\''s.app/Contents/MacOS/Swiftr' --mod \"$@\""))
        #expect(FileManager.default.isExecutableFile(atPath: home.appending(path: "bin/swiftr-mod").path))
        // A second start changes nothing on disk.
        let before = try FileManager.default.attributesOfItem(atPath: home.appending(path: "API.md").path)[.modificationDate] as? Date
        ModGuide.write(home: home, program: "/Applications/Swiftr's.app/Contents/MacOS/Swiftr", version: "9.9")
        let after = try FileManager.default.attributesOfItem(atPath: home.appending(path: "API.md").path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test func theNamesComeFromTheRuntime() {
        let api = ModGuide.api()
        for name in ["`div`", "`v_flex`", "`agents`", "`on_click`", "`write_to_clipboard`", "`localStorage`", "`after`"] {
            #expect(api.contains(name), "\(name) is missing")
        }
        // What does nothing is said to.
        let idle = api.components(separatedBy: "Taken, and do nothing here: ").dropFirst()
            .map { $0.prefix { $0 != "\n" } }.joined(separator: " ")
        #expect(idle.contains("`on_pinch`") && idle.contains("`scroll_size`"))
        // What Swiftr runs is not in that list.
        for name in ["`transition`", "`on_drop`", "`loop`", "`frames`", "`spring`", "`tab_index`", "`drag_paths`"] {
            #expect(api.contains(name) && !idle.contains(name), "\(name) should be live")
        }
    }

    /// The guide's second example, on parts, runs as it says: the checkbox
    /// reports its change, the menu opens, picks and shuts.
    @Test func theGuidesPartsExampleRuns() throws {
        let guide = ModGuide.guide(home: try folder(), version: "1")
        let blocks = guide.components(separatedBy: "```js\n").dropFirst().compactMap { $0.components(separatedBy: "\n```").first }
        let source = try #require(blocks.first { $0.contains("Popover.new") })
        let home = try Home(["options": source])
        let view = try home.view("options")
        #expect(view.texts() == ["Wrap lines", "Sort by Name"])
        #expect(view.accessReport() == ["CheckBox: Wrap lines [0]", "PopUpButton: Sort by Name"])
        #expect(view.click(text: "Wrap lines"))
        #expect(view.click(text: "Sort by Name"))
        view.renderNow()
        #expect(view.texts() == ["Wrap lines", "Sort by Name", "Name", "Date", "Size"])
        #expect(view.accessReport().first == "CheckBox: Wrap lines [1]")
        #expect(view.click(text: "Date"))
        view.renderNow()
        #expect(view.texts() == ["Wrap lines", "Sort by Date"])
        #expect(home.center.loaded("options")?.unsupported.isEmpty == true)
        #expect(home.center.loaded("options")?.errors.isEmpty == true)
    }

    /// Every name the guide tells an agent to call is one the runtime has.
    @Test func theGuideNamesOnlyWhatIsThere() throws {
        let home = try folder()
        let guide = ModGuide.guide(home: home, version: "1")
        let api = ModGuide.api()
        let section = try #require(guide.components(separatedBy: "## What a mod can read").last?.components(separatedBy: "## What the person allows").first)
        let regex = try NSRegularExpression(pattern: "`(?:await )?(?:cx\\.)?(?:window\\.|timer\\.)?([A-Za-z_]+)\\(")
        var names: Set<String> = []
        for match in regex.matches(in: section, range: NSRange(section.startIndex..., in: section)) {
            if let range = Range(match.range(at: 1), in: section) { names.insert(String(section[range])) }
        }
        #expect(names.count > 20)
        // `fetch` is a global, `text` and `json` its answer's.
        for name in names.sorted() where !["fetch", "text", "json"].contains(name) { #expect(api.contains("`\(name)`"), "\(name) is in the guide and not in the runtime") }
    }

    /// The guide's layout is one Swiftr reads: the tab, and the mod beside it.
    @Test func theGuidesLayoutLoads() throws {
        let guide = ModGuide.guide(home: try folder(), version: "1")
        let start = try #require(guide.range(of: "```json\n{\n  \"type\": \"row\"")), rest = guide[guide.index(start.lowerBound, offsetBy: 8)...]
        let end = try #require(rest.range(of: "\n```"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(rest[..<end.lowerBound].utf8)) as? [String: Any])
        let layout = try #require(WindowLayout(name: "guide", json: json))
        #expect(layout.mods == ["hello"])
        #expect(layout.find("panel") != nil && layout.find("main") != nil)
        layout.run("layout.toggle", ["id": "panel"])
        #expect(layout.find("panel")?.hidden == true)
    }

    /// The guide's own example is a mod that draws.
    @Test func theGuidesExampleRuns() throws {
        let guide = ModGuide.guide(home: try folder(), version: "1")
        let start = try #require(guide.range(of: "```js\n")), rest = guide[start.upperBound...]
        let end = try #require(rest.range(of: "\n```"))
        let home = try Home(["hello": String(rest[..<end.lowerBound])])
        home.center.setData("agents", [["address": "a"], ["address": "b"]])
        let view = try home.view("hello")
        #expect(view.texts().contains("2 agents"))
        #expect(view.click(text: "Clicked 0"))
        view.renderNow()
        #expect(view.texts().contains("Clicked 1"))
        #expect(home.center.loaded("hello")?.unsupported.isEmpty == true)
        #expect(home.center.loaded("hello")?.errors.isEmpty == true)
    }
}
