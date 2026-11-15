#if DEBUG
import AppKit
import HerdrKit
import ScreenCaptureKit
import SwiftUI

/// Debug builds only: tests of the + menu, on their own channel so that
/// another Debug Swiftr (DebugHooks) doesn't act on them too:
///   DistributedNotificationCenter post "com.melvinsiadous.Swiftr.debug.agents",
///   object = "new-menu:tabStrip|toolbar|close" (opens or closes a + menu)
///   | "new-agent:claude" (starts an agent as the menu does)
///   | "new-command:printf hi" (runs those words in a new tab, as an agent starts)
///   | "favorite:claude=on|off" | "agents-check" (asks the shown space's machine again)
///   | "pretend-installed:pi,pig" (the shown space's machine has these agents)
///   | "menu-key:down|up|return|esc|1" | "menu-click:x,y" (points from the menu's top left)
///   | "shortcut:opt-cmd-t" (typed in the window)
///   | "menu-open" (fills the File menu as opening it does)
///   | "front" | "snapshot:name" (the window) | "menu-snapshot:name" (the open + menu)
///   | "menu-render:name" (the menu drawn off screen, -light and -dark)
///   | "dump"
/// Pictures go to $TMPDIR/swiftr-agents-<name>.png, `dump` to
/// $TMPDIR/swiftr-agents-debug.json.
enum AgentDebug {
    nonisolated(unsafe) private static var token: NSObjectProtocol?
    private static var log: [String] = []

    static func install(_ model: AppModel) {
        token = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.melvinsiadous.Swiftr.debug.agents"), object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { run(command, model) }
        }
    }

    private static func run(_ command: String, _ model: AppModel) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "new-menu":
            model.launcher.menu = switch arg {
            case "close": nil
            case "toolbar": .toolbar
            default: .tabStrip
            }
        case "new-agent":
            if let agent = Programs.startable(arg) { model.newTab(agent: agent) } else { log.append("new-agent: no \(arg)") }
        case "new-command":
            model.newTab(command: arg.split(separator: " ").map(String.init), name: "")
        case "favorite":
            let pair = arg.split(separator: "=").map(String.init)
            if pair.count == 2 { model.prefs.setFavorite(pair[1] == "on", agent: pair[0]) }
        case "agents-check":
            model.launcher.check(model.activeSpace?.machine ?? "", force: true)
        case "front":
            mainWindow?.orderFrontRegardless()
        case "snapshot":
            Task { await snapshot(mainWindow, arg.isEmpty ? "window" : arg) }
        case "menu-snapshot":
            Task { await snapshot(popoverWindows.first, arg.isEmpty ? "menu" : arg) }
        case "menu-render":
            render(arg.isEmpty ? "menu" : arg, model)
        case "menu-key":
            // A key pressed in the open + menu: down, up, return, esc, or a character.
            press(arg)
        case "menu-click":
            // A click in the open + menu, at x,y points from its top left.
            click(arg)
        case "pretend-installed":
            // The shown space's machine has these agents: pretend-installed:pi,pig.
            model.launcher.pretend(Set(arg.split(separator: ",").map(String.init)), on: model.activeSpace?.machine ?? "")
        case "shortcut":
            // A shortcut typed in the window, through the event queue so the
            // app's key monitor sees it first: shortcut:opt-cmd-t.
            var parts = arg.split(separator: "-").map(String.init)
            let key = parts.popLast() ?? ""
            var flags: NSEvent.ModifierFlags = []
            for p in parts {
                switch p {
                case "cmd": flags.insert(.command)
                case "opt": flags.insert(.option)
                case "shift": flags.insert(.shift)
                case "ctrl": flags.insert(.control)
                default: break
                }
            }
            if let window = mainWindow,
               let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: key,
                                            charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "t" ? 17 : 0)
            {
                NSApp.postEvent(event, atStart: false)
                log.append("shortcut \(arg): posted")
            }
        case "menu-open":
            // What AppKit does as the File menu opens.
            if let menu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                log.append("menu-open: " + menu.items.map(line).joined(separator: " | "))
            }
        case "dump":
            dump(model)
        default:
            log.append("unknown: \(command)")
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { AppDelegate.isMainWindow($0) }
    }

    private static var popoverWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }

    /// Sends a key to the open menu's window, as if typed there, without
    /// making Swiftr the active app.
    private static func press(_ key: String) {
        guard let window = popoverWindows.first else {
            log.append("menu-key: no popover open")
            return
        }
        let special: [String: (code: UInt16, char: Int)] = ["down": (125, NSDownArrowFunctionKey), "up": (126, NSUpArrowFunctionKey), "return": (36, 13), "esc": (53, 27)]
        let digitCodes: [Character: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29]
        let (code, chars): (UInt16, String) = if let s = special[key] {
            (s.code, String(Character(UnicodeScalar(UInt32(s.char))!)))
        } else {
            (key.first.flatMap { digitCodes[$0] } ?? 0, key)
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            else { continue }
            window.sendEvent(event)
        }
        log.append("menu-key \(key): first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
    }

    /// Sends a click to the open menu, at a point of the SwiftUI view it shows.
    private static func click(_ arg: String) {
        let xy = arg.split(separator: ",").compactMap { Double($0) }
        guard xy.count == 2, let window = popoverWindows.first, let host = hostingView(in: window.contentView) else {
            log.append("menu-click: no menu open, or not x,y")
            return
        }
        let local = NSPoint(x: xy[0], y: host.isFlipped ? xy[1] : host.bounds.height - xy[1])
        let point = host.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            window.sendEvent(event)
        }
        log.append("menu-click \(arg): view \(Int(host.bounds.width))x\(Int(host.bounds.height)), window point \(Int(point.x)),\(Int(point.y))")
    }

    private static func hostingView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if String(describing: type(of: view)).contains("HostingView") { return view }
        return view.subviews.lazy.compactMap { hostingView(in: $0) }.first
    }

    private static func dump(_ model: AppModel) {
        let machine = model.activeSpace?.machine ?? ""
        let launcher = model.launcher!
        var out: [String: Any] = [
            "menu": launcher.menu.map { "\($0)" } ?? "",
            "machine": machine,
            "installed": launcher.installed(on: machine).map { $0.sorted() as Any } ?? "unknown",
            "checking": launcher.isChecking(machine),
            "failed": launcher.checkFailed(machine),
            "choices": launcher.choices(on: machine).map { $0.agent.key + ($0.installed ? "" : " (not installed)") },
            "favorites": model.prefs.favoriteAgents,
            "picks": model.prefs.agentPicks,
            "shell": AgentLauncher.localShell,
            "fileMenu": NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu?.items.map(line) ?? [],
            // Whatever else answers to T, so ⌥⌘T is free.
            "keysOnT": allItems(NSApp.mainMenu).filter { $0.keyEquivalent.lowercased() == "t" }.map(line),
            "popovers": popoverWindows.map { "\(type(of: $0)) \(NSStringFromRect($0.frame)) key=\($0.isKeyWindow)" },
            "keyWindow": NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "",
            "firstResponder": NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "log": log,
        ]
        out["spaces"] = model.allSpaces.map { s -> [String: Any] in
            ["id": s.id, "active": s.id == model.activeSpace?.id,
             "tabs": s.tabs.map { t -> [String: Any] in
                 ["id": t.id, "name": t.name, "active": t.id == model.activeTab(in: s)?.id, "icon": model.programKey(of: t, in: s) ?? "",
                  "terminals": model.addresses(of: t, in: s).map { a -> [String: Any] in
                      let m = model.store.model(a)
                      return ["address": a, "foreground": m?.foreground?.argv ?? [], "title": m?.title ?? "", "cwd": m?.currentFolder ?? ""]
                  }]
             }]
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftr-agents-debug.json")
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    private static func allItems(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + allItems($0.submenu) }
    }

    private static func line(_ item: NSMenuItem) -> String {
        if item.isSeparatorItem { return "—" }
        guard !item.keyEquivalent.isEmpty else { return item.title }
        let m = item.keyEquivalentModifierMask
        let keys = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
        return "\(item.title) \(keys)\(item.keyEquivalent.uppercased())"
    }

    private static func snapshot(_ target: NSWindow?, _ name: String) async {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftr-agents-\(name).png")
        guard let number = target?.windowNumber else {
            log.append("snapshot \(name): no window")
            return
        }
        do {
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(number) }) else {
                log.append("snapshot \(name): window \(number) not shareable")
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            log.append("snapshot \(name): ok")
        } catch {
            log.append("snapshot \(name): \(error)")
        }
    }

    /// The menu as the shown space would list it, without opening it.
    private static func render(_ name: String, _ model: AppModel) {
        for scheme in [ColorScheme.light, .dark] {
            let view = NewTabMenu(machine: model.activeSpace?.machine ?? "")
                .environment(model)
                .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.97))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let url = FileManager.default.temporaryDirectory.appending(path: "swiftr-agents-\(name)-\(scheme == .dark ? "dark" : "light").png")
            if let image = renderer.cgImage {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            } else {
                log.append("menu-render: nothing drawn")
            }
        }
    }
}
#endif
