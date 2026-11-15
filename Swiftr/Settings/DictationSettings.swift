import AppKit
import HerdrKit
import SwiftUI

/// The Dictation pane, a section for each thing it does: how a dictation
/// goes and the key to hold; the tidy-up; the names to write as spelled.
/// Each shows the model it runs on, to download there.
struct DictationSettings: View {
    @AppStorage(Dictation.tidyDefaults) private var tidies = true
    @AppStorage(Dictation.wordsDefaults) private var words = ""

    var body: some View {
        let library = DictationLibrary.shared
        let tidyReady = library.isInstalled(DictationCatalog.tidy)
        Form {
            Section {
                DictationFlow()
                DictationModelRow(model: DictationCatalog.speech)
            } header: {
                Text("Speech to text")
            } footer: {
                SettingsNote("Or click the microphone beside Send. The text goes where the cursor is; nothing is sent.")
            }
            Section {
                HStack(spacing: 12) {
                    TidyPicture(on: tidies && tidyReady)
                        .frame(maxWidth: .infinity)
                    Toggle("Tidy up the text", isOn: $tidies)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!tidyReady)
                        .help(tidyReady ? "Tidy up the text" : "Download Qwen3 below first")
                }
                .padding(.vertical, 8)
                DictationModelRow(model: DictationCatalog.tidy)
            } header: {
                Text("Tidy-up")
            }
            Section {
                VocabularyPicture()
                WordChips(text: $words)
                DictationModelRow(model: DictationCatalog.vocabulary)
            } header: {
                Text("Vocabulary")
            } footer: {
                SettingsNote("The names the conversation uses count too.")
            }
            if DictationCatalog.models.contains(where: { library.isInstalled($0) }) {
                Section {
                    ModelUpdatesRow()
                } footer: {
                    SettingsNote("The models run on this Mac: what you say stays on it.")
                }
            }
        }
        .formStyle(.grouped)
        .dictationAccent()
    }
}

// MARK: Models

/// A model, in the section of what it does: its sign, its name, what it
/// takes, and its buttons.
struct DictationModelRow: View {
    let model: DictationModel
    @State private var confirmingDelete = false

    var body: some View {
        let library = DictationLibrary.shared
        let state = library.state(model)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                ModelGlyph(role: model.role, faded: state != .installed)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.name)
                            .fontWeight(.medium)
                        if model.role == .speech, state != .installed {
                            Text("Needed")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(model.about)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(model.credits)
                Spacer(minLength: 8)
                actions(state)
            }
            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if state == .installed {
                ModelUpdateNote(key: DictationLibrary.key(model))
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Delete \(model.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { library.delete(model) }
        } message: {
            Text("The \(ModelBytes.text(DictationLibrary.used(model))) it takes come back. You can download it again later.")
        }
    }

    @ViewBuilder private func actions(_ state: DictationLibrary.State) -> some View {
        let library = DictationLibrary.shared
        switch state {
        case .absent:
            HStack(spacing: 10) {
                Text(ModelBytes.text(model.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Download") { library.download(model) }
                    .buttonStyle(.borderedProminent)
            }
        case .downloading(let done, let total):
            DownloadProgress(done: done, total: total, stopHelp: "Stop Download") { library.cancel(model) }
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing…").foregroundStyle(.secondary)
            }
            .help("The first time, the Neural Engine readies it: a few seconds.")
        case .installed:
            DownloadedActions(key: DictationLibrary.key(model), used: DictationLibrary.used(model),
                              update: { library.update(model) }, stop: { library.cancel(model) },
                              delete: { confirmingDelete = true })
        case .failed:
            Button("Try Again") { library.download(model) }
        }
    }
}

/// What a model does, as a sign on a tile in the accent's colors; gray
/// until it's downloaded.
private struct ModelGlyph: View {
    @Environment(\.themeAccent) private var themeAccent
    @Environment(\.self) private var environment
    let role: DictationModel.Role
    let faded: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let accent = themeAccent ?? .accentColor
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(faded ? AnyShapeStyle(.secondary) : AnyShapeStyle(ChatStyle.ink(on: accent.resolve(in: environment))))
            .frame(width: 28, height: 28)
            .background {
                if faded {
                    shape.fill(.quaternary)
                } else {
                    shape.fill(accent.gradient)
                }
            }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch role {
        case .speech: "waveform"
        case .vocabulary: "character.cursor.ibeam"
        case .tidy: "wand.and.sparkles"
        }
    }
}
