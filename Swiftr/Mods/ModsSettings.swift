import AppKit
import ModKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Mods: the layout the window follows, shown as pictures; the
/// mods, what each may do and where it shows; and the ones to bring over
/// from herdr-app.
struct ModsSettings: View {
    var body: some View {
        let mods = Mods.shared
        // The layout's tree changes in place.
        let _ = mods.revision
        Form {
            Section {
                LayoutGallery()
                HStack {
                    Button("Add Layout…") { chooseLayout() }
                    Button("Open Layouts Folder") { NSWorkspace.shared.open(mods.home.appending(path: "layouts")) }
                    Spacer()
                }
                if mods.panel != nil {
                    Toggle(isOn: Binding(get: { mods.panelShown }, set: { _ in mods.togglePanel() })) {
                        HStack(spacing: 8) {
                            Text("Show the mods sidebar")
                            KeyCap(label: "⌥⌘B", small: true)
                        }
                    }
                }
            } header: {
                Text("Layout")
            } footer: {
                SettingsNote("With Swiftr's own, your mods share a sidebar on the right. A layout file, in herdr-app's format, puts them around the tab instead; Swiftr keeps its own sidebar and tabs.")
            }
            Section {
                // Swiftr's own panel: nothing to allow, only where it shows.
                LabeledContent {
                    Toggle("Show Changes", isOn: Binding(get: { mods.isInPanel("changes") }, set: { mods.setInPanel("changes", $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .help("Show Changes in the mods sidebar")
                } label: {
                    ModRowLabel {
                        Image(systemName: "plusminus")
                    } title: {
                        Text("Changes")
                            .fontWeight(.semibold)
                    } detail: {
                        Text("Built in. The uncommitted changes of the focused terminal's folder; it only reads.")
                    }
                }
                .padding(.vertical, 4)
                ForEach(mods.entries) { entry in
                    ModRow(entry: entry)
                }
                HStack {
                    Button("Add Mod…") { chooseMod() }
                    Button("Add from Link…") { mods.linkAdd.open() }
                        .help("Add a mod or a layout someone shared")
                    Button("Open Mods Folder") { NSWorkspace.shared.open(mods.center.modsFolder) }
                    Spacer()
                }
            } header: {
                Text("Mods")
            } footer: {
                SettingsNote("A mod is a small program that draws a panel. Ask your coding agent for one (its guide is AGENTS.md in the mods folder), or add one someone shared, written for Swiftr or herdr-app. It runs only once you allow what its files ask for.")
            }
            let waiting = mods.importable
            if !waiting.isEmpty {
                Section {
                    ForEach(waiting, id: \.self) { name in
                        LabeledContent {
                            Button {
                                mods.importFromHerdr(name)
                            } label: {
                                Label("Add", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy \(name) to Swiftr")
                        } label: {
                            ModRowLabel {
                                Image(systemName: "puzzlepiece.extension")
                            } title: {
                                Text(name)
                            } detail: {
                                EmptyView()
                            }
                        }
                    }
                } header: {
                    Text("From herdr-app")
                } footer: {
                    SettingsNote("Your herdr-app mods that Swiftr doesn't have. Adding one copies it; it stays off until you allow it.")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { mods.linkAdd.shown }, set: { mods.linkAdd.shown = $0 })) {
            LinkAddSheet(state: mods.linkAdd)
        }
    }

    private func chooseLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/herdr-app/layouts")
        panel.message = "Choose a herdr-app layout file."
        if panel.runModal() == .OK, let url = panel.url { Mods.shared.add(layout: url) }
    }

    private func chooseMod() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a mod's folder: the one that holds main.js."
        if panel.runModal() == .OK { for url in panel.urls { Mods.shared.add(folder: url) } }
    }
}

// MARK: Layouts

/// Swiftr's own layout and each layout file, drawn as the window would be
/// with it: a click picks it.
private struct LayoutGallery: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var removing: String?

    var body: some View {
        let mods = Mods.shared
        let has = Set(Mods.builtIn + mods.entries.map(\.name))
        let chosen = mods.layoutName ?? ""
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 16)], alignment: .leading, spacing: 14) {
            ForEach([""] + mods.layoutNames, id: \.self) { name in
                let layout = name.isEmpty ? WindowLayout.own(mods: mods.panelMods) : mods.preview(layout: name)
                Button {
                    withAnimation(.snappy(duration: 0.25)) { mods.loadLayout(named: name) }
                } label: {
                    VStack(spacing: 6) {
                        LayoutPicture(dark: scheme == .dark, theme: model.prefs.theme, layout: layout, has: has, sidebar: mods.sidebarStyle)
                            .frame(height: 84)
                            .tileFrame(chosen: name == chosen)
                        VStack(spacing: 1) {
                            Text(name.isEmpty ? "Swiftr's own" : name)
                                .font(.callout)
                                .foregroundStyle(name == chosen ? .primary : .secondary)
                                .lineLimit(1)
                            Text(caption(name, layout, has))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name.isEmpty ? "Swiftr's own" : name)
                .accessibilityAddTraits(name == chosen ? .isSelected : [])
                .contextMenu {
                    if !name.isEmpty {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([mods.home.appending(path: "layouts/\(name).json")])
                        }
                        Button("Remove…") { removing = name }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Remove the layout \(removing ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let removing { mods.remove(layout: removing) }
                removing = nil
            }
        } message: {
            Text("Its file goes to the Trash. Your mods stay.")
        }
    }

    /// How many of the layout's mods the person has.
    private func caption(_ name: String, _ layout: WindowLayout?, _ has: Set<String>) -> String {
        let wanted = layout?.mods ?? []
        if name.isEmpty { return wanted.isEmpty ? "No mods yet" : "Mods in a sidebar" }
        let here = wanted.filter(has.contains).count
        if wanted.isEmpty { return "No mods" }
        return here == wanted.count ? (here == 1 ? "1 mod" : "\(here) mods") : "\(here) of \(wanted.count) mods added"
    }
}

// MARK: Mods

/// A row's left part, as the Updates pane lays its rows out: an icon, a
/// title, and a quieter line under it.
private struct ModRowLabel<Icon: View, Title: View, Detail: View>: View {
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                title
                detail
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A mod: where it shows, what its files ask for, and the control that
/// lets it run. What it asks stays in sight beside that control.
private struct ModRow: View {
    let entry: Mods.Entry
    @State private var confirmingRemove = false

    var body: some View {
        let mods = Mods.shared
        let _ = mods.reloads(of: entry.name)
        let lacking = (mods.center.loaded(entry.name)?.unsupported ?? [:]).sorted { $0.value > $1.value }.map(\.key)
        HStack(alignment: .top, spacing: 12) {
            ModRowLabel {
                ModIcon(name: entry.name, revision: mods.reloads(of: entry.name))
            } title: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.manifest.title)
                        .fontWeight(.semibold)
                    if !entry.allowed {
                        Text("Needs your OK")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.14), in: Capsule())
                    }
                }
            } detail: {
                Text(entry.origin.map { "\(mods.place(of: entry.name)) · from \($0)" } ?? mods.place(of: entry.name))
                    .lineLimit(1)
                    .truncationMode(.middle)
                VStack(alignment: .leading, spacing: 3) {
                    ModAsks(report: entry.report)
                    // Known once the mod has run: what it calls that Swiftr
                    // has no drawing for.
                    if !lacking.isEmpty {
                        Label("Calls parts Swiftr lacks: \(lacking.prefix(6).joined(separator: ", "))\(lacking.count > 6 ? "…" : "")", systemImage: "exclamationmark.triangle")
                            .help(lacking.joined(separator: ", "))
                    }
                }
                .labelStyle(AskLabelStyle())
                .padding(.top, 3)
            }
            .help("\(entry.name): \(entry.report.files) files, \(entry.report.lines) lines")
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                if entry.allowed {
                    Toggle("Allowed", isOn: Binding(get: { true }, set: { if !$0 { mods.disallow(entry.name) } }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .help("Stop \(entry.manifest.title)")
                } else {
                    Button("Allow") { mods.allow(entry.name) }
                        .help("Let \(entry.manifest.title) do what is listed")
                }
                Menu {
                    if mods.layoutName == nil {
                        Toggle("Show in the Mods Sidebar", isOn: Binding(get: { mods.isInPanel(entry.name) }, set: { mods.setInPanel(entry.name, $0) }))
                    }
                    Button("Show Files") { NSWorkspace.shared.open(mods.center.modsFolder.appending(path: entry.name)) }
                    Divider()
                    Button("Remove…") { confirmingRemove = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Remove \(entry.manifest.title)?", isPresented: $confirmingRemove) {
            Button("Move to Trash", role: .destructive) { mods.remove(entry.name) }
        } message: {
            Text("Its folder goes to the Trash, with what it kept there.")
        }
        .accessibilityIdentifier("mod-row-\(entry.name)")
    }
}

/// What a mod's files ask for, a line each, and the programs they name.
private struct ModAsks: View {
    let report: ModScan.Report

    /// What a mod can ask for, each with its symbol.
    private static let asks: [(ModCapabilities, String)] = [
        (.programs, "terminal"), (.writeFiles, "square.and.pencil"), (.readFiles, "folder"),
        (.network, "network"), (.commands, "command"),
    ]

    var body: some View {
        if report.needs.isEmpty {
            Label("Only draws its panel", systemImage: "checkmark.circle")
        }
        ForEach(Self.asks.filter { report.needs.contains($0.0) }, id: \.1) { ask, symbol in
            Label(ask.sentences.first ?? "", systemImage: symbol)
        }
        if !report.programs.isEmpty {
            Text(report.programs.joined(separator: ", "))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.leading, 24)
        }
    }
}

// MARK: Add from a link

/// Settings › Mods › Add from Link: what the person pasted, and what came
/// of it.
@Observable
final class LinkAdd {
    var shown = false
    var text = ""
    private(set) var busy = false
    private(set) var added: ModFetch.Added?
    private(set) var failure: String?

    func open() {
        text = ""
        added = nil
        failure = nil
        shown = true
    }

    func run() {
        guard !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        failure = nil
        Task {
            switch await Mods.shared.add(link: text) {
            case .success(let added): self.added = added
            case .failure(let failure): self.failure = failure.description
            }
            busy = false
        }
    }
}

/// The sheet: a field for the link, then what was copied and what each
/// mod asks for. Nothing runs from here: the mods wait in the list.
private struct LinkAddSheet: View {
    @Bindable var state: LinkAdd
    @FocusState private var inField: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.added == nil ? "Add from a Link" : "Added")
                .font(.headline)
            if let added = state.added {
                result(added)
            } else {
                TextField("Link", text: $state.text, prompt: Text("herdr.dev/mods/owner/name or github.com/owner/repo"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($inField)
                    .disabled(state.busy)
                    .onSubmit { state.run() }
                    .accessibilityIdentifier("mod-link-field")
                SettingsNote("A page of herdr.dev's gallery, or a folder on GitHub. Swiftr copies the files and runs nothing: a mod stays off until you allow it, and nothing you have is replaced.")
                if let failure = state.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if state.busy {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.added == nil {
                    Button("Cancel", role: .cancel) { state.shown = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Add") { state.run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(state.busy || state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Done") { state.shown = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { inField = true }
    }

    @ViewBuilder
    private func result(_ added: ModFetch.Added) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(added.mods, id: \.self) { name in
                ModRowLabel {
                    Image(systemName: "puzzlepiece.extension")
                } title: {
                    Text(name)
                        .fontWeight(.semibold)
                } detail: {
                    VStack(alignment: .leading, spacing: 3) {
                        if let report = added.reports[name] { ModAsks(report: report) }
                    }
                    .labelStyle(AskLabelStyle())
                    .padding(.top, 1)
                }
            }
            ForEach(added.layouts, id: \.self) { name in
                ModRowLabel {
                    Image(systemName: "rectangle.split.3x1")
                } title: {
                    Text(name)
                        .fontWeight(.semibold)
                } detail: {
                    Text("Layout. Pick it at the top of this pane.")
                }
            }
            if !added.skipped.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Left out")
                        .font(.callout.weight(.medium))
                    ForEach(added.skipped, id: \.self) { line in
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !added.mods.isEmpty {
                SettingsNote(added.mods.count == 1 ? "It is off. Read what it asks for, then allow it in the list." : "They are off. Read what each asks for, then allow them in the list.")
            }
        }
    }
}

/// A line of what a mod asks: its symbol in a column, the words beside it.
private struct AskLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .font(.caption)
                .frame(width: 18)
            configuration.title
        }
    }
}
