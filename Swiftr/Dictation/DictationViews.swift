import AppKit
import HerdrKit
import SwiftUI

/// What went wrong with a dictation, and the button that fixes it: over a
/// Messages field, or in the panel. While it goes well, the field itself
/// shows it (`DictationCover`), or the panel's bars.
struct DictationProblem: View {
    let size: Double
    /// In the panel, which Settings can't be opened from.
    var inPanel = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let dictation = Dictation.shared
        if let problem = dictation.problem {
            HStack(spacing: size * 0.5) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.readable(.orange))
                    // The panel sizes itself to what it shows: lines this
                    // wide at most.
                    .frame(maxWidth: inPanel ? 340 : nil, alignment: .leading)
                    .fixedSize(horizontal: inPanel, vertical: true)
                switch dictation.fix {
                case .microphone:
                    Button("Open System Settings") { Dictation.openMicrophoneSettings() }
                        .controlSize(.small)
                case .model where !inPanel:
                    Button("Open Settings") { Dictation.openSettings(with: openSettings) }
                        .controlSize(.small)
                default:
                    EmptyView()
                }
            }
            .font(.system(size: size * 0.85))
            .lineLimit(3)
        }
    }
}

/// Over pane `address`'s Messages field: what went wrong with a dictation.
struct DictationLine: View {
    let address: String
    let size: Double

    var body: some View {
        let dictation = Dictation.shared
        if dictation.address == address, dictation.problem != nil {
            DictationProblem(size: size)
                .padding(.leading, 4)
                .transition(.opacity)
        }
    }
}

extension Dictation {
    /// Whether pane `address`'s field shows a dictation under way.
    func shows(in address: String) -> Bool {
        self.address == address && problem == nil && phase != .idle
    }

    var wavePhase: VoiceWaveView.Phase {
        phase == .writing ? .writing : .listening
    }
}

/// The Messages field's text while the voice goes into it: the words there
/// fade, and bars follow the voice over them, the time at the end, and ✕
/// to drop it.
struct DictationCover: ViewModifier {
    let address: String
    let size: Double

    func body(content: Content) -> some View {
        let dictation = Dictation.shared
        let here = dictation.shows(in: address)
        content
            // Gone a moment: the bars take their place, and they come back.
            .opacity(here ? 0 : 1)
            .overlay {
                if here {
                    HStack(spacing: size * 0.5) {
                        RenderStandIn {
                            VoiceWave(phase: dictation.wavePhase, clockSize: size * 0.82, started: dictation.meter.started)
                        } standIn: {
                            Capsule().fill(.tint.opacity(0.4)).frame(height: 3)
                        }
                        DictationCancelButton(size: size)
                    }
                    // Taller than one line: the bars use the field's margins;
                    // no taller than two, however long the draft.
                    .padding(.vertical, -size * 0.4)
                    .frame(maxHeight: size * 2.3)
                    .transition(.opacity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(dictation.phase == .writing ? "Writing what you said" : "Listening")
                }
            }
            .animation(.easeOut(duration: 0.18), value: here)
    }
}

/// The line of light around pane `address`'s Messages field while the voice
/// goes into it.
struct DictationFieldEdge: View {
    let address: String
    let corner: CGFloat

    var body: some View {
        let dictation = Dictation.shared
        let here = dictation.shows(in: address)
        ZStack {
            if here {
                RenderStandIn {
                    Color.clear.voiceEdge(phase: dictation.wavePhase, corner: corner)
                } standIn: {
                    EmptyView()
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.25), value: here)
    }
}

/// ✕: drops what was heard, as Esc does.
struct DictationCancelButton: View {
    let size: Double

    var body: some View {
        Button {
            Dictation.shared.cancel()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.62, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: size * 1.5, height: size * 1.5)
                .background(Circle().fill(.quaternary))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Cancel (Esc)")
        .opacity(Dictation.shared.phase == .listening ? 1 : 0)
    }
}

/// The microphone beside Send: click to dictate into this field, click
/// again to write it. Filled with the accent while it listens. None on an
/// Intel Mac.
struct DictationButton: View {
    @Environment(\.themeAccent) private var themeAccent
    @Environment(\.self) private var environment
    let address: String
    let size: Double
    let ready: Bool

    var body: some View {
        if SpeechModels.supported { button }
    }

    @ViewBuilder private var button: some View {
        let dictation = Dictation.shared
        let active = dictation.shows(in: address)
        let writing = active && dictation.phase == .writing
        let fill = themeAccent ?? Color.accentColor
        Button {
            dictation.toggle(for: address)
        } label: {
            ZStack {
                Circle()
                    .fill(fill)
                    .opacity(active ? 1 : 0)
                Image(systemName: active ? "mic.fill" : "mic")
                    .font(.system(size: size * (active ? 0.95 : 1.05), weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? ChatStyle.ink(on: fill.resolve(in: environment)) : Color.primary.opacity(ready ? 0.85 : 0.3))
            }
            .frame(width: size * 2.15, height: size * 2.15)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!ready || writing)
        .help(help(active))
        .animation(.easeOut(duration: 0.15), value: active)
    }

    private func help(_ active: Bool) -> String {
        if active { return "Write it" }
        guard let key = Dictation.key else { return "Dictate" }
        return "Dictate (or hold \(key.name))"
    }
}

/// A small panel at the bottom of the window while dictating into a
/// terminal or another field, which have no room of their own for it.
@MainActor
final class DictationHUD {
    static let shared = DictationHUD()

    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?

    /// Shows, moves or hides the panel as the dictation goes.
    func refresh() {
        let dictation = Dictation.shared
        let shown = dictation.address == nil && (dictation.phase != .idle || dictation.problem != nil)
        guard shown, let window = dictation.anchorWindow ?? NSApp.keyWindow, window.isVisible else {
            hide()
            return
        }
        let panel = panel ?? makePanel()
        guard let host else { return }
        let size = host.fittingSize
        // The card sits inside the room its glow takes.
        let room = VoiceEdgeView.room
        // Centered on what it writes into: near the bottom of a terminal,
        // under a small field.
        let anchor = dictation.anchorRect ?? window.frame
        let y = anchor.height < 120 ? anchor.minY - size.height - 8 + room : max(anchor.minY, window.frame.minY) + 18 - room
        var frame = NSRect(x: anchor.midX - size.width / 2, y: y, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, window.frame.minX + 12 - room), window.frame.maxX - size.width - 12 + room)
        panel.setFrame(frame, display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func hide() {
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Its card draws its own shadow, inside the glow's room.
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(HUDCard()))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }
}

/// The panel's card: the bars and ✕ in a capsule with its line of light,
/// or what went wrong.
private struct HUDCard: View {
    var body: some View {
        let dictation = Dictation.shared
        let accent = dictation.model?.prefs.theme.accentColor.map { Color(nsColor: $0) } ?? .accentColor
        let card = Color(nsColor: .windowBackgroundColor)
        Group {
            if dictation.problem != nil {
                DictationProblem(size: 15, inPanel: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(card).shadow(color: .black.opacity(0.25), radius: 6, y: 2))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            } else {
                HStack(spacing: 10) {
                    VoiceWave(phase: dictation.wavePhase, clockSize: 12, started: dictation.meter.started, accent: accent)
                        .frame(width: 196, height: 22)
                    DictationCancelButton(size: 13)
                }
                .padding(.leading, 18)
                .padding(.trailing, 9)
                .frame(height: 40)
                .background(Capsule().fill(card).shadow(color: .black.opacity(0.25), radius: 6, y: 2))
                .voiceEdge(phase: dictation.wavePhase, corner: 20, accent: accent)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(dictation.phase == .writing ? "Writing what you said" : "Listening")
            }
        }
        .padding(VoiceEdgeView.room)
    }
}
