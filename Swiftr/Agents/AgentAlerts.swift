import AppKit
import Observation
import HerdrKit
import UserNotifications

/// Tells the person when an agent needs them, or finished while they weren't
/// looking (herdr-app's rule, `AgentAlert`): a sound, and a notification that
/// leads to the agent's pane. herdr-app does the same with its own sounds and
/// toasts: while it runs with its sounds on, Swiftr plays none; while it is in
/// front, Swiftr posts nothing.
@MainActor @Observable
final class AgentAlerts: NSObject, UNUserNotificationCenterDelegate {
    /// What macOS allows Swiftr: nil until known.
    private(set) var permission: UNAuthorizationStatus?

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var asked = false
    /// Terminals with a notification on screen.
    @ObservationIgnored private var posted: Set<String> = []

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func start() {
        center.delegate = self
        askPermission()
        // Notices left by an earlier run go when their terminal is looked at.
        center.getDeliveredNotifications { list in
            let ids = list.map(\.request.identifier)
            onMain { self.posted.formUnion(ids) }
        }
    }

    /// The first time notifications are on, macOS asks the person.
    func askPermission() {
        guard model.prefs.agentNotifications, !asked else {
            refreshPermission()
            return
        }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            onMain { self.refreshPermission() }
        }
    }

    func refreshPermission() {
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            onMain { if self.permission != status { self.permission = status } }
        }
    }

    /// System Settings, at Swiftr's notifications.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// An agent's status word changed (a `status` event, already applied).
    func statusChanged(_ address: String, previous: JSON?) {
        guard let m = model.store.model(address), m.isLive else { return }
        let before = AgentStatus(json: previous?["status"])?.state
        let now = m.status?.state
        // Back at work: a notice that it waited or finished is old news.
        if now == "working" { withdraw([address]) }
        // A sub-agent tells through its parent; a terminal without a pane isn't shown.
        if let parent = m.parent, !parent.isEmpty { return }
        guard model.place(of: address) != nil else { return }
        let looking = model.isLooking(at: address)
        guard let alert = AgentAlert.on(previous: before, next: now, looking: looking) else { return }
        let sound = !herdrAppPlaysSounds
        let notify = !looking && model.prefs.agentNotifications && !herdrAppInFront
        #if DEBUG
        debugLog.append("\(alert) \(address) looking=\(looking) sound=\(sound) notify=\(notify)\(Self.quiet ? " quiet" : "")")
        // A test build's notices would pass for the installed app's.
        if Self.quiet { return }
        #endif
        if sound { play(alert) }
        if notify { post(alert, about: m) }
    }

    #if DEBUG
    /// Launched with `SWIFTR_QUIET=1`: decides as usual, plays and posts nothing.
    static let quiet = ProcessInfo.processInfo.environment["SWIFTR_QUIET"] == "1"
    #endif

    #if DEBUG
    /// Decisions and posting errors, for the debug dump.
    @ObservationIgnored var debugLog: [String] = []
    /// What macOS allows, and the notifications on screen.
    @ObservationIgnored var debugCenter: [String: Any] = [:]

    func refreshDebugCenter() {
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus.rawValue
            let alert = settings.alertSetting.rawValue
            onMain { self.debugCenter["authorization"] = status; self.debugCenter["alertSetting"] = alert }
        }
        center.getDeliveredNotifications { list in
            let shown = list.map { "\($0.request.identifier): \($0.request.content.title) — \($0.request.content.subtitle)" }
            onMain { self.debugCenter["delivered"] = shown }
        }
    }
    #endif

    /// The person looks at these terminals: their notifications can go.
    func looked(at addresses: [String]) {
        withdraw(addresses.filter(posted.contains))
    }

    func play(_ alert: AgentAlert) {
        let name = alert == .needsYou ? model.prefs.needsYouSound : model.prefs.finishedSound
        guard !name.isEmpty else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func post(_ alert: AgentAlert, about m: TerminalModel) {
        let content = UNMutableNotificationContent()
        let who = Self.agentName(m)
        content.title = alert == .needsYou ? "\(who) needs you" : "\(who) is done"
        if let p = model.place(of: m.address) {
            content.subtitle = "\(model.title(of: p.space)) / \(model.title(of: p.tab, index: p.index))"
        }
        if let message = m.status?.message, !message.isEmpty { content.body = message }
        content.userInfo = ["address": m.address]
        content.threadIdentifier = m.address
        // One notice per terminal: a new one takes the old one's place.
        #if DEBUG
        let address = m.address
        center.add(UNNotificationRequest(identifier: address, content: content, trigger: nil)) { error in
            if let error { onMain { self.debugLog.append("post \(address): \(error.localizedDescription)") } }
        }
        #else
        center.add(UNNotificationRequest(identifier: m.address, content: content, trigger: nil))
        #endif
        posted.insert(m.address)
    }

    private func withdraw(_ addresses: [String]) {
        guard !addresses.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: addresses)
        posted.subtract(addresses)
    }

    static func agentName(_ m: TerminalModel) -> String {
        if let name = m.name, !name.isEmpty { return name }
        switch m.status?.app ?? "" {
        case "claude-code", "claude": return "Claude"
        case "codex": return "Codex"
        case "": return m.isClaude ? "Claude" : "An agent"
        case let app: return app.prefix(1).uppercased() + app.dropFirst()
        }
    }

    // MARK: herdr-app

    private var herdrAppInFront: Bool {
        model.herdrAppRunning && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == AppModel.herdrAppID
    }

    /// herdr-app runs and plays its sounds (settings.json `sounds.enabled`).
    private var herdrAppPlaysSounds: Bool {
        guard model.herdrAppRunning else { return false }
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/herdr-app/settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sounds = settings["sounds"] as? [String: Any]
        else { return true }
        return sounds["enabled"] as? Bool ?? true
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let address = response.notification.request.content.userInfo["address"] as? String else { return }
        await MainActor.run {
            model.show(address)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
