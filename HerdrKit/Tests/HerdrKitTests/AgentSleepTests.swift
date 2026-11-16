import Foundation
import Testing
@testable import HerdrKit

@Suite struct AgentSleepTests {
    private let id = "3f6c60ef-5ecc-485a-accf-2b3b41e81a17"

    private func sleeper(flags: [String] = []) -> SleepingAgent {
        SleepingAgent(agent: .claude, session: id, pid: 500, created: 42, sleptAt: 1000, flags: flags)
    }

    @Test func keepsOnlyPermissionFlags() {
        let argv = ["claude", "--settings", #"{"a":1}"#, "--resume", id, "--effort", "max", "--dangerously-skip-permissions", "fix the bug; rm -rf /"]
        #expect(SleepingAgent.keptFlags(argv) == ["--dangerously-skip-permissions"])
        #expect(SleepingAgent.keptFlags(["claude", "--permission-mode", "plan"]) == ["--permission-mode", "plan"])
        #expect(SleepingAgent.keptFlags(["claude", "--permission-mode=acceptEdits"]) == ["--permission-mode=acceptEdits"])
        #expect(SleepingAgent.keptFlags(["claude", "--permission-mode", "plan; ls"]) == [])
        #expect(SleepingAgent.keptFlags(["claude"]) == [])
        // The servers a session was given, as a shell wrapper passes them.
        #expect(SleepingAgent.keptFlags(["claude", "--mcp-config=/Users/me/.claude/mcp/rea.json", "--resume", id])
            == ["--mcp-config=/Users/me/.claude/mcp/rea.json"])
        #expect(SleepingAgent.keptFlags(["claude", "--mcp-config", "/tmp/a b.json", "--chrome"]) == ["--chrome"])
        #expect(SleepingAgent.keptFlags(["claude", "--mcp-config=$(rm -rf ~)"]) == [])
        #expect(SleepingAgent.keptFlags(["claude", "--add-dir", "../lib", "--settings", "{}"]) == ["--add-dir", "../lib"])
    }

    @Test func wakesOnTheSameConversation() {
        #expect(sleeper().wakeCommand() == "claude --resume \(id)")
        #expect(sleeper().wakeCommand(model: "claude-fable-5-2", effort: "max", defaultModel: "opus")
            == "claude --resume \(id) --model claude-fable-5-2 --effort max")
        #expect(sleeper(flags: ["--permission-mode", "plan"]).wakeCommand(effort: "high")
            == "claude --resume \(id) --effort high --permission-mode plan")
        // A file changed by hand types nothing of its own into the shell.
        #expect(sleeper(flags: ["--x; rm -rf ~"]).wakeCommand() == "claude --resume \(id)")
        var other = sleeper()
        other.session = "a b"
        #expect(other.wakeCommand() == nil)
    }

    @Test func tellsAsleepFromAwake() {
        // Still quitting: the same Claude in front.
        #expect(sleeper().check(agentInFront: true, foregroundPid: 500, created: 42) == .asleep)
        // Its shell is back.
        #expect(sleeper().check(agentInFront: false, foregroundPid: 400, created: 42) == .asleep)
        // The core made the terminal again: a new shell, the same terminal.
        #expect(sleeper().check(agentInFront: false, foregroundPid: 900, created: 42) == .asleep)
        // Someone started an agent there.
        #expect(sleeper().check(agentInFront: true, foregroundPid: 501, created: 42) == .awake)
        #expect(sleeper().check(agentInFront: false, foregroundPid: 400, created: 43) == .otherTerminal)
    }

    @Test func sleepsOnlyWhenNothingIsLost() {
        let now = Date(timeIntervalSince1970: 100_000)
        func facts(state: String? = "idle", ago: TimeInterval = 7200, visible: Bool = false, draft: Bool = false, commands: Bool = false) -> SleepRules.Facts {
            SleepRules.Facts(state: state, lastActive: now.addingTimeInterval(-ago), visible: visible, draft: draft, runsCommands: commands)
        }
        #expect(SleepRules.sleepsNow(facts(), after: 3600, now: now))
        #expect(SleepRules.sleepsNow(facts(state: "done"), after: 3600, now: now))
        #expect(SleepRules.sleepsNow(facts(state: nil), after: 3600, now: now))
        #expect(!SleepRules.sleepsNow(facts(), after: 0, now: now))
        #expect(!SleepRules.sleepsNow(facts(ago: 600), after: 3600, now: now))
        #expect(!SleepRules.sleepsNow(facts(state: "working"), after: 3600, now: now))
        #expect(!SleepRules.sleepsNow(facts(state: "blocked"), after: 3600, now: now))
        #expect(!SleepRules.sleepsNow(facts(visible: true), after: 3600, now: now))
        #expect(!SleepRules.sleepsNow(facts(draft: true), after: 3600, now: now))
        #expect(!SleepRules.sleepsNow(facts(commands: true), after: 3600, now: now))
    }

    @Test func keepsTheTimeItsRowShowed() throws {
        var kept = sleeper()
        #expect(kept.rowTime == 1_000_000)
        kept.lastActive = 42_000
        #expect(kept.rowTime == 42_000)
        // A record written before the time was kept still reads.
        let old = #"{"agent":"claude","session":"s","pid":1,"sleptAt":7,"flags":[]}"#
        #expect(try JSONDecoder().decode(SleepingAgent.self, from: Data(old.utf8)).rowTime == 7000)
    }

    @Test func saysHowLong() {
        #expect(SleepRules.duration(20) == "a moment")
        #expect(SleepRules.duration(20 * 60) == "20 min")
        #expect(SleepRules.duration(3 * 3600 + 120) == "3 h")
        #expect(SleepRules.duration(2 * 86400 + 5) == "2 d")
    }
}
