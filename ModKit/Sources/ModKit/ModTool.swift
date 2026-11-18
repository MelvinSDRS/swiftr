import AppKit
import Foundation
import JavaScriptCore

// swiftr-mod: look at a mod without the app, and bring one in from a link.
// The app runs this too, started with `--mod` (`Swiftr --mod check <folder>`),
// so the tool is there on every Mac that has Swiftr.
//
//   swiftr-mod check <mod folder> [options]    load it, draw it once, say what it uses
//   swiftr-mod shot <mod folder> <out.png>     the same, and a picture of its panel
//   swiftr-mod add <link> [--home <dir>]       copy a mod or a layout from herdr.dev or GitHub
//   swiftr-mod api                             what a mod's script can call here
//   swiftr-mod syntax <folder>…                parse every module under the folders
//
// Options of check and shot: --home <dir> (the person's home the mod sees),
// --data <file.json> (spaces, agents, theme… and canned program answers),
// --width, --height, --wait <ms>, --props <json>, --do <steps>, --json.
//
// A mod checked here never runs a program, reaches the network, or reads a
// file outside `--home` and its own folder: it is somebody else's code.
public enum ModTool {
    static let usage = """
    usage:
      swiftr-mod check <mod folder> [--json] [--texts] [--data file.json] [--do "click:Add; type:name=text"]
          Loads the mod, draws it once, and prints its errors, what it asks
          the app for, and what it calls that Swiftr lacks. It runs no
          program and reaches no site. A mod that came from a link is
          refused until you pass --reviewed.
      swiftr-mod shot <mod folder> <out.png> [--width 360] [--height 560]
          The same, with the same options, and a picture of the panel.
          More --do steps: key:tab (shift-tab, space, enter, escape, down…),
          hover:Text, drop:Text=/a/file,/another, drag:Text=40,0, wait:300.
          --data gives the mod its lists (focused, agents, spaces…) and,
          under "exec", answers to the programs it runs.
      swiftr-mod add <link> [--home <folder>]
          Copies the mods and layouts of a herdr.dev/mods page or a GitHub
          folder into Swiftr's. It replaces nothing and allows nothing.
      swiftr-mod api
          Every name a mod's script can call.
    """

    public static func run(_ arguments: [String]) -> Never {
        guard let verb = arguments.first else { fail(usage) }
        switch verb {
        case "syntax":
            var bad: Int32 = 0
            for folder in arguments.dropFirst() { bad |= syntax(folder) }
            exit(bad)
        case "function":
            guard arguments.count > 1 else { fail("function <file.js>") }
            print(ModSource.function(from: (try? String(contentsOfFile: arguments[1], encoding: .utf8)) ?? ""))
            exit(0)
        case "api":
            print(ModGuide.api())
            exit(0)
        case "add": add(Array(arguments.dropFirst()))
        case "check", "shot": check(verb, Array(arguments.dropFirst()))
        case "--help", "-h", "help":
            print(usage)
            exit(0)
        default: fail("unknown: \(verb)\n\(usage)")
        }
    }

    static func fail(_ text: String) -> Never {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(2)
    }

    private static func syntax(_ root: String) -> Int32 {
        let context = JSContext()!
        var files = 0, bad = 0
        guard let walker = FileManager.default.enumerator(atPath: root) else { fail("\(root): no such folder") }
        while let name = walker.nextObject() as? String {
            if name.contains("node_modules/") || name.contains(".git/") { continue }
            guard name.hasSuffix(".js") || name.hasSuffix(".mjs") else { continue }
            let path = root + "/" + name
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            guard source.contains("import ") || source.contains("export ") else { continue }
            files += 1
            var exception: JSValueRef?
            let script = JSStringCreateWithUTF8CString(ModSource.function(from: source))
            let ok = JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 0, &exception)
            JSStringRelease(script)
            if !ok {
                bad += 1
                let why = exception.map { JSValue(jsValueRef: $0, in: context).toString() ?? "" } ?? ""
                let line = exception.flatMap { JSValue(jsValueRef: $0, in: context).objectForKeyedSubscript("line")?.toInt32() } ?? 0
                print("BAD \(path):\(line) \(why)")
            }
        }
        print("\(files) modules, \(bad) bad")
        return bad == 0 ? 0 : 1
    }

    /// Options after the verb: `--name value`, the flags that take none,
    /// and what is left.
    private static func parse(_ arguments: [String], flags known: Set<String>) -> (positional: [String], options: [String: String], flags: Set<String>) {
        var positional: [String] = [], options: [String: String] = [:], flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if known.contains(word) { flags.insert(word) }
            else if word.hasPrefix("--"), index + 1 < arguments.count { options[word] = arguments[index + 1]; index += 1 }
            else { positional.append(word) }
            index += 1
        }
        return (positional, options, flags)
    }

    /// Swiftr's mods home, as the app finds it.
    static func home(_ options: [String: String]) -> URL {
        if let given = options["--home"] ?? ProcessInfo.processInfo.environment["SWIFTR_MODS_HOME"] {
            return URL(fileURLWithPath: given).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/swiftr")
    }

    // MARK: add

    /// `add <link>`: the mods and layouts a herdr.dev or GitHub link holds,
    /// copied into Swiftr's home. Nothing there is replaced, and nothing
    /// runs: the person allows each mod in Swiftr.
    private static func add(_ arguments: [String]) -> Never {
        let (positional, options, _) = parse(arguments, flags: [])
        guard let link = positional.first else { fail("add <herdr.dev or github.com link> [--home <dir>]") }
        let home = home(options)
        Task {
            do {
                let found = try await ModFetch.add(link: link, to: home)
                print(found.summary)
                exit(found.mods.isEmpty && found.layouts.isEmpty ? 1 : 0)
            } catch {
                fail("\(error)")
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    // MARK: check, shot

    /// The app, for a mod that is only looked at: it notes what the mod asks
    /// and answers from the data file.
    private final class StandIn: ModHost {
        var programs: [String] = []
        var full = false
        var commands: [String] = []
        var canned: [[String: Any]] = []

        func modRun(command: String, arguments: [String: Any], from copy: ModCopy?) { commands.append(command) }
        func modOpenOverlay(_ spec: [String: Any], from copy: ModCopy?) -> String { commands.append("openOverlay"); return "overlay-1" }
        func modNotify(_ notification: [String: Any]) -> String { "note-1" }
        func modOpen(_ url: URL) { commands.append("open \(url.host() ?? "")") }
        func modClipboard() -> String? { nil }
        func modSetClipboard(_ text: String) { commands.append("copy") }

        func modExec(_ request: ModExecRequest) async throws -> ModExecResult {
            let line = ([request.command] + request.arguments).joined(separator: " ")
            programs.append(full ? line : String(line.prefix(160)))
            for answer in canned {
                guard let pattern = answer["match"] as? String, line.range(of: pattern, options: .regularExpression) != nil else { continue }
                return ModExecResult(code: Int32(answer["code"] as? Int ?? 0), stdout: answer["stdout"] as? String ?? "", stderr: answer["stderr"] as? String ?? "")
            }
            return ModExecResult(code: 127, stdout: "", stderr: "\(request.command): not run in a check")
        }
    }

    private static func check(_ verb: String, _ arguments: [String]) -> Never {
        let (positional, options, flags) = parse(arguments, flags: ["--json", "--texts", "--reviewed"])
        guard let folderArgument = positional.first else { fail("which mod folder?") }
        let folder = URL(fileURLWithPath: folderArgument).standardizedFileURL
        guard FileManager.default.fileExists(atPath: folder.appending(path: "main.js").path) else {
            fail("\(folder.path): no main.js there. A mod is a folder that holds main.js.")
        }
        // A check runs the mod's script. One that came from a link is
        // somebody else's program: it is read first, and run on the
        // person's word.
        if let origin = ModFetch.origin(of: folder), !flags.contains("--reviewed") {
            fail("""
            \(folder.lastPathComponent) came from \(origin), and a check runs its script.
            Read its files, tell the person what they do, and once they agree run this again with --reviewed.
            """)
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftr-mod-\(ProcessInfo.processInfo.processIdentifier)")
        let userHome = options["--home"].map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? scratch.appending(path: "home").path
        try? FileManager.default.createDirectory(atPath: userHome, withIntermediateDirectories: true)
        // The mods' home: the folder that holds `mods/<this mod>`, when it is laid
        // out that way, so pictures named from it (`mods/vault/key.svg`) are found.
        let appHome = folder.deletingLastPathComponent().lastPathComponent == "mods"
            ? folder.deletingLastPathComponent().deletingLastPathComponent()
            : URL(fileURLWithPath: userHome).appending(path: ".config/swiftr")

        var data: [String: Any] = [:]
        if let file = options["--data"] {
            guard let bytes = FileManager.default.contents(atPath: file), let parsed = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                fail("\(file): not a JSON object")
            }
            data = parsed
        }

        // No Dock icon and no window: this is a tool, even inside the app.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = StandIn()
        host.canned = data["exec"] as? [[String: Any]] ?? []
        host.full = flags.contains("--json")
        let center = ModCenter(home: appHome, host: host, userHome: userHome)
        center.jail = [userHome, folder.path, appHome.path]
        center.assetRoots = [appHome]

        let theme = data["theme"] as? [String: Any] ?? ["background": "#1f2126", "foreground": "#d7dae0"]
        let colors = ModTheme.colors(from: theme)
        center.setData("theme", colors)
        var settings = data["settings"] as? [String: Any] ?? [:]
        settings["dark"] = !ModTheme.isLight(colors["background"] ?? "#000000")
        center.setData("settings", settings)
        for key in ["spaces", "agents", "panes", "terminals", "focused", "machines", "layout", "layouts", "window", "themes", "keys", "commands", "fonts", "shared"] {
            if let value = data[key] {
                if key == "shared", let all = value as? [String: Any] { for (name, item) in all { center.setShared(name, item) } }
                else { center.setData(key, value) }
            }
        }

        // What it may do in a check: ask for anything, and get stand-in answers.
        // The network stays shut.
        let width = Double(options["--width"] ?? "") ?? 360
        let height = Double(options["--height"] ?? "") ?? 560
        let wait = Double(options["--wait"] ?? "") ?? 600
        var props: [String: Any] = [:]
        if let text = options["--props"], let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { props = parsed }

        // Whatever the script does, the check ends.
        DispatchQueue.global().asyncAfter(deadline: .now() + wait / 1000 + 20) {
            FileHandle.standardError.write(Data("\(folder.lastPathComponent): no end after 20 s\n".utf8))
            exit(3)
        }

        var report: [String: Any] = ["mod": folder.lastPathComponent]
        var image: CGImage?
        do {
            let runtime = try center.runtime(folder: folder, granted: [.programs, .readFiles, .writeFiles, .commands])
            let copy = try runtime.makeCopy(props: props, slot: "check")
            let view = ModView(copy: copy)
            view.setFrameSize(CGSize(width: width, height: height))
            // What it loads on start comes back over a few turns of the run loop.
            RunLoop.main.run(until: Date().addingTimeInterval(wait / 1000))
            view.renderNow()
            // --do "type:<hint>=<text>; click:<text>; submit:<hint>=<text>; wait:<ms>;
            //       hover:<text>; key:<chord>; drop:<text>=<paths>; drag:<text>=<dx>,<dy>"
            for step in (options["--do"] ?? "").split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !step.isEmpty {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let rest = parts.count > 1 ? parts[1] : ""
                let pair = rest.split(separator: "=", maxSplits: 1).map(String.init)
                var done = true
                switch parts[0] {
                case "click": done = view.click(text: rest)
                case "click-id": done = view.click(id: rest)
                case "select":
                    // select:<first text>..<last text>, as a drag from one to the other.
                    let ends = rest.components(separatedBy: "..")
                    done = ends.count == 2 && view.select(fromText: ends[0], toText: ends[1])
                case "right-click": done = view.click(text: rest, button: "right")
                case "type": done = view.type(pair.count > 1 ? pair[1] : "", inFieldWithHint: pair[0])
                case "submit": done = view.type(pair.count > 1 ? pair[1] : "", inFieldWithHint: pair[0], submit: true)
                case "wait": RunLoop.main.run(until: Date().addingTimeInterval((Double(rest) ?? 100) / 1000))
                // hover:<text> rests the pointer there until a hover card opens; hover: takes it away.
                case "hover": done = view.hover(text: rest.isEmpty ? nil : rest)
                // key:tab, key:shift-tab, key:space, key:enter, key:escape, key:down, key:a
                case "key": view.press(key: rest)
                case "drop":
                    // drop:<text>=<path>,<path>: files let go over the element that shows the text.
                    done = pair.count > 1 && view.drop(paths: pair[1].split(separator: ",").map(String.init), onText: pair[0])
                case "drag":
                    // drag:<text>=<dx>,<dy>: a press on the text, let go that far from it.
                    let by = (pair.count > 1 ? pair[1] : "").split(separator: ",").compactMap { Double($0) }
                    done = by.count == 2 && view.locate({ $0.kind == .text && $0.text == pair[0] }) != nil
                    if done { view.drag(fromText: pair[0], by: CGSize(width: by[0], height: by[1])) }
                default: done = false
                }
                if !done { print("  step not done: \(step)") }
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                view.renderNow()
            }
            let started = CFAbsoluteTimeGetCurrent()
            image = view.snapshot(size: CGSize(width: width, height: height))
            report["texts"] = view.texts()
            if !view.selectedText.isEmpty { report["selected"] = view.selectedText }
            report["render_ms"] = ((CFAbsoluteTimeGetCurrent() - started) * 100_000).rounded() / 100
            report["nodes"] = view.nodeCount
            // --bench <n>: n full passes (the mod's render, layout, paint at 2x),
            // the middle one of each, in milliseconds.
            if let passes = Int(options["--bench"] ?? ""), passes > 0 {
                var script: [Double] = [], layout: [Double] = [], paint: [Double] = []
                for _ in 0..<passes {
                    let before = CFAbsoluteTimeGetCurrent()
                    _ = view.snapshot(size: CGSize(width: width, height: height))
                    let total = (CFAbsoluteTimeGetCurrent() - before) * 1000
                    let s = view.lastRenderMs["script"] ?? 0, l = view.lastRenderMs["layout"] ?? 0
                    script.append(s); layout.append(l); paint.append(max(0, total - s - l))
                }
                func middle(_ values: [Double]) -> Double { (values.sorted()[values.count / 2] * 1000).rounded() / 1000 }
                report["bench_ms"] = ["script": middle(script), "layout": middle(layout), "paint": middle(paint)]
            }
            report["unsupported"] = runtime.unsupported
            report["errors"] = runtime.errors
            report["log"] = Array(runtime.log.suffix(20))
            report["files"] = runtime.files
        } catch {
            report["errors"] = ["\(error)"]
        }
        var ranOnce: [String] = []
        for line in host.programs where !ranOnce.contains(line) { ranOnce.append(line) }
        report["programs"] = ranOnce
        report["commands"] = Array(Set(host.commands)).sorted()

        if verb == "shot" {
            guard positional.count > 1 else { fail("shot <mod folder> <out.png>") }
            if let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: positional[1]))
            }
        }
        if flags.contains("--json") {
            let bytes = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            print(String(decoding: bytes, as: UTF8.self))
        } else {
            print("\(report["mod"] ?? ""): \(report["nodes"] ?? 0) elements, drawn in \(report["render_ms"] ?? 0) ms")
            for error in report["errors"] as? [String] ?? [] { print("  error: \(error.split(separator: "\n").prefix(3).joined(separator: "\n         "))") }
            let missing = (report["unsupported"] as? [String: Int] ?? [:]).sorted { $0.value > $1.value }
            if !missing.isEmpty { print("  not in Swiftr yet: " + missing.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")) }
            for line in report["programs"] as? [String] ?? [] { print("  runs: \(line.split(separator: "\n").first ?? "")") }
            for (path, how) in (report["files"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }) { print("  file (\(how)): \(path)") }
            if flags.contains("--texts") { print("  texts: " + (report["texts"] as? [String] ?? []).joined(separator: " | ")) }
            let ran = report["commands"] as? [String] ?? []
            if !ran.isEmpty { print("  commands: " + ran.joined(separator: ", ")) }
        }
        try? FileManager.default.removeItem(at: scratch)
        exit((report["errors"] as? [String] ?? []).isEmpty ? 0 : 1)
    }
}
