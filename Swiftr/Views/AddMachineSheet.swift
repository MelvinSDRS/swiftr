import AppKit
import HerdrKit
import SwiftUI

/// A host ~/.ssh/config names, to pick in the Add a Machine sheet.
nonisolated struct SSHHost: Identifiable, Equatable, Sendable {
    let alias: String
    var aliases: [String]
    var hostname: String?
    var user: String?

    var id: String { alias }

    /// What the sheet shows beside its name: user@hostname, or its other names.
    var detail: String {
        let at = [user, hostname].compactMap { $0 }.joined(separator: "@")
        if !at.isEmpty { return at }
        return aliases.isEmpty ? "" : "also " + aliases.joined(separator: ", ")
    }
}

/// The named hosts of ~/.ssh/config and the files it includes, as
/// herdr-app's machine-add reads them: no patterns, each name once.
nonisolated enum SSHConfig {
    static func hosts() -> [SSHHost] {
        var hosts: [SSHHost] = []
        read(NSHomeDirectory() + "/.ssh/config", into: &hosts, depth: 0)
        return hosts
    }

    private static func read(_ path: String, into hosts: inout [SSHHost], depth: Int) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        // The host the lines below describe, if they describe one we list.
        var current: Int?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (key, value) = entry(line) else { continue }
            switch key {
            case "host", "match":
                let names = key == "host" ? value.split(whereSeparator: \.isWhitespace).map(String.init).filter { name in
                    !name.contains(where: { "*?!".contains($0) }) && !hosts.contains { $0.alias == name || $0.aliases.contains(name) }
                } : []
                if let first = names.first {
                    hosts.append(SSHHost(alias: first, aliases: Array(names.dropFirst())))
                    current = hosts.count - 1
                } else {
                    current = nil
                }
            case "include" where depth < 16:
                // ssh goes 16 deep.
                for file in includedFiles(value) { read(file, into: &hosts, depth: depth + 1) }
            case "hostname":
                if let current { hosts[current].hostname = value }
            case "user":
                if let current { hosts[current].user = value }
            default:
                break
            }
        }
    }

    /// A line's keyword, lowercased, and its value: `Key value` or `Key=value`.
    private static func entry(_ line: Substring) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first != "#", first != "=" else { return nil }
        let end = trimmed.firstIndex { $0.isWhitespace || $0 == "=" || $0 == "#" } ?? trimmed.endIndex
        var rest = trimmed[end...].drop { $0.isWhitespace }
        if rest.first == "=" { rest = rest.dropFirst() }
        return (trimmed[..<end].lowercased(), rest.trimmingCharacters(in: .whitespaces))
    }

    /// An Include's files, as ssh finds them: ~ is home, a relative path is
    /// under ~/.ssh, and a pattern matches files.
    private static func includedFiles(_ value: String) -> [String] {
        let home = NSHomeDirectory()
        return words(value).flatMap { word -> [String] in
            let path = word.hasPrefix("~/") ? home + word.dropFirst() : word.hasPrefix("/") ? word : home + "/.ssh/" + word
            return path.contains(where: { "*?[".contains($0) }) ? matches(path) : [path]
        }
    }

    /// Words apart, a quoted one whole.
    private static func words(_ value: String) -> [String] {
        var out: [String] = []
        var rest = Substring(value)
        while let start = rest.firstIndex(where: { !$0.isWhitespace }) {
            rest = rest[start...]
            if rest.first == "\"", let close = rest.dropFirst().firstIndex(of: "\"") {
                out.append(String(rest[rest.index(after: rest.startIndex) ..< close]))
                rest = rest[rest.index(after: close)...]
            } else {
                let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
                out.append(String(rest[..<end]))
                rest = rest[end...]
            }
        }
        return out
    }

    private static func matches(_ pattern: String) -> [String] {
        var found = glob_t()
        defer { globfree(&found) }
        guard glob(pattern, 0, nil, &found) == 0 else { return [] }
        return (0 ..< Int(found.gl_pathc)).compactMap { i in found.gl_pathv[i].map { String(cString: $0) } }.filter { path in
            var folder: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && !folder.boolValue
        }
    }
}

/// The Add a Machine sheet's state: the hosts to pick, and how each add
/// went. The model holds it while the sheet shows.
@Observable
final class MachineAdder: Identifiable {
    enum Step: Equatable {
        case adding
        /// Why it failed. `answer`: someone at a terminal can get past it
        /// (a password, a new host key, herdr-core to put there).
        case failed(String, answer: Bool)
    }

    let id = UUID()
    /// nil until ~/.ssh/config is read.
    private(set) var hosts: [SSHHost]?
    /// Targets typed in the sheet, listed under its field.
    private(set) var typed: [String] = []
    private(set) var steps: [String: Step] = [:]
    /// Targets someone may be adding in a terminal: the sheet looks for
    /// them every 3 s.
    private(set) var waiting: Set<String> = []

    func readHosts() async {
        hosts = await Task.detached { SSHConfig.hosts() }.value
    }

    func isAdded(_ target: String, in model: AppModel) -> Bool {
        model.remotes.contains { $0.target == target || $0.name == target || $0.host == target }
    }

    /// A target typed in the sheet: listed under its field, then added.
    func add(typed raw: String, model: AppModel) {
        let target = raw.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        if !typed.contains(target), !(hosts ?? []).contains(where: { $0.alias == target }) { typed.append(target) }
        add(target, model: model)
    }

    func add(_ target: String, model: AppModel) {
        guard steps[target] != .adding else { return }
        waiting.remove(target)
        steps[target] = .adding
        Task {
            do {
                try await model.addMachine(target)
                steps[target] = nil
            } catch let error as CoreError where error.kind == "already_added" {
                await model.refreshMachines()
                steps[target] = nil
            } catch {
                let step = Self.failure(error, target: target)
                steps[target] = step
                if case .failed(_, answer: true) = step { waiting.insert(target) }
            }
        }
    }

    #if DEBUG
    /// What an add that failed with this error shows, without dialing anyone.
    func pretendFailure(_ target: String, kind: String, message: String) {
        if !typed.contains(target), !(hosts ?? []).contains(where: { $0.alias == target }) { typed.append(target) }
        let step = Self.failure(CoreError(kind: kind, message: message), target: target)
        steps[target] = step
        if case .failed(_, answer: true) = step { waiting.insert(target) }
    }
    #endif

    /// The targets added meanwhile from a terminal.
    func lookForWaiting(model: AppModel) async {
        guard !waiting.isEmpty else { return }
        await model.refreshMachines()
        for target in waiting where isAdded(target, in: model) {
            waiting.remove(target)
            steps[target] = nil
        }
    }

    /// What the core's error means for the person adding `target`.
    static func failure(_ error: any Error, target: String) -> Step {
        let core = error as? CoreError
        let message = core?.message ?? error.localizedDescription
        switch core?.kind {
        case "hc_missing":
            return .failed("herdr-core isn't on \(target) yet. In a terminal, hc machine add offers to put it there.", answer: true)
        case "incompatible":
            return .failed("\(target) has a herdr-core this one can't work with. In a terminal, hc machine add offers to put this one there.", answer: true)
        default:
            // ssh wants an answer: only a terminal can give it.
            if message.range(of: "password|passphrase|host key|permission denied|login", options: [.regularExpression, .caseInsensitive]) != nil {
                return .failed("\(target) asks for a password or a new host key: answer it in a terminal. (\(message))", answer: true)
            }
            var why = message.hasSuffix(".") ? message : message + "."
            if let hint = core?.hint, !hint.isEmpty {
                why += " " + hint.prefix(1).uppercased() + hint.dropFirst() + (hint.hasSuffix(".") ? "" : ".")
            }
            return .failed(why, answer: false)
        }
    }

    /// `hc machine add` in a tab on this Mac, where it can ask its questions:
    /// the sheet goes, so they can be answered.
    func openInTab(_ target: String, model: AppModel) {
        model.addingMachine = nil
        var command = [model.endpoint.hcPath, "machine", "add", target]
        // Swiftr's core, whatever session the shell's own setup names.
        if model.endpoint.session != "default" { command = ["env", "HC_SESSION=\(model.endpoint.session)"] + command }
        model.newLocalTab(command: command, name: "Add \(target)")
    }

    /// The line that adds `target` from a terminal, to `session`'s core.
    static func command(_ target: String, session: String) -> String {
        (session == "default" ? "" : "HC_SESSION=\(shellWord(session)) ") + "hc machine add " + shellWord(target)
    }

    private static func shellWord(_ text: String) -> String {
        text.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil
            ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// herdr-app's Add a machine: the hosts in ~/.ssh/config, or one typed,
/// each added with a click as `hc machine add` adds it. One that needs an
/// answer (a password, a new host key, herdr-core put there) goes to a tab
/// running `hc machine add`.
struct AddMachineSheet: View {
    @Environment(AppModel.self) private var model
    let adder: MachineAdder
    @State private var typed = ""
    /// The target whose command was just copied.
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a Machine")
                .font(.title3.weight(.semibold))
            Text("A VPS, a Mac mini, a box at home: Swiftr reaches it over ssh, and the agents there keep running while this Mac sleeps.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            heading(adder.hosts?.isEmpty == true ? "Your ssh config lists no hosts" : "From your ssh config")
            if adder.hosts == nil {
                Text("Reading ~/.ssh/config…")
                    .foregroundStyle(.secondary)
            } else {
                // As tall as its rows, up to a point; then it scrolls.
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView { rows }
                }
                .frame(maxHeight: 340)
            }
            heading("Or type how ssh reaches it")
            HStack(spacing: 8) {
                TextField("user@host", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            // What was typed, under the field: its answer shows where it was asked.
            VStack(spacing: 0) {
                ForEach(adder.typed, id: \.self) { target in
                    row(target, detail: "")
                }
            }
            .padding(.top, adder.typed.isEmpty ? 0 : 6)
            HStack {
                Spacer()
                Button("Done") { model.addingMachine = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(width: 500)
        .task { await adder.readHosts() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await adder.lookForWaiting(model: model)
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(adder.hosts ?? []) { host in
                row(host.alias, detail: host.detail)
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

    private func row(_ target: String, detail: String) -> some View {
        let added = adder.isAdded(target, in: model)
        let step = adder.steps[target]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(target)
                Text(detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if added {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if step == .adding {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Add") { adder.add(target, model: model) }
                }
            }
            .frame(minHeight: 32)
            if !added, case .failed(let why, let answer) = step {
                VStack(alignment: .leading, spacing: 6) {
                    Text(why)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if answer {
                        HStack(spacing: 8) {
                            Button("Open in a Tab") { adder.openInTab(target, model: model) }
                            Button(copied == target ? "Copied" : "Copy Command") { copy(target) }
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.bottom, 8)
            }
        }
    }

    private func addTyped() {
        adder.add(typed: typed, model: model)
        typed = ""
    }

    private func copy(_ target: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MachineAdder.command(target, session: model.endpoint.session), forType: .string)
        copied = target
    }
}
