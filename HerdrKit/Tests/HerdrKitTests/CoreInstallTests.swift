import Foundation
import Testing
@testable import HerdrKit

@Suite struct CoreInstallTests {
    @Test func installerComesFromTheReleaseServer() {
        #expect(CoreRelease.installerURL(environment: [:]).absoluteString == "https://releases.herdr.dev/core/install.sh")
        let moved = ["HERDR_RELEASES_URL": "http://127.0.0.1:8080//"]
        #expect(CoreRelease.installerURL(environment: moved).absoluteString == "http://127.0.0.1:8080/core/install.sh")
        #expect(CoreRelease.latestURL(environment: moved).absoluteString == "http://127.0.0.1:8080/core/latest.json")
    }

    @Test func hcIsLookedForWhereTheInstallerPutsIt() throws {
        let home = NSHomeDirectory()
        #expect(CoreEndpoint.hcCandidates(environment: [:]) == [
            "\(home)/.local/bin/hc", "\(home)/.local/bin/herdr-core", "/opt/homebrew/bin/hc", "/usr/local/bin/hc",
        ])

        let dir = FileManager.default.temporaryDirectory.appending(path: "hc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["HC_INSTALL_DIR": dir.path]
        #expect(CoreEndpoint.hcCandidates(environment: env) == ["\(dir.path)/hc", "\(dir.path)/herdr-core"])
        #expect(CoreEndpoint.installedHC(environment: env) == nil)

        // herdr-core alone: the installer left `hc` to another program.
        let core = dir.appending(path: "herdr-core")
        try Data("#!/bin/sh\n".utf8).write(to: core)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: core.path)
        #expect(CoreEndpoint.installedHC(environment: env) == core.path)

        let hc = dir.appending(path: "hc")
        try FileManager.default.createSymbolicLink(atPath: hc.path, withDestinationPath: "herdr-core")
        #expect(CoreEndpoint.installedHC(environment: env) == hc.path)
    }
}
