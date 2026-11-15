import AppKit
import HerdrKit
import SwiftUI

/// The Updates pane, which Swiftr › Check for Updates… opens: Swiftr,
/// herdr-core and the downloaded models, what each can take, and how often
/// Swiftr looks by itself.
struct UpdatesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var center = model.updateCenter!
        let models = ModelUpdates.shared
        let shownModels = models.targets.filter { models.available[$0.key] != nil || models.steps[$0.key] != nil || models.failures[$0.key] != nil }
        Form {
            Section {
                UpdatesSummary()
            }
            Section("Swiftr") {
                SwiftrUpdateRow(app: center.app)
            }
            Section("herdr-core") {
                ForEach(model.machineItems) { machine in
                    if machine.name.isEmpty {
                        CoreThisMacRow(machine: machine)
                        if case .update = model.updates.offer, let release = model.updates.latest, !release.notes.isEmpty {
                            CoreReleaseNotes(release: release)
                        }
                    } else {
                        CoreMachineRow(machine: machine, version: model.remotes.first { $0.name == machine.name }?.version ?? "")
                    }
                }
            }
            if !models.targets.isEmpty {
                Section("Models") {
                    ForEach(shownModels, id: \.key) { target in
                        ModelUpdateRow(target: target)
                    }
                    if shownModels.isEmpty {
                        LabeledContent {
                            if models.checking { UpdateWorking(word: "Checking…") } else if models.checkedAt != nil { UpToDateMark() }
                        } label: {
                            UpdateRowLabel(symbol: "waveform") {
                                Text("Voice and dictation models")
                            } detail: {
                                Text("\(models.targets.count) downloaded")
                            }
                        }
                    }
                }
            }
            Section {
                Picker("Check for updates", selection: $center.hours) {
                    ForEach(hourChoices(center.hours), id: \.self) { hours in
                        Text(UpdateSchedule.label(hours: hours)).tag(hours)
                    }
                    Divider()
                    Text(UpdateSchedule.label(hours: 0)).tag(0)
                }
            } footer: {
                SettingsNote("Swiftr looks at launch, then at this pace, and marks the sidebar when it finds something. It installs nothing by itself.")
            }
        }
        .formStyle(.grouped)
    }

    /// The paces on offer, and the saved one when it is another.
    private func hourChoices(_ saved: Int) -> [Int] {
        (UpdateSchedule.choices + (saved > 0 ? [saved] : [])).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }.sorted()
    }
}

/// How things stand, when Swiftr last looked, and the two buttons.
private struct UpdatesSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let center = model.updateCenter!
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title(center))
                    .font(.headline)
                ForEach(problems(center), id: \.self) { problem in
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(checked(center))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if center.checking {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Check Now") { center.checkNow() }
                .disabled(center.checking)
            if center.count > 0 || center.updatingAll {
                Button("Update All") { center.updateAll() }
                    .buttonStyle(.borderedProminent)
                    .disabled(center.busy)
            }
        }
        .padding(.vertical, 2)
    }

    private func title(_ center: UpdateCenter) -> String {
        if center.updatingAll { return "Updating…" }
        switch center.count {
        case 0:
            if center.checkedAt == nil { return center.checking ? "Checking for updates…" : "Not checked yet" }
            return problems(center).isEmpty ? "Everything is up to date" : "Swiftr couldn't check everything"
        case 1: return "1 update is ready"
        default: return "\(center.count) updates are ready"
        }
    }

    /// What couldn't be asked, by name.
    private func problems(_ center: UpdateCenter) -> [String] {
        [("Swiftr", center.app.checkError), ("herdr-core", model.updates.checkError), ("Models", ModelUpdates.shared.checkError)]
            .compactMap { name, error in error.map { "\(name): \($0)" } }
    }

    private func checked(_ center: UpdateCenter) -> String {
        guard let at = center.checkedAt else { return "Swiftr looks for Swiftr, herdr-core and your models at once." }
        return "Last checked " + at.formatted(date: Calendar.current.isDateInToday(at) ? .omitted : .abbreviated, time: .shortened)
    }
}

/// Swiftr itself: its version, and the newer one when there is one.
private struct SwiftrUpdateRow: View {
    let app: AppUpdate

    var body: some View {
        LabeledContent {
            switch app.step {
            case .updating:
                UpdateWorking(word: "Upgrading…")
            case .restarting:
                UpdateWorking(word: "Restarting…")
            case .failed:
                Button("Try Again") { app.install() }
            case nil:
                offer
            }
        } label: {
            UpdateRowLabel {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
            } title: {
                Text("Swiftr")
            } detail: {
                detail
            }
        }
    }

    @ViewBuilder private var offer: some View {
        if app.way == .source {
            Text("Built from source")
                .foregroundStyle(.secondary)
        } else if let latest = app.latest {
            if app.blocked == nil {
                Button("Update to \(latest)") { app.install() }
                    .buttonStyle(.borderedProminent)
            }
        } else if app.checking {
            UpdateWorking(word: "Checking…")
        } else if app.checkError == nil {
            UpToDateMark()
        }
    }

    private var detail: Text {
        let version = "Swiftr \(AppUpdate.version)"
        if case .failed(let why) = app.step {
            return Text("The update failed: \(why)").foregroundStyle(.red)
        }
        if let blocked = app.blocked { return Text("\(version) · \(blocked)") }
        switch app.way {
        case .source:
            return Text("\(version) · update it with git pull and scripts/install.sh")
        case .homebrew:
            return Text(app.latest.map { "\(version) · \($0) is out, and Homebrew installs it" } ?? "\(version) · installed with Homebrew")
        case .sparkle:
            return Text(app.latest.map { "\(version) · \($0) is out" } ?? version)
        }
    }
}

/// A downloaded model with a newer version out, on its way in, or refused.
private struct ModelUpdateRow: View {
    let target: ModelUpdates.Target

    var body: some View {
        let updates = ModelUpdates.shared
        LabeledContent {
            switch updates.steps[target.key] {
            case .downloading(let done, let total):
                DownloadProgress(done: done, total: total, stopHelp: "Stop Update") { updates.cancel(target.key) }
            case .installing:
                UpdateWorking(word: "Installing…")
                    .help("Swiftr loads the new version once to see it works.")
            case nil:
                if updates.available[target.key] != nil {
                    Button("Update") { updates.update(target) }
                }
            }
        } label: {
            UpdateRowLabel(symbol: target.key.hasPrefix("dictation/") ? "mic" : "speaker.wave.2") {
                Text(target.name)
            } detail: {
                // The row has its picture already.
                ModelUpdateNote(key: target.key)
                    .labelStyle(.titleOnly)
            }
        }
    }
}

/// A row's picture and name, and a line under the name: as herdr-core's rows.
private struct UpdateRowLabel<Icon: View, Title: View, Detail: View>: View {
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 22)
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

extension UpdateRowLabel where Icon == AnyView {
    init(symbol: String, @ViewBuilder title: () -> Title, @ViewBuilder detail: () -> Detail) {
        self.init(icon: { AnyView(Image(systemName: symbol).foregroundStyle(.secondary)) }, title: title, detail: detail)
    }
}

/// Swiftr › Check for Updates…: the pane opens and Swiftr looks now.
struct CheckForUpdatesButton: View {
    @Environment(\.openSettings) private var openSettings
    let model: AppModel

    var body: some View {
        Button("Check for Updates…") { UpdatesSettings.open(model, with: openSettings) }
    }
}

extension UpdatesSettings {
    static func open(_ model: AppModel, with openSettings: OpenSettingsAction, checking: Bool = true) {
        UserDefaults.standard.set(SettingsPane.updates.rawValue, forKey: SettingsPane.defaultsKey)
        openSettings()
        if checking { model.updateCenter.checkNow() }
    }
}

/// At the sidebar's foot once a look found something: how many updates
/// wait. A click opens the pane.
struct UpdatesMark: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let count = model.updateCenter.count
        if count > 0 {
            Button {
                UpdatesSettings.open(model, with: openSettings, checking: false)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                    Text(count == 1 ? "1 update" : "\(count) updates")
                    Spacer(minLength: 0)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
            .help("Show the updates")
        }
    }
}
