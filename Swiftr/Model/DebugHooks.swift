#if DEBUG
import AppKit
import HerdrKit
import ScreenCaptureKit
import SwiftUI

/// Debug builds only: lets a test script run window actions.
///   DistributedNotificationCenter post "com.melvinsiadous.Swiftr.debug"
///   (with SWIFTR_DEBUG_CHANNEL=name set: "com.melvinsiadous.Swiftr.debug.name"),
///   object = "newTab" | "split-row" | "split-column" | "closePane" | "closeTab" | "close-tab:tb…"
///   | "tab:N" | "space:N" | "next-space:1|-1" | "zoom" | "focus:left|right|up|down" | "newSpace" | "dump"
///   | "type:text" | "rename-tab:name" | "rename-space:name" | "weights:0.3" | "front" | "back" | "active:0|1" | "reopen"
///   | "machine-menu:server=Icon/Mac mini" | "machine-name:server=Hetzner"
///   | "space-icon:star" | "space-image:/path/logo.png" | "menu-at:x,y" | "select-at:x,y"
///   | "header-views:server" | "chevron:server" | "agents:fold|open" | "agents-chevron" | "burst:name:N:ms:command"
///   | "agent-group:done:fold|open" (needsYou, done, working, idle) | "burst-area:x,y,w,h"
///   | "pointer:in|out" | "table-focus" | "space-expand:open|fold" | "disclose-at:x,y"
///   | "move-row:from,parent,index" | "row-button:x,y" | "hover-at:x,y" | "window-frame:x,y,w,h" | "tab-bar:hide|show"
///   | "hover-tab:tb…" | "hover-tab:tb…:close" | "hover-tab:" | "split-drag:-120" | "agents-place:top|bottom"
///   | "spaces:fold|open" | "spaces-chevron" | "spaces-plus" | "machine-click:server"
///   | "add-machine:open|close" | "add-machine:add=vps" | "add-machine:type=can@10.0.0.7" | "sheet-snapshot:name"
///   | "add-machine:fail=box:hc_missing:message" | "add-machine:tab=box" | "menu-item:File/Add Machine…"
///   | "onboarding:show|close|next|back" | "onboarding:step=agents" | "onboarding:add=/a,/b" | "onboarding:pick=/a"
///   | "onboarding:star=claude" | "onboarding:core=missing|installing|failed=why|ready|real" (the welcome sheet)
///   | "look-now:light|dark|mac" (the app's light or dark, as macOS would switch it, not saved)
///   | "settings-snapshot:name" (after "menu-item:Swiftr/Settings…") | "next-agent" (OpenCode's Shift-Tab)
///   | "sleep" | "sleep:t3" (puts the focused agent, or that terminal's, to sleep, as its menu does) | "wake" | "wake:t3"
///   | "sleep-idle" (Pane › Sleep Idle Agents) | "sleep-tick" (the minute's check, now; "sleep-tick:5": as if set to 5 s)
///   | "sleep-after:0|1|2|4|8|24" (the setting, in hours; writes the shared `sleepAfter`)
///   | "settings-pane:terminal" (the Settings pane shown: appearance, window, terminal, agents, claude, codex,
///     opencode, gemini, voice, core, updates)
///   | "usage:fake" (example usage for every agent instead of real reads) | "usage:real"
///   | "usage:problem=expired|signedOut|keychain|busy|failed" (with usage:fake) | "usage:details" (the focused
///     pane's usage popover) | "usage:refresh" (the focused pane's account, read now)
///   | "usage-settings:claude=shown:0|1,left:0|1,resets:0|1,limits:session+weekly" (an agent's usage settings;
///     `limits` shows those, in that order, and hides the others) | "status-line:claude=on|off" (an agent's status line)
///   | "settings-frame:w,h" (the Settings window's size, its top left kept) | "settings-click:x,y"
///   | "click-at:x,y" (a left click, the window left as it is)
///   | "wheel-at:x,y,dx,dy[,mouse]" (a scroll there, through NSApp; the log says where it went)
///   | "render:name[:N[:width]]" (the focused conversation's last N rows, drawn off-screen)
///   | "render-pane:name[:N[:width]]" (the same, then the cards, field and status bar under them)
///   | "read-aloud:N" (Read Aloud on the focused conversation's N-th agent message from the end) | "read-aloud:stop"
///   | "read-aloud:text:<markdown>" (reads that) | "read-aloud-speed:1.5" | "read-aloud-speed:" (Settings' speed again)
///   | "voice-model:download:kokoro" | "voice-model:cancel:kokoro" | "voice-model:delete:kokoro" (Settings › Voice's
///     buttons for a voice model) | "voice-sample:kokoro-af_heart" (a model voice's recording) | "voice-sample:stop"
///   | "voice-voices:kokoro" | "voice-voices:close" (a model's voices) | "voice-language:add:es" | "voice-language:remove:es"
///   | "popover-snapshot:name" (the popover shown)
///   | "dictation-model:download:parakeet-ultra" | "dictation-model:cancel:…" | "dictation-model:delete:…" (Settings ›
///     Dictation's buttons) | "dictate-file:/path/to.wav" (the recording, as if dictated into the focused pane's field)
///   | "dictation-terms:A,B" (names added to the conversation's) | "dictation-key:61" (the key to hold; "dictation-key:none")
///   | "dictation-look:listening|writing|problem|model|mic|idle[:panel][:key]" (a dictation's look, without the microphone)
///   | "dictation-probe[:<seconds>]" (where the dictation bars in sight stand, 240 times a second, to $TMPDIR/swiftr-probe.json)
///   | "dictation-record:on|refused|off" (Settings › Dictation's key recorder; "dictation-record:show:none|<code>[:<modifiers>:<label>]"
///     shows another key in its picture without saving it)
///   | "voice-model:update:voxtral" | "dictation-model:update:parakeet-ultra" (a model's Update button; cancel stops it too)
///   | "model-updates:check" (Check Now) | "model-update-head:dictation/parakeet-ctc=<commit>" (taken for the repository's
///     latest commit by the next check; nothing after = the real one)
///   | "updates:check" (Swiftr, herdr-core and the models, as Check Now) | "updates:all" (Update All) | "updates:app"
///     (Swiftr's own Update button) | "updates:hours=6" | "updates:offer=0.2.0" (a Swiftr version on offer, without a
///     feed) | "updates:notes=What's New\n• One" (that version's notes) | "updates:click=Install Update" (a button of Sparkle's window); "settings-pane:updates" shows the pane
///   | "dictation:start|finish|cancel" (as the key would) | "dictation:button" (the focused pane's microphone button)
/// `dump` writes what the window shows to $TMPDIR/swiftr-debug.json (name-swiftr-debug.json).
/// The sidebar has two lists, so two tables: commands at x,y act on the one there.
/// A channel lets two Debug builds run side by side, each with its own commands and files.
enum DebugHooks {
    nonisolated(unsafe) private static var token: NSObjectProtocol?
    /// What `burst` takes, in points from the window's top left.
    private static var burstArea = CGRect(x: 0, y: 40, width: 260, height: 320)
    private static var resumeCommand = ""
    private static var debugActions: [String] = []
    /// What `header-views` found in a machine header's row.
    private static var headerViews: [String] = []
    /// The menu `menu-at` opened, while it is open, and its lines.
    private static var openMenu: NSMenu?
    private static var menuLines: [Any] = []

    nonisolated private static let channel = ProcessInfo.processInfo.environment["SWIFTR_DEBUG_CHANNEL"] ?? ""

    /// A file in $TMPDIR, its name after the channel's when there is one.
    nonisolated private static func tempFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: channel.isEmpty ? name : channel + "-" + name)
    }

    static func install(_ model: AppModel) {
        token = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.melvinsiadous.Swiftr.debug" + (channel.isEmpty ? "" : "." + channel)), object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { run(command, model) }
        }
    }

    private static func run(_ command: String, _ model: AppModel) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "newTab": model.newTab()
        case "newSpace": model.newSpace(on: parts.count > 1 ? parts[1] : "")
        case "split-row": model.split(.row)
        case "split-column": model.split(.column)
        case "closePane": model.closePane()
        case "closeTab": model.closeTab()
        case "close-tab":
            // What a tab row's Close Tab does, for any space: close-tab:tb… or close-tab:server/tb….
            let (machine, local) = splitAddress(parts.count > 1 ? parts[1] : "")
            if let place = model.place(ofTab: local, on: machine) { model.closeTab(place.tab.id, in: place.space) }
        case "zoom": model.toggleZoom()
        case "tab": model.selectTab(at: (Int(parts.last ?? "") ?? 1) - 1)
        case "space": model.selectSpace(at: (Int(parts.last ?? "") ?? 1) - 1)
        case "next-space": model.selectNeighborSpace(Int(parts.last ?? "") ?? 1)
        case "reveal": model.reveal(parts.last ?? "")
        case "focus":
            let d: PaneDirection = switch parts.last { case "left": .left; case "right": .right; case "up": .up; default: .down }
            model.moveFocus(d)
        case "type":
            // As the person types in the focused terminal: \r Return, \n ⌃J, \e Esc, \x15 ⌃U.
            var text = (parts.count > 1 ? parts[1] : "").replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\e", with: "\u{1b}")
            text = text.replacing(/\\x([0-9a-fA-F]{2})/) { String(UnicodeScalar(UInt8($0.1, radix: 16) ?? 0)) }
            if let a = model.focusedAddress, let s = model.pool.existing(a) { s.view.send(txt: text) }
        case "rename-tab":
            if let s = model.activeSpace, let t = model.activeTab(in: s) {
                model.rename(.tab(Place(s.machine, t.id), t.name), to: parts.count > 1 ? parts[1] : "")
            }
        case "rename-space":
            if let s = model.activeSpace { model.rename(.space(s.place, s.space.name), to: parts.count > 1 ? parts[1] : "") }
        case "new-space":
            // A space in a folder: new-space:/path here, new-space:server=/path there.
            let arg = parts.count > 1 ? parts[1] : ""
            let pair = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { model.newSpace(on: pair[0], folder: pair[1]) } else { model.newSpace(on: "", folder: arg) }
        case "close-space":
            if let s = model.activeSpace { model.closeSpace(s) }
        case "space-logo":
            // What “Logo from …” does: space-logo:/path shows that folder's logo.
            if let s = model.activeSpace, parts.count > 1 { model.setIcon(SpaceIcon(folder: parts[1]), of: s) }
        case "space-icon":
            // The shown space's icon: space-icon:star; space-icon: is the automatic one again.
            if let s = model.activeSpace {
                let symbol = parts.count > 1 ? parts[1] : ""
                model.setIcon(symbol.isEmpty ? nil : SpaceIcon(symbol: symbol), of: s)
            }
        case "space-image":
            // What “Image…” does once its panel gave a file.
            if let s = model.activeSpace, parts.count > 1 {
                if let name = IconImages.save(from: URL(filePath: parts[1])) {
                    model.setIcon(SpaceIcon(image: name), of: s)
                } else {
                    debugActions.append("space-image: can't read \(parts[1])")
                }
            }
        case "click-at":
            // A left click at x,y points from the window's top left, sent to the
            // window without making it key: SwiftUI buttons take it (a chip).
            let xy = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 { leftClick(at: NSPoint(x: xy[0], y: xy[1])) }
        case "menu-at":
            // A right click at x,y points from the window's top left: the dump's
            // "menu" gets the lines of the menu that opens, then it closes.
            let xy = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 { rightClick(at: NSPoint(x: xy[0], y: xy[1])) }
        case "select-at":
            // What a click on the sidebar row at x,y points from the window's top
            // left does to the selection, without a mouse event, which would take
            // the keyboard from the person.
            let xy = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 { selectRow(at: NSPoint(x: xy[0], y: xy[1])) }
        case "space-expand":
            // What the shown space's triangle does: space-expand:open or space-expand:fold.
            if let s = model.activeSpace { model.setExpanded(parts.last == "open", space: s) }
        case "disclose-at":
            // Clicks the triangle of the sidebar row at x,y points from the window's top left.
            let xy = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 { disclose(at: NSPoint(x: xy[0], y: xy[1])) }
        case "move-row":
            // A drag of the sidebar's row `from` dropped as child `index` of row
            // `parent` (-1: the list itself), through the table's own drop code,
            // without the mouse: move-row:from,parent,index.
            let v = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Int($0) }
            if v.count == 3 { moveRow(v[0], parent: v[1], index: v[2]) }
        case "row-button":
            // What a click on the last button of the sidebar row at x,y points
            // from the window's top left does (a tab's ×).
            let xy = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 { pressRowButton(at: NSPoint(x: xy[0], y: xy[1])) }
        case "hover-at":
            // The pointer moved to x,y points from the window's top left, as far as
            // the window knows: the real pointer stays where it is.
            let xy = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            if xy.count == 2, let window = mainWindow,
               let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: xy[0], y: window.frame.height - xy[1]),
                                              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
            {
                window.sendEvent(event)
            }
        case "wheel-at":
            // A scroll at x,y points from the window's top left, through NSApp as a
            // real one goes, event monitors too: wheel-at:x,y,dx,dy sends ten small
            // steps in points without a phase, as Mos smooths a mouse wheel;
            // wheel-at:x,y,dx,dy,mouse three notches of a plain wheel, in lines.
            // dy < 0 brings in what is below, dx < 0 what is on the right.
            let args = (parts.count > 1 ? parts[1] : "").split(separator: ",").map(String.init)
            let v = args.prefix(4).compactMap { Double($0) }
            if v.count == 4 { wheel(at: NSPoint(x: v[0], y: v[1]), dx: v[2], dy: v[3], notches: args.count > 4 && args[4] == "mouse") }
        case "window-frame":
            // Moves the window, as x,y,w,h points from the main screen's top left:
            // away from the real pointer, whose moves would undo `hover-at`.
            let v = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            if v.count == 4, let window = mainWindow, let screen = NSScreen.screens.first {
                window.setFrame(NSRect(x: v[0], y: screen.frame.maxY - v[1] - v[3], width: v[2], height: v[3]), display: true)
            }
        case "hover-tab":
            // A tab's row acts as under the pointer, whatever the real pointer does:
            // hover-tab:tb…, on its close button hover-tab:tb…:close, none hover-tab:.
            let args = (parts.count > 1 ? parts[1] : "").split(separator: ":").map(String.init)
            DebugHover.shared.tab = args.first
            DebugHover.shared.onClose = args.count > 1 && args[1] == "close"
        case "tab-bar":
            // What View › Hide Tab Bar and Show Tab Bar do: tab-bar:hide or tab-bar:show.
            model.prefs.showsTabBar = parts.last == "show"
        case "table-focus":
            // Whether the sidebar's tables take the keyboard, as a click on them
            // would ask: into the actions, then the keyboard goes back.
            if let window = mainWindow {
                for (name, table) in sidebarTables() {
                    let before = window.firstResponder
                    // Refused, the keyboard goes to the window.
                    window.makeFirstResponder(table)
                    debugActions.append("table-focus \(name): \(window.firstResponder === table ? "took" : "refused") the keyboard")
                    window.makeFirstResponder(before)
                }
            }
        case "agents-place":
            // What Settings › Agents list does: agents-place:top or agents-place:bottom.
            // It writes the setting the installed app reads too.
            if let place = AgentsPlace(rawValue: parts.last ?? "") { model.prefs.agentsPlace = place }
        case "split-drag":
            // A drag of the line between the spaces and the agents, through its
            // own mouse code, without the window's events: split-drag:-120 goes
            // 120 points up.
            if let down = Double(parts.last ?? "") { dragSplit(by: down) }
        case "header-views":
            // The views in a machine header's row, into the dump's "headerViews":
            // header-views:server ("" is this Mac).
            let machine = parts.count > 1 ? parts[1] : ""
            if let row = headerRow(machine), let window = mainWindow {
                let f = row.convert(row.bounds, to: nil)
                headerViews = ["row in window: x=\(Int(f.minX)) y=\(Int(window.frame.height - f.maxY)) \(Int(f.width))x\(Int(f.height))"]
                    + describeTree(row, in: row)
            } else {
                headerViews = ["no row for \(machine)"]
            }
        case "chevron":
            // Clicks the chevron of a machine header, its last button: chevron:server ("" is this Mac).
            // performClick runs its own event loop while the button shows pressed, and `burst`
            // waits meanwhile: to time the fold, use machine-menu, which calls the same code.
            let machine = parts.count > 1 ? parts[1] : ""
            let button = headerRow(machine).flatMap { row in
                views(of: NSButton.self, in: row).max { $0.convert($0.bounds, to: row).minX < $1.convert($1.bounds, to: row).minX }
            }
            if let button { button.performClick(nil) } else { debugActions.append("chevron: none for \(machine)") }
        case "pointer":
            // What the pointer coming onto the sidebar or leaving it does: pointer:in or pointer:out.
            SidebarView.pointer(parts.last == "in", model: model)
        case "agents":
            // What the agents' chevron does: agents:fold or agents:open.
            SidebarView.foldAgents(parts.last == "fold", model: model)
        case "agent-group":
            // What a click on a group's header does: agent-group:done:fold or agent-group:done:open.
            let args = (parts.count > 1 ? parts[1] : "").split(separator: ":").map(String.init)
            if args.count == 2 { SidebarView.foldGroup(args[0], args[1] == "fold", model: model) }
        case "agents-chevron":
            // Clicks the chevron of the agents' title, the last button in its band.
            pressTitleButton(in: "agents-title", for: "agents-chevron")
        case "spaces-chevron":
            // The same for the spaces' title.
            pressTitleButton(in: "spaces-title", for: "spaces-chevron")
        case "spaces-plus":
            // Clicks the + of the spaces' title, the button before its chevron.
            pressTitleButton(in: "spaces-title", for: "spaces-plus", first: true)
        case "spaces":
            // What the spaces' chevron does: spaces:fold or spaces:open.
            SidebarView.foldSpaces(parts.last == "fold", model: model)
        case "add-machine":
            // The Add a Machine sheet: open or close it, or what a host's Add
            // (add=vps) or the typed field (type=can@10.0.0.7) does in it.
            let arg = parts.count > 1 ? parts[1] : ""
            if arg == "open" {
                model.addingMachine = MachineAdder()
            } else if arg == "close" {
                model.addingMachine = nil
            } else if let adder = model.addingMachine {
                let pair = arg.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2, pair[0] == "add" { adder.add(pair[1], model: model) }
                if pair.count == 2, pair[0] == "type" { adder.add(typed: pair[1], model: model) }
                // What a failed row's Open in a Tab does: tab=box.
                if pair.count == 2, pair[0] == "tab" { adder.openInTab(pair[1], model: model) }
                if pair.count == 2, pair[0] == "fail" {
                    // fail=target:kind:message, as if the core had answered that.
                    let f = pair[1].split(separator: ":", maxSplits: 2).map(String.init)
                    if f.count == 3 { adder.pretendFailure(f[0], kind: f[1], message: f[2]) }
                }
            } else {
                debugActions.append("add-machine: no sheet")
            }
        case "onboarding":
            // The welcome sheet: show, close, next, back, step=agents, add=/a,/b
            // (folders, as the open panel gives them), pick=/a (a row's click),
            // star=claude, core=missing|installing|failed=why|ready|real (what
            // the herdr-core step shows, whatever the link).
            let arg = parts.count > 1 ? parts[1] : ""
            let pair = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if arg == "show" {
                model.showOnboarding()
            } else if arg == "close" {
                model.endOnboarding()
            } else if let sheet = model.onboarding {
                switch pair[0] {
                case "next": sheet.proceed(model)
                case "back": sheet.back()
                case "step" where pair.count == 2:
                    if pair[1] == "core" { sheet.needsCore = true }
                    if let step = Onboarding.Step(rawValue: pair[1]) { sheet.show(step) }
                case "add" where pair.count == 2: sheet.add(pair[1].split(separator: ",").map(String.init))
                case "pick" where pair.count == 2:
                    if let folder = sheet.folders.first(where: { $0.path == pair[1] }) { sheet.toggle(folder) }
                case "star" where pair.count == 2:
                    model.prefs.setFavorite(!model.prefs.isFavorite(agent: pair[1]), agent: pair[1])
                case "core" where pair.count >= 2:
                    let value = pair[1].split(separator: "=", maxSplits: 1).map(String.init)
                    sheet.debugCore = switch value[0] {
                    case "missing": .missing
                    case "installing": .installing
                    case "failed": .failed(value.count > 1 ? value[1] : "Could not connect to the server.")
                    case "ready": .ready
                    default: nil
                    }
                default: debugActions.append("onboarding: unknown \(arg)")
                }
            } else {
                debugActions.append("onboarding: no sheet")
            }
        case "machine-click":
            // A click on a machine header's name, through its own mouse code:
            // machine-click:server ("" is this Mac).
            let machine = parts.count > 1 ? parts[1] : ""
            if let root = mainWindow?.contentView?.superview,
               let grip = views(of: MachineGripView.self, in: root).first(where: { $0.name == machine }) {
                click(grip)
            } else {
                debugActions.append("machine-click: none for \(machine)")
            }
        case "machine-name":
            // What the rename alert's button does: machine-name:server=Hetzner ("" before "=" is this Mac).
            let pair = (parts.count > 1 ? parts[1] : "").split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2 else { break }
            model.rename(.machine(pair[0], model.title(ofMachine: pair[0])), to: pair[1])
            model.renaming = nil
        case "menu-item":
            // Chooses a main-menu item: menu-item:File/New Space On/server.
            var titles = (parts.count > 1 ? parts[1] : "").split(separator: "/").map(String.init)
            var menu = NSApp.mainMenu
            while let menuNow = menu, !titles.isEmpty {
                // SwiftUI fills a menu's items as it opens.
                menuNow.delegate?.menuNeedsUpdate?(menuNow)
                let title = titles.removeFirst()
                guard let index = menuNow.items.firstIndex(where: { $0.title == title }) else {
                    debugActions.append("menu-item: no \(title)")
                    break
                }
                if titles.isEmpty {
                    if menuNow.items[index].isEnabled { menuNow.performActionForItem(at: index) } else { debugActions.append("menu-item: \(title) is off") }
                }
                menu = menuNow.items[index].submenu
            }
        case "machine-menu":
            // Chooses an item of a machine header's menu: machine-menu:server=Icon/Mac mini
            // ("" before "=" is this Mac).
            let pair = (parts.count > 1 ? parts[1] : "").split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2, let machine = model.machineItems.first(where: { $0.name == pair[0] }) else { break }
            var menu = MenuEntry.menu(MachineHeader.entries(for: machine, model: model))
            let titles = pair[1].split(separator: "/").map(String.init)
            for (i, title) in titles.enumerated() {
                guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                    debugActions.append("machine-menu: no \(title)")
                    break
                }
                if i == titles.count - 1 {
                    menu.performActionForItem(at: index)
                } else if let sub = menu.items[index].submenu {
                    menu = sub
                }
            }
        case "weights":
            // The first child's share of the shown tab's top split: weights:0.3
            if let s = model.activeSpace, let t = model.activeTab(in: s), case .split(let id, _, let children, _, _) = t.root,
               children.count == 2, let w = Double(parts.last ?? "")
            {
                model.setWeights([children[0].id: w, children[1].id: 1 - w], container: id, on: s.machine)
            }
        case "dump": dump(model)
        case "look-now":
            // Light or dark for the app without touching the saved Appearance.
            NSApp.appearance = switch parts.last { case "light": NSAppearance(named: .aqua); case "dark": NSAppearance(named: .darkAqua); default: nil }
        case "reopen": model.reopenClosedTab()
        case "resume-command":
            // What ⇧⌘T or a lost terminal would type for this session:
            // resume-command:<session> (Claude's) or resume-command:<agent>:<session>.
            let rest = (parts.count > 1 ? parts[1] : "").split(separator: ":", maxSplits: 1).map(String.init)
            let agent = rest.count > 1 ? ResumableAgent(rawValue: rest[0]) ?? .claude : .claude
            let session = rest.last ?? ""
            Task {
                let started = Date()
                let command = await ClaudeWatch.resumeCommand(agent: agent, session: session, machine: nil) ?? "(no command: unsafe id)"
                resumeCommand = "\(command) (\(Int(-started.timeIntervalSinceNow * 1000)) ms)"
            }
        case "active":
            model.debugSetActive(parts.last == "1")
        case "tools-open":
            // Tool rows and notices drawn from now on start open: tools-open:on|off.
            ToolRow.debugOpen = parts.last == "on"
        case "find":
            // find:<words> opens Find in the focused conversation with them; find:next|previous|close.
            let what = parts.count > 1 ? parts[1] : ""
            let step = ["next", "previous", "close"].contains(what)
            NotificationCenter.default.post(name: .swiftrFind, object: model.focusedAddress,
                                            userInfo: step ? ["do": what] : ["do": "open", "query": what])
        case "actions-shown":
            // Every message shows its Copy and Edit buttons, as under the pointer: actions-shown:on|off.
            HoverActions.debugShown = parts.last == "on"
        case "read-aloud":
            // read-aloud:<n> as the Read Aloud button of the n-th agent message from the end (1: the last); read-aloud:stop.
            if parts.last == "stop" {
                ReadAloud.shared.stop()
            } else if let rest = parts.last, rest.hasPrefix("text:") {
                // read-aloud:text:<markdown> reads that, as an agent's message.
                ReadAloud.shared.read(id: "debug-text", markdown: String(rest.dropFirst(5)))
            } else if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                let items = feed.rows.flatMap { row -> [TranscriptItem] in
                    switch row {
                    case .item(let item): [item]
                    case .activity(_, let items): items
                    }
                }
                let texts = items.compactMap { item -> (id: String, text: String)? in
                    if case .text(let markdown) = item.kind { (item.id, markdown) } else { nil }
                }
                let n = Int(parts.last ?? "") ?? 0
                if n >= 1, n <= texts.count {
                    ReadAloud.shared.toggle(id: texts[texts.count - n].id, markdown: texts[texts.count - n].text)
                }
            }
        case "read-aloud-speed":
            // read-aloud-speed:<x> reads at that speed without changing Settings'; read-aloud-speed: goes back to it.
            ReadAloud.debugSpeed = parts.count > 1 ? Double(parts[1]) : nil
        case "voice-model":
            // voice-model:download|cancel|delete:<model id>, as Settings › Voice's buttons.
            let action = (parts.last ?? "").split(separator: ":", maxSplits: 1).map(String.init)
            if action.count == 2, let voiceModel = VoiceCatalog.model(action[1]) {
                switch action[0] {
                case "download": VoiceLibrary.shared.download(voiceModel)
                case "update": VoiceLibrary.shared.update(voiceModel)
                case "cancel": VoiceLibrary.shared.cancel(voiceModel)
                case "delete": VoiceLibrary.shared.delete(voiceModel)
                default: break
                }
            }
        case "dictation-model":
            // dictation-model:download|cancel|delete:<model id>, as Settings › Dictation's buttons.
            let action = (parts.last ?? "").split(separator: ":", maxSplits: 1).map(String.init)
            if action.count == 2, let dictationModel = DictationCatalog.model(action[1]) {
                switch action[0] {
                case "download": DictationLibrary.shared.download(dictationModel)
                case "update": DictationLibrary.shared.update(dictationModel)
                case "cancel": DictationLibrary.shared.cancel(dictationModel)
                case "delete": DictationLibrary.shared.delete(dictationModel)
                default: break
                }
            }
        case "model-updates":
            if parts.last == "check" { ModelUpdates.shared.checkNow() }
        case "updates":
            UpdateHooks.run(parts.count > 1 ? parts[1] : "", model)
        case "model-update-head":
            // model-update-head:<key>=<commit>: the next check takes it for the latest.
            let pair = (parts.last ?? "").split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if pair.count == 2 { ModelUpdates.shared.debugHeads[pair[0]] = pair[1].isEmpty ? nil : pair[1] }
        case "dictate-file":
            if parts.count > 1 { Dictation.shared.debugDictate(file: parts[1], into: nil) }
        case "dictation-key":
            // dictation-key:<key code>[:<modifiers>] or dictation-key:none, as Settings › Dictation sets it.
            let key = (parts.last ?? "").split(separator: ":").map(String.init)
            if let code = key.first.flatMap({ UInt16($0) }) {
                Dictation.key = DictationKey(code: code, modifiers: key.count > 1 ? UInt(key[1]) ?? 0 : 0)
            } else {
                Dictation.key = nil
            }
        case "dictation-look":
            Dictation.shared.debugLook(parts.last ?? "idle")
        case "dictation-probe":
            VoiceWaveView.debugProbe(seconds: parts.count > 1 ? Double(parts[1]) ?? 1.5 : 1.5, to: tempFile("swiftr-probe.json"))
        case "dictation-record":
            // dictation-record:on|refused|off: Settings › Dictation's key, as a click on it and a key press would leave it;
            // dictation-record:show:…: a key in its picture only.
            NotificationCenter.default.post(name: .swiftrDebugDictationRecord, object: parts.last)
        case "dictation-terms":
            // dictation-terms:<name>,<name>: names the conversation uses, for tests.
            Dictation.shared.debugTerms = parts.count > 1 ? DictationVocabulary.parse(parts[1]) : []
        case "dictation":
            switch parts.last {
            case "start": Dictation.shared.start()
            case "finish": Dictation.shared.finish()
            case "cancel": Dictation.shared.cancel()
            case "button": if let a = model.focusedAddress { Dictation.shared.toggle(for: a) }
            default: break
            }
        case "voice-voices":
            // voice-voices:<model id> opens that model's voices in Settings › Voice; voice-voices:close.
            VoiceSettingsDebug.shared.voices = parts.last == "close" ? nil : parts.last
        case "voice-language":
            // voice-language:add:<code> or remove:<code>, as Add Language and a row's remove button.
            let action = (parts.last ?? "").split(separator: ":", maxSplits: 1).map(String.init)
            if action.count == 2 {
                if action[0] == "add" { ReadAloud.remember(action[1]) } else if action[0] == "remove" { ReadAloud.forget(action[1]) }
            }
        case "voice-sample":
            // voice-sample:<recording name> plays it as its button in Settings › Voice; voice-sample:stop.
            if parts.last == "stop" { SamplePlayer.shared.stop() } else if let name = parts.last { SamplePlayer.shared.play(name) }
        case "sleep", "wake", "sleep-idle", "sleep-tick", "sleep-after":
            model.sleepers.debug(parts.first ?? "", parts.count > 1 ? parts[1] : "")
        case "messages":
            // messages:on|off for the focused pane, messages:default-on|default-off for the setting.
            // Every agent's setting: messages:default-on; one agent's: messages:default-on=codex.
            let arg = parts.count > 1 ? parts[1] : ""
            let pair = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let agents = pair.count == 2 ? [ChatAgent(rawValue: pair[1])].compactMap { $0 } : ChatAgent.allCases
            switch pair.first {
            case "default-on": for agent in agents { model.prefs.setPanes(.messages, of: agent) }
            case "default-off": for agent in agents { model.prefs.setPanes(.terminal, of: agent) }
            default: if let a = model.focusedAddress { model.setPaneMode(parts.last == "on" ? .messages : .terminal, for: a) }
            }
        case "usage":
            let arg = parts.count > 1 ? parts[1] : ""
            switch arg {
            case "fake": model.usage.debugReports = debugUsageReports()
            case "real":
                model.usage.debugReports = nil
                model.usage.debugProblem = nil
            case "details":
                if let a = model.focusedAddress { NotificationCenter.default.post(name: .swiftrUsageDetails, object: a) }
            case "refresh":
                if let a = model.focusedAddress, let account = model.usage.account(of: a) { model.usage.refresh(account, force: true) }
            default:
                if arg.hasPrefix("problem=") {
                    let name = String(arg.dropFirst("problem=".count))
                    model.usage.debugProblem = switch name {
                    case "expired": .expired
                    case "signedOut": .signedOut
                    case "keychain": .keychain("The user name or passphrase you entered is not correct.")
                    case "busy": .busy(until: Date().addingTimeInterval(600))
                    case "failed": .failed("Anthropic answered 500.")
                    default: nil
                    }
                }
            }
        case "usage-settings":
            // usage-settings:claude=shown:1,left:0,resets:1,limits:session+weekly
            let pair = (parts.count > 1 ? parts[1] : "").split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, let agent = ChatAgent(rawValue: pair[0]) {
                var settings = model.prefs.usage(of: agent)
                for item in pair[1].split(separator: ",") {
                    let kv = item.split(separator: ":", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { continue }
                    switch kv[0] {
                    case "shown": settings.shown = kv[1] == "1"
                    case "left": settings.countsLeft = kv[1] == "1"
                    case "resets": settings.showsResets = kv[1] == "1"
                    case "limits":
                        let picked = kv[1].split(separator: "+").map(String.init)
                        let known = model.usage.limits(of: agent).map(\.id)
                        settings.order = picked + known.filter { !picked.contains($0) }
                        for id in Set(known + picked + settings.choices.keys) { settings.choices[id] = picked.contains(id) }
                    default: break
                    }
                }
                model.prefs.setUsage(settings, of: agent)
            }
        case "status-line":
            // status-line:codex=off
            let pair = (parts.count > 1 ? parts[1] : "").split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, let agent = ChatAgent(rawValue: pair[0]) { model.prefs.setShowsStatusLine(pair[1] == "on", of: agent) }
        case "send":
            // What the composer does, for the focused pane.
            if let a = model.focusedAddress {
                let feed = model.feeds.feed(a)
                let text = parts.count > 1 ? parts[1] : ""
                Task {
                    do {
                        try await feed.send(text)
                        debugActions.append("send ok: \(text)")
                    } catch {
                        debugActions.append("send failed: \(error)")
                    }
                }
            }
        case "choose":
            // An option of what Claude asks, or of a menu of its own.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a), let n = Int(parts.last ?? ""),
               let shown = feed.prompt ?? feed.dialog, let option = shown.options.first(where: { $0.number == n })
            {
                Task {
                    await feed.choose(option, in: shown)
                    debugActions.append("choose \(n): \(feed.actionError ?? "ok")")
                }
            }
        case "styled":
            // The focused agent's screen with colors: the input box's rows, each
            // character with `~` under it when dim, the cursor, the suggestion found.
            if let a = model.focusedAddress, let m = model.store.model(a), let c = model.connection {
                Task {
                    guard let s = await StyledScreen.read(a, connection: c, cols: m.cols, rows: m.rows) else {
                        debugActions.append("styled: no screen")
                        return
                    }
                    let last = s.rows.lastIndex { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } ?? 0
                    for y in max(0, last - 9) ... last {
                        let r = s.rows[y]
                        debugActions.append("styled \(y): \(r.text.replacingOccurrences(of: " +$", with: "", options: .regularExpression))")
                        debugActions.append("styled \(y)~ \(String(r.dim.map { $0 ? "~" : " " }).replacingOccurrences(of: " +$", with: "", options: .regularExpression))")
                    }
                    debugActions.append("styled cursor \(s.cursor.x),\(s.cursor.y) suggestion: \(s.suggestion ?? "-")")
                }
            }
        case "render":
            // render:<name>[:N[:width]] — the focused conversation's last N rows (12),
            // drawn off-screen into $TMPDIR/swiftr-render-<name>.png, 860 points wide:
            // works with the screen locked. Scroll views come out cut, buttons may not draw.
            let args = (parts.count > 1 ? parts[1] : "rows").split(separator: ":").map(String.init)
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                render(args[0], feed: feed, count: args.count > 1 ? Int(args[1]) ?? 12 : 12,
                       width: args.count > 2 ? Double(args[2]) ?? 860 : 860, model: model)
            } else {
                debugActions.append("render: no conversation focused")
            }
        case "render-pane":
            // render-pane:<name>[:N[:width]] — the focused pane as shown: its last N rows (4),
            // then what Claude asks, the field and the status bar, into $TMPDIR/swiftr-render-<name>.png.
            let args = (parts.count > 1 ? parts[1] : "pane").split(separator: ":").map(String.init)
            if let a = model.focusedAddress, let feed = model.feeds.existing(a),
               let host = model.feeds.keptView(a) as? NSHostingView<ConversationRoot>
            {
                let root = host.rootView
                let pane = PaneRender(feed: feed, rows: Array(feed.rows.suffix(args.count > 1 ? Int(args[1]) ?? 4 : 4)),
                                      address: a, paneID: root.paneID, context: root.pane)
                renderPicture(args[0], pane, width: args.count > 2 ? Double(args[2]) ?? 860 : 860, feed: feed, model: model)
            } else {
                debugActions.append("render-pane: no conversation shown")
            }
        case "redo":
            // redo: the Restore of OpenCode's reverted row.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                Task {
                    await feed.redoRevert()
                    debugActions.append("redo: \(feed.actionError ?? "ok")")
                }
            }
        case "rewind":
            // rewind:<n> as the Rewind button of the n-th message from the end (1: the last); rewind:list opens the list only.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                let shown = feed.rewindable
                let n = Int(parts.last ?? "") ?? 0
                let id = n >= 1 && n <= shown.count ? shown[shown.count - n].id : nil
                Task {
                    switch (feed.agent, id) {
                    case (.opencode, let id?): await feed.openCodeRewind(to: id)
                    case (.codex, let id?): await feed.codexRewind(to: id)
                    default: await feed.rewind(to: id)
                    }
                    debugActions.append("rewind \(parts.last ?? ""): \(feed.actionError ?? "ok")")
                }
            }
        case "answer":
            // answer:[{"chosen":["Red"],"other":""},…] for the open AskUserQuestion, as the form sends it.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a),
               let call = feed.openCalls.last(where: { $0.name == "AskUserQuestion" }),
               let given = (try? JSON(text: parts.count > 1 ? parts[1] : ""))?.array
            {
                let questions = AskQuestion.list(call.input)
                let answers = given.map { AskAnswer(chosen: $0["chosen"]?.stringArray ?? [], other: $0["other"]?.string ?? "") }
                Task {
                    let started = Date()
                    do {
                        try await feed.answer(questions, answers)
                        debugActions.append("answer ok in \(Int(-started.timeIntervalSinceNow * 1000)) ms")
                    } catch {
                        debugActions.append("answer failed: \(feed.actionError ?? "\(error)")")
                    }
                }
            } else {
                debugActions.append("answer: no open question")
            }
        case "card-answers":
            // card-answers:[{"chosen":["Red"],"other":""},…]: the open question's card, as if clicked.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a), let open = feed.openQuestion,
               let given = (try? JSON(text: parts.count > 1 ? parts[1] : ""))?.array
            {
                feed.askAnswers = [open.call.id: given.map { AskAnswer(chosen: $0["chosen"]?.stringArray ?? [], other: $0["other"]?.string ?? "") }]
            } else {
                debugActions.append("card-answers: no open question")
            }
        case "card-words":
            // card-words:<words> as typed in the field under Codex's or Gemini's question card.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a), let p = feed.prompt {
                feed.cardWords[feed.cardWordsKey(p)] = parts.count > 1 ? parts[1] : ""
            } else {
                debugActions.append("card-words: no question")
            }
        case "card-next":
            // card-next: the Next Question button on Gemini's question card.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                Task {
                    try? await feed.nextGeminiQuestion()
                    debugActions.append("card-next: \(feed.actionError ?? "ok")")
                }
            }
        case "card-done":
            // card-done: the Done button on Gemini's question card.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                Task {
                    try? await feed.doneGemini()
                    debugActions.append("card-done: \(feed.actionError ?? "ok")")
                }
            }
        case "card-send":
            // card-send: the arrow of the field under Codex's or Gemini's question card.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a), let p = feed.prompt {
                let key = feed.cardWordsKey(p)
                let words = feed.cardWords[key] ?? ""
                Task {
                    if feed.isCodex, let option = feed.noteOption(p) {
                        try? await feed.answerCodex(option, note: words, in: p)
                        if feed.actionError == nil { feed.cardNoteOn[key] = nil }
                    } else if feed.isGemini {
                        let custom = p.customOption.flatMap { n in p.options.first { $0.number == n } }
                        try? await feed.answerGemini(words, custom: custom)
                    }
                    if feed.actionError == nil { feed.cardWords[key] = nil }
                    debugActions.append("card-send: \(feed.actionError ?? "ok")")
                }
            }
        case "held":
            // held:take|clear: Take It or Clear on the line over the field (words held in Claude's box).
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                Task {
                    if parts.last == "clear" { await feed.clearHeldBox() } else { await feed.takeBackDraft() }
                    debugActions.append("held \(parts.last ?? ""): \(feed.actionError ?? "ok")")
                }
            }
        case "codex-note":
            // codex-note:<words> as the field under Codex's question: None of the above, the words as its note.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a), let p = feed.prompt,
               let other = p.options.last(where: { $0.label.hasPrefix("None of the above") })
            {
                let words = parts.count > 1 ? parts[1] : ""
                Task {
                    try? await feed.answerCodex(other, note: words, in: p)
                    debugActions.append("codex-note: \(feed.actionError ?? "ok")")
                }
            } else {
                debugActions.append("codex-note: no question")
            }
        case "refuse":
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                Task {
                    do {
                        try await feed.refuse(parts.count > 1 ? parts[1] : "")
                        debugActions.append("refuse ok")
                    } catch {
                        debugActions.append("refuse failed: \(feed.actionError ?? "\(error)")")
                    }
                }
            }
        case "revise":
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                Task {
                    do {
                        try await feed.revisePlan(parts.count > 1 ? parts[1] : "")
                        debugActions.append("revise ok")
                    } catch {
                        debugActions.append("revise failed: \(feed.actionError ?? "\(error)")")
                    }
                }
            }
        case "attach":
            // attach:/path/picture.png: a picture in the focused Claude's field, as a paste puts it.
            if let a = model.focusedAddress, parts.count > 1, let data = FileManager.default.contents(atPath: parts[1]),
               let picture = PendingImage.fitted(name: (parts[1] as NSString).lastPathComponent, data: data)
            {
                model.draftImages[a, default: []].append(picture)
            } else {
                debugActions.append("attach: can't read \(parts.count > 1 ? parts[1] : "-")")
            }
        case "select-text":
            // select-text:<words>: those words selected in the conversation shown, as a drag over them leaves them.
            selectText(parts.count > 1 ? parts[1] : "", model)
        case "select-drag":
            // select-drag:x1,y1,x2,y2 (points from the window's top left): a press, a drag in ten steps, a
            // release, through NSApp as real ones go, event monitors too. select-drag:x,y,x,y,2: a double click.
            let v = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            if v.count >= 4 { drag(from: NSPoint(x: v[0], y: v[1]), to: NSPoint(x: v[2], y: v[3]), clicks: v.count > 4 ? Int(v[4]) : 1) }
        case "quote":
            // quote:ask (the button over the selection) | quote:add:<words> | quote:clear (the focused
            // field's passages) | quote:reveal:<words> (where they came from, as a click on a sent quote).
            guard let a = model.focusedAddress else { break }
            let rest = (parts.count > 1 ? parts[1] : "").split(separator: ":", maxSplits: 1).map(String.init)
            switch rest.first ?? "" {
            case "ask":
                if let offer = QuoteOffer.shownOffers[a], let shown = offer.shown, let take = offer.debugTake {
                    offer.unselect()
                    take(shown.text)
                } else {
                    debugActions.append("quote:ask: no offer shown")
                }
            case "add": model.draftQuotes[a, default: []].append(rest.count > 1 ? rest[1] : "")
            case "clear": model.draftQuotes[a] = nil
            case "reveal": NotificationCenter.default.post(name: .swiftrRevealQuote, object: a, userInfo: ["quote": rest.count > 1 ? rest[1] : ""])
            default: debugActions.append("quote: \(rest.first ?? "-")?")
            }
        case "field":
            // field:submit|up|down|tab|right|backtab|enter|escape: what that key does in the focused Claude's field;
            // field:drop:/a/file: that file dropped on it.
            let what = parts.count > 1 ? parts[1] : ""
            if what.hasPrefix("drop:") {
                NotificationCenter.default.post(name: .swiftrDebugField, object: model.focusedAddress, userInfo: ["do": "drop", "path": String(what.dropFirst(5))])
            } else {
                NotificationCenter.default.post(name: .swiftrDebugField, object: model.focusedAddress, userInfo: ["do": what])
            }
        case "field-key":
            // field-key:ctrl+r: a real key event to the shown message field,
            // through its own keyDown, without making the window key.
            guard let window = mainWindow, let root = window.contentView,
                  let field = views(of: ComposerTextView.self, in: root).first(where: { !$0.isHiddenOrHasHiddenAncestor && $0.isEditable })
            else {
                debugActions.append("field-key: no field")
                break
            }
            // ctrl+r, alt+., ctrl+shift+b: modifiers first, then the key.
            let key = (parts.count > 1 ? parts[1] : "").lowercased()
            var flags: NSEvent.ModifierFlags = []
            var rest = Substring(key)
            for (name, flag) in [("ctrl+", NSEvent.ModifierFlags.control), ("alt+", .option), ("shift+", .shift), ("cmd+", .command)] where rest.hasPrefix(name) {
                flags.insert(flag)
                rest = rest.dropFirst(name.count)
            }
            // `return`: the Return key (after ctrl+x, Claude Code's pair);
            // `left`, `right`, `up`, `down`: the arrows.
            let isReturn = rest == "return"
            let arrows: [Substring: (Int, UInt16)] = ["left": (NSLeftArrowFunctionKey, 123), "right": (NSRightArrowFunctionKey, 124),
                                                       "down": (NSDownArrowFunctionKey, 125), "up": (NSUpArrowFunctionKey, 126)]
            let arrow = arrows[rest]
            if arrow != nil { flags.formUnion([.function, .numericPad]) }
            let letter = isReturn ? "\r" : arrow.map { String(UnicodeScalar(UInt16($0.0)).map(Character.init) ?? " ") } ?? String(rest)
            let typed = flags.contains(.control) && !isReturn && arrow == nil ? String(UnicodeScalar(UInt8(letter.unicodeScalars.first.map { $0.value & 0x1F } ?? 0))) : letter
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: typed, charactersIgnoringModifiers: letter,
                                            isARepeat: false, keyCode: arrow?.1 ?? (isReturn ? 36 : letter == "r" ? 15 : 0))
            {
                field.keyDown(with: event)
                debugActions.append("field-key: \(key)")
            }
        case "scroll-to":
            // scroll-to:0 (top) … 1 (bottom): the widest scroll view shown, the conversation's.
            guard let window = mainWindow, let root = window.contentView,
                  let scroll = views(of: NSScrollView.self, in: root).filter({ !$0.isHiddenOrHasHiddenAncestor })
                      .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
                  let document = scroll.documentView
            else {
                debugActions.append("scroll-to: no scroll view")
                break
            }
            let f = min(max(Double(parts.last ?? "") ?? 0, 0), 1)
            let range = max(0, document.frame.height - scroll.contentView.bounds.height)
            let y = document.isFlipped ? range * f : range * (1 - f)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            debugActions.append("scroll-to \(f): \(type(of: document)) height \(document.frame.height) at \(y)")
        case "scroll-side":
            // scroll-side:0 (left) … 1 (right): every scroll view shown that is wider
            // inside than out, as a table too wide for its column.
            guard let window = mainWindow, let root = window.contentView else { break }
            let f = min(max(Double(parts.last ?? "") ?? 0, 0), 1)
            for scroll in views(of: NSScrollView.self, in: root) where !scroll.isHiddenOrHasHiddenAncestor {
                let shown = scroll.contentView.bounds
                guard let document = scroll.documentView, document.frame.width > shown.width + 1 else { continue }
                let x = (document.frame.width - shown.width) * f
                scroll.contentView.scroll(to: NSPoint(x: x, y: shown.origin.y))
                scroll.reflectScrolledClipView(scroll.contentView)
                debugActions.append("scroll-side \(f): \(Int(document.frame.width)) wide, at \(Int(x))")
            }
        case "field-views":
            // The shown message field's views, from its scroll view down: class, frame, hidden, alpha.
            guard let window = mainWindow, let root = window.contentView,
                  let field = views(of: ComposerTextView.self, in: root).first(where: { !$0.isHiddenOrHasHiddenAncestor && $0.isEditable })
            else {
                debugActions.append("field-views: no field")
                break
            }
            func walk(_ v: NSView, _ depth: Int) {
                debugActions.append("field-views " + String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame.debugDescription) hidden=\(v.isHidden) alpha=\(v.alphaValue) layerOpacity=\(v.layer?.opacity ?? -1)")
                for sub in v.subviews { walk(sub, depth + 1) }
            }
            walk(field.enclosingScrollView ?? field, 0)
            if let layout = field.layoutManager, let container = field.textContainer, let font = field.font {
                layout.ensureLayout(for: container)
                debugActions.append("field-views line=\(layout.defaultLineHeight(for: font)) used=\(layout.usedRect(for: container).debugDescription) extra=\(layout.extraLineFragmentRect.debugDescription) typingFont=\(String(describing: field.typingAttributes[.font])) font=\(font)")
            }
        case "draft":
            // What the field holds for the focused pane: draft:/mo
            if let a = model.focusedAddress { model.drafts[a] = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil }
        case "next-agent":
            // OpenCode's agent chip: Shift-Tab, its next agent.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                Task {
                    do {
                        try await feed.nextAgent()
                        debugActions.append("next-agent ok: \(feed.footer?.mode ?? "-")")
                    } catch {
                        debugActions.append("next-agent failed: \(feed.actionError ?? "\(error)")")
                    }
                }
            }
        case "mode":
            // mode:plan, or mode:plan,shift+tab to name the key (a --safe-mode Claude's).
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                let args = (parts.count > 1 ? parts[1] : "default").split(separator: ",", maxSplits: 1).map(String.init)
                Task {
                    guard let key = args.count > 1 ? args[1] : feed.modeKey else {
                        debugActions.append("mode: no key")
                        return
                    }
                    do {
                        try await feed.setMode(args[0], key: key)
                        debugActions.append("mode ok: \(feed.footer?.mode ?? "-")")
                    } catch {
                        debugActions.append("mode failed: \(feed.actionError ?? "\(error)")")
                    }
                }
            }
        case "escape":
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                Task {
                    await feed.escape()
                    debugActions.append("escape")
                }
            }
        case "menu-chip":
            // `menu-chip:effort|model`: the chip under the field opens Claude's menu,
            // its card in the chip's popover; `menu-chip:close` closes the popover as
            // a click outside it does; `menu-chip:leave`, as Show in Terminal does.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                let arg = parts.count > 1 ? parts[1] : ""
                let menus = feed.menus
                switch arg {
                case "close": if let kind = menus.inPopover { menus.popoverClosed(kind) }
                case "leave": menus.leavePopover()
                default: if let kind = ClaudeMenuKind(rawValue: arg) { menus.openInPopover(kind) }
                }
                debugActions.append("menu-chip:\(arg): \(menus.inPopover?.rawValue ?? "none")")
            }
        case "model-pick", "model-more", "model-effort", "model-take", "effort-level", "effort-ultra", "effort-take", "resume-search",
             "resume-pick", "resume-move", "resume-projects", "resume-branch", "resume-take", "resume-close", "menu-key", "ask-words", "ask-next":
            // The menu cards (`ClaudeMenuDriver`): `model-pick:<n>` (or `:more`), `model-more`,
            // `model-effort:up|down|<0…4>`, `model-take:session|default`; `effort-level:<0…>`,
            // `effort-ultra`, `effort-take:session|default`; `resume-search:<words>`, `resume-pick:<row>`,
            // `resume-move:up|down[:n]`, `resume-projects`, `resume-branch`, `resume-take`, `resume-close`;
            // `menu-key:<left|right|up|down|enter|esc|tab|s|ctrl+a|ctrl+b>`: a key on the card.
            // A question read from the screen: `ask-words:<own words>`, `ask-next` (several answers).
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                let arg = parts.count > 1 ? parts.dropFirst().joined(separator: ":") : ""
                let menus = feed.menus
                Task {
                    switch parts.first ?? "" {
                    case "model-pick": menus.highlight(Int(arg).map { .model($0) } ?? .more)
                    case "model-more": menus.openOrCloseMore()
                    case "model-effort":
                        if let i = Int(arg) { menus.setModelEffort(i) } else { menus.stepModelEffort(arg == "up" ? 1 : -1) }
                    case "model-take", "effort-take": await menus.choose(arg == "session" ? "s" : "enter")
                    case "effort-level": menus.setEffort(Int(arg) ?? 0)
                    case "effort-ultra": menus.toggleUltracode()
                    case "resume-search": menus.search(arg)
                    case "resume-pick": await menus.resume(Int(arg) ?? 0)
                    case "resume-move":
                        let bits = arg.split(separator: ":")
                        let n = bits.count > 1 ? Int(bits[1]) ?? 1 : 1
                        menus.moveResume(bits.first == "down" ? n : -n)
                    case "resume-projects":
                        if let m = feed.dialog?.resumeMenu { menus.showAllProjects(!menus.allProjectsShown(m)) }
                    case "resume-branch":
                        if let m = feed.dialog?.resumeMenu, let only = menus.branchOnlyShown(m) { menus.showBranchOnly(!only) }
                    case "resume-take": await menus.choose("enter")
                    case "resume-close": await menus.choose("esc")
                    case "menu-key":
                        if !menus.key(arg) { debugActions.append("menu-key: \(arg) not taken") }
                    default:
                        if let p = feed.prompt, let q = p.shownQuestion {
                            let chosen = p.options.filter { $0.checked == true && q.options.indices.contains($0.number - 1) }.map { q.options[$0.number - 1].label }
                            try? await feed.answerShown(q, AskAnswer(chosen: q.multiSelect ? chosen : [], other: parts.first == "ask-words" ? arg : ""))
                        }
                    }
                    debugActions.append("\(parts.first ?? ""): \(feed.actionError ?? "ok")")
                }
            }
        case "key":
            // key:left, key:ctrl+a, key:s: a real key event to the main window's
            // first responder (a card's keys, its search), the window not made key.
            // key:cmd+backspace, key:alt+delete (⌦): a terminal's line keys.
            guard let window = mainWindow else { break }
            let key = (parts.count > 1 ? parts[1] : "").lowercased()
            var flags: NSEvent.ModifierFlags = []
            var rest = Substring(key)
            for (name, flag) in [("ctrl+", NSEvent.ModifierFlags.control), ("alt+", .option), ("shift+", .shift), ("cmd+", .command)] where rest.hasPrefix(name) {
                flags.insert(flag)
                rest = rest.dropFirst(name.count)
            }
            let special: [Substring: (String, UInt16)] = [
                "left": (String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!), 123), "right": (String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!), 124),
                "down": (String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125), "up": (String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), 126),
                "return": ("\r", 36), "enter": ("\r", 36), "esc": ("\u{1b}", 53), "tab": ("\t", 48), "space": (" ", 49), "backspace": ("\u{7f}", 51),
                "delete": (String(UnicodeScalar(UInt16(NSDeleteFunctionKey))!), 117),
            ]
            let found = special[rest]
            if let found, (123 ... 126).contains(found.1) { flags.formUnion([.function, .numericPad]) }
            if found?.1 == 117 { flags.insert(.function) }
            let letter = found?.0 ?? String(rest)
            let typed = flags.contains(.control) && found == nil
                ? String(UnicodeScalar(UInt8(letter.unicodeScalars.first.map { $0.value & 0x1F } ?? 0))) : letter
            let codes: [Character: UInt16] = ["a": 0, "s": 1, "b": 11, "x": 7]
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: typed, charactersIgnoringModifiers: letter,
                                            isARepeat: false, keyCode: found?.1 ?? letter.first.flatMap { codes[$0] } ?? 0)
            {
                // A terminal's line keys, taken as the app's key monitor takes them.
                if let terminal = window.firstResponder as? SwiftrTerminalView, terminal.takeLineKey(event) {
                    debugActions.append("key: \(key) → line key")
                    break
                }
                window.sendEvent(event)
                if let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: typed, charactersIgnoringModifiers: letter,
                                             isARepeat: false, keyCode: found?.1 ?? letter.first.flatMap { codes[$0] } ?? 0)
                {
                    window.sendEvent(up)
                }
                debugActions.append("key: \(key) → \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
            }
        case "drag-at":
            // drag-at:x1,y1,x2,y2: a press at x1,y1 (points from the window's top
            // left), moved to x2,y2 in ten steps, let go; the same point twice: a
            // tap. Straight to the view there: a window that isn't key would
            // take the press for its own.
            let xy = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            guard xy.count == 4, let window = mainWindow, let content = window.contentView, let frameView = content.superview else { break }
            func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: window.frame.height - y), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let start = frameView.convert(NSPoint(x: xy[0], y: window.frame.height - xy[1]), from: nil)
            guard let target = content.hitTest(start) else {
                debugActions.append("drag-at: no view")
                break
            }
            Task { @MainActor in
                if let e = event(.leftMouseDown, xy[0], xy[1]) { target.mouseDown(with: e) }
                for step in 1 ... 10 {
                    try? await Task.sleep(for: .milliseconds(30))
                    let f = Double(step) / 10
                    if let e = event(.leftMouseDragged, xy[0] + (xy[2] - xy[0]) * f, xy[1] + (xy[3] - xy[1]) * f) { target.mouseDragged(with: e) }
                }
                try? await Task.sleep(for: .milliseconds(30))
                if let e = event(.leftMouseUp, xy[2], xy[3]) { target.mouseUp(with: e) }
                debugActions.append("drag-at \(xy.map { Int($0) }) → \(type(of: target))")
            }
        case "interrupt":
            // The composer's stop button.
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
                Task {
                    await feed.interrupt()
                    debugActions.append("interrupt")
                }
            }
        case "earlier":
            if let a = model.focusedAddress, let feed = model.feeds.existing(a) { Task { await feed.loadEarlier() } }
        case "front":
            // On top of other apps' windows, without taking the keyboard.
            mainWindow?.orderFrontRegardless()
        case "back":
            mainWindow?.orderBack(nil)
        case "snapshot":
            // The window as shown, into $TMPDIR/swiftr-snapshot-<name>.png: an app
            // may capture its own windows even when scripts can't capture the screen.
            Task { await snapshot(parts.count > 1 ? parts[1] : "window") }
        case "sheet-snapshot":
            // The sheet on the window, which is a window of its own.
            Task { await snapshot(parts.count > 1 ? parts[1] : "sheet", sheet: true) }
        case "settings-snapshot":
            // The Settings window, once menu-item:Swiftr/Settings… opened it.
            Task { await snapshot(parts.count > 1 ? parts[1] : "settings", settings: true) }
        case "popover-snapshot":
            // The popover shown, a window of its own (Settings' or the main window's).
            Task { await snapshot(parts.count > 1 ? parts[1] : "popover", popover: true) }
        case "settings-pane":
            // As a click in the Settings window's list: it opens there next time too.
            UserDefaults.standard.set(parts.count > 1 ? parts[1] : "", forKey: SettingsPane.defaultsKey)
        case "settings-frame":
            let v = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            if v.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }) {
                var frame = window.frame
                frame.origin.y += frame.height - v[1]
                frame.size = CGSize(width: v[0], height: v[1])
                window.setFrame(frame, display: true)
            }
        case "settings-click":
            // A left click at x,y points from the Settings window's top left.
            let xy = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            if xy.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }) {
                let at = NSPoint(x: xy[0], y: window.frame.height - xy[1])
                let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap {
                    NSEvent.mouseEvent(with: $0, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                if events.count == 2 {
                    NSApp.postEvent(events[1], atStart: false)
                    window.sendEvent(events[0])
                }
            }
        case "burst":
            // burst:name:N:ms:command — N snapshots of the sidebar's top, one after
            // the other, into $TMPDIR/swiftr-snapshot-name-i.png; the command runs
            // ms after the first. To see something move.
            let args = (parts.count > 1 ? parts[1] : "").split(separator: ":", maxSplits: 3).map(String.init)
            guard args.count == 4, let count = Int(args[1]), let delay = Int(args[2]) else { break }
            Task { await burst(args[0], count: count) }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { run(args[3], model) }
        case "burst-area":
            // burst-area:x,y,w,h — where the next bursts look (the agents are lower).
            let v = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { burstArea = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
        default: break
        }
    }

    /// Usage to test with: Claude ahead in its week, Codex calm, Gemini near its day's end.
    private static func debugUsageReports() -> [String: UsageReport] {
        let now = Date()
        let hour: TimeInterval = 3600
        return [
            "claude": UsageReport(windows: [
                UsageWindow(id: "session", title: "Session", used: 55, resetsAt: now + 2 * hour + 300, length: 5 * hour),
                UsageWindow(id: "weekly", title: "Weekly", used: 88, resetsAt: now + 98 * hour, length: 168 * hour),
                UsageWindow(id: "model:fable", title: "Fable", used: 12, resetsAt: now + 98 * hour, length: 168 * hour),
                UsageWindow(id: "model:sonnet", title: "Sonnet", used: 5, resetsAt: now + 98 * hour, length: 168 * hour),
                UsageWindow(id: "credits", title: "Usage credits", used: 24.7),
            ], plan: "Max 20x", at: now - 140),
            "codex": UsageReport(windows: [
                UsageWindow(id: "session", title: "Session", used: 23.5, resetsAt: now + 3 * hour, length: 5 * hour),
                UsageWindow(id: "weekly", title: "Weekly", used: 41, resetsAt: now + 120 * hour, length: 168 * hour),
            ], plan: "ChatGPT Plus", at: now - 30),
            "gemini": UsageReport(windows: [UsageWindow(id: "daily", title: "Daily", used: 93, length: 24 * hour)], at: now),
        ]
    }

    private static func render(_ name: String, feed: TranscriptFeed, count: Int, width: Double, model: AppModel) {
        let folder = model.store.model(feed.address)?.currentFolder ?? ""
        let rows = RowsRender(feed: feed, rows: Array(feed.rows.suffix(count)), size: model.prefs.fontSize, folder: folder)
        renderPicture(name, rows, width: width, feed: feed, model: model)
    }

    /// `content` drawn off-screen as the pane draws it, into $TMPDIR/swiftr-render-<name>.png.
    private static func renderPicture(_ name: String, _ content: some View, width: Double, feed: TranscriptFeed, model: AppModel) {
        let theme = model.prefs.theme
        let noop = RowAction(key: "render") { _ in }
        let view = content
            .frame(width: width, alignment: .leading)
            .background(Color(nsColor: theme.backgroundColor))
            .environment(model)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
            .environment(\.themeAccent, theme.accentColor.map { Color(nsColor: $0) })
            .environment(\.codeFamily, model.prefs.fontName)
            .environment(\.agentName, feed.agentName)
            .environment(\.reusePrompt, noop)
            .environment(\.rewindPrompt, noop)
            .environment(\.redoRevert, feed.isOpenCode ? noop : nil)
            .environment(\.unrewindable, feed.summarized)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            debugActions.append("render \(name): nothing drawn")
            return
        }
        let url = tempFile("swiftr-render-\(name).png")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        debugActions.append("render \(name): \(image.width)x\(image.height)")
    }

    private static func burst(_ name: String, count: Int) async {
        guard let number = mainWindow?.windowNumber,
              let content = try? await SCShareableContent.currentProcess,
              let window = content.windows.first(where: { $0.windowID == CGWindowID(number) })
        else { return }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let area = burstArea
        config.sourceRect = area
        config.width = Int(area.width * CGFloat(filter.pointPixelScale))
        config.height = Int(area.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        var frames: [(ms: Int, image: CGImage)] = []
        let start = Date()
        for _ in 0 ..< count {
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                frames.append((Int(-start.timeIntervalSinceNow * 1000), image))
            }
        }
        for (i, frame) in frames.enumerated() {
            let url = tempFile("swiftr-snapshot-\(name)-\(i).png")
            try? NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:])?.write(to: url)
        }
        debugActions.append("burst \(name): " + frames.map { String($0.ms) }.joined(separator: ","))
    }

    private static func snapshot(_ name: String, sheet: Bool = false, settings: Bool = false, popover: Bool = false) async {
        let url = tempFile("swiftr-snapshot-\(name).png")
        do {
            let target = popover
                ? NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
                : settings
                ? NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }
                : sheet ? mainWindow?.attachedSheet : mainWindow
            guard let number = target?.windowNumber else {
                debugActions.append("snapshot: no \(popover ? "popover" : settings ? "settings window" : sheet ? "sheet" : "window")")
                return
            }
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(number) }) else {
                debugActions.append("snapshot: window \(number) not shareable")
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            } catch {
                // A locked screen: macOS captures nothing. The window draws
                // itself instead; glass and other materials may come out plain.
                guard let view = target?.contentView?.superview ?? target?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { throw error }
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: url)
                debugActions.append("snapshot: drawn by the window, the screen can't be captured")
            }
        } catch {
            debugActions.append("snapshot: \(error)")
        }
    }

    private static func leftClick(at point: NSPoint) {
        guard let main = mainWindow else { return }
        // The app's window there: a popover's or a sheet's own, else the main
        // one. Not the screen's: another app's window may cover this one.
        let onScreen = NSPoint(x: main.frame.minX + point.x, y: main.frame.maxY - point.y)
        let window = NSApp.windows.first { $0.isVisible && $0.parent != nil && $0.frame.contains(onScreen) } ?? main
        let at = NSPoint(x: onScreen.x - window.frame.minX, y: onScreen.y - window.frame.minY)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        // Queued first: a button that tracks the mouse after the down finds it.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        debugActions.append("click-at \(Int(point.x)),\(Int(point.y)): \(type(of: window))")
    }

    /// A scroll at `point` (from the window's top left): logs the view the
    /// window finds there, and the scroll views over it before and after.
    /// A trackpad's swipe can't be made up this way: AppKit's scroll views,
    /// the sidebar's list too, ignore made-up events that have phases.
    private static func wheel(at point: NSPoint, dx: Double, dy: Double, notches: Bool) {
        guard let window = mainWindow, let root = window.contentView?.superview else { return }
        let inWindow = NSPoint(x: point.x, y: window.frame.height - point.y)
        var chain: [String] = []
        var hit = root.hitTest(inWindow)
        while let v = hit, chain.count < 14 {
            chain.append(String(describing: type(of: v)))
            hit = v.superview
        }
        debugActions.append("wheel-at \(Int(point.x)),\(Int(point.y)) hits: \(chain.joined(separator: " < "))")
        func offsets() -> String {
            views(of: NSScrollView.self, in: root)
                .filter { !$0.isHiddenOrHasHiddenAncestor && frameInWindow($0).contains(inWindow) }
                .map { s in
                    let f = frameInWindow(s)
                    return "\(type(of: s)) \(Int(f.minX)),\(Int(window.frame.height - f.maxY)) \(Int(f.width))x\(Int(f.height)) doc \(Int(s.documentView?.frame.width ?? 0))w at \(Int(s.contentView.bounds.origin.x)),\(Int(s.contentView.bounds.origin.y))"
                }
                .joined(separator: "; ")
        }
        debugActions.append("wheel-at before: \(offsets())")
        let onScreen = window.convertPoint(toScreen: inWindow)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        // NSEvent(cgEvent:) takes the window from field 51 (found by trying each
        // field), and the place in it from the event's window location, which
        // only a private CoreGraphics call sets. Without them, NSApp drops it.
        typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
        let setWindowLocation = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
            .map { unsafeBitCast($0, to: SetWindowLocation.self) }
        let count = notches ? 3 : 10
        let (sx, sy) = notches ? (dx, dy) : (dx / Double(count), dy / Double(count))
        for i in 0 ..< count {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: notches ? .line : .pixel, wheelCount: 2,
                                   wheel1: Int32(sy), wheel2: Int32(sx), wheel3: 0),
                  let windowField = CGEventField(rawValue: 51)
            else { continue }
            cg.location = CGPoint(x: onScreen.x, y: top - onScreen.y)
            cg.setIntegerValueField(windowField, value: Int64(window.windowNumber))
            setWindowLocation?(cg, point)
            if !notches {
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: sy)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: sx)
                cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: sy)
                cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: sx)
            }
            guard let event = NSEvent(cgEvent: cg) else { continue }
            if i == 0 {
                debugActions.append("wheel-at event: window \(event.windowNumber) (main \(window.windowNumber)) at \(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y)) precise \(event.hasPreciseScrollingDeltas) dx \(event.scrollingDeltaX) dy \(event.scrollingDeltaY)")
            }
            NSApp.sendEvent(event)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            debugActions.append("wheel-at after: \(offsets())")
        }
    }

    private static func rightClick(at point: NSPoint) {
        guard let window = mainWindow,
              let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: point.x, y: window.frame.height - point.y),
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        menuLines = []
        // Posted on the main thread once the menu shows, submenus filled in.
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            // On the main thread already.
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard openMenu == nil, let menu else { return }
                openMenu = menu
                menuLines = describe(menu)
            }
        }
        // The main run loop tracks the menu until it closes: snapshot and
        // close it from another thread, in the run loop's tracking mode.
        let shot = tempFile("swiftr-snapshot-menu.png")
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.8)
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await snapshotMenus(to: shot)
                done.signal()
            }
            done.wait()
            let main = CFRunLoopGetMain()
            let mode = CFRunLoopCopyCurrentMode(main)?.rawValue ?? CFRunLoopMode.commonModes.rawValue
            CFRunLoopPerformBlock(main, mode) {
                MainActor.assumeIsolated { openMenu?.cancelTracking() }
            }
            CFRunLoopWakeUp(main)
        }
        window.sendEvent(event)
        NotificationCenter.default.removeObserver(observer)
        openMenu = nil
    }

    /// The sidebar's tables by list ("spaces", "agents"), the top one first.
    private static func sidebarTables() -> [(name: String, table: NSOutlineView)] {
        ["spaces", "agents"]
            .compactMap { name in SidebarTable.Finder.tables.object(forKey: name as NSString).map { (name, $0) } }
            .filter { $0.table.window != nil }
            .sorted { frameInWindow($0.table).maxY > frameInWindow($1.table).maxY }
    }

    /// The sidebar table whose list holds x,y points from the window's top left.
    private static func table(at point: NSPoint) -> NSOutlineView? {
        guard let window = mainWindow else { return nil }
        let p = NSPoint(x: point.x, y: window.frame.height - point.y)
        return sidebarTables().first { SidebarTable.Finder.frame(of: $0.table).contains(p) }?.table
    }

    /// A view's frame in its window's points (from the bottom left).
    private static func frameInWindow(_ view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    /// The frame of the `debugMark` called `name`, and the window's root view.
    private static func marked(_ name: String) -> (frame: NSRect, root: NSView)? {
        guard let root = mainWindow?.contentView?.superview,
              let mark = views(of: DebugMarkView.self, in: root).first(where: { $0.name == name })
        else { return nil }
        return (frameInWindow(mark), root)
    }

    /// Clicks the last button in the band of the `debugMark` called `mark`,
    /// or its first.
    private static func pressTitleButton(in mark: String, for command: String, first: Bool = false) {
        guard let band = marked(mark) else {
            debugActions.append("\(command): no \(mark)")
            return
        }
        let buttons = views(of: NSButton.self, in: band.root).filter { band.frame.contains(frameInWindow($0).center) }
        let byX = buttons.sorted { frameInWindow($0).minX < frameInWindow($1).minX }
        if let button = first ? byX.first : byX.last {
            button.performClick(nil)
        } else {
            debugActions.append("\(command): no button in \(mark)")
        }
    }

    /// A press and a release on a view's middle, sent to the view itself:
    /// the window doesn't become key.
    private static func click(_ view: NSView) {
        guard let window = view.window else { return }
        let at = frameInWindow(view).center
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { continue }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    /// What a hand dragging the line between the lists does: press on its
    /// middle, move `down` points in ten steps, let go.
    private static func dragSplit(by down: Double) {
        guard let window = mainWindow, let root = window.contentView?.superview,
              let handle = views(of: SplitHandleView.self, in: root).first
        else {
            debugActions.append("split-drag: no handle")
            return
        }
        let start = frameInWindow(handle).center
        func event(_ type: NSEvent.EventType, down: Double) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x, y: start.y - down), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = event(.leftMouseDown, down: 0) { handle.mouseDown(with: e) }
        for step in 1 ... 10 {
            if let e = event(.leftMouseDragged, down: down * Double(step) / 10) { handle.mouseDragged(with: e) }
        }
        if let e = event(.leftMouseUp, down: down) { handle.mouseUp(with: e) }
        debugActions.append("split-drag: \(Int(down)) from y=\(Int(window.frame.height - start.y))")
    }

    private static func selectRow(at point: NSPoint) {
        guard let window = mainWindow, let table = table(at: point) else {
            debugActions.append("select-at: no list there")
            return
        }
        let row = table.row(at: table.convert(NSPoint(x: point.x, y: window.frame.height - point.y), from: nil))
        guard row >= 0 else {
            debugActions.append("select-at: no row")
            return
        }
        // What the table asks its delegate before a click selects a row:
        // selectRowIndexes alone would mark a row a click can't.
        var rows = IndexSet(integer: row)
        if let delegate = table.delegate {
            if let allowed = delegate.outlineView?(table, selectionIndexesForProposedSelection: rows) {
                rows = allowed
            } else if let item = table.item(atRow: row),
                      delegate.outlineView?(table, shouldSelectItem: item) == false {
                rows = []
            }
        }
        guard !rows.isEmpty else {
            debugActions.append("select-at: row \(row) refused")
            return
        }
        table.selectRowIndexes(rows, byExtendingSelection: false)
        debugActions.append("select-at: row \(row)")
    }

    private static func disclose(at point: NSPoint) {
        guard let window = mainWindow, let table = table(at: point) else {
            debugActions.append("disclose-at: no list there")
            return
        }
        let row = table.row(at: table.convert(NSPoint(x: point.x, y: window.frame.height - point.y), from: nil))
        guard row >= 0, let rowView = table.rowView(atRow: row, makeIfNecessary: false) else {
            debugActions.append("disclose-at: no row")
            return
        }
        let triangle = views(of: NSButton.self, in: rowView).first { $0.identifier == NSOutlineView.disclosureButtonIdentifier }
        guard let triangle else {
            debugActions.append("disclose-at: no triangle in row \(row)")
            return
        }
        // Its action without performClick, whose own event loop would hold
        // `burst` while the button looks pressed.
        if let action = triangle.action { NSApp.sendAction(action, to: triangle.target, from: triangle) }
        debugActions.append("disclose-at: row \(row)")
    }

    /// In the spaces' list: the agents' has no moves.
    private static func moveRow(_ from: Int, parent: Int, index: Int) {
        guard let window = mainWindow, let table = sidebarTables().first(where: { $0.name == "spaces" })?.table,
              let source = table.dataSource,
              (0 ..< table.numberOfRows).contains(from), parent < table.numberOfRows
        else {
            debugActions.append("move-row: no such row")
            return
        }
        let item = table.item(atRow: from) as Any
        let target = parent >= 0 ? table.item(atRow: parent) : nil
        // What a drag carries: the table's own pasteboard writer and items.
        let board = NSPasteboard(name: NSPasteboard.Name("com.melvinsiadous.Swiftr.debug-drag"))
        board.clearContents()
        let writer = source.outlineView?(table, pasteboardWriterForItem: item)
        if let writer { board.writeObjects([writer]) }
        let session = NSDraggingSession()
        source.outlineView?(table, draggingSession: session, willBeginAt: .zero, forItems: [item])
        // Over the row the drop lands before, else under the last one.
        let below = min(parent + 1 + index, table.numberOfRows - 1)
        let rect = table.rect(ofRow: below)
        let point = table.convert(NSPoint(x: rect.midX, y: below == parent + 1 + index ? rect.minY + 2 : rect.maxY - 2), to: nil)
        let drop = TestDrop(board: board, source: table, window: window, location: point, writer: writer)
        let operation = source.outlineView?(table, validateDrop: drop, proposedItem: target, proposedChildIndex: index) ?? []
        let accepted = operation.isEmpty ? false : source.outlineView?(table, acceptDrop: drop, item: target, childIndex: index) ?? false
        source.outlineView?(table, draggingSession: session, endedAt: .zero, operation: accepted ? .move : [])
        debugActions.append("move-row \(from) to \(parent):\(index): writer=\(writer != nil) validate=\(operation.rawValue) accept=\(accepted) source=\(type(of: source)) "
            + dragMethods(of: source).joined(separator: " "))
    }

    /// The drag and drop methods an object answers.
    private static func dragMethods(of object: AnyObject) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(object_getClass(object), &count) else { return [] }
        defer { free(list) }
        return (0 ..< Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }
            .filter { $0.contains("rag") || $0.contains("rop") || $0.contains("asteboard") }
            .sorted()
    }

    private static func pressRowButton(at point: NSPoint) {
        guard let window = mainWindow, let table = table(at: point) else {
            debugActions.append("row-button: no list there")
            return
        }
        let row = table.row(at: table.convert(NSPoint(x: point.x, y: window.frame.height - point.y), from: nil))
        guard row >= 0, let rowView = table.rowView(atRow: row, makeIfNecessary: false) else {
            debugActions.append("row-button: no row")
            return
        }
        let buttons = views(of: NSButton.self, in: rowView).filter { $0.identifier != NSOutlineView.disclosureButtonIdentifier }
        guard let button = buttons.max(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) else {
            debugActions.append("row-button: no button in row \(row): " + describeTree(rowView, in: rowView).joined(separator: " | "))
            return
        }
        // SwiftUI's buttons have no action to send: they answer a click.
        if let action = button.action { NSApp.sendAction(action, to: button.target, from: button) } else { button.performClick(nil) }
        debugActions.append("row-button: row \(row)")
    }

    /// The sidebar's rows, list by list: where each sits (points from the
    /// window's top left; a row scrolled out of its list sits outside it),
    /// its level, its triangle, whether it shows as selected.
    private static func sidebarRows() -> [[String: Any]] {
        guard let window = mainWindow else { return [] }
        return sidebarTables().flatMap { name, table in
            (0 ..< table.numberOfRows).map { row -> [String: Any] in
                let frame = table.convert(table.rect(ofRow: row), to: nil)
                let item = table.item(atRow: row)
                let triangle = table.rowView(atRow: row, makeIfNecessary: false).flatMap { rowView in
                    views(of: NSButton.self, in: rowView).first { $0.identifier == NSOutlineView.disclosureButtonIdentifier }
                }
                return ["list": name, "row": row, "top": Int(window.frame.height - frame.maxY), "height": Int(frame.height),
                        "level": table.level(forRow: row), "expandable": table.isExpandable(item),
                        "expanded": table.isItemExpanded(item), "selected": table.isRowSelected(row),
                        "triangle": triangle.map { "x=\(Int($0.convert($0.bounds, to: nil).minX)) hidden=\($0.isHidden)" } ?? "none"]
            }
        }
    }

    /// Where each of the sidebar's lists sits, and the line between them
    /// (points from the window's top left).
    private static func sidebarLists() -> [String: Any] {
        guard let window = mainWindow, let root = window.contentView?.superview else { return [:] }
        func place(_ frame: NSRect) -> [String: Int] {
            ["top": Int(window.frame.height - frame.maxY), "height": Int(frame.height), "left": Int(frame.minX), "width": Int(frame.width)]
        }
        var out: [String: Any] = [:]
        for (name, table) in sidebarTables() { out[name] = place(SidebarTable.Finder.frame(of: table)) }
        if let handle = views(of: SplitHandleView.self, in: root).first { out["handle"] = place(frameInWindow(handle)) }
        if let band = marked("agents-title") { out["agentsTitle"] = place(band.frame) }
        if let band = marked("spaces-title") { out["spacesTitle"] = place(band.frame) }
        return out
    }

    private static func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(of: type, in: $0) }
    }

    /// `select-drag`: the release and the moves queued first, as a view that
    /// follows the drag in a loop of its own reads them from the queue.
    private static func drag(from start: NSPoint, to end: NSPoint, clicks: Int) {
        guard let window = mainWindow else { return }
        func event(_ type: NSEvent.EventType, _ p: NSPoint, count: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: window.frame.height - p.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1)
        }
        if clicks > 1 {
            for n in 1 ..< clicks {
                if let up = event(.leftMouseUp, start, count: n) { NSApp.postEvent(up, atStart: false) }
                if let down = event(.leftMouseDown, start, count: n + 1) { NSApp.postEvent(down, atStart: false) }
            }
        } else {
            for step in 1 ... 10 {
                let t = Double(step) / 10
                let p = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                if let moved = event(.leftMouseDragged, p, count: 1) { NSApp.postEvent(moved, atStart: false) }
            }
        }
        if let up = event(.leftMouseUp, clicks > 1 ? start : end, count: clicks) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown, start, count: 1) { NSApp.sendEvent(down) }
        debugActions.append("select-drag \(Int(start.x)),\(Int(start.y)) → \(Int(end.x)),\(Int(end.y)) ×\(clicks)")
    }

    /// `select-text`: SwiftUI's selectable texts say what they hold through
    /// accessibility; the first shown that holds `words` gets them selected,
    /// then its conversation looks, as after a release.
    private static func selectText(_ words: String, _ model: AppModel) {
        guard !words.isEmpty, let window = mainWindow, let root = window.contentView?.superview else { return }
        let texts = views(of: NSView.self, in: root).filter {
            !$0.isHiddenOrHasHiddenAncestor && NSStringFromClass(type(of: $0)).contains("TextInteractionView")
        }
        for view in texts {
            let count = view.accessibilityNumberOfCharacters()
            guard count > 0 else { continue }
            let all = view.accessibilityString(for: NSRange(location: 0, length: count)) ?? view.accessibilityValue() as? String ?? ""
            guard let range = all.range(of: words) else { continue }
            window.makeFirstResponder(view)
            view.setAccessibilitySelectedTextRange(NSRange(range, in: all))
            // Each conversation looks: the one that holds the text shows its button.
            for a in QuoteOffer.shownOffers.keys {
                NotificationCenter.default.post(name: .swiftrDebugSelection, object: a)
            }
            debugActions.append("select-text: \(NSStringFromClass(type(of: view))) \(NSRange(range, in: all)) of \(count): \(view.accessibilitySelectedText() ?? "-")")
            return
        }
        debugActions.append("select-text: no text holds \(words) (\(texts.count) looked at)")
    }

    /// The table row holding a machine's header ("" is this Mac).
    private static func headerRow(_ machine: String) -> NSView? {
        guard let root = mainWindow?.contentView?.superview,
              let grip = views(of: MachineGripView.self, in: root).first(where: { $0.name == machine })
        else { return nil }
        var view: NSView? = grip
        while let v = view, !(v is NSTableRowView) { view = v.superview }
        return view
    }

    /// A view and those inside it, one per line: class, frame in `row`, and
    /// what tells buttons apart.
    private static func describeTree(_ view: NSView, in row: NSView, depth: Int = 0) -> [String] {
        let f = view.convert(view.bounds, to: row)
        var line = String(repeating: "  ", count: depth) + String(describing: type(of: view))
            + " (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))"
        if view.isHidden { line += " hidden" }
        if view.alphaValue < 1 { line += " alpha=\(view.alphaValue)" }
        if let id = view.identifier?.rawValue { line += " id=\(id)" }
        if let button = view as? NSButton { line += " button '\(button.title)' state=\(button.state.rawValue)" }
        return [line] + view.subviews.flatMap { describeTree($0, in: row, depth: depth + 1) }
    }

    /// The open menus of this app (window layer 101) into one PNG, the first found.
    nonisolated private static func snapshotMenus(to url: URL) async {
        guard let content = try? await SCShareableContent.currentProcess,
              let menu = content.windows.first(where: { $0.isOnScreen && $0.windowLayer == 101 })
        else { return }
        let filter = SCContentFilter(desktopIndependentWindow: menu)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// A menu's lines: ✓ for a check, [img] for an icon shown, [img hidden]
    /// for one macOS 27 hides, — for a divider.
    private static func describe(_ menu: NSMenu) -> [Any] {
        menu.items.map { item -> Any in
            if item.isSeparatorItem { return "—" }
            var image = item.image.map { " [img \(Int($0.size.width))x\(Int($0.size.height))]" } ?? ""
            if #available(macOS 27, *), item.image != nil, item.preferredImageVisibility != .visible { image = " [img hidden]" }
            let line = (item.state == .on ? "✓ " : "") + item.title + image
            if let sub = item.submenu { return [line: describe(sub)] }
            return line
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    private static func dump(_ model: AppModel) {
        var out: [String: Any] = [:]
        out["link"] = "\(model.link)"
        if let sheet = model.onboarding { out["onboarding"] = sheet.debugSummary(model) }
        out["activeSpace"] = model.activeSpace?.id ?? ""
        if let s = model.activeSpace, let t = model.activeTab(in: s) {
            out["activeTab"] = t.id
            out["focusedPane"] = model.focusedPane(in: t, of: s) ?? ""
            out["visible"] = model.visibleAddresses
        }
        out["spaces"] = model.allSpaces.map { s -> [String: Any] in
            let icon = model.view.spaceIcons?[s.id]
            let look = switch model.look(of: s) {
            case .symbol(let name): "symbol:" + name
            case .image: "image"
            case .letter(let letter, let hash): "letter:\(letter):\(Int(hash % UInt32(SpaceIconView.letterColors.count)))"
            }
            return ["id": s.id, "title": model.title(of: s), "name": s.space.name, "expanded": model.isExpanded(s),
                    "tabs": s.tabs.map { ["id": $0.id, "name": $0.name, "icon": model.programKey(of: $0, in: s) ?? "", "subtitle": model.subtitle(of: $0, in: s)] },
                    "icon": icon?.image.map { "image:" + $0 } ?? icon?.folder.map { "folder:" + $0 } ?? icon?.symbol ?? "", "look": look,
                    "folder": model.shownFolder(of: s)]
        }
        out["menu"] = menuLines
        out["logos"] = model.logos.mapValues { logo -> String in
            if case .image = logo { return "image" }
            return "none"
        }
        if let s = model.activeSpace, let t = model.activeTab(in: s) {
            out["rootSizes"] = t.root.children.map { c -> String in
                if case .weight(let w) = c.size { return "\(c.id)=\(w)" }
                return "\(c.id)=-"
            }
        }
        out["sessions"] = model.pool.sessions.mapValues { s -> [String: Any] in
            let d = s.view.terminalDimensions
            return ["phase": "\(s.phase)", "cols": d.cols, "rows": d.rows, "inWindow": s.view.window != nil, "firstResponder": s.view.window?.firstResponder === s.view,
                    "received": s.sink?.received.withLock { $0 } ?? -1,
                    "core": model.store.model(s.address).map { "\($0.cols)x\($0.rows)" } ?? "-"]
        }
        out["windowVisible"] = mainWindow?.occlusionState.contains(.visible) ?? false
        let theme = model.prefs.theme
        out["theme"] = ["name": model.prefs.themeName, "appearance": model.prefs.appearance.rawValue, "looksDark": model.prefs.looksDark,
                        "bg": theme.background, "fg": theme.foreground, "cursor": theme.cursor ?? "", "selection": theme.selection ?? ""]
        out["claude"] = model.claude.debugState
        out["sleep"] = model.sleepers.debugState
        out["alerts"] = model.alerts.debugLog
        var reading = ReadAloud.shared.debugState
        reading["readingID"] = ReadAloud.shared.readingID ?? ""
        // The voices Settings offers, best first, as this app sees them.
        reading["languages"] = ReadAloud.settingsLanguages
        reading["otherLanguages"] = ReadAloud.otherLanguages.count
        reading["voices"] = Dictionary(uniqueKeysWithValues: ReadAloud.settingsLanguages.map { language in
            (language, ReadAloud.systemVoices(for: language).map { "\($0.quality.rawValue) \($0.identifier)" })
        })
        // The voice each language reads in now, and the model voices it could.
        reading["chosen"] = Dictionary(uniqueKeysWithValues: ReadAloud.settingsLanguages.map { language in
            (language, ReadAloud.label(ReadAloud.voice(for: language)))
        })
        reading["modelVoices"] = Dictionary(uniqueKeysWithValues: ReadAloud.settingsLanguages.map { language in
            (language, ReadAloud.modelVoices(for: language).map(\.key))
        })
        reading["modelSeconds"] = ModelReader.shared.debugSeconds
        reading["modelPace"] = ModelReader.shared.debugPace
        reading["speed"] = ReadAloud.speed
        reading["modelErrors"] = ReadAloud.shared.modelErrors
        reading["sample"] = SamplePlayer.shared.playing ?? ""
        out["readAloud"] = reading
        out["voiceModels"] = Dictionary(uniqueKeysWithValues: VoiceCatalog.models.map { voiceModel in
            (voiceModel.id, String(describing: VoiceLibrary.shared.state(voiceModel)))
        })
        let dictation = Dictation.shared
        out["dictation"] = [
            "phase": String(describing: dictation.phase), "level": dictation.level, "address": dictation.address ?? "",
            "problem": dictation.problem ?? "", "key": Dictation.key?.name ?? "none", "last": dictation.debugLast,
            "models": Dictionary(uniqueKeysWithValues: DictationCatalog.models.map { m in
                (m.id, String(describing: DictationLibrary.shared.state(m)))
            }),
        ] as [String: Any]
        out["updates"] = UpdateHooks.dump(model)
        let updates = ModelUpdates.shared
        out["modelUpdates"] = [
            "checking": updates.checking, "checkedAt": updates.checkedAt.map { $0.timeIntervalSince1970 } ?? 0,
            "checkError": updates.checkError ?? "", "failures": updates.failures.mapValues { [$0.said, $0.detail] },
            "steps": updates.steps.mapValues { String(describing: $0) },
            "available": updates.available.mapValues { update -> [String: Any] in
                ["revision": update.revision, "bytes": update.bytes, "files": update.files.map(\.path), "kept": update.kept.count,
                 "date": update.date.map { $0.timeIntervalSince1970 } ?? 0]
            },
            "revisions": Dictionary(uniqueKeysWithValues: (VoiceCatalog.models.map { (VoiceLibrary.key($0), VoiceLibrary.folder($0)) }
                    + DictationCatalog.models.map { (DictationLibrary.key($0), DictationLibrary.folder($0)) })
                .map { ($0.0, ModelFolder(url: $0.1).revision ?? "") }),
        ] as [String: Any]
        out["notifications"] = model.alerts.debugCenter
        out["resumeCommand"] = resumeCommand
        out["feeds"] = model.feeds.feeds.mapValues(\.debugState)
        out["paneModes"] = (model.view.paneModes ?? [:]).mapValues(\.rawValue)
        out["machines"] = model.machineItems.map { m -> [String: Any] in
            ["name": m.name, "title": m.title, "icon": m.icon, "key": model.lookKey(ofMachine: m.name),
             "collapsed": model.isCollapsed(m.name),
             "menu": describe(MenuEntry.menu(MachineHeader.entries(for: m, model: model)))]
        }
        out["collapsedMachines"] = (model.view.collapsedMachines ?? []).sorted()
        out["agentsCollapsed"] = model.agentsCollapsed
        out["spacesCollapsed"] = model.spacesCollapsed
        if let adder = model.addingMachine {
            out["addMachine"] = [
                "hosts": (adder.hosts ?? []).map { [$0.alias, $0.detail] },
                "typed": adder.typed,
                "steps": adder.steps.mapValues { step -> String in
                    switch step {
                    case .adding: "adding"
                    case .failed(let why, let answer): (answer ? "answer: " : "failed: ") + why
                    }
                },
                "waiting": Array(adder.waiting),
                "added": ((adder.hosts ?? []).map(\.alias) + adder.typed).filter { adder.isAdded($0, in: model) },
                "sheet": mainWindow?.attachedSheet != nil,
            ] as [String: Any]
        }
        out["agentGroups"] = model.agentGroups.map { group -> [String: Any] in
            ["attention": "\(group.attention)", "folded": model.isFolded(group),
             "agents": group.agents.map { a in
                 "\(a.address) \(a.statusMs ?? 0) " + (a.statusMs.map { ElapsedTime.text(since: $0, now: .now) } ?? "-")
             }]
        }
        out["agentRows"] = Dictionary(uniqueKeysWithValues: model.agentGroups.flatMap(\.agents).map { a in
            (a.address, ["logo": AgentRow.icon(of: a), "folder": AgentRow.folder(of: a), "subtitle": AgentRow.subtitle(of: a),
                         "help": a.status?.message ?? ""])
        })
        out["foldedAgentGroups"] = (model.view.foldedAgentGroups ?? []).sorted()
        out["expandedSpaces"] = (model.view.expandedSpaces ?? []).sorted()
        out["sidebarRows"] = sidebarRows()
        out["sidebarLists"] = sidebarLists()
        out["agentsShare"] = model.view.agentsShare ?? -1
        out["agentsPlace"] = model.prefs.agentsPlace.rawValue
        out["pointerOnSidebar"] = model.pointerOnSidebar
        out["keptDone"] = model.keptDone.sorted()
        out["selection"] = SidebarView.selectionKeys(model).sorted()
        out["headerViews"] = headerViews
        out["renaming"] = model.renaming.map { "\($0)" } ?? ""
        out["subtitle"] = model.activeSpace.map { model.title(ofMachine: $0.machine) } ?? ""
        out["claudePanes"] = model.prefs.claudePanes.rawValue
        out["agentPanes"] = Dictionary(uniqueKeysWithValues: ChatAgent.allCases.map { ($0.rawValue, model.prefs.panes(of: $0).rawValue) })
        out["usageSettings"] = Dictionary(uniqueKeysWithValues: ChatAgent.allCases.map { ($0.rawValue, model.prefs.usage(of: $0).plist) })
        out["statusLines"] = Dictionary(uniqueKeysWithValues: ChatAgent.allCases.map { ($0.rawValue, model.prefs.showsStatusLine(of: $0)) })
        // The limits Settings lists for each agent, in the person's order, and the plans.
        out["usageLimits"] = Dictionary(uniqueKeysWithValues: ChatAgent.allCases.map { agent in
            (agent.rawValue, model.prefs.usage(of: agent).arrange(model.usage.limits(of: agent), all: true).map(\.id))
        })
        out["usagePlans"] = Dictionary(uniqueKeysWithValues: ChatAgent.allCases.map { ($0.rawValue, model.usage.plans(of: $0)) })
        out["usageSeen"] = model.usage.seen.map { account, report -> String in
            let name: String = switch account {
            case .claude(let service, let folder): "claude \(service) \(folder)"
            case .codex(let home): "codex \(home)"
            }
            return "\(name): \(report.windows.map(\.id).joined(separator: " ")) \(report.plan ?? "")"
        }
        // What is known of each account's usage; never a sign-in.
        out["usage"] = model.usage.states.map { account, state -> [String: Any] in
            let name: String = switch account {
            case .claude(let service, let folder): "claude \(service) \(folder)"
            case .codex(let home): "codex \(home)"
            }
            return ["account": name, "checking": state.checking, "problem": state.problem.map { "\($0)" } ?? "",
                    "plan": state.report?.plan ?? "", "at": state.report.map { $0.at.formatted(.iso8601) } ?? "",
                    "windows": (state.report?.windows ?? []).map { "\($0.id) \($0.used) \($0.resetsAt.map { $0.formatted(.iso8601) } ?? "-")" }]
        }
        out["usageLog"] = model.usage.debugLog
        if let a = model.focusedAddress, let account = model.usage.account(of: a) {
            out["usageAccount"] = switch account {
            case .claude(let service, let folder): "claude \(service) \(folder)"
            case .codex(let home): "codex \(home)"
            }
        }
        if let a = model.focusedAddress, let feed = model.feeds.existing(a) {
            out["usageShown"] = UsageShown(feed: feed, model: model).map { shown -> [String: Any] in
                ["agent": shown.agent.rawValue, "windows": shown.windows(at: Date()).map(\.id), "problem": shown.state.problem.map { "\($0)" } ?? ""]
            } ?? [:]
        }
        out["showsTabBar"] = model.prefs.showsTabBar
        let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu
        out["viewMenuBefore"] = viewMenu.map(describe) ?? []
        // As when it opens: its delegate brings its items up to date then.
        if let viewMenu { viewMenu.delegate?.menuNeedsUpdate?(viewMenu) }
        out["viewMenu"] = viewMenu.map(describe) ?? []
        if let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu {
            editMenu.delegate?.menuNeedsUpdate?(editMenu)
            out["editMenu"] = describe(editMenu)
        }
        // Words selected in each conversation shown, the button over them; the passages in each field;
        // what the last passage brought back from a quote marked.
        out["quoteOffers"] = QuoteOffer.shownOffers.mapValues(\.debugState)
        out["draftQuotes"] = model.draftQuotes
        out["passageMark"] = PassageMark.debugLast
        out["actions"] = debugActions
        model.alerts.refreshDebugCenter()
        out["firstResponder"] = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? ""
        out["windowFirstResponder"] = mainWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? ""
        let url = tempFile("swiftr-debug.json")
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

/// For `hover-tab`: the tab row that acts as under the pointer. The real
/// pointer moves over a window in front and undoes `hover-at`.
@Observable
final class DebugHover {
    static let shared = DebugHover()
    /// The tab's id.
    var tab: String?
    /// The pointer is on that row's close button.
    var onClose = false
    /// While a row is held, the real pointer changes nothing.
    var holds: Bool { tab != nil }
}

/// A drop that no mouse made, for `move-row`: what a table asks of one.
private final class TestDrop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let writer: NSPasteboardWriting?
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(board: NSPasteboard, source: Any, window: NSWindow, location: NSPoint, writer: NSPasteboardWriting?) {
        draggingPasteboard = board
        draggingSource = source
        draggingDestinationWindow = window
        draggingLocation = location
        self.writer = writer
    }

    var draggingSourceOperationMask: NSDragOperation { [.move, .generic, .private] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 4242 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    // NSObject answers namesOfPromisedFilesDropped(atDestination:).
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}

    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void)
    {
        guard let writer else { return }
        var stop: ObjCBool = false
        block(NSDraggingItem(pasteboardWriter: writer), 0, &stop)
    }
}
#endif
