import Foundation
import Testing
@testable import HerdrKit

@Suite struct AgentAlertTests {
    @Test func needingYouAlwaysAlerts() {
        #expect(AgentAlert.on(previous: "working", next: "blocked", looking: true) == .needsYou)
        #expect(AgentAlert.on(previous: nil, next: "error", looking: false) == .needsYou)
        #expect(AgentAlert.on(previous: "blocked", next: "error", looking: false) == nil)
    }

    @Test func finishingAlertsOnlyWhenNotLooking() {
        #expect(AgentAlert.on(previous: "working", next: "idle", looking: false) == .finished)
        #expect(AgentAlert.on(previous: "blocked", next: "done", looking: false) == .finished)
        #expect(AgentAlert.on(previous: "working", next: "idle", looking: true) == nil)
        // Status cleared (the program ended) or never busy: no news.
        #expect(AgentAlert.on(previous: "working", next: nil, looking: false) == nil)
        #expect(AgentAlert.on(previous: "idle", next: "done", looking: false) == nil)
        #expect(AgentAlert.on(previous: nil, next: "working", looking: false) == nil)
    }
}

@Suite struct ClaudeTitleTests {
    @Test func dropsStatusMarks() {
        #expect(ClaudeTitle.clean("✳ Fix login") == "Fix login")
        #expect(ClaudeTitle.clean("✳️ Fix login") == "Fix login")
        #expect(ClaudeTitle.clean("⠂ Fix login") == "Fix login")
        #expect(ClaudeTitle.clean("· Fix login") == "Fix login")
        #expect(ClaudeTitle.clean("  SPFX-1454 · Missing Logos ") == "SPFX-1454 · Missing Logos")
    }

    @Test func defaultTitlesAreNotSessionTitles() {
        #expect(ClaudeTitle.clean("") == nil)
        #expect(ClaudeTitle.clean("✳ Claude Code") == nil)
        #expect(ClaudeTitle.clean("✳") == nil)
    }

    @Test func sessionTitleOfAnyAgent() {
        #expect(ClaudeTitle.session(reported: nil, terminal: "✳ Fix login") == "Fix login")
        #expect(ClaudeTitle.session(reported: "Review PR", terminal: "✳ Fix login") == "Review PR")
        #expect(ClaudeTitle.session(reported: "", terminal: "Fix @mention parsing") == "Fix @mention parsing")
        #expect(ClaudeTitle.session(reported: nil, terminal: "✳ Claude Code") == nil)
        // What the shell left in the title says nothing of the session.
        #expect(ClaudeTitle.session(reported: nil, terminal: "~/Projects/swiftr") == nil)
        #expect(ClaudeTitle.session(reported: nil, terminal: "/Users/me/x") == nil)
        #expect(ClaudeTitle.session(reported: nil, terminal: "me@mbp.local: ~/x") == nil)
    }
}

@Suite struct ProgramsTests {
    @Test func whatTheAgentReportsComesFirst() {
        #expect(Programs.key(app: "claude-code", argv: [], name: "") == "claude")
        #expect(Programs.key(app: "github-copilot", argv: ["node", "x"], name: "node") == "copilot")
        #expect(Programs.key(app: "Codex", argv: [], name: "") == "codex")
        #expect(Programs.key(app: "my-agent", argv: ["/opt/homebrew/bin/codex"], name: "codex") == "codex")
    }

    @Test func elseTheProgramItRuns() {
        // Claude's process takes its version as its name.
        #expect(Programs.key(app: nil, argv: ["/Users/me/.local/bin/claude", "--settings", "{}"], name: "2.1.316") == "claude")
        #expect(Programs.key(app: nil, argv: ["node", "/opt/homebrew/bin/codex"], name: "node") == "codex")
        #expect(Programs.key(app: nil, argv: ["env", "FOO=1", "gemini", "-p", "x"], name: "env") == "gemini")
        #expect(Programs.key(app: nil, argv: ["agy"], name: "agy") == "antigravity")
        #expect(Programs.key(app: nil, argv: [], name: "claude") == "claude")
        #expect(Programs.key(app: nil, argv: ["nvim", "README.md"], name: "nvim") == "nvim")
        #expect(Programs.key(app: nil, argv: ["vi"], name: "vi") == "vim")
        #expect(Programs.key(app: nil, argv: ["npx", "vite"], name: "node") == "vite")
        #expect(Programs.key(app: nil, argv: ["sudo", "apt", "update"], name: "sudo") == "apt")
        #expect(Programs.key(app: nil, argv: ["Rscript", "x.R"], name: "Rscript") == "R")
    }

    @Test func aScriptItDoesNotKnowShowsItsRunner() {
        #expect(Programs.key(app: nil, argv: ["python3", "-I", "/tmp/agent.py"], name: "python3") == "python")
        #expect(Programs.key(app: nil, argv: ["/opt/homebrew/bin/node", "server.js"], name: "node") == "node")
        #expect(Programs.key(app: nil, argv: ["env", "my-tool"], name: "env") == "program")
    }

    @Test func shellsAndTheRest() {
        #expect(Programs.key(app: nil, argv: ["/bin/zsh", "-l"], name: "zsh") == "shell")
        #expect(Programs.key(app: nil, argv: ["-zsh"], name: "zsh") == "shell")
        #expect(Programs.key(app: nil, argv: [], name: "") == "shell")
        #expect(Programs.key(app: nil, argv: ["./build-site"], name: "build-site") == "program")
    }

    @Test func agentsAreMarked() {
        #expect(Programs.isAgent("claude"))
        #expect(Programs.isAgent("agent"))
        #expect(!Programs.isAgent("python"))
        #expect(!Programs.isAgent("shell"))
        #expect(Programs.name("nvim") == "Neovim")
        // herdr-app's table, whole.
        #expect(Programs.all.count == 122)
    }
}

@Suite struct ResumableRunTests {
    let run = ResumableRun(agent: .claude, session: "s1", pid: 200, shell: 100, created: 1000)

    @Test func shellInFront() {
        #expect(run.check(foregroundName: "zsh", foregroundProgram: "zsh", foregroundPid: 100, created: 1000) == .agentQuit)
        #expect(run.check(foregroundName: "zsh", foregroundProgram: "-zsh", foregroundPid: 300, created: 1000) == .newShell)
        #expect(run.check(foregroundName: "zsh", foregroundProgram: "zsh", foregroundPid: 300, created: 2000) == .otherTerminal)
        #expect(run.check(foregroundName: "2.1.322", foregroundProgram: "claude", foregroundPid: 200, created: 1000) == .none)
        #expect(run.check(foregroundName: nil, foregroundProgram: nil, foregroundPid: nil, created: 1000) == .none)
    }

    @Test func fileFormat() throws {
        let text = #"{"t9":{"agent":"codex","session":"f12b","pid":56524,"shell":49718,"created":1793306182371}}"#
        let runs = try JSONDecoder().decode([String: ResumableRun].self, from: Data(text.utf8))
        #expect(runs["t9"] == ResumableRun(agent: .codex, session: "f12b", pid: 56524, shell: 49718, created: 1_793_306_182_371))
    }
}

@Suite struct ResumeTests {
    let uuid = "019a5b2c-1d2e-7f30-8a4b-5c6d7e8f9a0b"

    @Test func eachAgentHasItsCommand() {
        #expect(ResumableAgent.claude.resumeCommand(session: "abc-1") == "claude --resume abc-1")
        #expect(ResumableAgent.codex.resumeCommand(session: uuid) == "codex resume --no-daemon \(uuid)")
        #expect(ResumableAgent.opencode.resumeCommand(session: "ses_5f0a1b2c3d") == "opencode --session ses_5f0a1b2c3d")
        #expect(ResumableAgent.gemini.resumeCommand(session: uuid) == "gemini --resume \(uuid)")
    }

    @Test func noCommandForAnIDAShellWouldReadAsMore() {
        #expect(ResumableAgent.codex.resumeCommand(session: "x; rm -rf ~") == nil)
        #expect(ResumableAgent.opencode.resumeCommand(session: "$(id)") == nil)
        #expect(ResumableAgent.gemini.resumeCommand(session: "") == nil)
    }

    @Test func claudeKeepsOtherFamiliesAndEffort() {
        #expect(ResumableAgent.claudeCommand(session: "s", model: "claude-opus-5-5", effort: nil, defaultModel: "opus") == "claude --resume s")
        #expect(ResumableAgent.claudeCommand(session: "s", model: "claude-opus-5-5", effort: "max", defaultModel: "opus[1m]") == "claude --resume s --effort max")
        #expect(ResumableAgent.claudeCommand(session: "s", model: "claude-sonnet-5-5", effort: "high", defaultModel: nil)
            == "claude --resume s --model claude-sonnet-5-5 --effort high")
    }

    @Test func sessionFromArguments() {
        #expect(ResumableAgent.claude.resumedSession(["claude", "--resume", "abc"]) == "abc")
        #expect(ResumableAgent.claude.resumedSession(["claude", "-r", "abc", "--model", "x"]) == "abc")
        #expect(ResumableAgent.claude.resumedSession(["claude", "--resume=abc"]) == "abc")
        #expect(ResumableAgent.claude.resumedSession(["claude", "--resume"]) == nil)
        #expect(ResumableAgent.codex.resumedSession(["codex", "resume", "--no-daemon", uuid]) == uuid)
        #expect(ResumableAgent.codex.resumedSession(["codex", "resume", "--last"]) == nil)
        #expect(ResumableAgent.codex.resumedSession(["codex", "--no-daemon"]) == nil)
        #expect(ResumableAgent.opencode.resumedSession(["opencode", "--session", "ses_1"]) == "ses_1")
        #expect(ResumableAgent.opencode.resumedSession(["opencode", "-s", "ses_1"]) == "ses_1")
        #expect(ResumableAgent.gemini.resumedSession(["gemini", "--resume", uuid]) == uuid)
        #expect(ResumableAgent.gemini.resumedSession(["gemini", "-r", "latest"]) == nil)
        #expect(ResumableAgent.gemini.resumedSession(["gemini", "--resume=3"]) == nil)
    }

    @Test func geminiSessionIDFromTheChatsFirstLine() {
        let line = #"{"sessionId":"ce45542d-bca9-4f45-a640-d717a4454570","projectHash":"x","startTime":"2026-10-03T05:06:00Z","kind":"main"}"#
        #expect(GeminiFiles.sessionID(start: line) == "ce45542d-bca9-4f45-a640-d717a4454570")
        #expect(GeminiFiles.sessionID(start: #"{"id":"m1"}"#) == nil)
    }
}

@Suite struct ClosedTabTests {
    @Test func readsAndWritesTheStackFile() throws {
        let text = #"[{"machine":null,"space":"sp1","space_name":"Shop","tab":"5","cwd":"/x/shop","session":null,"closed_at":12}]"#
        let stack = try JSONDecoder().decode([ClosedTab].self, from: Data(text.utf8))
        #expect(stack.count == 1)
        #expect(stack[0].machine == nil && stack[0].session == nil && stack[0].closedAt == 12)
        #expect(stack[0].ownTabName == nil)
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stack)) as? [[String: Any]]
        #expect(back?[0]["machine"] is NSNull)
        #expect(back?[0]["space_name"] as? String == "Shop")
    }

    @Test func ownNames() {
        let t = ClosedTab(machine: "server", space: "server/sp1", spaceName: "shop", tab: "Fix login", cwd: "/x/shop/", session: "s", closedAt: 1)
        #expect(t.ownTabName == "Fix login")
        #expect(t.ownSpaceName == nil)
        var u = t
        u.spaceName = "Shop"
        #expect(u.ownSpaceName == "Shop")
    }

    @Test func aSessionKeptBeforeOtherAgentsIsClaudes() throws {
        let old = #"[{"machine":null,"space":"sp1","space_name":"","tab":"","cwd":"/x","session":"s1","closed_at":1}]"#
        #expect(try JSONDecoder().decode([ClosedTab].self, from: Data(old.utf8))[0].agent == .claude)
        let codex = ClosedTab(machine: nil, space: nil, spaceName: "", tab: "", cwd: "/x", session: "s2", agent: .codex, closedAt: 2)
        #expect(try JSONDecoder().decode(ClosedTab.self, from: JSONEncoder().encode(codex)) == codex)
    }

    @Test func picksTheTerminalWithASession() {
        let a = ClosedTab(machine: nil, space: "sp", spaceName: "", tab: "", cwd: "/a", session: nil, closedAt: 1)
        let b = ClosedTab(machine: nil, space: "sp", spaceName: "", tab: "", cwd: "/b", session: "s", closedAt: 1)
        let c = ClosedTab(machine: nil, space: "sp", spaceName: "", tab: "", cwd: "/c", session: nil, closedAt: 1)
        #expect(ClosedTab.pick([a, b, c]) == b)
        #expect(ClosedTab.pick([a, c]) == c)
    }
}
