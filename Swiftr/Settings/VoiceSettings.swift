import AVFoundation
import SwiftUI

/// The Voice pane: the voice that reads each language and how fast, the
/// voice models to download, and this Mac's own voices.
struct VoiceSettings: View {
    @AppStorage(ReadAloud.speedKey) private var speed = 1.0

    var body: some View {
        Form {
            Section {
                ReadAloudFlow()
                Picker("Speed", selection: Binding(get: { ReadAloud.nearest(speed) }, set: { speed = $0 })) {
                    ForEach(ReadAloud.speeds, id: \.self) { speed in
                        Text(speed.formatted(.number.precision(.fractionLength(0 ... 2))) + "×").tag(speed)
                    }
                }
            } header: {
                Text("Read aloud")
            } footer: {
                SettingsNote("The speaker under an agent's message reads it in the voice of its language. A language joins the list once a message in it is read.")
            }
            Section {
                ForEach(VoiceCatalog.models) { model in
                    ModelRow(model: model)
                }
                if VoiceCatalog.models.contains(where: { VoiceLibrary.shared.isInstalled($0) }) {
                    ModelUpdatesRow()
                }
            } header: {
                Text("Voice models")
            } footer: {
                SettingsNote("They run on this Mac, so what they read stays on it. Each downloads only when you ask; its voices then join the lists above. Swiftr looks for newer versions when this pane opens.")
            }
            Section {
                LabeledContent("Premium and Enhanced voices") {
                    Button("Open System Settings") { ReadAloud.openSystemVoices() }
                }
            } header: {
                Text("This Mac's voices")
            } footer: {
                SettingsNote("They read every language without a download from Swiftr. Add the better ones in Accessibility › Read & Speak, under System voice.")
            }
        }
        .formStyle(.grouped)
        .onDisappear { SamplePlayer.shared.stop() }
    }
}

// MARK: Read aloud

/// A message, the languages it can be in, and the voice that reads each:
/// a picture whose rows pick the voices.
private struct ReadAloudFlow: View {
    static let row: CGFloat = 30
    static let gap: CGFloat = 10
    static let fanWidth: CGFloat = 38
    /// Each language's voice menu width, so the play buttons line up
    /// after the widest.
    @State private var menuWidths: [String: CGFloat] = [:]

    var body: some View {
        // Lists the languages again when one is added, read or removed.
        let _ = ReadAloud.shared.languagesChanged
        let languages = ReadAloud.settingsLanguages
        let count = CGFloat(languages.count)
        let menuWidth = languages.compactMap { menuWidths[$0] }.max() ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 0) {
                MessageNode()
                FanLines(count: languages.count)
                    .frame(width: Self.fanWidth, height: count * Self.row + (count - 1) * Self.gap)
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(languages, id: \.self) { language in
                        LanguageRow(language: language, menuWidth: menuWidth, menuWidths: $menuWidths)
                    }
                }
                Spacer(minLength: 0)
            }
            AddLanguageMenu()
                .padding(.leading, MessageNode.width + Self.fanWidth)
        }
        .padding(.vertical, 6)
    }
}

/// An agent's message in small: its lines, its code, which isn't read,
/// and the speaker under it that reads the rest.
private struct MessageNode: View {
    static let width: CGFloat = 100

    var body: some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 5) {
                line(70)
                line(54)
                code
                line(62)
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20, height: 16)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
            }
            .padding(10)
            .frame(width: Self.width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
            VStack(spacing: 1) {
                Text("A message")
                    .font(.callout.weight(.semibold))
                Text("read without its code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
        .accessibilityHidden(true)
    }

    private func line(_ width: CGFloat) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.4))
            .frame(width: width, height: 4)
    }

    /// The code block, struck through: it's left out.
    private var code: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(.quaternary)
            .frame(width: 76, height: 16)
            .overlay {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .overlay {
                Canvas { g, size in
                    var p = Path()
                    p.move(to: CGPoint(x: 3, y: size.height - 2))
                    p.addLine(to: CGPoint(x: size.width - 3, y: 2))
                    g.stroke(p, with: .style(.secondary), lineWidth: 1)
                }
            }
    }
}

/// Lines from the message to each language, ending in arrows.
private struct FanLines: View {
    let count: Int

    var body: some View {
        Canvas { g, size in
            let mid = size.height / 2
            var lines = Path()
            var heads = Path()
            for i in 0 ..< count {
                let y = ReadAloudFlow.row / 2 + CGFloat(i) * (ReadAloudFlow.row + ReadAloudFlow.gap)
                lines.move(to: CGPoint(x: 2, y: mid))
                lines.addCurve(to: CGPoint(x: size.width - 9, y: y),
                               control1: CGPoint(x: size.width * 0.55, y: mid),
                               control2: CGPoint(x: size.width * 0.3, y: y))
                heads.move(to: CGPoint(x: size.width - 10, y: y - 3.5))
                heads.addLine(to: CGPoint(x: size.width - 3, y: y))
                heads.addLine(to: CGPoint(x: size.width - 10, y: y + 3.5))
                heads.closeSubpath()
            }
            g.stroke(lines, with: .style(.tertiary), lineWidth: 1.5)
            g.fill(heads, with: .style(.tertiary))
        }
        .accessibilityHidden(true)
    }
}

/// A language, the voice that reads it, and a button that plays that
/// voice. Automatic takes the first downloaded model's voice for it, else
/// this Mac's best.
private struct LanguageRow: View {
    let language: String
    /// The widest voice menu in the flow.
    let menuWidth: CGFloat
    @Binding var menuWidths: [String: CGFloat]
    @AppStorage private var chosen: String
    @State private var hovering = false

    init(language: String, menuWidth: CGFloat, menuWidths: Binding<[String: CGFloat]>) {
        self.language = language
        self.menuWidth = menuWidth
        _menuWidths = menuWidths
        _chosen = AppStorage(wrappedValue: "", ReadAloud.voiceKey(language))
    }

    var body: some View {
        // Lists the voices again once one is added in System Settings, or a
        // model comes or goes.
        let _ = ReadAloud.shared.voicesChanged
        let _ = VoiceLibrary.shared.states
        let name = ReadAloud.name(language)
        let system = ReadAloud.systemVoices(for: language)
        let models = VoiceCatalog.models.filter { VoiceLibrary.shared.isInstalled($0) && !$0.voices(for: language).isEmpty }
        let sampling = ReadAloud.shared.readingID == ReadAloud.sampleID(language)
        // A voice gone from this Mac reads as Automatic.
        let known = ReadAloud.modelVoice(chosen, language: language) != nil || system.contains { $0.identifier == chosen }
        let selection = Binding(get: { known ? chosen : "" }, set: { chosen = $0 })
        let automatic = "Automatic (\(ReadAloud.label(ReadAloud.automaticVoice(for: language))))"
        HStack(spacing: 8) {
            LanguageChip(language: language)
                .contextMenu {
                    if !ReadAloud.isMacLanguage(language) {
                        Button("Remove \(name)") { ReadAloud.forget(language) }
                    }
                }
            Picker(selection: selection) {
                Text(automatic).tag("")
                ForEach(models) { model in
                    Section(model.name) {
                        ForEach(model.voices(for: language)) { voice in
                            Text(voice.label).tag(voice.key)
                        }
                    }
                }
                if !system.isEmpty {
                    Section("This Mac") {
                        ForEach(system, id: \.identifier) { voice in
                            Text(ReadAloud.label(voice)).tag(voice.identifier)
                        }
                    }
                }
            } label: {
                Text(name)
            } currentValueLabel: {
                // Closed, the menu names the model too: "Pocket TTS: Alba".
                Text(known && !chosen.isEmpty ? ReadAloud.label(ReadAloud.voice(for: language)) : automatic)
            }
            .labelsHidden()
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { menuWidths[language] = $0 }
            .frame(minWidth: menuWidth, alignment: .leading)
            Button {
                if sampling {
                    ReadAloud.shared.stop()
                } else {
                    SamplePlayer.shared.stop()
                    ReadAloud.shared.sample(language)
                }
            } label: {
                Image(systemName: sampling ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.borderless)
            .help(sampling ? "Stop" : "Hear This Voice")
            if !ReadAloud.isMacLanguage(language) {
                Button {
                    ReadAloud.forget(language)
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove \(name)")
                .opacity(hovering ? 1 : 0)
            }
        }
        .frame(height: ReadAloudFlow.row)
        .onHover { hovering = $0 }
    }
}

/// "EN English", as the flow's rows start.
private struct LanguageChip: View {
    let language: String

    var body: some View {
        HStack(spacing: 6) {
            LanguageCode(language: language, yours: false)
            Text(ReadAloud.name(language))
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(width: 118, height: ReadAloudFlow.row, alignment: .leading)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
    }
}

/// A language's two letters in a small box, tinted for the languages
/// Settings lists.
private struct LanguageCode: View {
    let language: String
    let yours: Bool

    var body: some View {
        Text(language.uppercased())
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(yours ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(minWidth: 18)
            .padding(.horizontal, 3)
            .frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(yours ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary)))
            .help(ReadAloud.name(language))
    }
}

/// Another language for the list: one a voice model or this Mac can read.
private struct AddLanguageMenu: View {
    var body: some View {
        let _ = ReadAloud.shared.languagesChanged
        let others = ReadAloud.otherLanguages
        Menu {
            ForEach(others, id: \.self) { language in
                Button(ReadAloud.name(language)) { ReadAloud.remember(language) }
            }
        } label: {
            Label("Add Language", systemImage: "plus.circle.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(others.isEmpty)
    }
}

// MARK: Voice models

/// A voice model: what it is, the languages it reads, its voices to hear,
/// and the button that downloads or deletes it.
private struct ModelRow: View {
    let model: VoiceModel
    @State private var confirmingDelete = false
    @State private var showsVoices = false

    var body: some View {
        // Tints the codes again when a language is added or removed.
        let _ = ReadAloud.shared.languagesChanged
        let library = VoiceLibrary.shared
        let state = library.state(model)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.name)
                            .fontWeight(.semibold)
                        if model.id == VoiceCatalog.recommended {
                            Text("Recommended")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(model.about)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .help(model.credits)
                Spacer(minLength: 8)
                actions(state)
            }
            HStack(spacing: 10) {
                let mine = ReadAloud.settingsLanguages
                let languages = mine.filter { model.languages.contains($0) } + model.languages.filter { !mine.contains($0) }
                HStack(spacing: 4) {
                    ForEach(languages, id: \.self) { language in
                        LanguageCode(language: language, yours: mine.contains(language))
                    }
                }
                Spacer(minLength: 8)
                Button {
                    showsVoices.toggle()
                } label: {
                    Label("Voices", systemImage: "waveform")
                }
                .buttonStyle(.borderless)
                .help("Hear \(model.name)'s Voices")
                .popover(isPresented: $showsVoices, arrowEdge: .trailing) {
                    VoicesPopover(model: model)
                }
            }
            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if state == .installed, let error = ReadAloud.shared.modelErrors[model.id] {
                Label("It couldn't read the last message: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if state == .installed {
                ModelUpdateNote(key: VoiceLibrary.key(model))
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Delete \(model.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { library.delete(model) }
        } message: {
            Text("Its voices leave the lists, and the \(ModelBytes.text(VoiceLibrary.used(model))) it takes come back. You can download it again later.")
        }
        #if DEBUG
        .onChange(of: VoiceSettingsDebug.shared.voices) { _, id in showsVoices = id == model.id }
        #endif
    }

    @ViewBuilder private func actions(_ state: VoiceLibrary.State) -> some View {
        let library = VoiceLibrary.shared
        switch state {
        case .absent:
            HStack(spacing: 10) {
                Text(ModelBytes.text(model.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Download") { library.download(model) }
            }
        case .downloading(let done, let total):
            DownloadProgress(done: done, total: total, stopHelp: "Stop Download") { library.cancel(model) }
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing…").foregroundStyle(.secondary)
            }
        case .installed:
            DownloadedActions(key: VoiceLibrary.key(model), used: VoiceLibrary.used(model),
                              update: { library.update(model) }, stop: { library.cancel(model) },
                              delete: { confirmingDelete = true })
        case .failed:
            Button("Try Again") { library.download(model) }
        }
    }
}

/// A model's voices, a row per language (Settings' languages first), each
/// a button that plays it.
private struct VoicesPopover: View {
    let model: VoiceModel

    var body: some View {
        let _ = ReadAloud.shared.languagesChanged
        let mine = ReadAloud.settingsLanguages
        let languages = mine.filter { model.languages.contains($0) } + model.languages.filter { !mine.contains($0) }
        let unheard = !VoiceLibrary.shared.isInstalled(model) && model.voices.contains { !SamplePlayer.has($0.sampleName) }
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.name) voices")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(languages, id: \.self) { language in
                    GridRow {
                        Text(ReadAloud.name(language))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        FlowLayout(spacing: 6) {
                            ForEach(model.voices(for: language)) { voice in
                                SampleButton(voice: voice)
                            }
                        }
                    }
                }
            }
            if unheard {
                SettingsNote("The grayed voices play once \(model.name) is downloaded.")
            }
        }
        .padding(16)
        .frame(width: 470)
    }
}

/// Plays a voice: its recording when Swiftr has one, else the model reads
/// a few words once it's downloaded.
private struct SampleButton: View {
    let voice: ModelVoice

    var body: some View {
        let recorded = SamplePlayer.has(voice.sampleName)
        let installed = VoiceCatalog.model(voice.model).map { VoiceLibrary.shared.isInstalled($0) } ?? false
        let playing = recorded
            ? SamplePlayer.shared.playing == voice.sampleName
            : ReadAloud.shared.readingID == ReadAloud.sampleID(voice.key)
        Button {
            if playing {
                SamplePlayer.shared.stop()
                ReadAloud.shared.stop()
            } else if recorded {
                ReadAloud.shared.stop()
                SamplePlayer.shared.play(voice.sampleName)
            } else {
                SamplePlayer.shared.stop()
                ReadAloud.shared.sample(voice: voice)
            }
        } label: {
            Label(voice.label, systemImage: playing ? "stop.fill" : "play.fill")
                .labelStyle(SampleLabelStyle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!recorded && !installed)
        .help(playing ? "Stop" : "Hear \(voice.label)")
    }
}

/// The symbol small before the name.
private struct SampleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 8))
            configuration.title
        }
    }
}

/// Plays the recordings that ship with Swiftr, one at a time.
@MainActor @Observable
final class SamplePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = SamplePlayer()

    /// The recording playing, by name.
    private(set) var playing: String?
    @ObservationIgnored private var player: AVAudioPlayer?

    /// Swiftr has a recording by that name.
    static func has(_ name: String) -> Bool {
        Bundle.main.url(forResource: name, withExtension: "m4a") != nil
    }

    func play(_ name: String) {
        stop()
        guard let url = Bundle.main.url(forResource: name, withExtension: "m4a"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        #if DEBUG
        if ProcessInfo.processInfo.environment["SWIFTR_QUIET"] == "1" { player.volume = 0 }
        #endif
        self.player = player
        playing = name
        player.play()
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            if let current = self.player, ObjectIdentifier(current) == finished { self.stop() }
        }
    }
}

#if DEBUG
/// What the debug hooks open in this pane.
@MainActor @Observable
final class VoiceSettingsDebug {
    static let shared = VoiceSettingsDebug()
    /// The model whose voices show, by id.
    var voices: String?
}
#endif

/// Lays its views out in a row, wrapping onto the next line when full.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
