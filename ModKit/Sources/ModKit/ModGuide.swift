import Foundation
import JavaScriptCore

/// What Swiftr tells a coding agent about mods, as files in the mods' home
/// (`~/.config/swiftr`): `AGENTS.md`, the guide; `API.md`, every name a
/// mod's script can call here; and `bin/swiftr-mod`, which runs the app's
/// own tool. With them, a person asks their agent for a panel and the
/// agent can write it, check it and look at it.
///
/// Swiftr writes them on each start, so they match the app that runs.
public enum ModGuide {
    /// Reads the names out of the runtime itself: each module's exports,
    /// an element's methods, the context's. A method whose whole body gives
    /// the element back, or nothing, is taken but does nothing here.
    private static let survey = """
    (function () {
      function inert(f) {
        var body = String(f).replace(/\\s+/g, " ");
        return /\\{ ?(return (this|null|false|\\[\\]|undefined|Promise\\.resolve\\([^)]*\\));?)? ?\\}$/.test(body);
      }
      // Kept by the script and never drawn or called by Swiftr.
      var quiet = { on_pinch: 1 };
      function split(object) {
        var live = [], idle = [];
        Object.keys(object).sort().forEach(function (name) {
          if (name === "default" || name === "toString" || name === "valueOf") return;
          var f = object[name];
          (quiet[name] || (typeof f === "function" && inert(f)) ? idle : live).push(name);
        });
        return { live: live, idle: idle };
      }
      var out = { modules: {} };
      ["gpui-kit", "gpui-base", "herdr", "path", "fs/promises", "process", "os", "url", "console", "gpui-fps",
       "buffer", "crypto", "zlib", "net", "websocket"].forEach(function (name) {
        out.modules[name] = split(__mod.module(name));
      });
      var Buffer = __mod.module("buffer").Buffer;
      function own(object) {
        return Object.getOwnPropertyNames(object).filter(function (name) { return name !== "constructor" && typeof object[name] === "function"; }).sort();
      }
      // The number readers and writers are named in one line of their own.
      out.buffer = { live: own(Buffer), idle: own(Buffer.prototype).filter(function (name) { return !/^(read|write)(U?[Ii]nt|Float|Double)/.test(name); }) };
      var proto = Object.getPrototypeOf(__mod.module("gpui-kit").div());
      var methods = {};
      Object.getOwnPropertyNames(proto).forEach(function (name) {
        if (name !== "constructor" && name !== "toJSON" && typeof proto[name] === "function") methods[name] = proto[name];
      });
      out.element = split(methods);
      var cx = null;
      function Probe() {}
      Probe.prototype.init = function (_props, context) { cx = context; };
      __mod.create(1, Probe, "{}", null);
      out.context = cx ? split(cx) : { live: [], idle: [] };
      out.timer = cx ? split(cx.timer) : { live: [], idle: [] };
      out.window = cx ? split(cx.window) : { live: [], idle: [] };
      return JSON.stringify(out);
    })()
    """

    private struct Names: Decodable {
        struct Group: Decodable { var live: [String]; var idle: [String] }
        var modules: [String: Group]
        /// `Buffer`'s own functions (`live`) and a buffer's methods (`idle`).
        var buffer: Group
        var element: Group
        var context: Group
        var timer: Group
        var window: Group
    }

    private static func names() -> Names? {
        guard let url = Bundle.module.url(forResource: "prelude", withExtension: "js"),
              let prelude = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else { return nil }
        // No app behind it: whatever the prelude asks of Swiftr answers nothing.
        context.evaluateScript("this.__native = new Proxy({}, { get: function () { return function () { return null; }; } });")
        context.evaluateScript(prelude)
        guard let text = context.evaluateScript(survey)?.toString(), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Names.self, from: data)
    }

    /// `API.md`: the names, as a list. It carries no types.
    public static func api() -> String {
        guard let names = names() else { return "The mod runtime is missing from this copy of Swiftr.\n" }
        func list(_ words: [String]) -> String { words.map { "`\($0)`" }.joined(separator: ", ") }
        var out = """
        # What a mod's script can call in Swiftr

        <!-- Written by Swiftr on every start, from its own runtime. Edits here are overwritten. -->

        Names only: this list carries no types. The builders follow gpui-kit's
        (https://gpui-kit.com), which herdr-app's mods are written against; if
        herdr-app is on this Mac, `~/.config/herdr-app/gpui-kit.d.ts` and
        `~/.config/herdr-app/herdr.d.ts` give their arguments. A name that is
        not here is not in Swiftr: `swiftr-mod check` names the ones a mod
        calls anyway.


        """
        func section(_ title: String, _ group: Names.Group, idle: String) {
            out += "## \(title)\n\n\(list(group.live))\n\n"
            if !group.idle.isEmpty { out += "\(idle): \(list(group.idle))\n\n" }
        }
        let nothing = "Taken, and do nothing here"
        for name in ["gpui-kit", "gpui-base", "herdr"] {
            guard let group = names.modules[name] else { continue }
            section("`import { … } from \"\(name)\"`", group, idle: nothing)
        }
        section("Methods of an element (`div().…`)", names.element, idle: nothing)
        out += """
        Lengths also take suffixes, as in gpui: `p_2`, `px_3`, `gap_1p5`, `w_full`,
        `h_8`, `mt_neg_1`.


        """
        section("The context (`cx`, the last argument of `init`, `render` and every handler)", names.context, idle: nothing)
        section("`cx.timer`", names.timer, idle: nothing)
        section("`cx.window`", names.window, idle: "Answer a fixed value here")
        out += "## Node-style modules\n\n"
        for name in ["path", "fs/promises", "process", "os"] {
            guard let group = names.modules[name] else { continue }
            out += "- `\(name)` (also `node:\(name)`): \(list(group.live + group.idle))\n"
        }
        for name in ["url", "console", "gpui-fps"] {
            guard let group = names.modules[name] else { continue }
            if name == "console" { out += "- `console`: the global `console`, as its default export\n"; continue }
            out += "- `\(name)`: \(list(group.live + group.idle))\(name == "gpui-fps" ? " (taken, and show nothing here)" : "")\n"
        }
        for name in ["buffer", "crypto", "zlib", "net"] {
            guard let group = names.modules[name] else { continue }
            out += "- `\(name)` (also `node:\(name)`): \(list(group.live + group.idle))\n"
        }
        if let group = names.modules["websocket"] { out += "- `websocket`: \(list(group.live + group.idle))\n" }
        out += """

        `Buffer` is a `Uint8Array` with \(list(names.buffer.live)), and on each buffer
        \(list(names.buffer.idle)), with Node's number readers and writers (`readUInt32BE`,
        `writeInt16LE`, `readDoubleLE`…). Its encodings are `utf8`, `hex`, `base64`, `base64url`,
        `latin1`, `ascii` and `utf16le`. `readFile(path)` with no encoding gives the file's bytes,
        and `writeFile` and `fetch`'s `body` take bytes.

        `createHash` takes `md5`, `sha1`, `sha256`, `sha384` or `sha512`; `digest()` gives a
        `Buffer`, `digest("hex")` text. `webcrypto` has `getRandomValues`, `randomUUID` and
        `subtle.digest`.

        `await connect(host, port)` from `net` gives a socket: `await read(maxBytes)` (bytes, or
        null once the other side is done), `await write(data)`, `close()`.
        `await WebSocket.connect(url, { headers })` from `websocket` gives one whose
        `await read()` is the next message (text, or bytes), with `await write(data)` and
        `await close()`. Both need the leave to reach the network.

        """
        out += "\nThere is no `setTimeout` and no `setInterval`: use `cx.sleep(ms)`, `cx.timer.after(ms, f)` and `cx.timer.every(ms, f)`.\n"
        return out
    }

    /// The guide, for this app: where its tool is and where the mods live.
    public static func guide(home: URL, version: String) -> String {
        guard let url = Bundle.module.url(forResource: "guide", withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let person = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = home.path.hasPrefix(person + "/") ? "~" + home.path.dropFirst(person.count) : home.path
        return text.replacingOccurrences(of: "{{home}}", with: shown).replacingOccurrences(of: "{{version}}", with: version)
    }

    /// Writes the guide, the names and the tool's launcher into `home`.
    /// `program` is the app's own executable: the launcher runs it with
    /// `--mod`. Files that already say the same are left alone.
    public static func write(home: URL, program: String, version: String) {
        func put(_ text: String, at path: String, executable: Bool = false) {
            let file = home.appending(path: path)
            if let old = try? String(contentsOf: file, encoding: .utf8), old == text { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
            if executable { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        }
        let guide = guide(home: home, version: version)
        guard !guide.isEmpty else { return }
        let quoted = "'" + program.replacingOccurrences(of: "'", with: "'\\''") + "'"
        put("#!/bin/sh\n# Written by Swiftr on every start: runs the app's own mod tool.\nexec \(quoted) --mod \"$@\"\n", at: "bin/swiftr-mod", executable: true)
        put(api(), at: "API.md")
        put(guide, at: "AGENTS.md")
    }
}
