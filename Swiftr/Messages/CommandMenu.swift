import Foundation
import HerdrKit
import Observation
import SwiftUI

/// The slash commands a Claude session offers: Claude Code's own, and the
/// commands, skills and plugins of the person and of the project, read
/// from disk (on this Mac) and read again after a while.
@MainActor @Observable
final class CommandCatalog {
    static let shared = CommandCatalog()

    /// The person's commands and skills, and their plugins', by configuration folder.
    private var personal: [String: [SlashCommand]] = [:]
    /// The project's, by folder.
    private var projects: [String: [SlashCommand]] = [:]
    @ObservationIgnored private var readAt: [String: Date] = [:]

    static let stale: TimeInterval = 30

    /// What `/` offers in a session; built-ins only until `load` has read the disk.
    func commands(config: String?, folder: String) -> [SlashCommand] {
        SlashCommand.merged([projects[folder] ?? [], config.flatMap { personal[$0] } ?? [], SlashCommand.builtIns])
    }

    /// What `/` offers in a Codex session: its own commands (Codex 0.167
    /// reads no command files).
    func codexCommands() -> [SlashCommand] {
        SlashCommand.codexBuiltIns
    }

    /// What `/` offers in an OpenCode session: the project's commands, the
    /// person's, then OpenCode's own. `loadOpenCode` reads the files.
    func openCodeCommands(folder: String) -> [SlashCommand] {
        SlashCommand.merged([projects["oc:" + folder] ?? [], personal["oc"] ?? [], SlashCommand.openCodeBuiltIns])
    }

    /// What `/` offers in a Gemini session: the project's commands and
    /// skills, the person's, then Gemini's own. `gemini` is the `.gemini`
    /// folder the Gemini reads (nil on another machine); `loadGemini` reads them.
    func geminiCommands(gemini: String?, folder: String) -> [SlashCommand] {
        SlashCommand.merged([projects["gm:" + folder] ?? [], gemini.flatMap { personal["gm:" + $0] } ?? [], SlashCommand.geminiBuiltIns])
    }

    /// Gemini's command files (`commands/**/*.toml`) and skills
    /// (`skills/<name>/SKILL.md`), in its `.gemini` folder and the `.agents`
    /// one beside it, and in the project's `.gemini` and `.agents` folders.
    func loadGemini(gemini: String?, folder: String) {
        let now = Date()
        if let gemini, now.timeIntervalSince(readAt["gm:" + gemini] ?? .distantPast) > Self.stale {
            readAt["gm:" + gemini] = now
            Task {
                let found = await Task.detached(priority: .utility) {
                    Self.scanGemini(URL(filePath: gemini), agents: URL(filePath: gemini).deletingLastPathComponent().appending(path: ".agents"), source: .personal)
                }.value
                personal["gm:" + gemini] = found
            }
        }
        if gemini != nil, !folder.isEmpty, now.timeIntervalSince(readAt["gmp:" + folder] ?? .distantPast) > Self.stale {
            readAt["gmp:" + folder] = now
            Task {
                let found = await Task.detached(priority: .utility) {
                    let root = URL(filePath: folder)
                    return Self.scanGemini(root.appending(path: ".gemini"), agents: root.appending(path: ".agents"), source: .project)
                }.value
                projects["gm:" + folder] = found
            }
        }
    }

    nonisolated static func scanGemini(_ dot: URL, agents: URL, source: SlashCommand.Source) -> [SlashCommand] {
        var out: [SlashCommand] = []
        let dir = dot.appending(path: "commands")
        let base = dir.standardizedFileURL.path
        if let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where url.pathExtension == "toml" {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                let name = String(path.dropFirst(base.count + 1).dropLast(5))
                if name.split(separator: "/").count > 3 { continue }
                if let c = SlashCommand.from(toml: head(url), name: name, source: source) { out.append(c) }
                if out.count > 400 { break }
            }
        }
        // Gemini offers its skills as commands too, by name.
        out += skills(in: dot.appending(path: "skills"), source: source, plugin: nil)
        out += skills(in: agents.appending(path: "skills"), source: source, plugin: nil)
        return out.map { c in
            var c = c
            c.name = c.name.replacingOccurrences(of: " ", with: "-")
            return c
        }
    }

    /// OpenCode's command files: `~/.config/opencode/command(s)/*.md`, and
    /// `.opencode/command(s)` in the project's folders.
    func loadOpenCode(folder: String) {
        let now = Date()
        if now.timeIntervalSince(readAt["oc"] ?? .distantPast) > Self.stale {
            readAt["oc"] = now
            Task {
                let found = await Task.detached(priority: .utility) { () -> [SlashCommand] in
                    let env = ProcessInfo.processInfo.environment
                    let config = env["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
                        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
                    let root = config.appending(path: "opencode")
                    return Self.commands(in: root.appending(path: "command"), source: .personal, plugin: nil)
                        + Self.commands(in: root.appending(path: "commands"), source: .personal, plugin: nil)
                }.value
                personal["oc"] = found
            }
        }
        if !folder.isEmpty, now.timeIntervalSince(readAt["ocp:" + folder] ?? .distantPast) > Self.stale {
            readAt["ocp:" + folder] = now
            Task {
                let found = await Task.detached(priority: .utility) { Self.scanOpenCodeProject(folder) }.value
                projects["oc:" + folder] = found
            }
        }
    }

    nonisolated static func scanOpenCodeProject(_ folder: String) -> [SlashCommand] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var dir = URL(filePath: folder).standardizedFileURL
        var out: [SlashCommand] = []
        for _ in 0 ..< 12 {
            guard dir.path != home, dir.path != "/" else { break }
            let oc = dir.appending(path: ".opencode")
            out += commands(in: oc.appending(path: "command"), source: .project, plugin: nil)
            out += commands(in: oc.appending(path: "commands"), source: .project, plugin: nil)
            if FileManager.default.fileExists(atPath: dir.appending(path: ".git").path) { break }
            dir = dir.deletingLastPathComponent()
        }
        return out
    }

    /// Reads the files again when it's been a while. `config` is Claude's
    /// configuration folder on this Mac; nil for another machine.
    func load(config: String?, folder: String) {
        let now = Date()
        if let config, now.timeIntervalSince(readAt["c:" + config] ?? .distantPast) > Self.stale {
            readAt["c:" + config] = now
            Task {
                let found = await Task.detached(priority: .utility) { Self.scanPersonal(URL(filePath: config)) }.value
                personal[config] = found
            }
        }
        if config != nil, !folder.isEmpty, now.timeIntervalSince(readAt["p:" + folder] ?? .distantPast) > Self.stale {
            readAt["p:" + folder] = now
            Task {
                let found = await Task.detached(priority: .utility) { Self.scanProject(folder) }.value
                projects[folder] = found
            }
        }
    }

    // MARK: Reading the disk

    nonisolated static func scanPersonal(_ config: URL) -> [SlashCommand] {
        var out = commands(in: config.appending(path: "commands"), source: .personal, plugin: nil)
        out += skills(in: config.appending(path: "skills"), source: .personal, plugin: nil)
        // Enabled plugins: `installed_plugins.json` says where each is.
        let settings = json(config.appending(path: "settings.json"))
        let enabled = settings?["enabledPlugins"]?.object ?? [:]
        let installed = json(config.appending(path: "plugins/installed_plugins.json"))?["plugins"]?.object ?? [:]
        for (key, entries) in installed.sorted(by: { $0.key < $1.key }) where enabled[key]?.bool == true {
            let list = entries.array ?? []
            guard let entry = list.first(where: { $0["scope"]?.string == "user" }) ?? list.first,
                  let path = entry["installPath"]?.string
            else { continue }
            let root = URL(filePath: path)
            let name = json(root.appending(path: ".claude-plugin/plugin.json"))?["name"]?.string
                ?? String(key.split(separator: "@").first ?? Substring(key))
            out += commands(in: root.appending(path: "commands"), source: .plugin, plugin: name)
            out += skills(in: root.appending(path: "skills"), source: .plugin, plugin: name)
        }
        return out
    }

    /// The `.claude` folders of `folder` and the folders above it, up to the
    /// repository's top or the home folder.
    nonisolated static func scanProject(_ folder: String) -> [SlashCommand] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var dir = URL(filePath: folder).standardizedFileURL
        var out: [SlashCommand] = []
        for _ in 0 ..< 12 {
            guard dir.path != home, dir.path != "/" else { break }
            let claude = dir.appending(path: ".claude")
            out += commands(in: claude.appending(path: "commands"), source: .project, plugin: nil)
            out += skills(in: claude.appending(path: "skills"), source: .project, plugin: nil)
            if FileManager.default.fileExists(atPath: dir.appending(path: ".git").path) { break }
            dir = dir.deletingLastPathComponent()
        }
        return out
    }

    /// `commands/**/*.md`: `review.md` is `/review`, `frontend/review.md` is `/frontend:review`.
    nonisolated static func commands(in dir: URL, source: SlashCommand.Source, plugin: String?) -> [SlashCommand] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [SlashCommand] = []
        let base = dir.standardizedFileURL.path
        for case let url as URL in walker where url.pathExtension == "md" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let name = String(path.dropFirst(base.count + 1).dropLast(3))
            if name.split(separator: "/").count > 3 { continue }
            if let c = SlashCommand.from(file: head(url), name: name, source: source, isSkill: false, plugin: plugin) { out.append(c) }
            if out.count > 400 { break }
        }
        return out
    }

    /// `skills/<name>/SKILL.md`.
    nonisolated static func skills(in dir: URL, source: SlashCommand.Source, plugin: String?) -> [SlashCommand] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { name in
            let file = dir.appending(path: name).appending(path: "SKILL.md")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return SlashCommand.from(file: head(file), name: name, source: source, isSkill: true, plugin: plugin)
        }
    }

    /// A file's first few kilobytes: its front matter and first line.
    nonisolated private static func head(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 8192)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func json(_ url: URL) -> JSON? {
        (try? Data(contentsOf: url)).flatMap { try? JSON(data: $0) }
    }
}

/// The project's files and folders that match the `@word` in the field.
struct FilePopup: View {
    @Environment(\.codeFamily) private var codeFamily
    let paths: [String]
    let selection: Int
    let size: Double
    let pick: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(paths.enumerated()), id: \.element) { i, path in
                        row(path, selected: i == selection)
                            .id(path)
                            .contentShape(.rect)
                            .onTapGesture { pick(path) }
                    }
                }
                .padding(5)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 290)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) {
                if paths.indices.contains(selection) { proxy.scrollTo(paths[selection]) }
            }
        }
        .paneGlass(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func row(_ path: String, selected: Bool) -> some View {
        let folder = path.hasSuffix("/")
        let trimmed = folder ? String(path.dropLast()) : path
        let name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let parent = trimmed.count > name.count ? String(trimmed.dropLast(name.count + 1)) : ""
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: folder ? "folder" : "doc")
                .font(.system(size: size * 0.8))
                .foregroundStyle(folder ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: size * 1.1)
            Text(name + (folder ? "/" : ""))
                .font(CodeFont.font(size * 0.9, family: codeFamily, bold: selected))
                .lineLimit(1)
                .layoutPriority(2)
            if !parent.isEmpty {
                Text(parent)
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: .rect(cornerRadius: 8))
    }
}

/// The commands that match what is typed after `/`, over the field: each
/// with its symbol, its name, what may follow it and what it does. With
/// `/` alone, every command, in sections: the agent's own, the project's,
/// the person's, then plugins'.
struct CommandPopup: View {
    @Environment(\.codeFamily) private var codeFamily
    @Environment(\.themeAccent) private var themeAccent
    let commands: [SlashCommand]
    let selection: Int
    let size: Double
    /// Whose the built-in commands are: "Claude Code", "Codex"…
    let agent: String
    /// Only `/` is typed: the list comes in sections.
    let sectioned: Bool
    let pick: (SlashCommand) -> Void

    /// More rows than this: a window of fixed height, drawn as it scrolls.
    private static let snug = 9

    private struct Section: Identifiable {
        let title: String
        let rows: Range<Int>
        var id: String { "section:" + title }
    }

    /// Runs of commands from the same place, in the list's order.
    private var sections: [Section] {
        guard sectioned else { return [Section(title: "", rows: commands.indices)] }
        var out: [Section] = []
        var start = 0
        for i in commands.indices where i + 1 == commands.count || title(commands[i + 1]) != title(commands[i]) {
            out.append(Section(title: title(commands[i]), rows: start ..< i + 1))
            start = i + 1
        }
        return out
    }

    private func title(_ c: SlashCommand) -> String {
        switch c.source {
        case .builtIn: agent
        case .project: "This Project"
        case .personal: "Personal"
        case .plugin: "Plugins"
        }
    }

    var body: some View {
        let many = commands.count > Self.snug
        let sections = sections
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if many {
                        LazyVStack(alignment: .leading, spacing: 1) { content(sections) }
                    } else {
                        VStack(alignment: .leading, spacing: 1) { content(sections) }
                    }
                }
                .padding(5)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: many ? 300 : nil)
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: !many)
            .onChange(of: selection) { old, new in
                guard commands.indices.contains(new) else { return }
                // Up to a section's first row: its title shows over it, the
                // list moving only if the title is out of sight. (Down, the row
                // comes in at the bottom, its title right over it.)
                if sectioned, new < old, let s = sections.first(where: { $0.rows.lowerBound == new }) {
                    proxy.scrollTo(s.id)
                } else {
                    proxy.scrollTo(commands[new].id)
                }
            }
        }
        .paneGlass(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    @ViewBuilder private func content(_ sections: [Section]) -> some View {
        ForEach(sections) { s in
            if sectioned {
                header(s.title, first: s.rows.lowerBound == 0)
                    .id(s.id)
            }
            ForEach(s.rows, id: \.self) { i in
                row(commands[i], selected: i == selection)
                    .id(commands[i].id)
                    .contentShape(.rect)
                    .onTapGesture { pick(commands[i]) }
            }
        }
    }

    private func header(_ title: String, first: Bool) -> some View {
        Text(title)
            .font(.system(size: size * 0.74, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.top, first ? 4 : 12)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ c: SlashCommand, selected: Bool) -> some View {
        let accent = themeAccent ?? .accentColor
        return HStack(spacing: 9) {
            Image(systemName: Self.symbol(for: c))
                .font(.system(size: size * 0.78, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                .frame(width: size * 1.55, height: size * 1.55)
                .background(selected ? accent.opacity(0.16) : Color.primary.opacity(0.06), in: .rect(cornerRadius: size * 0.42, style: .continuous))
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Text(verbatim: "/").foregroundStyle(.tertiary))\(Text(verbatim: c.name))")
                    .font(.system(size: size * 0.92, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .layoutPriority(2)
                if !c.argumentHint.isEmpty {
                    Text(c.argumentHint)
                        .font(CodeFont.font(size * 0.78, family: codeFamily))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Text(c.summary)
                    .font(.system(size: size * 0.85))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // In sections, the section says where it comes from.
                if !sectioned, let badge = Self.badge(c) {
                    Text(badge)
                        .font(.system(size: size * 0.7, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07), in: .capsule)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selected ? accent.opacity(0.2) : .clear, in: .rect(cornerRadius: 10))
    }

    /// Where a command comes from, when not from the agent itself.
    static func badge(_ c: SlashCommand) -> String? {
        switch c.source {
        case .project: "project"
        case .personal: "personal"
        case .plugin: "plugin"
        case .builtIn: nil
        }
    }

    /// The agent's own commands by their names; skills, command files
    /// and plugins' commands by what they are.
    static func symbol(for c: SlashCommand) -> String {
        if c.source == .builtIn, let s = symbols[c.name] { return s }
        if c.isSkill { return "wand.and.stars" }
        switch c.source {
        case .plugin: return "puzzlepiece.extension"
        case .builtIn: return "slash.circle"
        case .personal, .project: return "doc.text"
        }
    }

    /// The agents' own commands' symbols, by name (Claude Code, Codex,
    /// OpenCode and Gemini share most names).
    static let symbols: [String: String] = [
        "about": "info.circle",
        "add-dir": "folder.badge.plus",
        "advisor": "person.2",
        "agents": "person.2",
        "app": "macwindow",
        "approve": "checkmark.circle",
        "apps": "square.grid.2x2",
        "archive": "archivebox",
        "artifacts": "doc.richtext",
        "auth": "person.crop.circle",
        "autocompact": "rectangle.compress.vertical",
        "background": "rectangle.portrait.and.arrow.forward",
        "branch": "arrow.triangle.branch",
        "brief": "text.alignleft",
        "btw": "text.bubble",
        "bug": "ladybug",
        "cd": "folder",
        "chat": "clock.arrow.circlepath",
        "clear": "square.and.pencil",
        "code-review": "text.magnifyingglass",
        "color": "paintpalette",
        "commands": "slash.circle",
        "compact": "arrow.down.right.and.arrow.up.left",
        "compress": "arrow.down.right.and.arrow.up.left",
        "config": "gearshape",
        "connect": "link",
        "context": "chart.pie",
        "continue": "clock.arrow.circlepath",
        "copy": "doc.on.doc",
        "daemon": "gearshape.2",
        "debug": "ant",
        "delete": "trash",
        "desktop": "macwindow",
        "diff": "plus.forwardslash.minus",
        "directory": "folder.badge.plus",
        "docs": "book",
        "editor": "pencil.and.outline",
        "effort": "gauge.with.dots.needle.50percent",
        "exit": "rectangle.portrait.and.arrow.right",
        "experimental": "flask",
        "export": "square.and.arrow.up",
        "export-session": "square.and.arrow.up",
        "extensions": "puzzlepiece.extension",
        "fast": "bolt",
        "feedback": "ladybug",
        "fewer-permission-prompts": "hand.raised",
        "focus": "scope",
        "footer": "menubar.rectangle",
        "fork": "arrow.triangle.branch",
        "goal": "target",
        "help": "questionmark.circle",
        "highlights": "newspaper",
        "hooks": "link",
        "ide": "chevron.left.forwardslash.chevron.right",
        "import": "square.and.arrow.down",
        "init": "doc.badge.plus",
        "insights": "chart.line.uptrend.xyaxis",
        "keybindings": "keyboard",
        "keymap": "keyboard",
        "list-agents": "person.2",
        "login": "person.crop.circle.badge.checkmark",
        "logout": "person.crop.circle.badge.xmark",
        "loop": "repeat",
        "loops": "repeat",
        "mcp": "server.rack",
        "mcps": "server.rack",
        "memories": "brain",
        "memory": "brain",
        "mention": "at",
        "model": "cpu",
        "models": "cpu",
        "new": "square.and.pencil",
        "open": "folder",
        "output-style": "textformat",
        "pair": "iphone",
        "permissions": "lock.shield",
        "pets": "pawprint",
        "plan": "list.bullet.clipboard",
        "plugin": "puzzlepiece.extension",
        "plugins": "puzzlepiece.extension",
        "policies": "checklist",
        "powerup": "graduationcap",
        "presets": "star",
        "privacy": "hand.raised",
        "ps": "list.bullet.rectangle",
        "pwd": "folder",
        "quit": "rectangle.portrait.and.arrow.right",
        "raw": "text.alignleft",
        "recap": "text.quote",
        "release-notes": "newspaper",
        "reload": "arrow.clockwise",
        "reload-plugins": "arrow.clockwise",
        "reload-skills": "arrow.clockwise",
        "remote-control": "iphone",
        "rename": "pencil",
        "resume": "clock.arrow.circlepath",
        "review": "text.magnifyingglass",
        "rewind": "arrow.uturn.backward",
        "rollout": "doc.text",
        "run": "play",
        "schedule": "calendar.badge.clock",
        "security-review": "checkmark.shield",
        "settings": "gearshape",
        "setup-github": "chevron.left.forwardslash.chevron.right",
        "shortcuts": "keyboard",
        "side": "bubble.left.and.bubble.right",
        "simplify": "scissors",
        "skill-doctor": "stethoscope",
        "skills": "wand.and.stars",
        "stats": "chart.bar",
        "status": "info.circle",
        "statusline": "menubar.rectangle",
        "subagents": "person.2",
        "tasks": "list.bullet.rectangle",
        "teleport": "icloud.and.arrow.up",
        "terminal": "terminal",
        "terminal-setup": "terminal",
        "theme": "circle.lefthalf.filled",
        "themes": "circle.lefthalf.filled",
        "timeline": "arrow.uturn.backward",
        "title": "pencil",
        "tools": "wrench.and.screwdriver",
        "undo": "arrow.uturn.backward",
        "update": "arrow.down.circle",
        "usage": "chart.bar",
        "version": "info.circle",
        "vim": "character.cursor.ibeam",
        "voice": "mic",
        "warnings": "exclamationmark.triangle",
        "workflows": "flowchart",
        "worktree": "square.stack.3d.up",
        "worktrees": "square.stack.3d.up",
    ]
}
