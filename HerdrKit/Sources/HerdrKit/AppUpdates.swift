import Foundation

/// Homebrew's record of an app it installed from a cask: Homebrew then
/// updates the app, so that `brew outdated` stays true.
public struct HomebrewCask: Sendable, Equatable {
    /// The cask's name, like `swiftr`.
    public let token: String
    /// The brew that installed it, like `/opt/homebrew/bin/brew`.
    public let brew: String

    public init(token: String, brew: String) {
        self.token = token
        self.brew = brew
    }

    /// Where Homebrew lives: Apple silicon's place, then Intel's.
    public static let prefixes = ["/opt/homebrew", "/usr/local"]

    /// The cask `token` when Homebrew installed the app at `app`: Homebrew
    /// keeps a link to the app in `<prefix>/Caskroom/<token>/<version>/`.
    public static func owning(app: URL, token: String, prefixes: [String] = prefixes) -> HomebrewCask? {
        let manager = FileManager.default
        let target = app.resolvingSymlinksInPath().standardizedFileURL.path
        for prefix in prefixes {
            let brew = prefix + "/bin/brew"
            let room = URL(filePath: prefix).appending(path: "Caskroom").appending(path: token)
            guard manager.isExecutableFile(atPath: brew),
                  let versions = try? manager.contentsOfDirectory(at: room, includingPropertiesForKeys: nil) else { continue }
            for version in versions where !version.lastPathComponent.hasPrefix(".") {
                let link = version.appending(path: app.lastPathComponent)
                guard let to = try? manager.destinationOfSymbolicLink(atPath: link.path) else { continue }
                let linked = URL(filePath: to, relativeTo: version).resolvingSymlinksInPath().standardizedFileURL.path
                if linked == target { return HomebrewCask(token: token, brew: brew) }
            }
        }
        return nil
    }

    /// What to run, in order: the taps' latest casks, then the upgrade.
    public var commands: [[String]] {
        [["update", "--quiet"], ["upgrade", "--cask", token]]
    }

    /// Why brew failed, from what it printed: its last `Error:` line, else
    /// its last line.
    public static func problem(in output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let error = lines.last(where: { $0.hasPrefix("Error:") }) {
            return String(error.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
        }
        return lines.last ?? "brew gave no reason."
    }
}

/// When Swiftr looks for updates by itself: every so many hours.
public enum UpdateSchedule {
    /// The hours on offer in Settings; 0 never looks.
    public static let choices = [1, 3, 6, 12, 24]
    public static let standard = 6

    /// The hours kept in settings, made one that counts: a number that
    /// isn't there gives the standard pace, a negative one never looks.
    public static func hours(saved: Int?) -> Int {
        guard let saved else { return standard }
        return max(0, saved)
    }

    /// Whether to look now: `last` is the last look by itself.
    public static func isDue(last: Date?, every hours: Int, now: Date = Date()) -> Bool {
        guard hours > 0 else { return false }
        guard let last else { return true }
        // A clock set back: look, rather than wait for the old time to come again.
        return now.timeIntervalSince(last) >= Double(hours) * 3600 || last > now
    }

    public static func label(hours: Int) -> String {
        switch hours {
        case ...0: "Never"
        case 1: "Every hour"
        case 24: "Every day"
        default: "Every \(hours) hours"
        }
    }
}
