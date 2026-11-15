import HerdrKit
import SwiftUI

/// The herdr-core pane's updates: this Mac's core against the latest
/// release, each other machine against this Mac, and when Swiftr last looked.
struct CoreUpdatesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates!
        Section {
            ForEach(model.machineItems) { machine in
                if machine.name.isEmpty {
                    ThisMacRow(machine: machine)
                    if case .update = updates.offer, let release = updates.latest, !release.notes.isEmpty {
                        ReleaseNotes(release: release)
                    }
                } else {
                    MachineRow(machine: machine, version: model.remotes.first { $0.name == machine.name }?.version ?? "")
                }
            }
            LastCheckRow()
        } header: {
            Text("Updates")
        } footer: {
            SettingsNote("Swiftr asks releases.herdr.dev when this pane opens, at most once an hour. Terminals keep running through an update: herdr-core restarts and Swiftr connects again. Another machine gets the herdr-core this Mac runs, so update this Mac first.")
        }
        .task { updates.checkIfStale() }
    }
}

/// This Mac's core: its version, and the latest release when it is newer.
private struct ThisMacRow: View {
    @Environment(AppModel.self) private var model
    let machine: MachineItem

    var body: some View {
        let updates = model.updates!
        LabeledContent {
            switch updates.steps[""] {
            case .updating:
                Working(word: "Updating…")
            case .restarting:
                Working(word: "Restarting…")
            case .failed:
                Button("Try Again") { updates.updateThisMac() }
                    .disabled(updates.busy || updates.thisMac == nil)
            case nil:
                offer(updates)
            }
        } label: {
            MachineLabel(machine: machine) { detail(updates) }
        }
    }

    @ViewBuilder private func offer(_ updates: CoreUpdates) -> some View {
        switch updates.offer {
        case .update(let version):
            Button("Update to \(version)") { updates.updateThisMac() }
                .buttonStyle(.borderedProminent)
                .disabled(updates.busy)
        case .upToDate:
            UpToDate()
        case .needsNewerSwiftr:
            Text("Needs a newer Swiftr")
                .foregroundStyle(.secondary)
        case .managed(let by):
            Text("Updated by \(by.capitalized)")
                .foregroundStyle(.secondary)
        case .unknown:
            if updates.checking {
                Working(word: "Checking…")
            } else if updates.thisMac == nil {
                Text("Not connected")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ updates: CoreUpdates) -> Text {
        if case .failed(let why, let hint) = updates.steps[""] {
            return Text("The update failed: \(why)" + (hint.map { " \($0)" } ?? ""))
                .foregroundStyle(.red)
        }
        guard let version = updates.thisMac else { return Text("herdr-core") }
        switch updates.offer {
        case .update(let next):
            return Text("herdr-core \(version) · \(next) is out")
        case .needsNewerSwiftr(let next):
            return Text("herdr-core \(version) · \(next) speaks a protocol this Swiftr doesn't yet")
        case .managed(let by):
            return Text("herdr-core \(version) · update it with \(by.capitalized)")
        case .upToDate, .unknown:
            return Text("herdr-core \(version)")
        }
    }
}

/// Another machine's core: its version, and this Mac's when that is newer.
private struct MachineRow: View {
    @Environment(AppModel.self) private var model
    let machine: MachineItem
    /// Its hc version when last seen.
    let version: String

    var body: some View {
        let updates = model.updates!
        LabeledContent {
            switch updates.steps[machine.name] {
            case .updating:
                Working(word: "Updating…")
            case .restarting:
                Working(word: "Restarting…")
            case .failed:
                Button("Try Again") { updates.update(machine: machine.name) }
                    .disabled(updates.busy || !machine.isConnected)
            case nil:
                if !machine.isConnected {
                    Text(stateWord)
                        .foregroundStyle(.secondary)
                } else if let target = updates.machineUpdate(from: version) {
                    Button("Update to \(target)") { updates.update(machine: machine.name) }
                        .disabled(updates.busy)
                } else if updates.offer == .upToDate {
                    UpToDate()
                }
            }
        } label: {
            MachineLabel(machine: machine) {
                if case .failed(let why, let hint) = updates.steps[machine.name] {
                    Text("The update failed: \(why)" + (hint.map { " \($0)" } ?? ""))
                        .foregroundStyle(.red)
                } else {
                    Text(version.isEmpty ? "herdr-core" : "herdr-core \(version)")
                }
            }
        }
    }

    private var stateWord: String {
        switch machine.state {
        case "connecting": "Connecting…"
        case "needs_login": "Needs login"
        default: "Unreachable"
        }
    }
}

/// A machine's icon and name, and a line under the name.
private struct MachineLabel<Detail: View>: View {
    let machine: MachineItem
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: machine.icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.title)
                detail
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What the latest release brings, under this Mac's row.
private struct ReleaseNotes: View {
    let release: CoreRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What's new in \(release.version)")
                .font(.callout.weight(.semibold))
            Text(notes)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notes: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: release.notes, options: options)) ?? AttributedString(release.notes)
    }
}

/// When Swiftr last asked for the latest release, and a button to ask now.
private struct LastCheckRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates!
        LabeledContent {
            HStack(spacing: 8) {
                if updates.checking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Check Now") { updates.checkNow() }
                    .disabled(updates.checking)
            }
        } label: {
            Text("Last checked")
            if let error = updates.checkError {
                Text("Swiftr couldn't check: \(error)")
                    .foregroundStyle(.red)
            } else if let at = updates.checkedAt {
                Text(at.formatted(date: Calendar.current.isDateInToday(at) ? .omitted : .abbreviated, time: .shortened))
            } else {
                Text("Not yet")
            }
        }
    }
}

private struct Working: View {
    let word: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(word)
                .foregroundStyle(.secondary)
        }
    }
}

private struct UpToDate: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Up to date")
                .foregroundStyle(.secondary)
        }
    }
}
