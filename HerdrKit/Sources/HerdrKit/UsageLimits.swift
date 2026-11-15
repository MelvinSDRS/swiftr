import CryptoKit
import Foundation

/// One of an agent's usage limits: how much of it is used, and when it
/// starts over. Claude's session and week, Codex's 5 hours and week,
/// Gemini's day.
public struct UsageWindow: Sendable, Equatable, Identifiable, Codable {
    /// The same from one read to the next, for the settings: `session`,
    /// `weekly`, `model:fable`, `daily`, `monthly`, `credits`.
    public let id: String
    /// For people: "Session", "Weekly", "Fable".
    public let title: String
    /// Percent used, 0 to 100.
    public let used: Double
    public let resetsAt: Date?
    /// How long the window runs, when known: 5 hours, 7 days.
    public let length: TimeInterval?

    public init(id: String, title: String, used: Double, resetsAt: Date? = nil, length: TimeInterval? = nil) {
        self.id = id
        self.title = title
        self.used = min(100, max(0, used))
        self.resetsAt = resetsAt
        self.length = length
    }

    public var left: Double { 100 - used }

    /// Money rather than time: usage credits, a credit or a promotion's.
    public var isCredit: Bool { Self.isCredit(id) }

    public static func isCredit(_ id: String) -> Bool {
        id == "credits" || id.hasPrefix("credit:") || id.hasPrefix("promo:")
    }

    /// As it stands at `now`: a window whose end has passed started over,
    /// with nothing used yet and no end until something is.
    public func current(at now: Date) -> UsageWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        return UsageWindow(id: id, title: title, used: 0, resetsAt: nil, length: length)
    }

    /// The share of the window gone by at `now`, 0 to 1, when its end and
    /// length are known.
    public func elapsed(at now: Date) -> Double? {
        guard let resetsAt, let length, length > 0, resetsAt > now else { return nil }
        return min(1, max(0, 1 - resetsAt.timeIntervalSince(now) / length))
    }

    /// How it goes, as the person's own status line colors it: calm while
    /// use keeps up with the time gone by; ahead when it runs more than 10
    /// points ahead of an even pace; near past 25 points ahead, or from 90%
    /// used. Without an end, from 75% and 90% used.
    public enum Level: Sendable, Equatable {
        case calm
        case ahead
        case near
    }

    public func level(at now: Date) -> Level {
        if used >= 90 { return .near }
        guard let elapsed = elapsed(at: now) else { return used >= 75 ? .ahead : .calm }
        let gap = used - elapsed * 100
        if gap > 25 { return .near }
        return gap > 10 ? .ahead : .calm
    }
}

/// What an agent's account has used, as read at one moment.
public struct UsageReport: Sendable, Equatable, Codable {
    public var windows: [UsageWindow]
    /// The plan, when the reply says: "Max 20x", "ChatGPT Plus".
    public var plan: String?
    /// When these numbers were true.
    public var at: Date

    public init(windows: [UsageWindow], plan: String? = nil, at: Date) {
        self.windows = windows
        self.plan = plan
        self.at = at
    }
}

// MARK: - Claude

/// Claude's limits, as Claude Code's `/usage` reads them: Anthropic's usage
/// endpoint, asked with the sign-in Claude Code keeps in the Keychain.
public enum ClaudeUsage {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static let hour: TimeInterval = 3600
    static let week: TimeInterval = 7 * 24 * 3600

    /// The keys a reply has one of at least, as Claude Code checks them.
    static let replyKeys = ["five_hour", "seven_day", "seven_day_oauth_apps", "seven_day_opus", "seven_day_sonnet",
                            "cinder_cove", "wattle_ember", "extra_usage", "limits"]

    /// The limits in the endpoint's reply that Claude Code's `/usage` lists,
    /// in its order: the session; the week for all models; Sonnet's own week,
    /// on Max and Team plans only (`subscription`, from the sign-in); each
    /// model's own week (`Fable`); then the credits the account has. A limit
    /// the reply leaves empty, or without a number, doesn't exist on this
    /// plan and isn't listed; Opus's own week no longer counts. nil when the
    /// reply isn't one.
    public static func windows(fromReply data: Data, subscription: String? = nil) -> [UsageWindow]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              replyKeys.contains(where: { object[$0] != nil })
        else { return nil }
        var out: [UsageWindow] = []
        func add(_ value: Any?, id: String, title: String, length: TimeInterval?) {
            guard let w = value as? [String: Any], let used = usageNumber(w["utilization"]),
                  !out.contains(where: { $0.id == id })
            else { return }
            out.append(UsageWindow(id: id, title: title, used: used, resetsAt: usageDate(w["resets_at"]), length: length))
        }
        add(object["five_hour"], id: "session", title: "Session", length: 5 * hour)
        add(object["seven_day"], id: "weekly", title: "Weekly", length: week)
        if subscription == nil || ["max", "team"].contains(subscription?.lowercased() ?? "") {
            add(object["seven_day_sonnet"], id: modelID("Sonnet"), title: "Sonnet", length: week)
        }
        for item in object["limits"] as? [[String: Any]] ?? [] {
            guard item["kind"] as? String == "weekly_scoped",
                  let name = (((item["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String)?
                  .trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  // Sonnet's week comes from its own key, on the plans that have it; Opus's is gone.
                  !["sonnet", "opus"].contains(where: { name.lowercased().hasPrefix($0) })
            else { continue }
            add(["utilization": item["percent"] ?? item["utilization"] ?? NSNull(), "resets_at": item["resets_at"] ?? NSNull()],
                id: modelID(name), title: name, length: week)
        }
        add(object["cinder_cove"], id: "credit:cinder_cove", title: "Claude Code and Cowork credit", length: nil)
        if let ember = object["wattle_ember"] as? [String: Any] {
            let label = (ember["label"] as? String)?.trimmingCharacters(in: .whitespaces)
            add(ember, id: "credit:wattle_ember", title: label.flatMap { $0.isEmpty ? nil : $0 } ?? "Credit", length: nil)
        }
        for item in object["promo_credits"] as? [[String: Any]] ?? [] {
            guard let program = item["program_id"] as? String, !program.isEmpty, program != "model_promo_fable",
                  let label = (item["label"] as? String)?.trimmingCharacters(in: .whitespaces), !label.isEmpty
            else { continue }
            add(item, id: "promo:" + program, title: label, length: nil)
        }
        // Usage credits with a monthly cap: how much of it went.
        if let extra = object["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true {
            var used = usageNumber(extra["utilization"])
            if used == nil, let cap = usageNumber(extra["monthly_limit"]), cap > 0, let spent = usageNumber(extra["used_credits"]) {
                used = spent / cap * 100
            }
            if let used { add(["utilization": used], id: "credits", title: "Usage credits", length: nil) }
        }
        return out
    }

    /// `model:fable` for "Fable".
    public static func modelID(_ name: String) -> String {
        "model:" + name.lowercased()
    }

    /// The Keychain entry Claude Code keeps its sign-in in, for a Claude run
    /// with `environment`: `Claude Code-credentials`, and for another
    /// configuration folder (`CLAUDE_CONFIG_DIR`, as cswap's accounts set it)
    /// the first 8 hex digits of that folder's SHA-256 after it.
    public static func keychainService(environment: [String: String]) -> String {
        let base = "Claude Code-credentials"
        let folder: String?
        if let own = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            folder = own.isEmpty ? nil : own
        } else if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            folder = config
        } else {
            folder = nil
        }
        guard let folder else { return base }
        let digest = SHA256.hash(data: Data(folder.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return base + "-" + hex.prefix(8)
    }

    /// The configuration folder of a Claude run with `environment`, where
    /// Claude Code keeps its sign-in when the Keychain can't.
    public static func configFolder(environment: [String: String], home: String) -> String {
        if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty { return config }
        return (home as NSString).appendingPathComponent(".claude")
    }

    /// The sign-in Claude Code keeps: its token, until when it holds, and the plan.
    public struct SignIn: Sendable, Equatable {
        public var token: String
        public var expires: Date?
        public var plan: String?
        /// As Claude Code keeps it: `max`, `pro`, `team`.
        public var subscription: String?

        public func expired(at now: Date) -> Bool {
            expires.map { $0 <= now } ?? false
        }
    }

    /// What Claude Code keeps in the Keychain or `.credentials.json`.
    public static func signIn(fromCredentials data: Data) -> SignIn? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expires = usageNumber(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        let subscription = oauth["subscriptionType"] as? String
        return SignIn(token: token, expires: expires,
                      plan: plan(subscription: subscription, tier: oauth["rateLimitTier"] as? String),
                      subscription: subscription.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// "Max 20x" from `max` and `default_claude_max_20x`; "Team", "Pro".
    public static func plan(subscription: String?, tier: String?) -> String? {
        guard let subscription, !subscription.isEmpty else { return nil }
        let name = subscription.prefix(1).uppercased() + subscription.dropFirst()
        if let tier, let multiple = tier.firstMatch(of: /(\d+x)$/) { return "\(name) \(multiple.output.1)" }
        return name
    }
}

// MARK: - Codex

/// Codex's limits: the `rate_limits` of its session files' `token_count`
/// events, or of its app server's `account/rateLimits/read`.
public enum CodexUsage {
    /// The limits Codex counts for every model: `codex`. A model with a
    /// quota of its own has another bucket, named in `limit_name`.
    static let ownBucket = "codex"

    /// The windows of one `rate_limits` object, in either spelling: the
    /// session file's (`used_percent`, `window_minutes`, `resets_at`) or the
    /// app server's (`usedPercent`, `windowDurationMins`, `resetsAt`). Those
    /// of another bucket than Codex's own carry its name: "Spark weekly".
    /// `own` says whose they are when the caller knows.
    public static func windows(fromRateLimits limits: [String: Any], own: Bool? = nil) -> [UsageWindow] {
        var out: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any],
                  let used = usageNumber(w["used_percent"]) ?? usageNumber(w["usedPercent"])
            else { continue }
            let minutes = usageNumber(w["window_minutes"]) ?? usageNumber(w["windowDurationMins"])
            let reset = usageNumber(w["resets_at"]) ?? usageNumber(w["resetsAt"])
            let (id, title) = name(minutes: minutes)
            guard !out.contains(where: { $0.id == id }) else { continue }
            out.append(UsageWindow(id: id, title: title, used: used,
                                   resetsAt: reset.map { Date(timeIntervalSince1970: $0) },
                                   length: minutes.map { $0 * 60 }))
        }
        let bucket = Self.bucket(of: limits)
        if !(own ?? (bucket == ownBucket)) {
            let label = (limits["limit_name"] as? String ?? limits["limitName"] as? String)?.trimmingCharacters(in: .whitespaces)
            let name = label.flatMap { $0.isEmpty ? nil : $0 } ?? bucket
            out = out.map {
                UsageWindow(id: bucket + ":" + $0.id, title: name + " " + $0.title.lowercased(), used: $0.used,
                            resetsAt: $0.resetsAt, length: $0.length)
            }
        }
        // Shortest first, as Claude's: the session, then the week.
        return out.sorted { ($0.length ?? .infinity) < ($1.length ?? .infinity) }
    }

    /// The bucket a `rate_limits` object counts: its `limit_id`, Codex's own without one.
    static func bucket(of limits: [String: Any]) -> String {
        let id = limits["limit_id"] as? String ?? limits["limitId"] as? String
        return id.flatMap { $0.isEmpty ? nil : $0 } ?? ownBucket
    }

    /// A window's name from its length: Codex's 5 hours is a session, as Claude's.
    public static func name(minutes: Double?) -> (id: String, title: String) {
        guard let minutes, minutes > 0 else { return ("limit", "Limit") }
        switch minutes {
        case ..<(12 * 60): return ("session", "Session")
        case ..<(3 * 24 * 60): return ("daily", "Daily")
        case ..<(20 * 24 * 60): return ("weekly", "Weekly")
        case ..<(300 * 24 * 60): return ("monthly", "Monthly")
        default: return ("annual", "Annual")
        }
    }

    /// "ChatGPT Plus" from `plus`, "ChatGPT Pro Lite" from `prolite`.
    public static func plan(_ type: String?) -> String? {
        guard let type, !type.isEmpty, type != "unknown" else { return nil }
        let names = ["prolite": "Pro Lite", "edu": "Edu", "self_serve_business_usage_based": "Business"]
        let name = names[type] ?? type.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return "ChatGPT " + name
    }

    /// The newest limits in a session file's text, read from its end: each
    /// bucket's last `token_count` that has some, Codex's own first. The
    /// report is as old as Codex's own bucket.
    public static func latest(inSessionTail text: Data) -> UsageReport? {
        var found: [(bucket: String, windows: [UsageWindow], plan: String?, at: Date)] = []
        var end = text.endIndex
        while end > text.startIndex {
            let start = text[..<end].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? text.startIndex
            let line = text[start ..< end]
            end = start > text.startIndex ? start - 1 : text.startIndex
            guard line.count > 40, line.range(of: Data("\"rate_limits\":{".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any],
                  case let key = Self.bucket(of: limits), !found.contains(where: { $0.bucket == key })
            else { continue }
            let windows = Self.windows(fromRateLimits: limits)
            guard !windows.isEmpty else { continue }
            found.append((key, windows, plan(limits["plan_type"] as? String), usageDate(object["timestamp"]) ?? Date.distantPast))
        }
        guard !found.isEmpty else { return nil }
        let ordered = found.filter { $0.bucket == ownBucket } + found.filter { $0.bucket != ownBucket }
        let main = ordered[0]
        return UsageReport(windows: ordered.flatMap(\.windows), plan: main.plan ?? ordered.compactMap(\.plan).first, at: main.at)
    }

    /// What the app server answers to `account/rateLimits/read`: Codex's own
    /// limits (`rateLimits`), then those of every other bucket
    /// (`rateLimitsByLimitId`).
    public static func report(fromServerResult result: [String: Any], at: Date) -> UsageReport? {
        guard let limits = result["rateLimits"] as? [String: Any] ?? result["rate_limits"] as? [String: Any] else { return nil }
        var windows = windows(fromRateLimits: limits, own: true)
        let own = Self.bucket(of: limits)
        let others = result["rateLimitsByLimitId"] as? [String: Any] ?? result["rate_limits_by_limit_id"] as? [String: Any] ?? [:]
        for key in others.keys.sorted() where key != own && key != ownBucket {
            guard var limits = others[key] as? [String: Any] else { continue }
            if limits["limitId"] == nil, limits["limit_id"] == nil { limits["limitId"] = key }
            let more = Self.windows(fromRateLimits: limits, own: false).filter { w in !windows.contains { $0.id == w.id } }
            windows += more
        }
        guard !windows.isEmpty else { return nil }
        let type = limits["planType"] as? String ?? limits["plan_type"] as? String ?? result["planType"] as? String
        return UsageReport(windows: windows, plan: plan(type), at: at)
    }
}

// MARK: - Gemini

public enum GeminiUsage {
    /// The quota column of Gemini's footer: `12% used`, `limit reached`.
    /// Gemini counts its daily limit, Pro and Flash together.
    public static func window(fromFooterValue value: String) -> UsageWindow? {
        let t = value.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("limit reached") { return UsageWindow(id: "daily", title: "Daily", used: 100, length: 24 * 3600) }
        guard let m = t.firstMatch(of: /^(\d+(?:\.\d+)?)%(?: used)?/), let used = Double(m.output.1) else { return nil }
        return UsageWindow(id: "daily", title: "Daily", used: used, length: 24 * 3600)
    }
}

// MARK: - Reading

/// A number in a reply; a JSON `true` isn't one (an NSNumber holding 1 or 0
/// also casts to Bool, so the check goes by its Core Foundation type).
private func usageNumber(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
}

/// An ISO 8601 date (fractions of a second cut, whatever their length) or
/// seconds since 1970.
private func usageDate(_ value: Any?) -> Date? {
    if let seconds = usageNumber(value) { return Date(timeIntervalSince1970: seconds) }
    guard var s = value as? String, !s.isEmpty else { return nil }
    if let dot = s.firstRange(of: /\.\d+/) { s.removeSubrange(dot) }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}
