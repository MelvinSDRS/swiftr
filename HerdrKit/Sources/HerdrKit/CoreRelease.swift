import Foundation

/// A herdr-core release, as `releases.herdr.dev/core/latest.json` gives it:
/// what `hc update` installs.
public struct CoreRelease: Sendable, Equatable {
    public var version: String
    /// Its protocol generation. `hc update` stays within one, and a core of a
    /// later one can't talk to this Swiftr.
    public var generation: Int
    /// What it brings, in Markdown.
    public var notes: String

    public init(version: String, generation: Int = 1, notes: String = "") {
        self.version = version
        self.generation = generation
        self.notes = notes
    }

    /// nil unless it names a version.
    public init?(json: JSON) {
        guard let version = json["version"]?.string, CoreVersion(version) != nil else { return nil }
        self.init(version: version, generation: json["generation"]?.int ?? 1, notes: json["notes"]?.string ?? "")
    }

    /// The release server: `HERDR_RELEASES_URL` moves it, for hc as for Swiftr.
    static func server(environment: [String: String]) -> String {
        var base = environment["HERDR_RELEASES_URL"] ?? ""
        while base.hasSuffix("/") { base.removeLast() }
        return base.isEmpty ? "https://releases.herdr.dev" : base
    }

    /// Where hc looks for the latest release.
    public static func latestURL(environment: [String: String]) -> URL {
        URL(string: server(environment: environment) + "/core/latest.json") ?? URL(string: "https://releases.herdr.dev/core/latest.json")!
    }

    /// herdr-core's own installer (`curl -fsSL <it> | sh`), which Swiftr
    /// runs on a Mac that has no herdr-core.
    public static func installerURL(environment: [String: String]) -> URL {
        URL(string: server(environment: environment) + "/core/install.sh") ?? URL(string: "https://releases.herdr.dev/core/install.sh")!
    }

    /// The latest release, asked of the release server now.
    public static func latest(environment: [String: String]) async throws -> CoreRelease {
        let url = latestURL(environment: environment)
        let server = url.host() ?? url.absoluteString
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CoreError(kind: "check", message: "\(server) answered \(http.statusCode).")
        }
        guard let json = try? JSON(data: data), let release = CoreRelease(json: json) else {
            throw CoreError(kind: "check", message: "\(server) sent no release.")
        }
        return release
    }
}

/// A release number like `0.1.21` (hc prints `hc 0.1.21`), compared part
/// by part: 0.1.100 is newer than 0.1.21, and 0.2 is 0.2.0.
public struct CoreVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let word = text.split(separator: " ").last ?? ""
        let parts = word.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public static func < (a: CoreVersion, b: CoreVersion) -> Bool {
        for i in 0 ..< max(a.parts.count, b.parts.count) where a.part(i) != b.part(i) {
            return a.part(i) < b.part(i)
        }
        return false
    }

    public static func == (a: CoreVersion, b: CoreVersion) -> Bool {
        !(a < b) && !(b < a)
    }

    private func part(_ i: Int) -> Int {
        i < parts.count ? parts[i] : 0
    }

    public var description: String {
        parts.map(String.init).joined(separator: ".")
    }
}

/// What `hc update --json` or `hc machine update --json` reported.
public struct CoreUpdateOutcome: Sendable, Equatable {
    /// A new build runs now.
    public var updated: Bool
    /// The build was already current, and hc restarted an older core onto it.
    public var restarted: Bool
    /// The release hc runs now, like `0.1.21`, when it said.
    public var release: String?
    public var error: CoreError?

    /// hc's output (its JSON object last; errors come on stderr, so take
    /// both) and its exit status: one other than 0 is a failure even when
    /// no error object came.
    public init(output: String, status: Int32) {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let object = lines.reversed().lazy.compactMap { try? JSON(text: $0) }.first { $0.object != nil }
        // An update says what ran before (`was`); one with nothing to do says `updated: false`.
        let was = object?["was"]?.string, now = object?["now"]?.string
        updated = object?["updated"]?.bool ?? (was != nil && now != nil && was != now)
        restarted = object?["restarted"]?.bool ?? false
        release = object?["release"]?.string ?? now.flatMap { CoreVersion($0)?.description }
        if let e = object?["error"], e.object != nil {
            let hint = e["hint"]?.string ?? ""
            error = CoreError(kind: e["kind"]?.string ?? "failed", message: e["message"]?.string ?? "hc gave no reason.", hint: hint.isEmpty ? nil : hint)
        } else if status != 0 {
            let last = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            error = CoreError(kind: "failed", message: last ?? "hc stopped with status \(status).")
        } else {
            error = nil
        }
    }
}
