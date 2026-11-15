import Foundation

/// A command typed after `/` in Claude Code: one of its own, or a person's
/// command, skill or plugin's.
public struct SlashCommand: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable {
        case builtIn
        /// `~/.claude/commands` or `~/.claude/skills`.
        case personal
        /// The project's `.claude` folder.
        case project
        case plugin
    }

    /// Without the slash: `model`, `huntkit:q-begin`.
    public var name: String
    public var summary: String
    /// `[model]`, `<path>`: what may follow the name.
    public var argumentHint: String
    public var aliases: [String]
    public var source: Source
    /// A skill rather than a command.
    public var isSkill: Bool
    /// Opens a screen of its own in the terminal (a picker, a settings panel).
    public var interactive: Bool

    public var id: String { name }

    public init(_ name: String, _ summary: String, argument: String = "", aliases: [String] = [], source: Source = .builtIn, isSkill: Bool = false, interactive: Bool = false) {
        self.name = name
        self.summary = summary
        argumentHint = argument
        self.aliases = aliases
        self.source = source
        self.isSkill = isSkill
        self.interactive = interactive
    }

    // MARK: Claude Code's own

    /// Claude Code's commands (2.1.x), those useful from a chat. `interactive`
    /// ones open a screen of their own when typed without an argument.
    public static let builtIns: [SlashCommand] = [
        SlashCommand("add-dir", "Add a new working directory", argument: "<path>"),
        SlashCommand("advisor", "Let Claude consult a stronger model at key moments", interactive: true),
        SlashCommand("artifacts", "Browse your published and shared artifacts", interactive: true),
        SlashCommand("autocompact", "Set how full the context gets before auto-summarizing", argument: "[auto|<tokens>]"),
        SlashCommand("background", "Send this session to the background and free the terminal", argument: "[prompt]", aliases: ["bg"]),
        SlashCommand("branch", "Create a branch of the current conversation at this point", argument: "[name]"),
        SlashCommand("brief", "Toggle brief-only mode"),
        SlashCommand("btw", "Ask a quick side question without interrupting the main conversation", argument: "<question>"),
        SlashCommand("cd", "Move this session to a new working directory", argument: "<path>"),
        SlashCommand("clear", "Start a new session with empty context; the previous one stays resumable", argument: "[name]", aliases: ["reset", "new"]),
        SlashCommand("color", "Set the prompt bar color for this session", interactive: true),
        SlashCommand("compact", "Free up context by summarizing the conversation so far", argument: "[instructions]"),
        SlashCommand("config", "Open settings", argument: "[key=value]", aliases: ["settings"], interactive: true),
        SlashCommand("context", "Show current context usage", argument: "[all]"),
        SlashCommand("copy", "Copy Claude's last response to the clipboard", argument: "[N]"),
        SlashCommand("daemon", "Manage background services and routines", interactive: true),
        SlashCommand("desktop", "Continue the current session in Claude Desktop"),
        SlashCommand("effort", "Set effort level for model usage", argument: "[low|medium|high|xhigh|max]", interactive: true),
        SlashCommand("exit", "Exit Claude Code", aliases: ["quit"]),
        SlashCommand("export", "Export the current conversation to a file or the clipboard", argument: "[filename]", interactive: true),
        SlashCommand("fast", "Turn fast mode on or off", argument: "[on|off]"),
        SlashCommand("feedback", "Send feedback to Anthropic or report a bug", argument: "[report]", aliases: ["bug"], interactive: true),
        SlashCommand("focus", "Toggle focus view: just your prompt, summary, and response", argument: "[on|off]"),
        SlashCommand("fork", "Spawn a background agent that inherits the full conversation", argument: "<directive>"),
        SlashCommand("goal", "Set a goal Claude checks before stopping", argument: "[<condition> | clear]"),
        SlashCommand("help", "Show help and available commands", interactive: true),
        SlashCommand("hooks", "View hook configurations for tool events", interactive: true),
        SlashCommand("ide", "Manage IDE integrations and show status", interactive: true),
        SlashCommand("import", "Import config from another AI coding agent", argument: "[codex|gemini|cursor]", interactive: true),
        SlashCommand("init", "Write a CLAUDE.md file that documents the codebase"),
        SlashCommand("insights", "Generate a report analyzing your Claude Code sessions"),
        SlashCommand("keybindings", "Open your keyboard shortcuts file"),
        SlashCommand("list-agents", "List subagents, teammates, and other Claude sessions you can message", aliases: ["peers"]),
        SlashCommand("login", "Sign in with your Anthropic account", interactive: true),
        SlashCommand("logout", "Sign out from your Anthropic account"),
        SlashCommand("loops", "List, create, and delete loops", interactive: true),
        SlashCommand("mcp", "Manage MCP servers", argument: "[enable|disable <server>]", interactive: true),
        SlashCommand("memory", "Edit CLAUDE.md files and memory settings", interactive: true),
        SlashCommand("model", "Set the AI model for Claude Code", argument: "[model]", interactive: true),
        SlashCommand("output-style", "List output styles or switch to one", argument: "[style]", interactive: true),
        SlashCommand("permissions", "Manage allow and deny tool permission rules", aliases: ["allowed-tools"], interactive: true),
        SlashCommand("plan", "Enable plan mode or view the current session plan", argument: "[open|<description>]"),
        SlashCommand("plugin", "Manage Claude Code plugins", aliases: ["plugins", "marketplace"], interactive: true),
        SlashCommand("powerup", "Discover Claude Code features through quick lessons", interactive: true),
        SlashCommand("recap", "Generate a one-line session recap now"),
        SlashCommand("release-notes", "View release notes", interactive: true),
        SlashCommand("reload-plugins", "Activate pending plugin changes in the current session"),
        SlashCommand("reload-skills", "Pick up skills added or changed on disk during this session"),
        SlashCommand("remote-control", "Control this session from your phone or claude.ai/code", aliases: ["rc"], interactive: true),
        SlashCommand("rename", "Rename the current conversation", argument: "[name]"),
        SlashCommand("resume", "Resume a conversation", argument: "[session]", aliases: ["continue"], interactive: true),
        SlashCommand("rewind", "Restore the code and/or conversation to a previous point", aliases: ["checkpoint", "undo"], interactive: true),
        SlashCommand("schedule", "Create and manage scheduled remote Claude Code agents", interactive: true),
        SlashCommand("skill-doctor", "Show which loaded skills are unused and costing context", interactive: true),
        SlashCommand("skills", "List available skills", interactive: true),
        SlashCommand("status", "Show version, model, account, connectivity and tool statuses", interactive: true),
        SlashCommand("statusline", "Set up Claude Code's status line"),
        SlashCommand("tasks", "View and manage everything running in the background", aliases: ["bashes"], interactive: true),
        SlashCommand("teleport", "Send this session to the cloud, or resume one from claude.ai", aliases: ["tp"], interactive: true),
        SlashCommand("theme", "Change the theme", interactive: true),
        SlashCommand("usage", "Show session cost, plan usage, and activity stats", aliases: ["cost", "stats"], interactive: true),
        SlashCommand("version", "Show this session's version"),
        SlashCommand("workflows", "Browse running and completed workflows", interactive: true),
        // Skills that come with Claude Code.
        SlashCommand("code-review", "Review the current diff or a pull request for bugs", argument: "[level] [target]", isSkill: true),
        SlashCommand("simplify", "Review the changed code for reuse and simplification, then fix it", isSkill: true),
        SlashCommand("security-review", "Complete a security review of the pending changes", isSkill: true),
        SlashCommand("loop", "Run a prompt or slash command on a recurring interval", argument: "[interval] <prompt>", isSkill: true),
        SlashCommand("fewer-permission-prompts", "Add an allowlist of common read-only calls to the project settings", isSkill: true),
        SlashCommand("run", "Launch and drive this project's app to see a change working", isSkill: true),
    ]

    /// Codex's own (0.167), from its command table; the debugging ones left out.
    public static let codexBuiltIns: [SlashCommand] = [
        SlashCommand("agents", "Open the agent command center", interactive: true),
        SlashCommand("app", "Continue this session in the Desktop app"),
        SlashCommand("approve", "Approve one retry of a recent auto-review denial"),
        SlashCommand("apps", "Manage apps", interactive: true),
        SlashCommand("archive", "Archive this session"),
        SlashCommand("cd", "Change the current working directory", argument: "<folder>"),
        SlashCommand("clear", "Clear the terminal and start a new chat"),
        SlashCommand("compact", "Summarize the conversation to stay under the context limit"),
        SlashCommand("copy", "Copy the last response or part of it", interactive: true),
        SlashCommand("delete", "Permanently delete this session", interactive: true),
        SlashCommand("diff", "Show the git diff, untracked files included"),
        SlashCommand("experimental", "Turn experimental features on or off", interactive: true),
        SlashCommand("export", "Export the conversation as Markdown"),
        SlashCommand("feedback", "Send logs to the maintainers", interactive: true),
        SlashCommand("fork", "Fork the current chat"),
        SlashCommand("goal", "Set or view the goal for a long-running task", argument: "[goal]"),
        SlashCommand("hooks", "View and manage lifecycle hooks", interactive: true),
        SlashCommand("ide", "Include the selection, open files and more from your IDE"),
        SlashCommand("import", "Import setup, this project and recent chats from Claude Code", interactive: true),
        SlashCommand("init", "Create an AGENTS.md file with instructions for Codex"),
        SlashCommand("keymap", "Remap the TUI's shortcuts", interactive: true),
        SlashCommand("logout", "Log out of Codex"),
        SlashCommand("mcp", "List MCP tools", argument: "[verbose|login <name>]"),
        SlashCommand("memories", "Configure memory use and generation", interactive: true),
        SlashCommand("mention", "Mention a file", argument: "<file>"),
        SlashCommand("model", "Choose the model and reasoning effort", interactive: true),
        SlashCommand("new", "Start a new chat during a conversation"),
        SlashCommand("permissions", "Choose what Codex is allowed to do", interactive: true),
        SlashCommand("pets", "Choose or hide the terminal pet", interactive: true),
        SlashCommand("plan", "Switch to Plan mode", argument: "[prompt]"),
        SlashCommand("plugins", "Browse plugins", interactive: true),
        SlashCommand("presets", "Run or save reusable prompts and slash commands", interactive: true),
        SlashCommand("ps", "List background terminals"),
        SlashCommand("pwd", "Show the current working directory"),
        SlashCommand("quit", "Exit Codex", aliases: ["exit"]),
        SlashCommand("raw", "Raw scrollback, for copying from the terminal"),
        SlashCommand("recap", "Summarize the conversation now"),
        SlashCommand("rename", "Rename the current thread", argument: "[name]"),
        SlashCommand("resume", "Resume a saved chat", interactive: true),
        SlashCommand("review", "Review the current changes and find issues", argument: "[instructions]"),
        SlashCommand("rollout", "Print the session file's path"),
        SlashCommand("side", "Start a side conversation in a fork that won't last", aliases: ["btw"]),
        SlashCommand("skills", "Use skills to improve how Codex does specific tasks", interactive: true),
        SlashCommand("status", "Show the session's configuration and token use"),
        SlashCommand("statusline", "Choose what the status line shows", interactive: true),
        SlashCommand("subagents", "Switch between this session's subagents", interactive: true),
        SlashCommand("theme", "Choose a syntax highlighting theme", interactive: true),
        SlashCommand("title", "Choose what the terminal title shows", interactive: true),
        SlashCommand("usage", "View account usage, or use a usage limit reset", interactive: true),
        SlashCommand("vim", "Turn Vim mode on or off for the input"),
        SlashCommand("voice", "Start or stop voice", argument: "[settings]"),
        SlashCommand("warnings", "View warnings and diagnostic details", interactive: true),
        SlashCommand("worktree", "Start or continue a conversation in a new worktree"),
    ]

    /// OpenCode's own (2.2.7), as its `/` list shows them.
    public static let openCodeBuiltIns: [SlashCommand] = [
        SlashCommand("agents", "Switch agent", interactive: true),
        SlashCommand("btw", "One-shot answer from the session's context, kept out of the conversation", argument: "<question>"),
        SlashCommand("cd", "Change the working directory", argument: "[folder]", interactive: true),
        SlashCommand("clear", "Clear the session"),
        SlashCommand("compact", "Compact the session"),
        SlashCommand("connect", "Connect an integration", interactive: true),
        SlashCommand("continue", "Switch session", aliases: ["resume", "sessions"], interactive: true),
        SlashCommand("copy", "Copy the last answer"),
        SlashCommand("debug", "View debug info", interactive: true),
        SlashCommand("diff", "Open the diff viewer", interactive: true),
        SlashCommand("editor", "Write the message in your editor", interactive: true),
        SlashCommand("effort", "Switch the model's variant", aliases: ["thinking", "variants"], interactive: true),
        SlashCommand("exit", "Exit OpenCode", aliases: ["q", "quit"]),
        SlashCommand("export", "Export the session's transcript", interactive: true),
        SlashCommand("fork", "Fork the session"),
        SlashCommand("goal", "Keep working until an objective is met", argument: "[objective|pause|resume|clear]"),
        SlashCommand("help", "Help", interactive: true),
        SlashCommand("highlights", "Show release highlights", interactive: true),
        SlashCommand("init", "Set up AGENTS.md, guided"),
        SlashCommand("mcps", "MCP servers", interactive: true),
        SlashCommand("models", "Switch model", interactive: true),
        SlashCommand("new", "New session"),
        SlashCommand("open", "Open a session or project", aliases: ["project", "projects"], interactive: true),
        SlashCommand("pair", "Pair a device", aliases: ["web"], interactive: true),
        SlashCommand("plugins", "Plugins", interactive: true),
        SlashCommand("reload", "Reload the configuration"),
        SlashCommand("rename", "Rename the session", interactive: true),
        SlashCommand("review", "Review changes, uncommitted ones unless told", argument: "[commit|branch|pr]"),
        SlashCommand("settings", "Open settings", interactive: true),
        SlashCommand("skills", "Skills", interactive: true),
        SlashCommand("stats", "Usage statistics", interactive: true),
        SlashCommand("status", "View status", interactive: true),
        SlashCommand("terminal", "New terminal", interactive: true),
        SlashCommand("themes", "Switch theme", interactive: true),
        SlashCommand("timeline", "Jump to a message", interactive: true),
        SlashCommand("undo", "Undo the last message"),
        SlashCommand("update", "Update OpenCode"),
        SlashCommand("usage", "View usage", interactive: true),
        SlashCommand("worktrees", "Manage workspaces", interactive: true),
    ]

    /// Gemini CLI's own (0.68), as its `/help` lists them; the debugging ones left out.
    public static let geminiBuiltIns: [SlashCommand] = [
        SlashCommand("about", "Show version info"),
        SlashCommand("agents", "Manage agents", argument: "[list|reload|enable|disable|config]"),
        SlashCommand("auth", "Sign in, change the authentication method or sign out", argument: "[signin|signout]", interactive: true),
        SlashCommand("bug", "Submit a bug report", argument: "[description]"),
        SlashCommand("chat", "Browse auto-saved conversations and manage chat checkpoints", argument: "[list|save|resume|delete|share] [tag]", interactive: true),
        SlashCommand("clear", "Clear the screen and start a new session", aliases: ["new"]),
        SlashCommand("commands", "Manage custom slash commands", argument: "[list|reload]"),
        SlashCommand("compress", "Compress the context by replacing it with a summary", aliases: ["summarize", "compact"]),
        SlashCommand("copy", "Copy the last result or code snippet to the clipboard"),
        SlashCommand("directory", "Manage workspace directories", argument: "[add <paths>|show]", aliases: ["dir"]),
        SlashCommand("docs", "Open the Gemini CLI documentation in your browser"),
        SlashCommand("editor", "Set the external editor", interactive: true),
        SlashCommand("export-session", "Export the current session to a JSON file"),
        SlashCommand("extensions", "Manage extensions", argument: "[list|install|update|enable|disable|uninstall]"),
        SlashCommand("footer", "Choose what the footer shows", aliases: ["statusline"], interactive: true),
        SlashCommand("help", "Help on Gemini CLI"),
        SlashCommand("hooks", "Manage hooks", argument: "[panel|enable|disable|enable-all|disable-all]"),
        SlashCommand("ide", "Manage IDE integration", argument: "[status|enable|disable]"),
        SlashCommand("init", "Analyze the project and write a GEMINI.md file for it"),
        SlashCommand("mcp", "Manage MCP servers", argument: "[list|desc|schema|auth|reload|enable|disable]"),
        SlashCommand("memory", "Show, reload or list the GEMINI.md memory", argument: "[show|reload|list|inbox]"),
        SlashCommand("model", "Manage model configuration", argument: "[manage|set <model>]", interactive: true),
        SlashCommand("permissions", "Manage folder trust", argument: "[trust [<folder>]]", interactive: true),
        SlashCommand("plan", "Switch to Plan Mode and view the current plan", argument: "[copy]"),
        SlashCommand("policies", "List the active policies", argument: "[list]"),
        SlashCommand("privacy", "Display the privacy notice", interactive: true),
        SlashCommand("quit", "Exit Gemini CLI", aliases: ["exit"]),
        SlashCommand("resume", "Browse auto-saved conversations and manage checkpoints", argument: "[list|save|resume|delete|share] [tag]", interactive: true),
        SlashCommand("rewind", "Jump back to a message and restart the conversation", interactive: true),
        SlashCommand("settings", "View and edit Gemini CLI settings", interactive: true),
        SlashCommand("setup-github", "Set up GitHub Actions"),
        SlashCommand("shortcuts", "Show or hide the shortcuts over the input"),
        SlashCommand("skills", "List, link, enable, disable or reload agent skills", argument: "[list|link|disable|enable|reload]"),
        SlashCommand("stats", "Check session stats", argument: "[session|model|tools]", aliases: ["usage"]),
        SlashCommand("tasks", "Show or hide the background tasks"),
        SlashCommand("terminal-setup", "Set up terminal key bindings for multiline input"),
        SlashCommand("theme", "Change the theme", interactive: true),
        SlashCommand("tools", "List available tools", argument: "[list|desc]"),
        SlashCommand("vim", "Turn vim mode on or off"),
    ]

    // MARK: Files

    /// `description`, `argument-hint` and the rest of a Markdown file's
    /// front matter (`---` lines at its top). A value may go on over
    /// indented lines: after `>` or `>-` (folded into one line), `|` (kept
    /// line by line), or nothing (folded).
    public static func frontMatter(_ text: String) -> [String: String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        guard let first = lines.next(), first.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        // The value going on over indented lines: its key, whether it came
        // after `|` or `>` (a block), how its lines join, its lines.
        var open: (key: String, block: Bool, literal: Bool, lines: [String])?
        func close() {
            guard let o = open else { return }
            open = nil
            let value: String
            if o.literal {
                value = o.lines.joined(separator: "\n")
            } else {
                // Folded: lines join with a space, an empty line starts a new one.
                value = o.lines.split(separator: "", omittingEmptySubsequences: true).map { $0.joined(separator: " ") }.joined(separator: "\n")
            }
            let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty || out[o.key] == nil { out[o.key] = t }
        }
        var count = 0
        while let line = lines.next(), count < 200 {
            count += 1
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" { break }
            if line.hasPrefix(" ") || line.hasPrefix("\t") || (t.isEmpty && open != nil) {
                // Under a key with no value, `- item` or `key: value`: a list
                // or a map, not words.
                if let o = open, !o.block, o.lines.isEmpty, t.hasPrefix("- ") || t.firstMatch(of: /^[\w.-]+:(\s|$)/) != nil {
                    open = nil
                }
                open?.lines.append(t)
                continue
            }
            close()
            guard let colon = t.firstIndex(of: ":"), !t.hasPrefix("#") else { continue }
            let key = t[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            var value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.wholeMatch(of: /[|>][+-]?[0-9]?/) != nil {
                open = (key, true, value.hasPrefix("|"), [])
                continue
            }
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
                if q == "\"" { value = value.replacingOccurrences(of: "\\\"", with: "\"") }
                out[key] = value
            } else {
                // A plain value may go on over indented lines.
                out[key] = value
                open = (key, false, false, value.isEmpty ? [] : [value])
            }
        }
        close()
        return out
    }

    /// A command file (`commands/review.md`) or a skill's `SKILL.md`, read.
    /// `name` is what the folders give (`frontend/review`, `my-skill`).
    public static func from(file text: String, name: String, source: Source, isSkill: Bool, plugin: String? = nil) -> SlashCommand? {
        let front = frontMatter(text)
        if front["user-invocable"]?.lowercased() == "false" { return nil }
        var base = isSkill ? (front["name"].flatMap { $0.isEmpty ? nil : $0 } ?? name) : name
        base = base.replacingOccurrences(of: "/", with: ":")
        let full = plugin.map { "\($0):\(base)" } ?? base
        var summary = front["description"] ?? ""
        if summary.isEmpty {
            // The first line of text after the front matter.
            summary = Self.firstLine(afterFrontMatter: text)
        }
        return SlashCommand(full, summary, argument: front["argument-hint"] ?? "", source: source, isSkill: isSkill)
    }

    /// A Gemini command file (`commands/git/commit.toml`), read: its
    /// `description`, else its prompt's first line. `name` is what the
    /// folders give (`git/commit`), which Gemini calls `git:commit`.
    public static func from(toml text: String, name: String, source: Source) -> SlashCommand? {
        let full = name.replacingOccurrences(of: "/", with: ":")
        guard !full.isEmpty else { return nil }
        let summary = tomlString("description", in: text) ?? tomlString("prompt", in: text) ?? ""
        let first = summary.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let takesArgs = (tomlString("prompt", in: text) ?? "").contains("{{args}}")
        return SlashCommand(full, String(first.prefix(120)), argument: takesArgs ? "[args]" : "", source: source)
    }

    /// A top-level string value of a TOML file: `key = "…"`, `'…'`,
    /// `"""…"""` or `'''…'''`.
    static func tomlString(_ key: String, in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i < lines.count {
            let t = lines[i].drop { $0 == " " || $0 == "\t" }
            i += 1
            // A table: the top-level keys are behind.
            if t.hasPrefix("[") { return nil }
            guard let eq = t.firstIndex(of: "=") else { continue }
            let name = t[..<eq].trimmingCharacters(in: .whitespaces)
            let v = t[t.index(after: eq)...].drop { $0 == " " || $0 == "\t" }
            if let quote = ["\"\"\"", "'''"].first(where: { v.hasPrefix($0) }) {
                // A multi-line string: its lines are no keys.
                var body = String(v.dropFirst(3))
                while body.range(of: quote) == nil, i < lines.count {
                    body += "\n" + lines[i]
                    i += 1
                }
                guard name == key else { continue }
                if let end = body.range(of: quote) { body = String(body[..<end.lowerBound]) }
                if body.hasPrefix("\n") { body.removeFirst() }
                return quote == "'''" ? body : unescape(body)
            }
            guard name == key else { continue }
            if v.hasPrefix("'") { return String(v.dropFirst().prefix { $0 != "'" }) }
            guard v.hasPrefix("\"") else { return nil }
            var out = ""
            var escaped = false
            for c in v.dropFirst() {
                if escaped { out.append("\\"); out.append(c); escaped = false; continue }
                if c == "\\" { escaped = true; continue }
                if c == "\"" { break }
                out.append(c)
            }
            return unescape(out)
        }
        return nil
    }

    private static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaped = false
        for c in s {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append("\\"); out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    private static func firstLine(afterFrontMatter text: String) -> String {
        var inFront = false
        var started = false
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !started, t == "---" { inFront = true; started = true; continue }
            started = true
            if inFront { if t == "---" { inFront = false }; continue }
            let words = t.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            if !words.isEmpty { return String(words.prefix(120)) }
        }
        return ""
    }

    // MARK: Finding

    /// The commands for what is typed after `/` (no space yet), best first:
    /// names that start with it, then names with a word that does. From
    /// three letters on, names that hold it anywhere; and when no name
    /// matches, the commands whose description holds it. Nothing typed:
    /// every command, as Claude Code lists them (`limit` is for words).
    public static func matching(_ typed: String, in all: [SlashCommand], limit: Int = 50) -> [SlashCommand] {
        let q = typed.lowercased()
        guard !q.isEmpty else { return all.sorted(by: Self.order) }
        // One or two letters are found inside too many names.
        let loose = q.count >= 3
        var scored: [(Int, SlashCommand)] = []
        for c in all {
            let name = c.name.lowercased()
            // A plugin's command answers to its own name too (`q-begin`).
            let short = name.split(separator: ":").last.map(String.init) ?? name
            let score: Int
            if name == q || c.aliases.contains(q) { score = 0 }
            else if name.hasPrefix(q) || short.hasPrefix(q) { score = 1 }
            else if c.aliases.contains(where: { $0.hasPrefix(q) }) { score = 2 }
            else if name.split(whereSeparator: { $0 == "-" || $0 == ":" || $0 == "_" }).contains(where: { $0.hasPrefix(q) }) { score = 3 }
            else if loose, name.contains(q) { score = 4 }
            else if loose, c.summary.lowercased().contains(q) { score = 5 }
            else { continue }
            scored.append((score, c))
        }
        if scored.contains(where: { $0.0 < 5 }) { scored.removeAll { $0.0 == 5 } }
        return Array(scored.sorted { a, b in a.0 != b.0 ? a.0 < b.0 : order(a.1, b.1) }.map(\.1).prefix(limit))
    }

    /// As Claude Code lists them: its own first, then the project's, the
    /// person's and plugins', each by name.
    static func order(_ a: SlashCommand, _ b: SlashCommand) -> Bool {
        func rank(_ s: Source) -> Int {
            switch s {
            case .builtIn: 0
            case .project: 1
            case .personal: 2
            case .plugin: 3
            }
        }
        if a.source != b.source { return rank(a.source) < rank(b.source) }
        return a.name < b.name
    }

    /// The typed text's command part: `/mod` in `/mod`, nil once a space follows
    /// or when it doesn't start with `/`.
    public static func typedName(_ text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        guard !rest.contains(where: { $0 == " " || $0 == "\n" }) else { return nil }
        return String(rest)
    }

    /// The commands, each name once: the person's own before Claude Code's
    /// (a command file named like a built-in replaces it), duplicates dropped.
    public static func merged(_ lists: [[SlashCommand]]) -> [SlashCommand] {
        var seen: Set<String> = []
        var out: [SlashCommand] = []
        for list in lists {
            for c in list where !seen.contains(c.name) {
                seen.insert(c.name)
                out.append(c)
            }
        }
        return out
    }
}
