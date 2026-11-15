import Foundation

/// How herdr-app starts an agent from its + menu, and asks a machine which
/// agents it has (programs.rs): both in the person's login, interactive
/// shell, so the PATH and functions set up there count. Once the agent
/// ends, that shell stays, as in any tab.
public enum AgentLaunch {
    /// Shells that take `-lic` and read `"$@"` as sh does.
    static let posixShells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    // Run with the shell's path as $0 (fish: $argv[1]), then the command.
    static let posixStart = #""$@"; exec "$0" -li"#
    static let fishStart = "command $argv[2..]; exec $argv[1] -li"
    static let otherStart = #""$@"; exec "${SHELL:-sh}" -i"#

    // Prints herdr-has:<name> for each name the shell knows, then a last
    // line, so output from rc files can't pass for an answer.
    static let posixCheck = #"for c; do unalias -- "$c" 2>/dev/null; command -v "$c" >/dev/null 2>&1 && printf 'herdr-has:%s\n' "$c"; done; printf '\nherdr-check-complete\n'"#
    static let fishCheck = #"for c in $argv[2..]; command -v $c >/dev/null 2>&1; and printf 'herdr-has:%s\n' $c; end; printf '\nherdr-check-complete\n'"#

    static let found = "herdr-has:"
    static let complete = "herdr-check-complete"

    /// What `terminal.run` starts to run `command` (an agent's `run`):
    /// in `shell`, this Mac's login shell, or with no shell, through `sh` on
    /// another machine, which finds its own in `$SHELL`.
    public static func start(_ command: [String], shell: String?) -> [String] {
        argv(posix: posixStart, fish: fishStart, other: otherStart, shell: shell) + command
    }

    /// What `machine.exec` runs to learn which of `names` the shell finds;
    /// `installed(in:)` reads its output.
    public static func check(_ names: [String], shell: String?) -> [String] {
        argv(posix: posixCheck, fish: fishCheck, other: posixCheck, shell: shell) + names
    }

    /// The names a check found; nil when it didn't get to its end.
    public static func installed(in output: String) -> Set<String>? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(complete) else { return nil }
        return Set(lines.filter { $0.hasPrefix(found) }.map { String($0.dropFirst(found.count)) })
    }

    private static func argv(posix: String, fish: String, other: String, shell: String?) -> [String] {
        guard let shell else {
            let script = """
            shell=${SHELL:-/bin/sh}
            case "${shell##*/}" in
              fish) exec "$shell" -lic \(quoted(fish)) "$shell" "$@" ;;
              sh|bash|zsh|dash|ksh) exec "$shell" -lic \(quoted(posix)) "$shell" "$@" ;;
              *) exec sh -c \(quoted(other)) sh "$@" ;;
            esac
            """
            return ["sh", "-c", script, "sh"]
        }
        let name = (shell as NSString).lastPathComponent
        if name == "fish" { return [shell, "-lic", fish, shell] }
        if posixShells.contains(name) { return [shell, "-lic", posix, shell] }
        return ["/bin/sh", "-c", other, "sh"]
    }

    /// `text` as one word for sh: in single quotes, its own quotes escaped.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
