import Foundation
import Testing
@testable import HerdrKit

/// Swiftr's own updates: whether Homebrew installed this copy, what brew
/// says when it fails, and when Swiftr looks by itself.
@Suite struct AppUpdatesTests {
    /// A made-up Homebrew: `<root>/brew` with an executable brew, and an
    /// app in `<root>/Applications`.
    private func stage() throws -> (root: URL, app: URL) {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "swiftr-brew-\(UUID().uuidString)")
        let app = root.appending(path: "Applications/Swiftr.app")
        try manager.createDirectory(at: app, withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appending(path: "brew/bin"), withIntermediateDirectories: true)
        let brew = root.appending(path: "brew/bin/brew")
        try Data("#!/bin/sh\n".utf8).write(to: brew)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        return (root, app)
    }

    private func link(_ app: URL, in root: URL, token: String = "swiftr", version: String = "0.1.1") throws {
        let folder = root.appending(path: "brew/Caskroom/\(token)/\(version)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: app.lastPathComponent).path, withDestinationPath: app.path)
    }

    @Test func homebrewOwnsTheAppItLinksTo() throws {
        let (root, app) = try stage()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "brew").path
        #expect(HomebrewCask.owning(app: app, token: "swiftr", prefixes: [prefix]) == nil)
        try link(app, in: root)
        #expect(HomebrewCask.owning(app: app, token: "swiftr", prefixes: [prefix]) == HomebrewCask(token: "swiftr", brew: prefix + "/bin/brew"))
        // Another prefix first, with nothing in it.
        #expect(HomebrewCask.owning(app: app, token: "swiftr", prefixes: [root.appending(path: "none").path, prefix])?.brew == prefix + "/bin/brew")
    }

    @Test func aCopyElsewhereIsNotHomebrews() throws {
        let (root, app) = try stage()
        defer { try? FileManager.default.removeItem(at: root) }
        try link(app, in: root)
        let prefix = root.appending(path: "brew").path
        // Built from source into another folder, while a cask is installed too.
        let other = root.appending(path: "Home/Applications/Swiftr.app")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(HomebrewCask.owning(app: other, token: "swiftr", prefixes: [prefix]) == nil)
        // Another cask's link.
        #expect(HomebrewCask.owning(app: app, token: "other", prefixes: [prefix]) == nil)
    }

    @Test func noBrewNoCask() throws {
        let (root, app) = try stage()
        defer { try? FileManager.default.removeItem(at: root) }
        try link(app, in: root)
        try FileManager.default.removeItem(at: root.appending(path: "brew/bin/brew"))
        #expect(HomebrewCask.owning(app: app, token: "swiftr", prefixes: [root.appending(path: "brew").path]) == nil)
    }

    @Test func brewUpgradesTheCaskAfterAnUpdate() {
        #expect(HomebrewCask(token: "swiftr", brew: "/opt/homebrew/bin/brew").commands == [["update", "--quiet"], ["upgrade", "--cask", "swiftr"]])
    }

    @Test func whyBrewFailed() {
        #expect(HomebrewCask.problem(in: "==> Upgrading 1 outdated package\nError: swiftr: Failure while executing; `/usr/bin/sudo` exited with 1.\n") == "swiftr: Failure while executing; `/usr/bin/sudo` exited with 1.")
        #expect(HomebrewCask.problem(in: "fatal: unable to access the tap\n\n") == "fatal: unable to access the tap")
        #expect(HomebrewCask.problem(in: "") == "brew gave no reason.")
    }

    @Test func looksEverySoManyHours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateSchedule.isDue(last: nil, every: 6, now: now))
        #expect(!UpdateSchedule.isDue(last: now.addingTimeInterval(-5 * 3600), every: 6, now: now))
        #expect(UpdateSchedule.isDue(last: now.addingTimeInterval(-6 * 3600), every: 6, now: now))
        #expect(UpdateSchedule.isDue(last: now.addingTimeInterval(-3600), every: 1, now: now))
        // Never.
        #expect(!UpdateSchedule.isDue(last: nil, every: 0, now: now))
        // The clock went back past the last look.
        #expect(UpdateSchedule.isDue(last: now.addingTimeInterval(3600), every: 6, now: now))
    }

    @Test func savedHours() {
        #expect(UpdateSchedule.hours(saved: nil) == 6)
        #expect(UpdateSchedule.hours(saved: 0) == 0)
        #expect(UpdateSchedule.hours(saved: -3) == 0)
        #expect(UpdateSchedule.hours(saved: 12) == 12)
        #expect(UpdateSchedule.choices.contains(UpdateSchedule.standard))
    }

    @Test func paceInWords() {
        #expect(UpdateSchedule.label(hours: 0) == "Never")
        #expect(UpdateSchedule.label(hours: 1) == "Every hour")
        #expect(UpdateSchedule.label(hours: 6) == "Every 6 hours")
        #expect(UpdateSchedule.label(hours: 24) == "Every day")
    }
}
