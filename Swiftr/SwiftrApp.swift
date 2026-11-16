import AppKit
import HerdrKit
import SwiftUI

/// Swiftr starts as the app, or as one of its helpers when Swiftr itself
/// starts it with `VoiceHelper.flag` or `DictationHelper.flag`.
@main
enum Launch {
    static func main() {
        switch CommandLine.arguments.dropFirst().first {
        case VoiceHelper.flag: VoiceHelper.run()
        case DictationHelper.flag: DictationHelper.run()
        default: break
        }
        #if DEBUG
        AppUpdate.quitIfTestRelaunch()
        #endif
        // Thin scroll bars that float over the content and fade, even with a
        // mouse. Under "Show scroll bars: Automatically", macOS gives a mouse
        // user wide ones that stay and take 15 points from every list, and
        // SwiftUI sets that style back on each update of a list. A value
        // System Settings has stored still wins over this one.
        UserDefaults.standard.register(defaults: ["AppleShowScrollBars": "WhenScrolling"])
        SwiftrApp.main()
    }
}

struct SwiftrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Swiftr", id: "main") {
            MainView()
                .environment(model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1300, height: 820)
        .commands { SwiftrCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet { Dictation.shared.model = model }
    }
    private var monitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the window shows, so it opens light or dark as set.
        Appearance.saved.apply()
        // Pictures taken out of conversations, to show them there: in a
        // folder of this run's own, gone when the app quits.
        let pictures = URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Swiftr", directoryHint: .isDirectory)
            .appending(path: "Pictures", directoryHint: .isDirectory)
        TranscriptImage.folder = TranscriptImage.runFolder(in: pictures)
        DispatchQueue.global(qos: .utility).async { TranscriptImage.removeLeftovers(in: pictures) }
        // JetBrains Mono, the default terminal font, ships inside the app.
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconStyle.saved.apply()
        NSWindow.allowsAutomaticWindowTabbing = false
        // The key held to dictate (Settings › Dictation).
        if SpeechModels.supported { DictationKeys.shared.install() }
        // Before menus and terminals see them: ⌘W closes a tab, not the
        // window, and ⌃⇥ moves between tabs even inside a terminal.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let model = self?.model else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            // ⌥⌘T starts the first favorite agent, whichever window is in
            // front: the File menu item that shows it hears of a change of
            // favorites only when the menu opens.
            if flags == [.command, .option], event.charactersIgnoringModifiers?.lowercased() == "t" {
                if let agent = model.prefs.favoriteAgents.lazy.compactMap({ Programs.startable($0) }).first {
                    model.newTab(agent: agent)
                } else {
                    NSSound.beep()
                }
                return nil
            }
            guard Self.isMainWindow(NSApp.keyWindow) else { return event }
            // ⌘← ⌘⌫ ⌥⌦…: a terminal's line edits as a text field's would.
            if let terminal = NSApp.keyWindow?.firstResponder as? SwiftrTerminalView, terminal.takeLineKey(event) {
                return nil
            }
            if event.keyCode == 48, flags == .control || flags == [.control, .shift] {
                model.selectNeighborTab(flags.contains(.shift) ? -1 : 1)
                return nil
            }
            if flags == .command, event.charactersIgnoringModifiers == "w" {
                model.closeTab()
                return nil
            }
            return event
        }
    }

    static func isMainWindow(_ window: NSWindow?) -> Bool {
        guard let window, window.sheetParent == nil else { return false }
        return window.identifier?.rawValue.hasPrefix("main") == true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // This run's pictures: the next run takes them out of the transcripts again.
        try? FileManager.default.removeItem(at: TranscriptImage.folder)
    }
}

struct SwiftrCommands: Commands {
    let model: AppModel

    private func find(_ what: String) {
        NotificationCenter.default.post(name: .swiftrFind, object: model.focusedAddress, userInfo: ["do": what])
    }

    private static func function(_ n: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt32(NSF1FunctionKey + n - 1))!))
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            // Swiftr itself, herdr-core and the models: the Updates pane.
            CheckForUpdatesButton(model: model)
            Button("Welcome to Swiftr…") { model.showOnboarding() }
                .disabled(model.onboarding != nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model.newTab() }
                .keyboardShortcut("t")
            // AppDelegate handles ⌥⌘T itself; this shows it.
            ForEach(Array(model.prefs.favoriteAgents.compactMap { Programs.startable($0) }.enumerated()), id: \.element.key) { i, agent in
                Button("New \(agent.name) Tab") { model.newTab(agent: agent) }
                    .keyboardShortcut(i == 0 ? KeyboardShortcut("t", modifiers: [.command, .option]) : nil)
            }
            Button("New Space") { model.newSpace(on: model.activeSpace?.machine ?? "") }
                .keyboardShortcut("n")
            Button("Reopen Closed Tab") { model.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Menu("New Space On") {
                ForEach(model.machineItems.filter(\.isConnected)) { machine in
                    Button(machine.title) { model.newSpace(on: machine.name) }
                }
            }
            // What the + on the sidebar's Spaces title opens.
            Button("Add Machine…") { model.addingMachine = MachineAdder() }
                .disabled(model.link != .connected || model.addingMachine != nil)
            Divider()
            Button("Close Tab") { model.closeTab() }
                .keyboardShortcut("w")
            Button("Close Pane") { model.closePane() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Rename Tab…") { model.startRenamingTab() }
                .keyboardShortcut(Self.function(2), modifiers: [])
            Button("Rename Space…") { model.startRenamingSpace() }
                .keyboardShortcut(Self.function(2), modifiers: [.shift])
        }

        CommandGroup(after: .textEditing) {
            // Find in the conversation of a pane shown as Messages.
            let messages = model.focusedAddress.map(model.showsMessages) == true
            Button("Find in Conversation…") { find("open") }
                .keyboardShortcut("f")
                .disabled(!messages)
            Button("Find Next") { find("next") }
                .keyboardShortcut("g")
                .disabled(!messages)
            Button("Find Previous") { find("previous") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!messages)
        }

        CommandMenu("Pane") {
            Button("Split Right") { model.split(.row) }
                .keyboardShortcut("d")
            Button("Split Down") { model.split(.column) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Zoom Pane") { model.toggleZoom() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button(model.focusedAddress.map(model.showsMessages) == true ? "Show Terminal" : "Show Messages") { model.toggleMessages() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!model.focusedRunsClaude)
            // An agent asleep holds no memory; it starts again on its conversation.
            if let focused = model.focusedAddress, model.sleepers.isAsleep(focused) {
                Button("Wake Agent") { model.sleepers.wake(focused) }
            } else {
                Button("Sleep Agent") { model.focusedAddress.map { model.sleepers.sleep([$0]) } }
                    .disabled(model.focusedAddress.map(model.sleepers.canSleep) != true)
            }
            Button("Sleep Idle Agents") { model.sleepers.sleepIdle() }
            Divider()
            Button("Select Pane Left") { model.moveFocus(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Select Pane Right") { model.moveFocus(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Select Pane Above") { model.moveFocus(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Select Pane Below") { model.moveFocus(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { model.view.sidebarVisible.toggle() }
                .keyboardShortcut("b")
            // As in the Finder, without its ⇧⌘T: here that reopens a closed tab.
            Button(model.prefs.showsTabBar ? "Hide Tab Bar" : "Show Tab Bar") { model.prefs.showsTabBar.toggle() }
            Divider()
            Button("Make Text Bigger") { model.prefs.zoom(by: 1) }
                .keyboardShortcut("=")
            Button("Make Text Smaller") { model.prefs.zoom(by: -1) }
                .keyboardShortcut("-")
            Button("Actual Size") { model.prefs.resetZoom() }
                .keyboardShortcut("0")
        }

        CommandMenu("Go") {
            Button("Next Tab") { model.selectNeighborTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { model.selectNeighborTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Space") { model.selectNeighborSpace(1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Previous Space") { model.selectNeighborSpace(-1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Divider()
            ForEach(1 ..< 10) { n in
                Button("Tab \(n)") { model.selectTab(at: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Divider()
            ForEach(1 ..< 10) { n in
                Button("Space \(n)") { model.selectSpace(at: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .control)
            }
        }
    }
}
