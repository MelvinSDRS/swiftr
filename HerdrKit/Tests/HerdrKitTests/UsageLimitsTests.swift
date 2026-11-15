import Foundation
import Testing
@testable import HerdrKit

/// Agents' usage limits: Claude's usage endpoint, Codex's rate limits,
/// Gemini's quota, and how each window goes.
@Suite struct UsageLimitsTests {
    /// The shape Anthropic's endpoint answers in (2026-11), with a model's
    /// own week in `limits` and dates to the microsecond.
    static let claudeReply = #"""
    {"five_hour":{"utilization":55.0,"resets_at":"2026-11-14T00:00:00.398235+00:00","limit_dollars":null},
     "seven_day":{"utilization":88.0,"resets_at":"2026-11-18T03:00:00.381474+00:00"},
     "seven_day_oauth_apps":null,
     "seven_day_opus":{"utilization":0.0,"resets_at":null},
     "seven_day_sonnet":{"utilization":4.0,"resets_at":"2026-11-18T03:00:00+00:00"},
     "cinder_cove":null,
     "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1234,"utilization":24.68},
     "limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":12,"resets_at":"2026-11-18T03:00:00Z"},
               {"kind":"five_hour","percent":55},
               {"kind":"weekly_scoped","scope":{"model":{"display_name":"Opus"}},"percent":3,"resets_at":"2026-11-18T03:00:00Z"},
               {"kind":"weekly_scoped","scope":{"model":{"display_name":"Sonnet"}},"percent":5,"resets_at":"2026-11-18T03:00:00Z"}]}
    """#

    /// Only the limits `/usage` lists: no Opus week, Sonnet's week on Max and
    /// Team plans only, from its own key.
    @Test func claudeReplyReads() throws {
        let data = Data(Self.claudeReply.utf8)
        let windows = try #require(ClaudeUsage.windows(fromReply: data, subscription: "max"))
        #expect(windows.map(\.id) == ["session", "weekly", "model:sonnet", "model:fable", "credits"])
        #expect(windows.map(\.title) == ["Session", "Weekly", "Sonnet", "Fable", "Usage credits"])
        #expect(windows[0].used == 55 && windows[0].left == 45)
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_794_614_400))
        #expect(windows[0].length == TimeInterval(5 * 3600))
        #expect(windows[2].used == 4)
        #expect(windows[3].used == 12)
        #expect(windows[3].length == TimeInterval(7 * 24 * 3600))
        #expect(windows[4].resetsAt == nil && windows[4].isCredit && !windows[3].isCredit)
        let pro = try #require(ClaudeUsage.windows(fromReply: data, subscription: "pro"))
        #expect(pro.map(\.id) == ["session", "weekly", "model:fable", "credits"])
        // Without a plan, as Claude Code does: Sonnet's week if the reply has it.
        #expect(ClaudeUsage.windows(fromReply: data)?.map(\.id) == ["session", "weekly", "model:sonnet", "model:fable", "credits"])
    }

    @Test func claudeLimitsThePlanHasNot() throws {
        // Empty, or without a number: not a limit of this plan.
        let older = #"{"five_hour":{"utilization":2.0,"resets_at":"2026-11-13T23:00:00.381452+00:00"},"seven_day":null,"seven_day_opus":{"utilization":30,"resets_at":null},"seven_day_sonnet":{"utilization":null,"resets_at":null},"extra_usage":{"is_enabled":false,"utilization":null}}"#
        let windows = try #require(ClaudeUsage.windows(fromReply: Data(older.utf8), subscription: "max"))
        #expect(windows.map(\.id) == ["session"])
        #expect(ClaudeUsage.windows(fromReply: Data(#"{"error":{"type":"authentication_error"}}"#.utf8)) == nil)
        #expect(ClaudeUsage.windows(fromReply: Data("<html>".utf8)) == nil)
        #expect(ClaudeUsage.windows(fromReply: Data(#"{"limits":[]}"#.utf8)) == [])
    }

    @Test func claudeCredits() throws {
        let reply = #"""
        {"five_hour":{"utilization":10,"resets_at":null},
         "cinder_cove":{"utilization":40,"resets_at":"2026-12-01T00:00:00Z"},
         "wattle_ember":{"utilization":5,"resets_at":null,"label":"  Launch credit "},
         "promo_credits":[{"program_id":"spring","label":"Spring credit","utilization":20,"resets_at":null},
                          {"program_id":"model_promo_fable","label":"Fable promo","utilization":1,"resets_at":null},
                          {"program_id":"","label":"No id","utilization":1}],
         "extra_usage":{"is_enabled":true,"monthly_limit":200,"used_credits":50,"utilization":null}}
        """#
        let windows = try #require(ClaudeUsage.windows(fromReply: Data(reply.utf8), subscription: "pro"))
        #expect(windows.map(\.id) == ["session", "credit:cinder_cove", "credit:wattle_ember", "promo:spring", "credits"])
        #expect(windows.map(\.title) == ["Session", "Claude Code and Cowork credit", "Launch credit", "Spring credit", "Usage credits"])
        #expect(windows[4].used == 25)
        #expect(windows.dropFirst().allSatisfy { $0.isCredit })
    }

    @Test func keychainEntryPerAccount() {
        #expect(ClaudeUsage.keychainService(environment: [:]) == "Claude Code-credentials")
        #expect(ClaudeUsage.keychainService(environment: ["CLAUDE_CONFIG_DIR": ""]) == "Claude Code-credentials")
        #expect(ClaudeUsage.keychainService(environment: ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-swap-backup/sessions/2-me_example.com"])
            == "Claude Code-credentials-a63d0b3b")
        // The folder's name in its composed form, whatever form it came in.
        #expect(ClaudeUsage.keychainService(environment: ["CLAUDE_CONFIG_DIR": "/Users/me/Cafe\u{301}"]) == "Claude Code-credentials-63a76eb4")
        // Its own folder for the Keychain wins; empty, it means the default entry.
        #expect(ClaudeUsage.keychainService(environment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": "/Users/me/Café", "CLAUDE_CONFIG_DIR": "/x"])
            == "Claude Code-credentials-63a76eb4")
        #expect(ClaudeUsage.keychainService(environment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": "", "CLAUDE_CONFIG_DIR": "/x"]) == "Claude Code-credentials")
        #expect(ClaudeUsage.configFolder(environment: [:], home: "/Users/me") == "/Users/me/.claude")
        #expect(ClaudeUsage.configFolder(environment: ["CLAUDE_CONFIG_DIR": "/x/y"], home: "/Users/me") == "/x/y")
    }

    @Test func signInReads() throws {
        let saved = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1794620000000,"scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#
        let signIn = try #require(ClaudeUsage.signIn(fromCredentials: Data(saved.utf8)))
        #expect(signIn.token == "tok")
        #expect(signIn.plan == "Max 20x" && signIn.subscription == "max")
        #expect(signIn.expires == Date(timeIntervalSince1970: 1_794_620_000))
        #expect(signIn.expired(at: Date(timeIntervalSince1970: 1_794_620_001)))
        #expect(!signIn.expired(at: Date(timeIntervalSince1970: 1_794_610_000)))
        #expect(ClaudeUsage.signIn(fromCredentials: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)) == nil)
        #expect(ClaudeUsage.signIn(fromCredentials: Data("x".utf8)) == nil)
        #expect(ClaudeUsage.plan(subscription: "team", tier: nil) == "Team")
        #expect(ClaudeUsage.plan(subscription: "pro", tier: "default_claude_ai") == "Pro")
    }

    /// A `token_count` line as Codex 0.16x writes it, and others around it.
    static let codexTail = [
        #"{"timestamp":"2026-11-12T18:56:40.808Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1791048274},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"prolite","rate_limit_reached_type":null}}}"#,
        #"{"timestamp":"2026-11-12T19:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":23.5,"window_minutes":300,"resets_at":1794600000},"secondary":{"used_percent":41,"window_minutes":10080,"resets_at":1795000000},"plan_type":"plus"}}}"#,
        #"{"timestamp":"2026-11-12T19:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":3}},"rate_limits":null}}"#,
        #"{"timestamp":"2026-11-12T19:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\"rate_limits\":{ in a reply"}]}}"#,
        "",
    ].joined(separator: "\n")

    @Test func codexSessionTail() throws {
        let report = try #require(CodexUsage.latest(inSessionTail: Data(Self.codexTail.utf8)))
        #expect(report.windows.map(\.id) == ["session", "weekly"])
        #expect(report.windows[0].used == 23.5)
        #expect(report.windows[0].length == TimeInterval(300 * 60))
        #expect(report.windows[1].resetsAt == Date(timeIntervalSince1970: 1_795_000_000))
        #expect(report.plan == "ChatGPT Plus")
        #expect(report.at.timeIntervalSince1970 == 1_794_510_000)
        // Only the older line: its week, the plan in its words.
        let first = Data(Self.codexTail.split(separator: "\n")[0].utf8)
        let older = try #require(CodexUsage.latest(inSessionTail: first))
        #expect(older.windows.map(\.title) == ["Weekly"] && older.plan == "ChatGPT Pro Lite")
        #expect(CodexUsage.latest(inSessionTail: Data()) == nil)
        #expect(CodexUsage.latest(inSessionTail: Data(Self.codexTail.split(separator: "\n")[2 ... 3].joined(separator: "\n").utf8)) == nil)
    }

    @Test func codexServerAnswer() throws {
        let result: [String: Any] = ["rateLimits": [
            "limitId": "codex",
            "primary": ["usedPercent": 100, "windowDurationMins": 43200, "resetsAt": 1_794_861_000],
            "secondary": NSNull(),
            "planType": "free",
        ]]
        let report = try #require(CodexUsage.report(fromServerResult: result, at: Date(timeIntervalSince1970: 5)))
        #expect(report.windows.map(\.id) == ["monthly"])
        #expect(report.windows[0].left == 0)
        #expect(report.plan == "ChatGPT Free")
        #expect(CodexUsage.report(fromServerResult: [:], at: .now) == nil)
        #expect(CodexUsage.name(minutes: 1440).id == "daily")
        #expect(CodexUsage.name(minutes: 525_600).id == "annual")
        #expect(CodexUsage.name(minutes: nil).id == "limit")
    }

    /// A model with a quota of its own: another bucket, after Codex's own.
    @Test func codexBuckets() throws {
        let result: [String: Any] = [
            "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 20, "windowDurationMins": 300],
                           "secondary": ["usedPercent": 35, "windowDurationMins": 10080], "planType": "pro"],
            "rateLimitsByLimitId": [
                "codex": ["limitId": "codex", "primary": ["usedPercent": 20, "windowDurationMins": 300]],
                "codex_spark": ["limitName": "GPT-6-Codex-Spark", "primary": ["usedPercent": 2, "windowDurationMins": 10080]],
            ],
        ]
        let report = try #require(CodexUsage.report(fromServerResult: result, at: .now))
        #expect(report.windows.map(\.id) == ["session", "weekly", "codex_spark:weekly"])
        #expect(report.windows[2].title == "GPT-6-Codex-Spark weekly")
        // In a session file: each bucket's newest line, Codex's own first, the report as old as it.
        let tail = [
            #"{"timestamp":"2026-11-12T19:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":10,"window_minutes":300}}}}"#,
            #"{"timestamp":"2026-11-12T19:05:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_spark","limit_name":"Spark","primary":{"used_percent":7,"window_minutes":10080}}}}"#,
            #"{"timestamp":"2026-11-12T19:01:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":12,"window_minutes":300}}}}"#,
        ].joined(separator: "\n")
        let fromFile = try #require(CodexUsage.latest(inSessionTail: Data(tail.utf8)))
        #expect(fromFile.windows.map(\.id) == ["session", "codex_spark:weekly"])
        #expect(fromFile.windows.map(\.used) == [12, 7])
        #expect(fromFile.windows[1].title == "Spark weekly")
        #expect(fromFile.at == Date(timeIntervalSince1970: 1_794_510_060))
    }

    @Test func howAWindowGoes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 3 of 5 hours gone: 60% is an even pace.
        func session(_ used: Double) -> UsageWindow {
            UsageWindow(id: "session", title: "Session", used: used, resetsAt: now + 2 * 3600, length: 5 * 3600)
        }
        #expect(session(55).elapsed(at: now) == 0.6)
        #expect(session(55).level(at: now) == .calm)
        #expect(session(75).level(at: now) == .ahead)
        #expect(session(86).level(at: now) == .near)
        #expect(session(92).level(at: now) == .near)
        let open = UsageWindow(id: "credits", title: "Usage credits", used: 80)
        #expect(open.elapsed(at: now) == nil)
        #expect(open.level(at: now) == .ahead)
        // Past its end, the window starts over.
        let over = session(70).current(at: now + 3 * 3600)
        #expect(over.used == 0 && over.resetsAt == nil)
        #expect(session(70).current(at: now) == session(70))
        #expect(UsageWindow(id: "x", title: "X", used: 130).used == 100)
    }

    @Test func geminiQuotaFromItsFooter() throws {
        #expect(GeminiUsage.window(fromFooterValue: "12% used")?.used == 12)
        #expect(GeminiUsage.window(fromFooterValue: "limit reached")?.left == 0)
        #expect(GeminiUsage.window(fromFooterValue: "7%")?.used == 7)
        #expect(GeminiUsage.window(fromFooterValue: "Auto") == nil)
        let names = " workspace (/directory)        sandbox       /model        quota"
        let values = " /Users/me/x                   no sandbox    Auto          37% used"
        let screen = GeminiScreens.ls_done.split(separator: "\n", omittingEmptySubsequences: false).dropLast(2).joined(separator: "\n")
            + "\n" + names + "\n" + values
        let footer = try #require(ClaudeFooter.parseGemini(screen: screen))
        #expect(footer.model == "Auto")
        #expect(footer.quota?.used == 37)
        #expect(footer.quota?.id == "daily")
        #expect(ClaudeFooter.parseGemini(screen: GeminiScreens.ls_done)?.quota == nil)
    }
}
