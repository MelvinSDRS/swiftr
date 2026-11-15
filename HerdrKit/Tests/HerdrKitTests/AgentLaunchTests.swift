import Foundation
import Testing
@testable import HerdrKit

@Suite struct AgentLaunchTests {
    @Test func theAgentsAMenuOffersAreHerdrAppsWithRun() {
        #expect(Programs.startable.map(\.key) == [
            "claude", "codex", "pi", "pig", "opencode", "cursor", "copilot", "amp", "grok", "dsh-tui",
            "antigravity", "kimi", "kiro", "hermes", "qoder", "crush", "gemini",
        ])
        #expect(Programs.startable("codex")?.run == ["codex", "--no-daemon"])
        #expect(Programs.startable("antigravity")?.run == ["agy"])
        // Known by sight, but with no way to start them.
        #expect(Programs.startable("mastracode") == nil)
        #expect(Programs.startable("shell") == nil)
    }

    @Test func onThisMacTheLoginShellRunsItThenStays() {
        // What herdr-app gave a Claude it started (hc get t4s, 2026-11-11).
        #expect(AgentLaunch.start(["claude"], shell: "/bin/zsh") == ["/bin/zsh", "-lic", #""$@"; exec "$0" -li"#, "/bin/zsh", "claude"])
        #expect(AgentLaunch.start(["codex", "--no-daemon"], shell: "/opt/homebrew/bin/fish")
            == ["/opt/homebrew/bin/fish", "-lic", "command $argv[2..]; exec $argv[1] -li", "/opt/homebrew/bin/fish", "codex", "--no-daemon"])
        #expect(AgentLaunch.start(["claude"], shell: "/usr/local/bin/nu") == ["/bin/sh", "-c", #""$@"; exec "${SHELL:-sh}" -i"#, "sh", "claude"])
    }

    @Test func onAnotherMachineShPicksItsShell() {
        // What herdr-app gave a Claude it started on another machine (hc get <machine>/t7, 2026-11-11).
        let script = "shell=${SHELL:-/bin/sh}\ncase \"${shell##*/}\" in\n  fish) exec \"$shell\" -lic 'command $argv[2..]; exec $argv[1] -li' \"$shell\" \"$@\" ;;\n  sh|bash|zsh|dash|ksh) exec \"$shell\" -lic '\"$@\"; exec \"$0\" -li' \"$shell\" \"$@\" ;;\n  *) exec sh -c '\"$@\"; exec \"${SHELL:-sh}\" -i' sh \"$@\" ;;\nesac"
        #expect(AgentLaunch.start(["claude"], shell: nil) == ["sh", "-c", script, "sh", "claude"])
    }

    @Test func aCheckCountsOnlyOnceItEnded() {
        let output = "Last login: today\nherdr-has:claude\n\u{1b}]7;file://x\u{07}\nherdr-has:codex\n\nherdr-check-complete\n"
        #expect(AgentLaunch.installed(in: output) == ["claude", "codex"])
        #expect(AgentLaunch.installed(in: "\nherdr-check-complete\n") == [])
        // An rc file that exits, a shell killed on the way: no answer, not "none".
        #expect(AgentLaunch.installed(in: "herdr-has:claude\n") == nil)
    }

    @Test func theScriptsRunInSh() throws {
        // Another machine whose shell is sh: the quoting inside the script holds.
        let check = try run(AgentLaunch.check(["sh", "no-such-program-swiftr"], shell: nil))
        #expect(AgentLaunch.installed(in: check) == ["sh"])
        let start = try run(AgentLaunch.start(["printf", "%s-%s\\n", "it's", "started"], shell: nil))
        #expect(start.contains("it's-started"))
    }

    /// Runs `argv` with sh as the login shell and nothing to read, and
    /// returns what it printed.
    private func run(_ argv: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/env")
        p.arguments = argv
        p.environment = ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
