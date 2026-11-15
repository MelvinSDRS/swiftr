import Foundation
import HerdrKit
import Observation

/// Everything Swiftr updates, in one place: Swiftr itself, herdr-core on
/// this Mac and the other machines, and the downloaded models. It looks
/// for all of them when asked (Swiftr › Check for Updates…) and by itself
/// every few hours, and installs them when the person asks.
@Observable
final class UpdateCenter {
    static let hoursKey = "updateCheckHours"

    /// Swiftr's own updates.
    let app = AppUpdate()
    /// Hours between the looks Swiftr takes by itself; 0 for none.
    var hours: Int {
        didSet { UserDefaults.standard.set(hours, forKey: Self.hoursKey) }
    }
    /// When Swiftr last looked, asked or not.
    private(set) var checkedAt: Date?
    private(set) var checking = false
    /// Update All is at work.
    private(set) var updatingAll = false

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The last look had a failure: the next one comes sooner.
    @ObservationIgnored private var failed = false

    init(model: AppModel) {
        self.model = model
        hours = UpdateSchedule.hours(saved: UserDefaults.standard.object(forKey: Self.hoursKey) as? Int)
    }

    private var core: CoreUpdates { model.updates }
    private var models: ModelUpdates { .shared }

    // MARK: What's on offer

    /// The other machines whose herdr-core is older than this Mac's.
    var machines: [RemoteMachine] {
        model.remotes.filter { $0.isConnected && core.machineUpdate(from: $0.version) != nil }
    }

    /// The downloaded models with a newer version out.
    var modelOffers: [ModelUpdates.Target] {
        models.targets.filter { models.available[$0.key] != nil }
    }

    /// This Mac's herdr-core has a newer release to take.
    var coreOffer: String? {
        if case .update(let version) = core.offer { return version }
        return nil
    }

    /// How many things have an update to take.
    var count: Int {
        (app.canInstall ? 1 : 0) + (coreOffer == nil ? 0 : 1) + machines.count + modelOffers.count
    }

    /// An update runs somewhere.
    var busy: Bool {
        updatingAll || core.busy || models.busy || app.step == .updating || app.step == .restarting
    }

    // MARK: Checking

    func checkNow() {
        guard !checking else { return }
        Task { await check() }
    }

    /// Asks for all three at once, and returns once every answer is in.
    func check() async {
        guard !checking else {
            while checking { try? await Task.sleep(for: .milliseconds(100)) }
            return
        }
        checking = true
        async let swiftr: Void = app.check()
        async let herdr: Void = core.check()
        async let downloaded: Void = models.check()
        _ = await (swiftr, herdr, downloaded)
        failed = app.checkError != nil || core.checkError != nil || models.checkError != nil
        checkedAt = Date()
        checking = false
    }

    /// Starts the looks Swiftr takes by itself: one soon after launch, then
    /// one every `hours`.
    func start() {
        guard loop == nil else { return }
        app.start()
        loop = Task { [weak self] in
            // Once Swiftr is up and herdr-core answers.
            try? await Task.sleep(for: .seconds(Self.tick.first))
            while !Task.isCancelled {
                guard let self else { return }
                if self.isDue { await self.check() }
                try? await Task.sleep(for: .seconds(Self.tick.next))
            }
        }
    }

    private var isDue: Bool {
        guard hours > 0, !checking else { return false }
        #if DEBUG
        // Test builds look only when told how often, in seconds.
        guard let pace = Self.debugPace else { return false }
        return checkedAt.map { Date().timeIntervalSince($0) >= pace } ?? true
        #else
        // After a failure (no network, a server down), again in a quarter of an hour.
        if failed, let checkedAt { return Date().timeIntervalSince(checkedAt) >= 900 }
        return UpdateSchedule.isDue(last: checkedAt, every: hours)
        #endif
    }

    /// Seconds before the first look, and between two readings of the clock:
    /// the clock is read often, so a Mac that slept looks soon after it wakes.
    private static var tick: (first: Double, next: Double) {
        #if DEBUG
        if debugPace != nil { return (2, 1) }
        #endif
        return (15, 60)
    }

    #if DEBUG
    /// `SWIFTR_UPDATE_EVERY`: seconds between a test build's looks.
    private static let debugPace = ProcessInfo.processInfo.environment["SWIFTR_UPDATE_EVERY"].flatMap(Double.init)
    #endif

    // MARK: Updating

    /// Every update on offer: the models and herdr-core first, the other
    /// machines after this Mac (they take its herdr-core), and Swiftr last,
    /// since it quits to open its new version.
    func updateAll() {
        guard !updatingAll else { return }
        updatingAll = true
        Task {
            models.updateAll()
            if coreOffer != nil {
                core.updateThisMac()
                await until { !self.core.busy }
                // The core restarted: its machines connect again.
                await until(atMost: 30) { self.model.machinesKnown && !self.model.remotes.contains { $0.state == "connecting" } }
            }
            // A failed update of this Mac leaves the machines as they are.
            if core.steps[""] == nil {
                for machine in machines {
                    core.update(machine: machine.name)
                    await until { !self.core.busy }
                }
            }
            await until { !self.models.busy }
            updatingAll = false
            if app.canInstall { app.install() }
        }
    }

    private func until(atMost seconds: Double = .infinity, _ done: () -> Bool) async {
        let start = Date()
        while !done(), Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
}
