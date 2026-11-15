import Foundation
import HerdrKit
import SwiftUI

/// Where an agent keeps what was sent in earlier conversations too:
/// Claude Code's `<config>/history.jsonl` (lines for one folder), Codex's
/// `<home>/history.jsonl` and OpenCode's `prompt-history.jsonl` (every
/// folder's), Gemini CLI's `logs.json` (one project's).
nonisolated struct HistorySource: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case claude(project: String)
        case codex, openCode, gemini
    }

    var kind: Kind
    /// The file on this Mac, or from the home folder on `machine`. Empty for
    /// OpenCode on another machine: its state folder is found there.
    var path: String
    var machine: String?
}

/// What was sent before, as each agent's ⌃R and ↑ go through it.
@MainActor @Observable
final class HistoryStore {
    static let shared = HistoryStore()

    /// Messages sent before, newest first, by where they were read.
    private(set) var entries: [HistorySource: [String]] = [:]
    @ObservationIgnored private var loadedAt: [HistorySource: Date] = [:]

    /// The file's last bytes read: the newest messages are at its end.
    nonisolated static let tailBytes = 6 << 20
    /// Gemini's list is one JSON value: read whole, up to this.
    nonisolated static let wholeBytes = 32 << 20

    func entries(_ source: HistorySource?) -> [String] {
        source.flatMap { entries[$0] } ?? []
    }

    /// Reads them, unless read in the last 20 seconds: on this Mac, or on
    /// `source.machine`. The reading, to wait for; nil when none starts.
    @discardableResult
    func load(_ source: HistorySource?, connection: CoreConnection? = nil) -> Task<Void, Never>? {
        guard let source else { return nil }
        if let at = loadedAt[source], Date().timeIntervalSince(at) < 20 { return nil }
        loadedAt[source] = Date()
        if let machine = source.machine {
            let line = Self.remoteLine(source)
            return Task {
                guard let r = try? await connection?.call("machine.exec", ["on": .string(machine), "line": .string(line), "timeout": 15], timeout: .seconds(20)),
                      let out = r["stdout"]?.string.flatMap({ Data(base64Encoded: $0) })
                else { return }
                entries[source] = await Task.detached(priority: .userInitiated) { Self.entries(in: out, of: source.kind) }.value
            }
        }
        return Task {
            let found = await Task.detached(priority: .userInitiated) { Self.read(source) }.value
            entries[source] = found
        }
    }

    nonisolated private static func remoteLine(_ source: HistorySource) -> String {
        switch source.kind {
        case .claude(let project):
            PromptHistory.remoteLine(config: (source.path as NSString).deletingLastPathComponent, project: project, tailBytes: tailBytes)
        case .codex:
            PromptHistory.codexRemoteLine(home: (source.path as NSString).deletingLastPathComponent, tailBytes: tailBytes)
        case .openCode:
            PromptHistory.openCodeRemoteLine(tailBytes: tailBytes)
        case .gemini:
            PromptHistory.geminiRemoteLine(project: (source.path as NSString).deletingLastPathComponent, maxBytes: wholeBytes)
        }
    }

    nonisolated private static func entries(in data: Data, of kind: HistorySource.Kind) -> [String] {
        switch kind {
        case .claude(let project): PromptHistory.entries(data, project: project)
        case .codex: PromptHistory.codexEntries(data)
        case .openCode: PromptHistory.openCodeEntries(data)
        case .gemini: PromptHistory.geminiEntries(data)
        }
    }

    nonisolated private static func read(_ source: HistorySource) -> [String] {
        guard let h = FileHandle(forReadingAtPath: source.path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if source.kind == .gemini {
            guard size <= UInt64(wholeBytes) else { return [] }
            try? h.seek(toOffset: 0)
            return entries(in: (try? h.readToEnd()) ?? Data(), of: .gemini)
        }
        let from = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? h.seek(toOffset: from)
        var data = (try? h.readToEnd()) ?? Data()
        // Started inside a line: from the next one.
        if from > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        return entries(in: Data(data), of: source.kind)
    }
}

/// ⌃R: the messages sent before that hold what the field says, newest
/// first. ↑ ↓ or ⌃R again move through them, Return or Tab puts one in the
/// field, Esc gives the field back as it was.
struct HistoryPopup: View {
    let entries: [String]
    let query: String
    let selection: Int
    let size: Double
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                Text(query.isEmpty ? "Earlier messages" : entries.isEmpty ? "No earlier message holds “\(query)”" : "Earlier messages with “\(query)”")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("↩ to use · Esc to go back")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: size * 0.78))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, entries.isEmpty ? 9 : 3)
            if !entries.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in
                                row(entry, selected: i == selection)
                                    .id(i)
                                    .contentShape(.rect)
                                    .onTapGesture { pick(entry) }
                            }
                        }
                        .padding(5)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 290)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
        }
        .paneGlass(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func row(_ entry: String, selected: Bool) -> some View {
        let lines = entry.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // The line that holds the words searched, else the first.
        let words = query.trimmingCharacters(in: .whitespaces)
        let at = words.isEmpty ? nil : lines.firstIndex { $0.range(of: words, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        let shown = at.map { ($0 > 0 ? "… " : "") + lines[$0].trimmingCharacters(in: .whitespaces) } ?? lines.first ?? entry
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(highlighted(shown))
                .font(.system(size: size * 0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if lines.count > 1 {
                Text("+\(lines.count - 1) lines")
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: .rect(cornerRadius: 8))
    }

    /// The words searched in bold, the rest as is.
    private func highlighted(_ s: String) -> AttributedString {
        var out = AttributedString(s)
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, let r = s.range(of: words, options: [.caseInsensitive, .diacriticInsensitive]),
              let lower = AttributedString.Index(r.lowerBound, within: out),
              let upper = AttributedString.Index(r.upperBound, within: out)
        else { return out }
        out[lower ..< upper].font = .system(size: size * 0.9, weight: .bold)
        return out
    }

    /// The messages that hold `query`, newest first: this conversation's,
    /// then the folder's earlier ones.
    static func matches(_ query: String, conversation: [String], folder: [String]) -> [String] {
        HistoryMatcher.shared.matches(query, conversation: conversation, folder: folder)
    }
}
