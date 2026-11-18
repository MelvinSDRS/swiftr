#if DEBUG
import AppKit
import Foundation
import ModKit

/// Test hooks for mods, beside `DebugHooks`: post a DistributedNotification
/// named `com.melvinsiadous.Swiftr.debug.mods` (plus `.<channel>` when
/// `SWIFTR_DEBUG_CHANNEL` is set) whose object is one of:
///
///     layout:<name>            show a layout (empty: Swiftr's own)
///     allow:<mod>              allow a mod what its files ask
///     stop:<mod>               take that back
///     import:<mod>             copy a mod over from herdr-app's folder
///     add:<folder>             copy a mod folder in
///     add-layout:<file>        copy a layout file in and show it
///     remove-layout:<name>     move a layout's file to the Trash
///     panel:toggle             show or hide the mods' sidebar
///     panel:show:<mod>         show a mod in the mods' sidebar
///     in-panel:<mod>:on|off    keep a mod in the mods' sidebar, or out
///     changes:<folder>         point the Changes panel at a folder (empty: the focused terminal's)
///     changes-pick:<path>      open a changed file's diff, or close it
///     style:card|floating      how the mods' sidebar shows
///     menu-pick:<x,y>:<title>  right-click at x,y points from the window's top
///                              left and pick that item of the menu (`pick` in the dump)
///     grip:sidebar:<points>    drag the floating sidebar's edge right (left: negative),
///                              through the window's events (`grip-at:` is the same)
///     grip:changes:<points>    drag the line under the Changes panel's files down
///     remove:<mod>             move a mod's folder to the Trash
///     open:<mod>               open a mod over the window
///     close                    close the mod opened last
///     run:<command>            a command, as a key would run it
///     click:<mod>:<text>       press the element of a mod that shows the text
///     type:<mod>:<hint>=<text> type into the field with that hint
///     drag:<mod>:<a>..<b>      real mouse events, from one text to another
///     copy:<mod>               Edit › Copy's action on the mod's window; the
///                              text it put on the clipboard goes to the dump
///                              (`copied`) and the clipboard gets its own back
///     dump                     write `$TMPDIR/[channel-]swiftr-mods.json`
enum ModDebug {
    private static var token: NSObjectProtocol?
    private static var copied: String?

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        window.sendEvent(event)
    }

    static func install(_ mods: Mods) {
        let channel = ProcessInfo.processInfo.environment["SWIFTR_DEBUG_CHANNEL"] ?? ""
        let name = "com.melvinsiadous.Swiftr.debug.mods" + (channel.isEmpty ? "" : "." + channel)
        token = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { run(command, mods, channel: channel) }
        }
    }

    private static func views(of mod: String) -> [ModView] {
        var out: [ModView] = []
        func walk(_ view: NSView) {
            if let found = view as? ModView, found.copy.runtime.name == mod { out.append(found) }
            for child in view.subviews { walk(child) }
        }
        for window in NSApp.windows { if let content = window.contentView { walk(content) } }
        // Shown ones first.
        return out.sorted { ($0.alphaValue > 0 && !$0.isHiddenOrHasHiddenAncestor ? 0 : 1) < ($1.alphaValue > 0 && !$1.isHiddenOrHasHiddenAncestor ? 0 : 1) }
    }

    /// What the last `grip:` did.
    private static var gripNote = ""

    /// What the last `menu-pick:` did, and the menu it opened.
    private static var pickNote = ""
    private static var pickMenu: NSMenu?

    /// A right click at a point of the window, then the item of that title
    /// in the menu that opens.
    private static func pick(_ title: String, at point: NSPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        pickNote = "no menu"
        pickMenu = nil
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            // On the main thread already.
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated { if pickMenu == nil { pickMenu = menu } }
        }
        // The main run loop tracks the menu until it closes: pick from
        // another thread, in the run loop's tracking mode.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.8)
            let main = CFRunLoopGetMain()
            let mode = CFRunLoopCopyCurrentMode(main)?.rawValue ?? CFRunLoopMode.commonModes.rawValue
            CFRunLoopPerformBlock(main, mode) {
                MainActor.assumeIsolated {
                    guard let menu = pickMenu else { return }
                    if let at = menu.items.firstIndex(where: { $0.title == title }) {
                        menu.performActionForItem(at: at)
                        pickNote = "picked \(title)"
                    } else {
                        pickNote = "no item \(title) in \(menu.items.map(\.title))"
                    }
                    menu.cancelTracking()
                }
            }
            CFRunLoopWakeUp(main)
        }
        window.sendEvent(event)
        NotificationCenter.default.removeObserver(observer)
        pickMenu = nil
    }

    /// A shown resize grip, by its name.
    private static func grip(named name: String) -> ModGripView? {
        var out: ModGripView?
        func walk(_ view: NSView) {
            if out != nil { return }
            if let found = view as? ModGripView, found.name == name, !found.isHiddenOrHasHiddenAncestor, found.bounds.width > 0 { out = found }
            for child in view.subviews { walk(child) }
        }
        for window in NSApp.windows { if let content = window.contentView?.superview ?? window.contentView { walk(content) } }
        return out
    }

    /// Where a grip is, from the window's top left.
    private static func gripFrames() -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ view: NSView) {
            if let found = view as? ModGripView, let window = found.window, !found.isHiddenOrHasHiddenAncestor {
                let f = found.convert(found.bounds, to: nil)
                // Its address too: a grip made anew mid-drag loses the drag.
                out[found.name] = "x=\(Int(f.minX)) y=\(Int(window.frame.height - f.maxY)) \(Int(f.width))x\(Int(f.height)) @\(UInt(bitPattern: ObjectIdentifier(found).hashValue) % 100_000)"
            }
            for child in view.subviews { walk(child) }
        }
        for window in NSApp.windows { if let content = window.contentView?.superview ?? window.contentView { walk(content) } }
        return out
    }

    private static func run(_ command: String, _ mods: Mods, channel: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "layout": mods.loadLayout(named: rest)
        case "allow": mods.allow(rest)
        case "stop": mods.disallow(rest)
        case "import": mods.importFromHerdr(rest)
        case "add": mods.add(folder: URL(fileURLWithPath: rest))
        case "add-layout": mods.add(layout: URL(fileURLWithPath: rest))
        // link-sheet:<text> opens Settings' sheet with the link typed;
        // link-go presses its Add.
        case "link-sheet":
            mods.linkAdd.open()
            mods.linkAdd.text = rest
        case "link-go": mods.linkAdd.run()
        case "remove-layout": mods.remove(layout: rest)
        case "remove": mods.remove(rest)
        case "panel":
            if rest == "toggle" { mods.togglePanel() } else if rest.hasPrefix("show:") { mods.showInPanel(String(rest.dropFirst(5))) }
        case "changes":
            // A folder for the Changes panel, in place of the focused terminal's.
            ChangesModel.shared.override = rest.isEmpty ? nil : ChangesPlace(folder: rest, machine: nil)
            ChangesModel.shared.refresh(nil)
        case "changes-pick": ChangesModel.shared.pick(rest)
        case "style": if let style = ModSidebarStyle(rawValue: rest) { mods.pick(style: style) }
        case "menu-pick":
            // menu-pick:1365,26:Card, in points from the window's top left.
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            let xy = (pair.first ?? "").split(separator: ",").compactMap { Double($0) }
            guard pair.count == 2, xy.count == 2,
                  let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) else { return }
            pick(pair[1], at: NSPoint(x: xy[0], y: window.frame.height - xy[1]), in: window)
        case "in-panel":
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 { mods.setInPanel(pair[0], pair[1] == "on") }
        case "open": mods.open(mod: rest)
        case "close": mods.modCloseOverlay(nil)
        case "run": mods.run(keyCommand: rest)
        case "click":
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 { _ = views(of: pair[0]).first { $0.click(text: pair[1]) } }
        case "type":
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            let field = (pair.count == 2 ? pair[1] : "").split(separator: "=", maxSplits: 1).map(String.init)
            if field.count == 2 { _ = views(of: pair[0]).first { $0.type(field[1], inFieldWithHint: field[0]) } }
        // key:<mod>:<chord> (tab, shift-tab, space, enter, escape, down…),
        // as the keyboard would send it to the mod.
        case "key":
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 { views(of: pair[0]).first?.press(key: pair[1]) }
        // hover:<mod>:<text> rests the pointer on the text; hover:<mod>: takes it away.
        case "hover":
            let pair = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if let view = views(of: pair[0]).first { view.hover(text: pair.count == 2 && !pair[1].isEmpty ? pair[1] : nil) }
        // drop:<mod>:<text>=<path>,<path>: files let go on the text.
        case "drop":
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            let target = (pair.count == 2 ? pair[1] : "").split(separator: "=", maxSplits: 1).map(String.init)
            if target.count == 2 { views(of: pair[0]).first?.drop(paths: target[1].split(separator: ",").map(String.init), onText: target[0]) }
        // slide:<mod>:<text>=<dx>,<dy>: a press on the text, let go that far away (a slider, a divider).
        case "slide":
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            let target = (pair.count == 2 ? pair[1] : "").split(separator: "=", maxSplits: 1).map(String.init)
            let by = (target.count == 2 ? target[1] : "").split(separator: ",").compactMap { Double($0) }
            if by.count == 2 { views(of: pair[0]).first?.drag(fromText: target[0], by: CGSize(width: by[0], height: by[1])) }
        // tap:<mod>:<text>: a real press and release where the text shows,
        // in the window that holds it (a popover's own layer, or the main one).
        case "tap", "tap-right":
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2, let view = views(of: pair[0]).first, let place = view.eventPlace(ofText: pair[1]) else { return }
            mouse(parts[0] == "tap" ? .leftMouseDown : .rightMouseDown, at: place.point, in: place.window)
            mouse(parts[0] == "tap" ? .leftMouseUp : .rightMouseUp, at: place.point, in: place.window)
        // tap-field:<mod>:<hint>: a real press in the field with this hint.
        case "tap-field":
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2, let view = views(of: pair[0]).first, let place = view.eventPlace(ofFieldWithHint: pair[1]) else { return }
            mouse(.leftMouseDown, at: place.point, in: place.window)
            mouse(.leftMouseUp, at: place.point, in: place.window)
        // tap-layer:<mod>:<dx>,<dy>: a real press in the first surface's own
        // layer, that far from the layer's top left (its clear margin is 32 points).
        case "tap-layer":
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            let xy = (pair.count == 2 ? pair[1] : "").split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2, let view = views(of: pair[0]).first,
                  let number = view.surfaceReport().first?["layer_number"] as? Int, let layer = NSApp.window(withWindowNumber: number) else { return }
            let at = CGPoint(x: xy[0], y: layer.frame.height - xy[1])
            mouse(.leftMouseDown, at: at, in: layer)
            mouse(.leftMouseUp, at: at, in: layer)
        // slide-at:<mod>:<x>,<y>=<dx>,<dy>: a press at a point of the mod's panel, let go that far away.
        case "slide-at":
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            let target = (pair.count == 2 ? pair[1] : "").split(separator: "=", maxSplits: 1).map(String.init)
            let from = (target.first ?? "").split(separator: ",").compactMap { Double($0) }
            let by = (target.count == 2 ? target[1] : "").split(separator: ",").compactMap { Double($0) }
            if from.count == 2, by.count == 2 {
                views(of: pair[0]).first?.drag(from: CGPoint(x: from[0], y: from[1]), by: CGSize(width: by[0], height: by[1]))
            }
        // tap-at:<x>,<y>: the same at a point of the main window, from its top left.
        case "tap-at":
            let xy = rest.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2, let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) else { return }
            let at = CGPoint(x: xy[0], y: window.frame.height - xy[1])
            mouse(.leftMouseDown, at: at, in: window)
            mouse(.leftMouseUp, at: at, in: window)
        // post-at:<x>,<y>: the same through the app's event queue, as a
        // real press comes, so the app's own event monitors see it.
        case "post-at":
            let xy = rest.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2, let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) else { return }
            let at = CGPoint(x: xy[0], y: window.frame.height - xy[1])
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        case "drag":
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            let ends = (pair.count == 2 ? pair[1] : "").components(separatedBy: "..")
            guard ends.count == 2, let view = views(of: pair[0]).first, let window = view.window,
                  let a = view.frame(ofText: ends[0]), let b = view.frame(ofText: ends[1]) else { return }
            let from = view.convert(CGPoint(x: a.minX + 0.5, y: a.midY), to: nil), to = view.convert(CGPoint(x: b.maxX - 0.5, y: b.midY), to: nil)
            mouse(.leftMouseDown, at: from, in: window)
            mouse(.leftMouseDragged, at: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), in: window)
            mouse(.leftMouseDragged, at: to, in: window)
            mouse(.leftMouseUp, at: to, in: window)
        case "grip", "grip-at":
            // A drag of a resize grip as the window routes it: the press
            // goes to whatever view lies at the grip's middle, and the grip
            // then reads the moves and the release from the app's queue, as
            // it reads a hand's. grip:sidebar:-80 goes 80 points left,
            // grip:changes:60 goes 60 down.
            let pair = rest.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2, let by = Double(pair[1]), let grip = grip(named: pair[0]), let window = grip.window else {
                gripNote = "no grip \(rest)"
                return
            }
            let frame = grip.convert(grip.bounds, to: nil)
            let start = CGPoint(x: frame.midX, y: frame.midY)
            let hit = window.contentView?.superview?.hitTest(start) ?? window.contentView?.hitTest(start)
            func event(_ type: NSEvent.EventType, _ share: Double) -> NSEvent? {
                let at = grip.sideways ? CGPoint(x: start.x + by * share, y: start.y) : CGPoint(x: start.x, y: start.y - by * share)
                return NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            gripNote = "\(pair[0]) by \(Int(by)); press lands on \(hit.map { String(describing: type(of: $0)) } ?? "nothing")"
            // Only a grip takes the press: any other view would keep the
            // moves that follow for itself.
            guard hit is ModGripView, let down = event(.leftMouseDown, 0) else { return }
            // The moves and the release wait in the queue before the press:
            // the grip's press does not return before the release, and
            // nothing queued on the main queue runs under it here (this
            // hook is itself a block of that queue).
            for step in 1 ... 10 {
                if let e = event(.leftMouseDragged, Double(step) / 10) { NSApp.postEvent(e, atStart: false) }
            }
            if let e = event(.leftMouseUp, 1) { NSApp.postEvent(e, atStart: false) }
            window.sendEvent(down)
        case "copy":
            guard let view = views(of: rest).first, let window = view.window else { return }
            // The person's clipboard comes back whole after the look.
            let board = NSPasteboard.general
            let kept = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
            board.clearContents()
            _ = window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil)
            copied = board.string(forType: .string) ?? ""
            board.clearContents()
            board.writeObjects(kept.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            })
        case "dump":
            var out: [String: Any] = [
                "ran": mods.ran,
                "importable": mods.importable,
                "layouts": mods.layoutNames,
                "publishes": mods.publishes,
                "publish_ms": mods.publishSeconds * 1000,
                "changes": mods.center.changes,
                "copied": copied as Any? ?? NSNull(),
                "changes_panel": [
                    "folder": ChangesModel.shared.place?.folder ?? "", "machine": ChangesModel.shared.place?.machine ?? "", "root": ChangesModel.shared.listing?.root ?? "",
                    "files": ChangesModel.shared.files.map { "\($0.status) \($0.path) +\($0.added) -\($0.deleted)" },
                    "open": ChangesModel.shared.open ?? "", "rows": ChangesModel.shared.rows.count,
                    "first_rows": ChangesModel.shared.rows.prefix(4).map(\.text),
                    "note": ChangesModel.shared.note ?? "",
                    "share": mods.changesShare as Any? ?? NSNull(),
                ] as [String: Any],
                "style": mods.sidebarStyle.rawValue,
                // A change of style: the card's and the column's widths
                // now, and the ones it counted from.
                "cross": ["on": mods.crossing, "card": mods.cardWidth, "column": mods.columnWidth,
                          "full": mods.cardFull, "from": mods.crossColumn],
                "grips": gripFrames(),
                "grip": gripNote,
                "pick": pickNote,
                "layout": mods.layoutName as Any? ?? NSNull(),
                "panel": mods.panel.map { panel in
                    let stack = mods.layout?.find(WindowLayout.panelStackID)
                    return ["shown": !panel.hidden, "px": panel.px ?? 0, "mods": stack?.children.map(\.id) ?? [],
                            "active": stack?.shownChild?.id ?? ""] as [String: Any]
                } as Any? ?? NSNull(),
                "places": Dictionary(uniqueKeysWithValues: mods.entries.map { ($0.name, mods.place(of: $0.name)) }),
                "overlays": mods.overlays.map { ["id": $0.id, "mod": $0.mod, "kind": $0.kind] },
                "toasts": mods.toasts.map { ["title": $0.title, "body": $0.body] },
                "unknown_command": mods.lastUnknownCommand as Any? ?? NSNull(),
            ]
            var list: [[String: Any]] = []
            for entry in mods.entries {
                let runtime = mods.center.loaded(entry.name)
                let shown = views(of: entry.name)
                list.append([
                    "name": entry.name, "allowed": entry.allowed, "loaded": runtime != nil, "needs": entry.report.needs.sentences,
                    "errors": runtime?.errors ?? [], "unsupported": runtime?.unsupported ?? [:], "files": runtime?.files ?? [:],
                    "views": shown.map { view in
                        let frame = view.window.map { _ in view.convert(view.bounds, to: nil) } ?? .zero
                        return ["texts": view.texts(), "nodes": view.nodeCount, "renders": view.renders, "selected": view.selectedText,
                                "first_responder": view.window?.firstResponder === view, "frame": [frame.minX, frame.minY, frame.width, frame.height],
                                "hints": view.fieldHints(), "render_ms": view.lastRenderMs,
                                "surfaces": view.surfaceReport(), "focus": view.focusReport,
                                "window_key": view.window?.isKeyWindow ?? false,
                                "window_first": view.window?.firstResponder.map { String(describing: type(of: $0)) } ?? ""] as [String: Any]
                    },
                ])
            }
            out["mods"] = list
            let file = FileManager.default.temporaryDirectory.appending(path: (channel.isEmpty ? "" : channel + "-") + "swiftr-mods.json")
            try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        default: break
        }
    }
}
#endif
