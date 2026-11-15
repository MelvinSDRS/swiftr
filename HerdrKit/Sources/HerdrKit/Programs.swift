import Foundation

/// The programs Swiftr knows by sight, from herdr-app's program table
/// (programs.json). Each has a key, which its icon goes by.
public enum Programs {
    public struct Program: Sendable {
        public let key: String
        /// For people: "Claude Code", "Neovim", "Shell".
        public let name: String
        /// A coding agent.
        public let agent: Bool
        /// How to start it, for the agents people start from a menu:
        /// herdr-app's `run`.
        public let run: [String]?
        /// Other names it reports itself as or runs as.
        let also: [String]

        init(_ key: String, _ name: String, agent: Bool = false, run: [String]? = nil, also: [String] = []) {
            self.key = key
            self.name = name
            self.agent = agent
            self.run = run
            self.also = also
        }
    }

    /// In herdr-app's order: the agents first, down to "agent" for one it
    /// doesn't know; "shell" for a shell, "program" for anything unknown.
    public static let all: [Program] = [
        Program("claude", "Claude Code", agent: true, run: ["claude"], also: ["claude-code"]),
        Program("codex", "Codex", agent: true, run: ["codex", "--no-daemon"]),
        Program("pi", "Pi", agent: true, run: ["pi"]),
        Program("pig", "PiG", agent: true, run: ["pig"]),
        Program("opencode", "OpenCode", agent: true, run: ["opencode"]),
        Program("cursor", "Cursor", agent: true, run: ["cursor-agent"], also: ["cursor-agent"]),
        Program("copilot", "Copilot", agent: true, run: ["copilot"], also: ["github-copilot"]),
        Program("amp", "Amp", agent: true, run: ["amp"]),
        Program("grok", "Grok", agent: true, run: ["grok"], also: ["grok-build"]),
        Program("dsh-tui", "DeepSeek Harness", agent: true, run: ["dsh-tui"]),
        Program("antigravity", "Antigravity", agent: true, run: ["agy"], also: ["agy"]),
        Program("kimi", "Kimi", agent: true, run: ["kimi"], also: ["kimi-code", "kimicodecli"]),
        Program("kiro", "Kiro", agent: true, run: ["kiro-cli"], also: ["kiro-cli"]),
        Program("hermes", "Hermes", agent: true, run: ["hermes"]),
        Program("mastracode", "Mastra Code", agent: true),
        Program("qoder", "Qoder", agent: true, run: ["qodercli"], also: ["qodercli"]),
        Program("muse", "Muse", agent: true),
        Program("crush", "Crush", agent: true, run: ["crush"]),
        Program("command-code", "Command Code", agent: true),
        Program("prime-agent", "Prime", agent: true),
        Program("gemini", "Gemini", agent: true, run: ["gemini"]),
        Program("ollama", "Ollama", agent: true),
        Program("agent", "Agent", agent: true),
        Program("shell", "Shell"),
        Program("program", "Program"),
        Program("vim", "Vim", also: ["vi", "view"]),
        Program("nvim", "Neovim"),
        Program("hx", "Helix", also: ["helix"]),
        Program("emacs", "Emacs"),
        Program("nano", "nano"),
        Program("less", "Pager", also: ["more", "man", "bat"]),
        Program("lazygit", "Git Changes", also: ["gitui", "tig"]),
        Program("git", "Git"),
        Program("gh", "GitHub"),
        Program("glab", "GitLab"),
        Program("htop", "Activity", also: ["btop", "top", "btm", "glances"]),
        Program("ssh", "SSH", also: ["mosh", "et"]),
        Program("tmux", "tmux", also: ["zellij", "screen"]),
        Program("rg", "Search", also: ["grep", "fzf", "fd", "find"]),
        Program("curl", "curl", also: ["wget", "http", "httpie", "xh"]),
        Program("ffmpeg", "FFmpeg"),
        Program("make", "Make", also: ["just", "ninja"]),
        Program("cmake", "CMake"),
        Program("jupyter", "Jupyter"),
        Program("node", "Node"),
        Program("bun", "Bun", also: ["bunx"]),
        Program("deno", "Deno"),
        Program("python", "Python", also: ["python3", "ipython", "pip", "pip3"]),
        Program("uv", "uv", also: ["uvx"]),
        Program("poetry", "Poetry"),
        Program("ruby", "Ruby", also: ["irb", "bundle", "gem", "rails"]),
        Program("go", "Go"),
        Program("cargo", "Cargo", also: ["rustc", "rustup"]),
        Program("java", "Java", also: ["javac", "jshell"]),
        Program("gradle", "Gradle", also: ["gradlew"]),
        Program("mvn", "Maven", also: ["mvnw"]),
        Program("dotnet", ".NET"),
        Program("php", "PHP", also: ["artisan"]),
        Program("composer", "Composer"),
        Program("iex", "Elixir", also: ["elixir", "mix"]),
        Program("erl", "Erlang"),
        Program("ghci", "Haskell", also: ["ghc", "stack", "cabal"]),
        Program("ocaml", "OCaml", also: ["utop", "dune", "opam"]),
        Program("zig", "Zig"),
        Program("swift", "Swift"),
        Program("kotlin", "Kotlin", also: ["kotlinc"]),
        Program("scala", "Scala", also: ["sbt"]),
        Program("lua", "Lua", also: ["luajit"]),
        Program("perl", "Perl"),
        Program("R", "R", also: ["Rscript"]),
        Program("julia", "Julia"),
        Program("dart", "Dart"),
        Program("flutter", "Flutter"),
        Program("tsc", "TypeScript", also: ["tsx", "ts-node"]),
        Program("npm", "npm", also: ["npx"]),
        Program("pnpm", "pnpm"),
        Program("yarn", "Yarn"),
        Program("vite", "Vite"),
        Program("next", "Next.js"),
        Program("astro", "Astro"),
        Program("nuxt", "Nuxt", also: ["nuxi"]),
        Program("turbo", "Turborepo"),
        Program("webpack", "webpack"),
        Program("esbuild", "esbuild"),
        Program("vitest", "Vitest"),
        Program("jest", "Jest"),
        Program("pytest", "pytest"),
        Program("eslint", "ESLint"),
        Program("prettier", "Prettier"),
        Program("biome", "Biome"),
        Program("ruff", "Ruff"),
        Program("expo", "Expo"),
        Program("tauri", "Tauri"),
        Program("electron", "Electron"),
        Program("prisma", "Prisma"),
        Program("supabase", "Supabase"),
        Program("django-admin", "Django"),
        Program("flask", "Flask"),
        Program("fastapi", "FastAPI"),
        Program("psql", "PostgreSQL", also: ["postgres"]),
        Program("mysql", "MySQL", also: ["mariadb"]),
        Program("sqlite3", "SQLite", also: ["sqlite"]),
        Program("redis-cli", "Redis", also: ["redis-server"]),
        Program("mongosh", "MongoDB", also: ["mongo"]),
        Program("docker", "Docker", also: ["docker-compose", "lazydocker"]),
        Program("podman", "Podman"),
        Program("kubectl", "Kubernetes", also: ["k9s", "minikube", "kind"]),
        Program("helm", "Helm"),
        Program("terraform", "Terraform", also: ["tofu"]),
        Program("ansible", "Ansible", also: ["ansible-playbook"]),
        Program("gcloud", "Google Cloud"),
        Program("vercel", "Vercel"),
        Program("netlify", "Netlify"),
        Program("wrangler", "Cloudflare"),
        Program("fly", "Fly.io", also: ["flyctl"]),
        Program("caddy", "Caddy"),
        Program("nginx", "nginx"),
        Program("nix", "Nix", also: ["nix-shell", "nixos-rebuild"]),
        Program("brew", "Homebrew"),
        Program("apt", "apt", also: ["apt-get", "dpkg"]),
        Program("dnf", "dnf", also: ["rpm-ostree"]),
        Program("pacman", "pacman", also: ["yay", "paru"]),
    ]

    /// A terminal at a shell's prompt shows "shell".
    static let shells: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "nu", "pwsh", "powershell", "cmd", "elvish", "xonsh",
        "tcsh", "csh", "ksh", "ion",
    ]

    /// Programs that start the one that counts: `node …/codex` shows Codex,
    /// `python3 server.py` Python.
    static let runners: Set<String> = [
        "node", "bun", "bunx", "deno", "python", "python3", "npx", "pnpm", "yarn", "uv", "uvx",
        "ruby", "bundle", "env", "sudo", "nice", "time", "watch", "nodemon",
    ]

    private static let byKey = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

    /// Each key and other name, lowercased.
    private static let byName: [String: Program] = {
        var map: [String: Program] = [:]
        for p in all {
            for name in [p.key] + p.also where map[name.lowercased()] == nil {
                map[name.lowercased()] = p
            }
        }
        return map
    }()

    public static func name(_ key: String) -> String? { byKey[key]?.name }

    public static func isAgent(_ key: String) -> Bool { byKey[key]?.agent == true }

    /// The agents people can start from a menu, in the table's order: those
    /// with a `run`, as herdr-app's `knownAgents` lists them.
    public static let startable = all.filter { $0.run != nil }

    /// One of `startable`, by key.
    public static func startable(_ key: String) -> Program? {
        byKey[key].flatMap { $0.run == nil ? nil : $0 }
    }

    /// What a terminal shows: the agent it reports itself as (OSC 7501
    /// `app`), else the program in front, past runners, their options and
    /// variables. "shell" at a shell's prompt, "program" for one the table
    /// doesn't know.
    public static func key(app: String?, argv: [String], name: String) -> String {
        if let app, let p = byName[app.lowercased()] { return p.key }
        var words = argv.map { ($0 as NSString).lastPathComponent.lowercased() }
        if words.isEmpty, !name.isEmpty { words = [name.lowercased()] }
        // A login shell's name starts with a dash: -zsh.
        if let first = words.first, first.hasPrefix("-") { words[0] = String(first.dropFirst()) }
        guard let first = words.first else { return "shell" }
        if shells.contains(first) { return "shell" }
        var runner: String?
        for word in words where !word.hasPrefix("-") && !word.contains("=") {
            guard runners.contains(word) else {
                if let p = byName[word] { return p.key }
                break
            }
            if runner == nil { runner = word }
        }
        // A script the table doesn't know: its runner, if the table knows it.
        return [runner, first].compactMap { $0.flatMap { byName[$0]?.key } }.first ?? "program"
    }
}

extension TerminalModel {
    /// The program it shows, as `Programs` keys them.
    public var programKey: String {
        Programs.key(app: status?.app, argv: foreground?.argv ?? [], name: foreground?.name ?? "")
    }

    /// Codex runs in front: `codex`, or `node …/codex`.
    public var isCodex: Bool {
        guard let fg = foreground else { return false }
        return Programs.key(app: nil, argv: fg.argv, name: fg.name) == "codex"
    }

    /// OpenCode runs in front.
    public var isOpenCode: Bool {
        guard let fg = foreground else { return false }
        return Programs.key(app: nil, argv: fg.argv, name: fg.name) == "opencode"
    }

    /// Gemini CLI runs in front: `gemini`, or `node …/gemini`.
    public var isGemini: Bool {
        guard let fg = foreground else { return false }
        return Programs.key(app: nil, argv: fg.argv, name: fg.name) == "gemini"
    }

    /// Claude Code, Codex, OpenCode or Gemini runs in front: an agent whose conversation can show as a chat.
    public var runsChatAgent: Bool { isClaude || isCodex || isOpenCode || isGemini }
}
