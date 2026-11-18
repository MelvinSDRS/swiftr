import AppKit
import Foundation
import JavaScriptCore

// JavaScriptCore's own stop for a script that runs too long (in its
// JSContextRefPrivate.h; not in the Swift module).
@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func JSContextGroupSetExecutionTimeLimit(
    _ group: JSContextGroupRef?, _ limit: Double,
    _ callback: (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?, _ context: UnsafeMutableRawPointer?
)

/// What a copy's view does for its script: the keyboard, fields, lists.
protocol ModSurface: AnyObject {
    func focus(handle: String)
    func focusField(_ id: String)
    func replaceInField(_ id: String, text: String)
    func selectInField(_ id: String, start: Int, end: Int)
    func scroll(handle: String, toItem index: Int, strategy: String?)
    /// The rows of a long list to describe: the ones near what shows.
    func listRange(id: String, count: Int) -> Range<Int>
    func dispatchAction(_ name: String)
    /// Moves the keyboard to the next (1) or the last (-1) Tab stop.
    @discardableResult
    func moveFocus(by step: Int) -> Bool
}

/// One mod: its script, loaded once and shared by its copies, as in
/// herdr-app.
public final class ModRuntime {
    public let name: String
    public let folder: URL
    public unowned let center: ModCenter
    /// What the person agreed this mod may do.
    public var granted: ModCapabilities {
        // A socket outlives the call that opened it: it goes with the leave.
        didSet { if !granted.contains(.network) { shutSockets() } }
    }

    /// The sockets the script holds (`net`, `websocket`), by the number it
    /// knows them by.
    private var sockets: [Int: any ModSocket] = [:]
    private var nextSocket = 1
    /// How many a mod may hold open at once.
    static let socketLimit = 16
    public var openSockets: Int { sockets.count }

    private func keep(_ socket: any ModSocket) -> Int {
        let id = nextSocket
        nextSocket += 1
        sockets[id] = socket
        return id
    }

    private func shutSockets() {
        for socket in sockets.values { socket.shut() }
        sockets = [:]
    }

    /// Whether one more socket may open. Those the other side ended, and
    /// the script never closed, give their place back first.
    private func hasRoomForSocket() -> Bool {
        if sockets.count >= Self.socketLimit {
            for (id, socket) in sockets where socket.isOver {
                socket.shut()
                sockets[id] = nil
            }
        }
        return sockets.count < Self.socketLimit
    }

    isolated deinit {
        for socket in sockets.values { socket.shut() }
    }

    let context: JSContext
    private var bridge: JSValue!
    private var viewClass: JSValue?
    private var modules: [String: JSValue] = [:]
    private var copies: [Int: WeakCopy] = [:]
    private var timers: [Int: Timer] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]

    /// Builder methods and modules the mod called that Swiftr doesn't have
    /// yet, with how often. They do nothing; the rest of the panel shows.
    public private(set) var unsupported: [String: Int] = [:]
    /// What went wrong in the script, latest last.
    public private(set) var errors: [String] = []
    public private(set) var log: [String] = []
    /// Called on each new error, for the app's status.
    public var onError: ((String) -> Void)?

    private struct WeakCopy { weak var copy: ModCopy? }

    private static var nextCopy = 1

    init(name: String, folder: URL, center: ModCenter, granted: ModCapabilities) throws {
        self.name = name
        self.folder = folder
        self.center = center
        self.granted = granted
        context = JSContext(virtualMachine: center.machine)!
        context.name = "mod \(name)"
        // A script that never returns would hold the whole app: it is cut.
        JSContextGroupSetExecutionTimeLimit(JSContextGetGroup(context.jsGlobalContextRef), center.scriptTimeLimit, nil, nil)
        context.exceptionHandler = { [weak self] _, value in
            guard let value else { return }
            let stack = value.objectForKeyedSubscript("stack")?.toString() ?? ""
            let line = value.objectForKeyedSubscript("line")?.toString() ?? ""
            let file = value.objectForKeyedSubscript("sourceURL")?.toString() ?? ""
            var text = value.toString() ?? "error"
            if file != "undefined", !file.isEmpty { text += " (\((file as NSString).lastPathComponent):\(line))" }
            if stack != "undefined", !stack.isEmpty { text += "\n" + stack }
            self?.note(error: text)
        }
        installNative()
        guard let url = Bundle.module.url(forResource: "prelude", withExtension: "js"),
              let prelude = try? String(contentsOf: url, encoding: .utf8) else {
            throw ModError("the mod runtime is missing from the app")
        }
        context.evaluateScript(prelude, withSourceURL: URL(string: "swiftr://prelude.js"))
        bridge = context.objectForKeyedSubscript("__mod")
        guard bridge != nil, !bridge.isUndefined else { throw ModError("the mod runtime didn't start: \(errors.last ?? "")") }
        context.evaluateScript("var __star = __mod.star;")
        for (key, json) in center.dataSnapshot { bridge.invokeMethod("setData", withArguments: [key, json]) }

        let main = folder.appending(path: "main.js")
        guard FileManager.default.fileExists(atPath: main.path) else { throw ModError("\(name): no main.js") }
        let exports = try load(file: main.standardizedFileURL.path)
        guard let view = exports.objectForKeyedSubscript("default"), view.isObject else {
            throw ModError("\(name): main.js doesn't default-export a View class" + (errors.last.map { "\n\($0)" } ?? ""))
        }
        viewClass = view
    }

    // MARK: Modules

    /// The exports of one of the mod's own files, run once.
    private func load(file path: String) throws -> JSValue {
        if let done = modules[path] { return done }
        guard ModFiles.canonical(path).hasPrefix(ModFiles.canonical(folder.path) + "/") else {
            throw ModError("\(name): a mod can only import files of its own folder (\(path))")
        }
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ModError("\(name): can't read \((path as NSString).lastPathComponent)")
        }
        let exports = JSValue(newObjectIn: context)!
        modules[path] = exports
        let before = errors.count
        guard let function = context.evaluateScript(ModSource.function(from: source), withSourceURL: URL(fileURLWithPath: path)),
              function.isObject else {
            throw ModError(errors.count > before ? errors[errors.count - 1] : "\(name): \((path as NSString).lastPathComponent) doesn't parse")
        }
        let directory = (path as NSString).deletingLastPathComponent
        let require: @convention(block) (String) -> JSValue = { [weak self] wanted in
            guard let self else { return JSValue(undefinedIn: JSContext.current()) }
            return self.require(wanted, from: directory)
        }
        let requireValue = JSValue(object: require, in: context)!
        let importer = context.evaluateScript("(function (req) { return function (name) { return new Promise(function (resolve) { resolve(req(name)); }); }; })")!
            .call(withArguments: [requireValue])!
        let meta = JSValue(newObjectIn: context)!
        meta.setObject(URL(fileURLWithPath: path).absoluteString, forKeyedSubscript: "url" as NSString)
        meta.setObject(directory, forKeyedSubscript: "dirname" as NSString)
        meta.setObject(path, forKeyedSubscript: "filename" as NSString)
        function.call(withArguments: [requireValue, exports, importer, meta])
        if errors.count > before {
            // Its top-level code threw: what it exported so far stays, as a
            // module that half ran would.
            throw ModError(errors[errors.count - 1])
        }
        return exports
    }

    private func require(_ wanted: String, from directory: String) -> JSValue {
        if wanted.hasPrefix("./") || wanted.hasPrefix("../") {
            var path = ((directory as NSString).appendingPathComponent(wanted) as NSString).standardizingPath
            if !FileManager.default.fileExists(atPath: path) {
                for ending in [".js", ".mjs", "/index.js"] where FileManager.default.fileExists(atPath: path + ending) { path += ending; break }
            }
            do { return try load(file: path) } catch {
                context.exception = JSValue(newErrorFromMessage: "\(error)", in: context)
                return JSValue(undefinedIn: context)
            }
        }
        if let builtin = bridge.invokeMethod("module", withArguments: [wanted]), builtin.isObject { return builtin }
        noteUnsupported("module " + wanted)
        context.exception = JSValue(newErrorFromMessage: "The module \"\(wanted)\" isn't available in Swiftr", in: context)
        return JSValue(undefinedIn: context)
    }

    // MARK: Swiftr's side of the script

    private func installNative() {
        let native = JSValue(newObjectIn: context)!
        func set(_ name: String, _ block: Any) { native.setObject(block, forKeyedSubscript: name as NSString) }

        let log: @convention(block) (String, String) -> Void = { [weak self] level, text in
            guard let self else { return }
            self.log.append("[\(level)] \(text)")
            if self.log.count > 400 { self.log.removeFirst(self.log.count - 400) }
            if level == "error" || level == "warn" { NSLog("mod %@: %@", self.name, text) }
        }
        set("log", log)
        let error: @convention(block) (Int, String) -> Void = { [weak self] _, text in self?.note(error: text) }
        set("error", error)
        let unsupported: @convention(block) (String) -> Void = { [weak self] name in self?.noteUnsupported(name) }
        set("unsupported", unsupported)
        let invalidate: @convention(block) (Int) -> Void = { [weak self] id in self?.copies[id]?.copy?.invalidate() }
        set("invalidate", invalidate)
        let timer: @convention(block) (Int, Double, Bool) -> Void = { [weak self] id, ms, every in self?.startTimer(id, ms: ms, every: every) }
        set("timer", timer)
        let cancelTimer: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: id)?.invalidate()
        }
        set("cancelTimer", cancelTimer)
        let focus: @convention(block) (Int, String) -> Void = { [weak self] id, handle in
            self?.copies[id]?.copy?.surface?.focus(handle: handle)
        }
        set("focus", focus)
        let sync: @convention(block) (String, String) -> String = { [weak self] name, arguments in
            guard let self else { return "" }
            let value = self.sync(name, ModJSON.parse(arguments))
            return value.map(ModJSON.text) ?? ""
        }
        set("sync", sync)
        // Bytes, as typed arrays: base64, and the sums of `crypto` and `zlib`.
        let b64: @convention(block) (JSValue) -> String = { ModByteBridge.data($0)?.base64EncodedString() ?? "" }
        set("b64", b64)
        let unb64: @convention(block) (String) -> JSValue? = { text in
            JSContext.current().flatMap { ModByteBridge.array(ModByteBridge.decode(text), in: $0) }
        }
        set("unb64", unb64)
        // Null for a hash Swiftr doesn't have.
        let hash: @convention(block) (String, JSValue) -> JSValue? = { algorithm, bytes in
            guard let context = JSContext.current(), let sum = ModCrypto.hash(algorithm, ModByteBridge.data(bytes) ?? Data()) else { return nil }
            return ModByteBridge.array(sum, in: context)
        }
        set("hash", hash)
        let random: @convention(block) (Int) -> JSValue? = { count in
            JSContext.current().flatMap { ModByteBridge.array(ModCrypto.random(count), in: $0) }
        }
        set("random", random)
        // The bytes, or a line of text saying what went wrong.
        let zip: @convention(block) (String, JSValue) -> JSValue? = { op, bytes in
            guard let context = JSContext.current() else { return nil }
            let data = ModByteBridge.data(bytes) ?? Data()
            do {
                let out = op == "inflate" || op == "gunzip" ? try ModZip.inflate(data, gzip: op == "gunzip") : try ModZip.deflate(data, gzip: op == "gzip")
                return ModByteBridge.array(out, in: context)
            } catch {
                return JSValue(object: "\(error)", in: context)
            }
        }
        set("zip", zip)
        let call: @convention(block) (String, String, Int, Int) -> Void = { [weak self] name, arguments, callID, viewID in
            self?.call(name, ModJSON.parse(arguments) as? [String: Any] ?? [:], callID: callID, viewID: viewID)
        }
        set("call", call)
        #if arch(arm64)
        set("arch", "arm64")
        #else
        set("arch", "x64")
        #endif
        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }

    private func note(error text: String) {
        // The same error on every redraw is one error.
        if errors.last == text { return }
        errors.append(text)
        if errors.count > 50 { errors.removeFirst(errors.count - 50) }
        NSLog("mod %@: %@", name, text)
        onError?(text)
    }

    func noteUnsupported(_ what: String) { unsupported[what, default: 0] += 1 }

    /// A command the app doesn't have (`run("…")`).
    public func noteUnsupportedCommand(_ name: String) { noteUnsupported("command " + name) }

    private func startTimer(_ id: Int, ms: Double, every: Bool) {
        timers.removeValue(forKey: id)?.invalidate()
        // From the end of one call to the next: a slow handler delays the
        // next tick instead of stacking.
        let timer = Timer(timeInterval: max(ms, 1) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timers.removeValue(forKey: id)
                let again = self.bridge.invokeMethod("timer", withArguments: [id])?.toBool() ?? false
                if again, every { self.startTimer(id, ms: ms, every: true) }
            }
        }
        timer.tolerance = min(ms / 10, 100) / 1000
        RunLoop.main.add(timer, forMode: .common)
        timers[id] = timer
    }

    // MARK: Calls that answer at once

    private func copy(_ arguments: Any?) -> ModCopy? {
        guard let id = (arguments as? [String: Any])?["view"] as? Int else { return nil }
        return copies[id]?.copy
    }

    private func sync(_ name: String, _ arguments: Any?) -> Any? {
        let dictionary = arguments as? [String: Any] ?? [:]
        switch name {
        case "run":
            guard let command = dictionary["name"] as? String else { return nil }
            let from = copy(arguments)
            // `<mod>.<command>` goes to that mod's shown copies.
            if center.deliver(command: command) { return nil }
            guard allowed(.commands, "run(\"\(command)\")") else { return nil }
            center.host?.modRun(command: command, arguments: dictionary["args"] as? [String: Any] ?? [:], from: from)
        case "openOverlay":
            return center.host?.modOpenOverlay(dictionary["spec"] as? [String: Any] ?? [:], from: copy(arguments)) ?? ""
        case "closeOverlay":
            center.host?.modCloseOverlay(arguments as? String)
        case "notify":
            return center.host?.modNotify(dictionary) ?? ""
        case "setShared":
            if let key = dictionary["key"] as? String { center.setShared(key, dictionary["value"], from: self) }
        case "setAgentOrder":
            center.host?.modSetAgentOrder(arguments as? [String] ?? [])
        case "playSound":
            if let sound = arguments as? String { center.host?.modPlaySound(sound) }
        // A page opens, and the clipboard is read, only on the person's own
        // click or key: neither is a way out for what a mod sees.
        case "open_url":
            if let text = arguments as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                guard byGesture("open_url") else { return nil }
                center.host?.modOpen(url)
            }
        case "clipboard.read":
            guard byGesture("read_from_clipboard") else { return nil }
            return center.host?.modClipboard()
        case "clipboard.write":
            if let text = arguments as? String, byGesture("write_to_clipboard") { center.host?.modSetClipboard(text) }
        case "field.focus":
            if let id = dictionary["id"] as? String { copy(arguments)?.surface?.focusField(id) }
        case "field.replace":
            if let id = dictionary["id"] as? String, let text = dictionary["text"] as? String {
                for entry in copies.values { entry.copy?.surface?.replaceInField(id, text: text) }
            }
        case "field.select":
            if let id = dictionary["id"] as? String, let start = dictionary["start"] as? Int, let end = dictionary["end"] as? Int {
                for entry in copies.values { entry.copy?.surface?.selectInField(id, start: start, end: end) }
            }
        case "scroll.item":
            if let handle = dictionary["id"] as? String, let index = dictionary["index"] as? Int {
                copy(arguments)?.surface?.scroll(handle: handle, toItem: index, strategy: dictionary["strategy"] as? String)
            }
        case "list.range":
            let count = dictionary["count"] as? Int ?? 0
            guard let id = dictionary["id"] as? String, let surface = copy(arguments)?.surface else { return [0, min(count, 60)] }
            let range = surface.listRange(id: id, count: count)
            return [range.lowerBound, range.upperBound]
        case "storage.read":
            return center.storage(mod: self.name, slot: copy(arguments)?.slot ?? "")
        case "storage.write":
            center.setStorage(dictionary["all"] as? [String: Any] ?? [:], mod: self.name, slot: copy(arguments)?.slot ?? "")
        case "action":
            if let action = dictionary["action"] as? String { copy(arguments)?.surface?.dispatchAction(action) }
        case "focus.move":
            copy(arguments)?.surface?.moveFocus(by: (dictionary["by"] as? Int ?? 1) < 0 ? -1 : 1)
        case "socket.close":
            if let id = dictionary["id"] as? Int { sockets.removeValue(forKey: id)?.shut() }
        default:
            noteUnsupported(name)
        }
        return nil
    }

    /// When the person last clicked or pressed a key in this mod.
    var lastGesture = Date.distantPast

    private func byGesture(_ what: String) -> Bool {
        if granted.contains(.programs) || Date().timeIntervalSince(lastGesture) < 5 { return true }
        note(error: "\(what) refused: only after a click or a key in the mod")
        return false
    }

    /// The files the mod asked for outside its own folder, and how it went
    /// (`read`, `absent`, `refused`, `written`).
    public private(set) var files: [String: String] = [:]

    /// Whether the person agreed to this. A refusal is an error the mod's
    /// own code sees (a rejected promise), and one line in the mod's status.
    private func allowed(_ capability: ModCapabilities, _ what: String) -> Bool {
        if granted.contains(capability) { return true }
        note(error: "\(what) refused: this mod wasn't given that when it was added")
        return false
    }

    /// May this mod hand a file to the person's drag (`drag_paths`)? Its own
    /// files always; any other only with the leave to read files, since a
    /// dragged file can end up anywhere the person drops it.
    func mayHandOver(_ asked: String) -> Bool {
        let real = ModFiles.canonical(ModFiles.expand(asked, home: center.userHome))
        let modFolder = ModFiles.canonical(folder.path)
        let ownData = ModFiles.canonical(center.home.path) + "/data/" + name
        if real.hasPrefix(modFolder + "/") || real == ownData || real.hasPrefix(ownData + "/") { return true }
        if center.jail != nil, !center.inJail(real) {
            files[real] = "outside the test folders"
            return false
        }
        guard allowed(.readFiles, "drag_paths(\"\(asked)\")") else { return false }
        files[real] = "handed over by a drag"
        return true
    }

    // MARK: Calls that answer later

    private func call(_ name: String, _ arguments: [String: Any], callID: Int, viewID: Int) {
        let home = center.userHome
        let options = arguments["options"] as? [String: Any] ?? [:]
        let machine = (options["on"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let host = center.host
        let modFolder = ModFiles.canonical(folder.path)
        let appHome = ModFiles.canonical(center.home.path)
        let ownData = appHome + "/data/" + self.name
        let modsFolder = appHome + "/mods"

        func refuse(_ capability: ModCapabilities, _ what: String) -> Bool {
            if granted.contains(capability) { return false }
            note(error: "\(what) refused: this mod wasn't given that when it was added")
            resolve(callID, .failure(ModError("\(what) isn't allowed for this mod")))
            return true
        }
        func path(_ key: String) -> String { ModFiles.expand(arguments[key] as? String ?? "", home: home) }
        /// The mod's own folder and its own data: no leave needed there.
        func isOwn(_ p: String) -> Bool {
            let real = ModFiles.canonical(p)
            return real.hasPrefix(modFolder + "/") || real == ownData || real.hasPrefix(ownData + "/")
        }
        /// May it write there? Its own places always; elsewhere with the
        /// leave to write; another mod's code only with the leave to run
        /// programs, which changing that code amounts to.
        func refuseWrite(_ p: String, _ what: String) -> Bool {
            if isOwn(p) { return false }
            if refuse(.writeFiles, what) { return true }
            let real = ModFiles.canonical(p)
            if real == modsFolder || real.hasPrefix(modsFolder + "/") { return refuse(.programs, what + " in another mod") }
            return false
        }
        func noted(_ p: String, _ how: String) { if !isOwn(p) { files[p] = how } }

        // Checks and tests keep a mod's files inside their own folders.
        if center.jail != nil, name.hasPrefix("fs.") || ["readTextFile", "writeTextFile", "watchFolder"].contains(name) {
            for key in ["path", "from", "to"] {
                guard let asked = arguments[key] as? String, !center.inJail(ModFiles.expand(asked, home: home)) else { continue }
                files[ModFiles.expand(asked, home: home)] = "outside the test folders"
                switch name {
                case "readTextFile": resolve(callID, .success(NSNull()))
                // Never answered: a mod that waits again at once would spin.
                case "watchFolder": break
                default: resolve(callID, .failure(ModError("\(asked): outside the test folders")))
                }
                return
            }
        }

        switch name {
        case "exec":
            guard !refuse(.programs, "exec") else { return }
            let request = ModExecRequest(
                command: arguments["command"] as? String ?? "",
                arguments: arguments["args"] as? [String] ?? [],
                cwd: (options["cwd"] as? String).map { ModFiles.expand($0, home: home) },
                machine: machine,
                timeout: (options["timeout"] as? NSNumber)?.intValue ?? 30_000
            )
            run(callID) { [weak host] in
                guard let host else { throw ModError("no app to run programs") }
                return try await host.modExec(request).json
            }
        case "hc":
            guard !refuse(.programs, "hc") else { return }
            let list = arguments["args"] as? [String] ?? []
            run(callID) { [weak host] in
                guard let host else { throw ModError("no app to run hc") }
                return try await host.modCore(list).json
            }
        case "readTextFile":
            let file = path("path")
            guard isOwn(file) || !refuse(.readFiles, "readTextFile") else { return }
            run(callID) { [weak host, weak self] in
                if let machine {
                    guard let host else { throw ModError("no app to read files on \(machine)") }
                    return try await host.modReadRemoteFile(file, on: machine) as Any? ?? NSNull()
                }
                let text = try await Task.detached { try ModFiles.read(file) }.value
                if !isOwn(file) { self?.files[file] = text == nil ? "absent" : "read" }
                return text as Any? ?? NSNull()
            }
        case "writeTextFile":
            let file = path("path")
            guard !refuseWrite(file, "writeTextFile") else { return }
            noted(file, "written")
            let text = arguments["text"] as? String ?? ""
            let expected = arguments["expected"] as? String
            run(callID) {
                try await Task.detached { try ModFiles.write(file, text: text, expected: expected) }.value
                return NSNull()
            }
        case "knownAgents":
            run(callID) { [weak host] in try await host?.modKnownAgents(on: machine) ?? [] }
        case "pickFolder":
            let prompt = options["prompt"] as? String
            run(callID) { [weak host] in await host?.modPickFolder(prompt: prompt) as Any? ?? NSNull() }
        case "watchFolder":
            let folder = path("path")
            guard isOwn(folder) || !refuse(.readFiles, "watchFolder") else { return }
            center.watch(folder) { [weak self] paths in self?.resolve(callID, .success(paths)) }
        case "fetch":
            guard !refuse(.network, "fetch") else { return }
            guard let url = URL(string: arguments["url"] as? String ?? ""), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                resolve(callID, .failure(ModError("fetch takes an http or https address")))
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = arguments["method"] as? String ?? "GET"
            for (key, value) in arguments["headers"] as? [String: String] ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
            if let body = arguments["body"] as? String { request.httpBody = Data(body.utf8) }
            if let bytes = arguments["bodyBytes"] as? String { request.httpBody = Data(base64Encoded: bytes) }
            run(callID) {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                for (key, value) in http?.allHeaderFields ?? [:] { headers["\(key)".lowercased()] = "\(value)" }
                return [
                    "status": http?.statusCode ?? 0, "url": response.url?.absoluteString ?? "",
                    "headers": headers, "body": String(decoding: data.prefix(8 * 1024 * 1024), as: UTF8.self),
                ] as [String: Any]
            }
        case "fs.readFile":
            let file = path("path")
            guard isOwn(file) || !refuse(.readFiles, "fs.readFile") else { return }
            // Without an encoding the script gets the file's bytes.
            if arguments["bytes"] as? Bool == true {
                run(callID) {
                    guard let data = try await Task.detached(operation: { try ModFiles.readBytes(file) }).value else { throw ModError("\(file): no such file") }
                    return data.base64EncodedString()
                }
                return
            }
            run(callID) {
                guard let text = try await Task.detached(operation: { try ModFiles.read(file) }).value else { throw ModError("\(file): no such file") }
                return text
            }
        case "fs.readdir":
            let folder = path("path")
            guard isOwn(folder) || !refuse(.readFiles, "fs.readdir") else { return }
            run(callID) { try await Task.detached { try FileManager.default.contentsOfDirectory(atPath: folder).sorted() }.value }
        case "fs.stat":
            let file = path("path")
            guard isOwn(file) || !refuse(.readFiles, "fs.stat") else { return }
            run(callID) {
                let (size, isFolder, modified) = try await Task.detached {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file)
                    return (
                        (attributes[.size] as? NSNumber)?.intValue ?? 0,
                        attributes[.type] as? FileAttributeType == .typeDirectory,
                        (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    )
                }.value
                return ["size": size, "dir": isFolder, "mtimeMs": modified * 1000] as [String: Any]
            }
        case "fs.writeFile", "fs.mkdir", "fs.rm", "fs.rename":
            let target = name == "fs.rename" ? path("to") : path("path")
            let source = path("from")
            guard !refuseWrite(target, name), name != "fs.rename" || !refuseWrite(source, name) else { return }
            noted(target, "written")
            let text = arguments["text"] as? String ?? ""
            let bytes = (arguments["bytes"] as? String).flatMap { Data(base64Encoded: $0) }
            let recursive = options["recursive"] as? Bool ?? false
            run(callID) {
                try await Task.detached {
                    let manager = FileManager.default
                    switch name {
                    case "fs.writeFile":
                        try manager.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                        try (bytes ?? Data(text.utf8)).write(to: URL(fileURLWithPath: target), options: .atomic)
                    case "fs.mkdir": try manager.createDirectory(atPath: target, withIntermediateDirectories: recursive)
                    case "fs.rm": if manager.fileExists(atPath: target) { try manager.removeItem(atPath: target) }
                    default: try manager.moveItem(atPath: source, toPath: target)
                    }
                }.value
                return NSNull()
            }

        // `net` and `websocket`: client sockets, under the same leave as
        // `fetch`. A check never has it, so a checked mod opens nothing.
        case "net.connect":
            guard !refuse(.network, "net.connect") else { return }
            guard hasRoomForSocket() else {
                resolve(callID, .failure(ModError("net.connect: \(Self.socketLimit) sockets are open already")))
                return
            }
            guard let socket = ModTCP(host: arguments["host"] as? String ?? "", port: arguments["port"] as? Int ?? 0) else {
                resolve(callID, .failure(ModError("net.connect takes a host and a port")))
                return
            }
            // Kept from the start, so a reload during the wait closes it.
            let id = keep(socket)
            run(callID) { [weak self] in
                do { try await socket.open() } catch {
                    self?.sockets[id] = nil
                    throw error
                }
                return ["id": id]
            }
        case "net.write":
            guard let socket = sockets[arguments["id"] as? Int ?? 0] as? ModTCP else {
                resolve(callID, .failure(ModError("net: the socket is closed")))
                return
            }
            let data = Data(base64Encoded: arguments["data"] as? String ?? "") ?? Data()
            run(callID) {
                try await socket.write(data)
                return NSNull()
            }
        case "net.read":
            // Closed here: the end, as when the other side closes.
            guard let socket = sockets[arguments["id"] as? Int ?? 0] as? ModTCP else {
                resolve(callID, .success(NSNull()))
                return
            }
            let most = arguments["max"] as? Int ?? 65536
            run(callID) { try await socket.read(max: most).map { $0.base64EncodedString() as Any } ?? NSNull() }
        case "ws.connect":
            guard !refuse(.network, "WebSocket.connect") else { return }
            guard hasRoomForSocket() else {
                resolve(callID, .failure(ModError("WebSocket.connect: \(Self.socketLimit) sockets are open already")))
                return
            }
            guard let url = URL(string: arguments["url"] as? String ?? ""), ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                resolve(callID, .failure(ModError("WebSocket.connect takes a ws or wss address")))
                return
            }
            var request = URLRequest(url: url)
            for (key, value) in arguments["headers"] as? [String: String] ?? [:] {
                guard !ModWebSocket.refuses(header: key) else {
                    resolve(callID, .failure(ModError("WebSocket.connect: the header \(key) can't be set")))
                    return
                }
                request.setValue(value, forHTTPHeaderField: key)
            }
            let socket = ModWebSocket()
            let id = keep(socket)
            run(callID) { [weak self] in
                do { try await socket.open(request) } catch {
                    self?.sockets[id] = nil
                    socket.shut()
                    throw error
                }
                return ["id": id]
            }
        case "ws.read":
            guard let socket = sockets[arguments["id"] as? Int ?? 0] as? ModWebSocket else {
                resolve(callID, .failure(ModError("websocket: the socket is closed")))
                return
            }
            run(callID) {
                switch try await socket.read() {
                case .string(let text): return ["text": text]
                case .data(let data): return ["data": data.base64EncodedString()]
                @unknown default: throw ModError("websocket: a message of a kind Swiftr doesn't know")
                }
            }
        case "ws.write":
            guard let socket = sockets[arguments["id"] as? Int ?? 0] as? ModWebSocket else {
                resolve(callID, .failure(ModError("websocket: the socket is closed")))
                return
            }
            let message: URLSessionWebSocketTask.Message
            if let text = arguments["text"] as? String { message = .string(text) } else {
                message = .data(Data(base64Encoded: arguments["data"] as? String ?? "") ?? Data())
            }
            run(callID) {
                try await socket.write(message)
                return NSNull()
            }
        case "ws.close":
            (sockets.removeValue(forKey: arguments["id"] as? Int ?? 0) as? ModWebSocket)?.close()
            resolve(callID, .success(NSNull()))
        default:
            noteUnsupported(name)
            resolve(callID, .failure(ModError("\(name) isn't available in Swiftr yet")))
        }
    }

    /// Runs the work off the script, then hands its answer back to it.
    private func run(_ callID: Int, _ work: @escaping @MainActor () async throws -> Any) {
        tasks[callID] = Task { [weak self] in
            let result: Result<Any, Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            self.tasks[callID] = nil
            self.resolve(callID, result)
        }
    }

    private func resolve(_ callID: Int, _ result: Result<Any, Error>) {
        switch result {
        case .success(let value):
            bridge.invokeMethod("resolve", withArguments: [callID, true, ModJSON.text(value)])
        case .failure(let error):
            bridge.invokeMethod("resolve", withArguments: [callID, false, "\(error)"])
        }
    }

    // MARK: Copies

    /// True when the mod has read that list: it is the one to draw again.
    @discardableResult
    func setData(_ key: String, json: String) -> Bool {
        bridge.invokeMethod("setData", withArguments: [key, json])?.toBool() ?? true
    }

    func invalidateAll() {
        for entry in copies.values { entry.copy?.invalidate() }
    }

    /// A new copy of the mod: one View instance, with its own props.
    public func makeCopy(props: [String: Any] = [:], slot: String = "", placement: [String: Any]? = nil) throws -> ModCopy {
        guard let viewClass else { throw ModError("\(name) isn't loaded") }
        let id = ModRuntime.nextCopy
        ModRuntime.nextCopy += 1
        let copy = ModCopy(id: id, runtime: self, props: props, slot: slot)
        copies[id] = WeakCopy(copy: copy)
        let before = errors.count
        let made = bridge.invokeMethod("create", withArguments: [id, viewClass, ModJSON.text(props), placement.map(ModJSON.text) ?? NSNull()])?.toBool() ?? false
        if !made {
            copies[id] = nil
            throw ModError(errors.count > before ? errors[errors.count - 1] : "\(name): its view didn't start")
        }
        return copy
    }

    fileprivate func render(_ id: Int) -> String? {
        guard let value = bridge.invokeMethod("render", withArguments: [id]), value.isString else { return nil }
        return value.toString()
    }

    fileprivate func event(_ id: Int, handler: Int, payload: Any?, gesture: Bool) -> Bool {
        if gesture { lastGesture = Date() }
        return bridge.invokeMethod("event", withArguments: [id, handler, payload.map(ModJSON.text) ?? NSNull()])?.toBool() ?? false
    }

    fileprivate func field(_ stateID: String, event: String, value: String?, extra: [String: Any]) {
        bridge.invokeMethod("field", withArguments: [stateID, event, value ?? NSNull(), ModJSON.text(extra)])
    }

    /// A slider the person moved: `change` while it moves, `release` at the end.
    fileprivate func slider(_ stateID: String, values: [Double], event: String) {
        lastGesture = Date()
        let value: Any = values.count == 1 ? values[0] : values
        bridge.invokeMethod("slider", withArguments: [stateID, ModJSON.text(["v": value]), event])
    }

    /// A step of a number field: `increment` or `decrement`.
    fileprivate func step(_ stateID: String, action: String) {
        lastGesture = Date()
        bridge.invokeMethod("step", withArguments: [stateID, action])
    }

    fileprivate func setProps(_ id: Int, props: [String: Any], placement: [String: Any]?) {
        bridge.invokeMethod("setProps", withArguments: [id, ModJSON.text(props), placement.map(ModJSON.text) ?? NSNull()])
    }

    fileprivate func focusChanged(_ id: Int, handle: String?) {
        bridge.invokeMethod("focusChanged", withArguments: [id, handle ?? NSNull()])
    }

    fileprivate func command(_ id: Int, name: String) -> Bool {
        bridge.invokeMethod("command", withArguments: [id, name])?.toBool() ?? false
    }

    fileprivate func close(_ id: Int) {
        bridge.invokeMethod("close", withArguments: [id])
        copies[id] = nil
    }

    /// `<mod>.<command>`, for the copies that show.
    func deliver(command: String) -> Bool {
        var delivered = false
        for entry in copies.values {
            guard let copy = entry.copy, copy.isShown else { continue }
            if self.command(copy.id, name: command) { delivered = true }
        }
        return delivered
    }

    /// Stops what the script left running. Its copies are gone or going.
    func shutDown() {
        for id in Array(copies.keys) { close(id) }
        for timer in timers.values { timer.invalidate() }
        timers = [:]
        for task in tasks.values { task.cancel() }
        tasks = [:]
        shutSockets()
    }
}

/// One copy of a mod: a block of a layout, a pane, an overlay.
public final class ModCopy {
    public let id: Int
    public let runtime: ModRuntime
    public private(set) var props: [String: Any]
    /// Where this copy lives (a layout block's id, an overlay): its own
    /// `localStorage`.
    public let slot: String
    /// The script asked for a redraw (`cx.notify()`), or live data changed.
    public var onInvalidate: (() -> Void)?
    weak var surface: ModSurface?
    /// On screen now: `<mod>.<command>` reaches shown copies only.
    public var isShown = true
    private var closed = false

    init(id: Int, runtime: ModRuntime, props: [String: Any], slot: String) {
        self.id = id
        self.runtime = runtime
        self.props = props
        self.slot = slot
    }

    func invalidate() { onInvalidate?() }

    /// The panel as the script describes it now. Nil when `render` threw:
    /// the last good one stays on screen.
    func render() -> ModNode? {
        guard !closed, let text = runtime.render(id), let json = ModJSON.parse(text) as? [String: Any],
              let root = json["root"] else { return nil }
        let tree = ModNode.build(root)
        tree?.bindings = (json["bindings"] as? [[String: Any]]) ?? []
        return tree
    }

    /// The panel as JSON text, for checks.
    public func renderJSON() -> String? { closed ? nil : runtime.render(id) }

    /// Runs a handler of the last render. Answers whether it stopped the event.
    @discardableResult
    func dispatch(_ handler: Int, payload: Any?, gesture: Bool = false) -> Bool {
        closed ? false : runtime.event(id, handler: handler, payload: payload, gesture: gesture)
    }

    func field(_ stateID: String, event: String, value: String?, extra: [String: Any] = [:]) {
        if !closed { runtime.field(stateID, event: event, value: value, extra: extra) }
    }

    func slider(_ stateID: String, values: [Double], event: String) {
        if !closed { runtime.slider(stateID, values: values, event: event) }
    }

    func step(_ stateID: String, action: String) {
        if !closed { runtime.step(stateID, action: action) }
    }

    public func setProps(_ props: [String: Any], placement: [String: Any]? = nil) {
        self.props = props
        if !closed { runtime.setProps(id, props: props, placement: placement) }
        invalidate()
    }

    func focusChanged(_ handle: String?) {
        if !closed { runtime.focusChanged(id, handle: handle) }
    }

    /// A key command for this mod (`"<mod>:<command>"` in keys.json).
    @discardableResult
    public func deliver(command: String) -> Bool {
        closed ? false : runtime.command(id, name: command)
    }

    /// The copy's block, pane or overlay went away.
    public func close() {
        guard !closed else { return }
        closed = true
        runtime.close(id)
    }
}

/// JSON to and from the script.
nonisolated enum ModJSON {
    static func parse(_ text: String) -> Any? {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else { return nil }
        return value is NSNull ? nil : value
    }

    static func text(_ value: Any) -> String {
        if value is NSNull { return "null" }
        guard JSONSerialization.isValidJSONObject([value]),
              // Sorted: the same value gives the same text, so a list that
              // didn't change is seen as such.
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
