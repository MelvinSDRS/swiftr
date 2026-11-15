import Testing
@testable import HerdrKit

/// herdr-core updates: what latest.json says, releases in order, and what
/// `hc update` reports.
@Suite struct CoreReleaseTests {
    @Test func versionsCompareByPart() throws {
        let v = { (text: String) throws -> CoreVersion in try #require(CoreVersion(text)) }
        #expect(try v("0.1.21") > v("0.1.20"))
        #expect(try v("0.1.100") > v("0.1.21"))
        #expect(try v("1.0.0") > v("0.99.99"))
        #expect(try v("0.2") == v("0.2.0"))
        #expect(try v("hc 0.1.20") == v("0.1.20"))
        #expect(try v("hc 0.1.20").description == "0.1.20")
    }

    @Test func notAVersion() {
        #expect(CoreVersion("") == nil)
        #expect(CoreVersion("0..1") == nil)
        #expect(CoreVersion("latest") == nil)
    }

    @Test func latestJSONReads() throws {
        let json = try JSON(text: #"{"version":"0.1.21","generation":1,"notes":"**Bold.** More.","targets":{}}"#)
        #expect(CoreRelease(json: json) == CoreRelease(version: "0.1.21", generation: 1, notes: "**Bold.** More."))
        #expect(CoreRelease(json: try JSON(text: #"{"version":"0.2.0"}"#)) == CoreRelease(version: "0.2.0"))
        #expect(CoreRelease(json: try JSON(text: #"{"notes":"x"}"#)) == nil)
        #expect(CoreRelease(json: try JSON(text: #"{"version":"soon"}"#)) == nil)
    }

    @Test func releasesComeFromTheEnvironmentsServer() {
        #expect(CoreRelease.latestURL(environment: [:]).absoluteString == "https://releases.herdr.dev/core/latest.json")
        #expect(CoreRelease.latestURL(environment: ["HERDR_RELEASES_URL": ""]).absoluteString == "https://releases.herdr.dev/core/latest.json")
        #expect(CoreRelease.latestURL(environment: ["HERDR_RELEASES_URL": "http://127.0.0.1:8123/"]).absoluteString == "http://127.0.0.1:8123/core/latest.json")
    }

    @Test func whatUpdatesReport() {
        // What hc 0.1.20 printed for its update to 0.1.21.
        let real = CoreUpdateOutcome(output: #"{"now":"hc 0.1.21","path":"/h/.local/share/herdr-core/active/Herdr Core.app/Contents/MacOS/herdr-core","pid":74032,"release":"0.1.21","restarted":true,"was":"hc 0.1.20"}"#, status: 0)
        #expect(real.updated && real.restarted && real.release == "0.1.21" && real.error == nil)

        let done = CoreUpdateOutcome(output: #"{"now":"hc 0.1.21","release":"0.1.21","updated":true}"#, status: 0)
        #expect(done.updated && !done.restarted && done.release == "0.1.21" && done.error == nil)

        let same = CoreUpdateOutcome(output: "Downloading…\n" + #"{"now":"hc 0.1.20","release":"0.1.20","updated":false}"# + "\n", status: 0)
        #expect(!same.updated && same.release == "0.1.20" && same.error == nil)

        let restarted = CoreUpdateOutcome(output: #"{"now":"hc 0.1.21","restarted":true,"updated":false}"#, status: 0)
        #expect(restarted.restarted && restarted.release == "0.1.21")

        let refused = CoreUpdateOutcome(output: #"{"error":{"hint":"","kind":"refused","message":"/x is not a working hc"}}"#, status: 1)
        #expect(refused.error == CoreError(kind: "refused", message: "/x is not a working hc"))

        let hinted = CoreUpdateOutcome(output: #"{"error":{"hint":"brew upgrade herdr-core","kind":"managed","message":"Homebrew installed hc."}}"#, status: 1)
        #expect(hinted.error?.hint == "brew upgrade herdr-core")

        let crashed = CoreUpdateOutcome(output: "something broke\n\n", status: 2)
        #expect(crashed.error?.message == "something broke")
        #expect(CoreUpdateOutcome(output: "", status: 2).error?.message == "hc stopped with status 2.")
    }
}
