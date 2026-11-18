import AppKit
import ModKit
import SwiftUI

/// Changes: the uncommitted changes of the focused terminal's folder, as
/// herdr-app's panel of that name shows them. Built in, so the mods'
/// sidebar has something to show before any mod is added. It only reads.

/// Where the changes are read: a folder, on this Mac or a machine.
nonisolated struct ChangesPlace: Hashable, Sendable {
    var folder: String
    /// Nil: this Mac.
    var machine: String?
}

/// A changed file.
nonisolated struct ChangedFile: Identifiable, Hashable, Sendable {
    var path: String
    /// A added, D deleted, M modified, U in conflict.
    var status: Character
    /// Not tracked yet: it has no diff against HEAD.
    var fresh = false
    var added = 0
    var deleted = 0
    var binary = false

    var id: String { path }
}

/// A line of a diff.
nonisolated struct ChangeRow: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case hunk, added, removed, same, note }

    var id: Int
    var kind: Kind
    /// The line's number, in the new file but for a removed line.
    var number: Int?
    var text: String
}

/// What `git` says of a folder, read without writing under `.git`.
nonisolated enum ChangesReader {
    /// No index refresh or lock, no fsmonitor cookie: a read on a timer
    /// must never hold the lock an agent's commit needs.
    static let quiet = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "diff.autoRefreshIndex=false"]
    static let fileLimit = 1000
    static let rowLimit = 1500
    static let lineLimit = 4000

    struct Listing: Sendable {
        var root: String
        var hasHead: Bool
        var files: [ChangedFile]
        var limited: Bool
    }

    struct Failure: Error { var text: String }

    static func git(_ arguments: [String], in folder: String, on machine: String?, quiet: Bool = true) async throws -> ModExecResult {
        let arguments = (quiet ? Self.quiet : []) + arguments
        guard let machine, !machine.isEmpty else {
            return try await ModProcess.run(ModExecRequest(command: "git", arguments: arguments, cwd: folder, timeout: 20_000))
        }
        // On another machine: through the core, as one shell line.
        func quote(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let line = "cd \(quote(folder)) && " + (["git"] + arguments).map(quote).joined(separator: " ")
        return try await ModProcess.run(ModExecRequest(command: "hc", arguments: ["exec", "--on", machine, line], timeout: 30_000))
    }

    /// The changed files, or nil when the folder is in no repository.
    static func list(_ place: ChangesPlace) async throws -> Listing? {
        let top = try await git(["rev-parse", "--show-toplevel"], in: place.folder, on: place.machine)
        guard top.code == 0 else {
            // Git's own "not a git repository"; anything else (a machine
            // out of reach, a folder that is gone) is said as it is.
            if top.stderr.contains("not a git repository") { return nil }
            throw Failure(text: top.stderr.isEmpty ? top.stdout : top.stderr)
        }
        let root = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        let status = try await git(["status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all"], in: root, on: place.machine)
        guard status.code == 0 else { throw Failure(text: status.stderr) }
        let head = try await git(["rev-parse", "--verify", "HEAD"], in: root, on: place.machine)
        let hasHead = head.code == 0
        let counts: [[String]] = hasHead
            ? [["diff", "HEAD", "--numstat", "-z", "--no-renames"]]
            : [["diff", "--cached", "--numstat", "-z", "--no-renames"], ["diff", "--numstat", "-z", "--no-renames"]]
        var stats: [String: (added: Int, deleted: Int, binary: Bool)] = [:]
        for arguments in counts {
            let result = try await git(arguments, in: root, on: place.machine)
            guard result.code == 0 else { throw Failure(text: result.stderr) }
            for entry in result.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
                let parts = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                let path = String(parts[2]), old = stats[path] ?? (0, 0, false)
                stats[path] = (old.added + (Int(parts[0]) ?? 0), old.deleted + (Int(parts[1]) ?? 0), parts[0] == "-")
            }
        }
        let entries = status.stdout.split(separator: "\0", omittingEmptySubsequences: true)
        let files = entries.prefix(fileLimit).compactMap { entry -> ChangedFile? in
            guard entry.count > 3 else { return nil }
            let xy = String(entry.prefix(2)), path = String(entry.dropFirst(3))
            let fresh = xy == "??"
            let conflict = xy.contains("U") || xy == "AA" || xy == "DD"
            let letter: Character = conflict ? "U" : xy.contains("D") ? "D" : fresh || xy.contains("A") ? "A" : "M"
            let stat = stats[path] ?? (0, 0, false)
            return ChangedFile(path: path, status: letter, fresh: fresh, added: stat.added, deleted: stat.deleted, binary: stat.binary)
        }
        return Listing(root: root, hasHead: hasHead, files: files, limited: entries.count > fileLimit)
    }

    /// A file's diff against HEAD; a new file's lines, all added.
    static func diff(of file: ChangedFile, in listing: Listing, on machine: String?) async throws -> [ChangeRow] {
        let plain = ["--no-ext-diff", "--no-textconv", "--no-color"]
        let result: ModExecResult
        if file.fresh || (!listing.hasHead && file.status == "A") {
            // Against nothing: git ends with 1 when the two differ.
            result = try await git(["diff", "--no-index"] + plain + ["--", "/dev/null", file.path], in: listing.root, on: machine)
            guard result.code == 0 || result.code == 1 else { throw Failure(text: result.stderr) }
        } else {
            result = try await git(["diff"] + (listing.hasHead ? ["HEAD"] : []) + plain + ["--", file.path], in: listing.root, on: machine)
            guard result.code == 0 else { throw Failure(text: result.stderr) }
        }
        return rows(from: result.stdout, binary: file.binary)
    }

    /// Numbers each line once, from the first hunk on.
    static func rows(from text: String, binary: Bool = false) -> [ChangeRow] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        guard let first = lines.firstIndex(where: { $0.hasPrefix("@@") }) else {
            let binary = binary || lines.contains { $0.hasPrefix("Binary files") }
            return [ChangeRow(id: 0, kind: .note, text: binary ? "Binary file: no text diff" : "No text diff")]
        }
        var old = 0, new = 0
        var out: [ChangeRow] = []
        for line in lines[first...].prefix(rowLimit) {
            var text = String(line.prefix(lineLimit))
            if line.count > lineLimit { text += "… (line cut)" }
            let id = out.count
            if text.hasPrefix("@@") {
                // "@@ -12,7 +12,9 @@": where each side starts.
                let sides = text.split(separator: " ")
                if sides.count > 2 {
                    old = Int(sides[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(sides[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                out.append(ChangeRow(id: id, kind: .hunk, text: text))
                continue
            }
            let body = untab(String(text.dropFirst()))
            switch text.first {
            case "-":
                out.append(ChangeRow(id: id, kind: .removed, number: old, text: body))
                old += 1
            case "+":
                out.append(ChangeRow(id: id, kind: .added, number: new, text: body))
                new += 1
            case " ":
                out.append(ChangeRow(id: id, kind: .same, number: new, text: body))
                old += 1
                new += 1
            default:
                // "\ No newline at end of file".
                out.append(ChangeRow(id: id, kind: .note, text: text))
            }
        }
        if lines.count - first > rowLimit {
            out.append(ChangeRow(id: out.count, kind: .note, text: "Showing the first \(rowLimit) lines"))
        }
        return out
    }

    /// A tab, as spaces up to the next 4-column stop.
    static func untab(_ text: String) -> String {
        guard text.contains("\t") else { return text }
        var out = ""
        var column = 0
        for character in text {
            if character == "\t" {
                let pad = 4 - column % 4
                out += String(repeating: " ", count: pad)
                column += pad
            } else {
                out.append(character)
                column += 1
            }
        }
        return out
    }
}

/// The panel's state: one for the window.
@MainActor @Observable
final class ChangesModel {
    static let shared = ChangesModel()

    private(set) var place: ChangesPlace?
    private(set) var listing: ChangesReader.Listing?
    private(set) var rows: [ChangeRow] = []
    /// The file whose diff shows.
    private(set) var open: String?
    /// Why there is nothing to list.
    private(set) var note: String?
    private(set) var loading = false
    /// A test's folder, in place of the focused terminal's.
    var override: ChangesPlace?

    @ObservationIgnored private var closed = false
    @ObservationIgnored private var again = false

    var files: [ChangedFile] { listing?.files ?? [] }

    /// Reads the place's changes; one read at a time, the last asked wins.
    func refresh(_ asked: ChangesPlace?) {
        let asked = override ?? asked
        if asked != place {
            place = asked
            listing = nil
            rows = []
            open = nil
            closed = false
            note = asked == nil ? "No folder" : nil
        }
        guard let asked else { return }
        guard !loading else {
            again = true
            return
        }
        loading = true
        Task {
            var found: ChangesReader.Listing?
            var failure: String?
            do { found = try await ChangesReader.list(asked) } catch let error as ChangesReader.Failure {
                failure = error.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { failure = "\(error)" }
            if place == asked {
                if let failure {
                    listing = nil
                    note = failure.isEmpty ? "Couldn't read the changes" : String(failure.prefix(200))
                } else if let found {
                    if found.files != listing?.files || found.root != listing?.root { listing = found }
                    note = found.files.isEmpty ? "No uncommitted changes" : nil
                    if let open, !found.files.contains(where: { $0.path == open }) {
                        self.open = nil
                        rows = []
                    }
                    // The first file's diff shows until another is picked.
                    if open == nil, !closed, let first = found.files.first { open = first.path }
                    await loadDiff(at: asked)
                } else {
                    listing = nil
                    rows = []
                    open = nil
                    note = "Not a git repository"
                }
            }
            loading = false
            if again {
                again = false
                refresh(place)
            }
        }
    }

    func pick(_ path: String) {
        open = open == path ? nil : path
        closed = open == nil
        rows = []
        guard let place, open != nil else { return }
        Task { await loadDiff(at: place) }
    }

    private func loadDiff(at asked: ChangesPlace) async {
        guard let listing, let path = open, let file = listing.files.first(where: { $0.path == path }) else { return }
        var found: [ChangeRow]
        do { found = try await ChangesReader.diff(of: file, in: listing, on: asked.machine) } catch {
            found = [ChangeRow(id: 0, kind: .note, text: "This diff can't be shown (too large or unreadable)")]
        }
        guard place == asked, open == path, found != rows else { return }
        rows = found
    }
}

/// The panel's colors, by the light or dark it is drawn in: fixed ones,
/// since the system's follow the window, not the card the panel may be on.
private struct ChangeColors {
    var added: Color
    var removed: Color
    var changed: Color

    init(dark: Bool) {
        added = dark ? Color(red: 0.2, green: 0.84, blue: 0.3) : Color(red: 0.11, green: 0.55, blue: 0.22)
        removed = dark ? Color(red: 1, green: 0.41, blue: 0.38) : Color(red: 0.82, green: 0.1, blue: 0.14)
        changed = dark ? Color(red: 1, green: 0.62, blue: 0.04) : Color(red: 0.77, green: 0.43, blue: 0)
    }
}

struct ChangesPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    /// False while another mod shows in its place, or the sidebar is
    /// hidden: nothing is read then.
    var shown = true
    @State private var tick = 0
    /// While the line under the files is dragged: their height when it was
    /// pressed, and now.
    @State private var resizeFrom: CGFloat?
    @State private var resizedTo: CGFloat?

    private struct Trigger: Hashable {
        var place: ChangesPlace?
        var shown: Bool
        var tick: Int
    }

    var body: some View {
        let changes = ChangesModel.shared
        let place = focusedPlace
        VStack(spacing: 0) {
            header(changes)
            if changes.files.isEmpty {
                Text(changes.note ?? (changes.loading ? "Reading the changes…" : "No uncommitted changes"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                Spacer(minLength: 0)
            } else {
                GeometryReader { box in
                    let total = box.size.height
                    let height = listHeight(files: changes.files.count, in: total)
                    VStack(spacing: 0) {
                        fileList(changes)
                            .frame(height: height)
                        // The line between the files and the diff, to drag,
                        // as the one between the left sidebar's lists.
                        Divider()
                            .frame(height: Self.dividerBand)
                            .overlay {
                                ModGrip(sideways: false, name: "changes") { down in
                                    let from = resizeFrom ?? height
                                    resizeFrom = from
                                    resizedTo = Self.clamp(from + down, in: total)
                                } ended: {
                                    if let to = resizedTo, total > 0 { Mods.shared.changesShare = Double(to / total) }
                                    resizeFrom = nil
                                    resizedTo = nil
                                }
                            }
                        ChangesDiff(rows: changes.rows, empty: changes.open == nil ? "Pick a file to see its changes" : "", font: font, colors: colors)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Read on show, when the folder changes, and every few seconds.
        .task(id: Trigger(place: place, shown: shown, tick: tick)) {
            guard shown else { return }
            changes.refresh(place)
            try? await Task.sleep(for: .seconds(place?.machine == nil ? 4 : 12))
            if !Task.isCancelled, NSApp.isActive { tick &+= 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick &+= 1 }
        .accessibilityIdentifier("changes-panel")
    }

    private static let rowHeight: CGFloat = 26
    /// The band between the files and the diff: a line in its middle, and
    /// room to grab it.
    private static let dividerBand: CGFloat = 7
    /// The least height the files keep, and the diff.
    private static let listFloor: CGFloat = 60
    private static let diffFloor: CGFloat = 90

    /// The files' height: the share the line was dragged to, and until
    /// then two fifths of the panel. Never more than the files need: a
    /// short list leaves its room to the diff.
    private func listHeight(files: Int, in total: CGFloat) -> CGFloat {
        let need = max(CGFloat(files) * Self.rowHeight + 8, Self.listFloor)
        let asked = resizedTo ?? total * CGFloat(Mods.shared.changesShare ?? 0.4)
        return Self.clamp(min(asked, need), in: total)
    }

    private static func clamp(_ height: CGFloat, in total: CGFloat) -> CGFloat {
        min(max(height, listFloor), max(listFloor, total - dividerBand - diffFloor))
    }

    private var colors: ChangeColors { ChangeColors(dark: scheme == .dark) }

    private var font: Font { Font(NSFont(name: model.prefs.fontName, size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)) }

    /// The focused terminal's folder, and its machine.
    private var focusedPlace: ChangesPlace? {
        guard let space = model.activeSpace, let address = model.focusedAddress, let terminal = model.store.model(address) else { return nil }
        let folder = terminal.currentFolder
        guard !folder.isEmpty else { return nil }
        let machine = address.contains("/") ? String(address.split(separator: "/")[0]) : space.machine
        return ChangesPlace(folder: folder, machine: machine.isEmpty ? nil : machine)
    }

    private func header(_ changes: ChangesModel) -> some View {
        let files = changes.files
        let added = files.reduce(0) { $0 + $1.added }, deleted = files.reduce(0) { $0 + $1.deleted }
        return HStack(spacing: 8) {
            Text("Changes")
                .fontWeight(.semibold)
            if !files.isEmpty {
                Text(files.count == 1 ? "1 file" : "\(files.count)\(changes.listing?.limited == true ? "+" : "") files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if added > 0 { Text("+\(added)").foregroundStyle(colors.added) }
            if deleted > 0 { Text("−\(deleted)").foregroundStyle(colors.removed) }
        }
        .font(.callout)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .help(changes.listing?.root ?? "")
    }

    private func fileList(_ changes: ChangesModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(changes.files) { file in
                    FileRow(file: file, open: file.path == changes.open, colors: colors) { changes.pick(file.path) }
                        .frame(height: Self.rowHeight)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
    }
}

private struct FileRow: View {
    let file: ChangedFile
    let open: Bool
    let colors: ChangeColors
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        let cut = file.path.lastIndex(of: "/")
        let folder = cut.map { String(file.path[...$0]) } ?? ""
        let name = cut.map { String(file.path[file.path.index(after: $0)...]) } ?? file.path
        Button(action: pick) {
            HStack(spacing: 8) {
                Text(String(file.status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 12)
                // The name stays whole; its folder gives way, from its start.
                HStack(spacing: 0) {
                    Text(folder)
                        .foregroundStyle(.tertiary)
                        .truncationMode(.head)
                        .layoutPriority(0)
                    Text(name)
                        .layoutPriority(1)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                Group {
                    if file.added > 0 { Text("+\(file.added)").foregroundStyle(colors.added) }
                    if file.deleted > 0 { Text("−\(file.deleted)").foregroundStyle(colors.removed) }
                }
                .font(.caption)
                .monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.primary.opacity(open ? 0.1 : hovered ? 0.05 : 0), in: .rect(cornerRadius: 7))
        .onHover { hovered = $0 }
        .help(file.path)
        .accessibilityAddTraits(open ? .isSelected : [])
    }

    private var color: Color {
        switch file.status {
        case "A": colors.added
        case "D", "U": colors.removed
        default: colors.changed
        }
    }
}

/// A diff's lines: numbered, the added and removed ones tinted. It scrolls
/// both ways, and only draws the lines in sight.
private struct ChangesDiff: View {
    let rows: [ChangeRow]
    let empty: String
    let font: Font
    let colors: ChangeColors

    var body: some View {
        if rows.isEmpty {
            Text(empty)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 14)
                .padding(.top, 8)
        } else {
            GeometryReader { box in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            line(row)
                        }
                    }
                    // Tints reach the panel's edge, and past it with the longest line.
                    .frame(minWidth: box.size.width, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func line(_ row: ChangeRow) -> some View {
        HStack(spacing: 10) {
            Text(row.number.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)
            Text(row.text.isEmpty ? " " : row.text)
                .foregroundStyle(row.kind == .hunk || row.kind == .note ? .secondary : .primary)
                .fixedSize()
            Spacer(minLength: 8)
        }
        .font(font)
        .lineLimit(1)
        .frame(height: 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint(row.kind))
    }

    private func tint(_ kind: ChangeRow.Kind) -> Color {
        switch kind {
        case .added: colors.added.opacity(0.16)
        case .removed: colors.removed.opacity(0.16)
        case .hunk: .primary.opacity(0.06)
        case .same, .note: .clear
        }
    }
}
