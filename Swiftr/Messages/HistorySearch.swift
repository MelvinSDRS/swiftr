import Foundation
import HerdrKit
import SwiftUI

/// What was sent from a folder in earlier conversations too, as Claude
/// Code's ⌃R searches it: `<config>/history.jsonl` on this Mac.
@MainActor @Observable
final class HistoryStore {
    static let shared = HistoryStore()

    /// Messages sent from a folder, newest first, by `machine|config|folder`.
    private(set) var entries: [String: [String]] = [:]
    @ObservationIgnored private var loadedAt: [String: Date] = [:]

    /// The file's last bytes read: the newest messages are at its end.
    nonisolated static let tailBytes = 6 << 20

    func entries(config: String?, folder: String, machine: String? = nil) -> [String] {
        guard let config else { return [] }
        return entries[Self.key(config, folder, machine)] ?? []
    }

    private static func key(_ config: String, _ folder: String, _ machine: String?) -> String {
        (machine ?? "") + "|" + config + "|" + folder
    }

    /// Reads them, unless read in the last 20 seconds: from this Mac's
    /// `<config>/history.jsonl`, or from `machine`'s.
    func load(config: String?, folder: String, machine: String? = nil, connection: CoreConnection? = nil) {
        guard let config, !folder.isEmpty else { return }
        let key = Self.key(config, folder, machine)
        if let at = loadedAt[key], Date().timeIntervalSince(at) < 20 { return }
        loadedAt[key] = Date()
        if let machine {
            let line = PromptHistory.remoteLine(config: config, project: folder, tailBytes: Self.tailBytes)
            Task {
                guard let r = try? await connection?.call("machine.exec", ["on": .string(machine), "line": .string(line), "timeout": 15], timeout: .seconds(20)),
                      let out = r["stdout"]?.string.flatMap({ Data(base64Encoded: $0) })
                else { return }
                entries[key] = await Task.detached(priority: .userInitiated) { PromptHistory.entries(out, project: folder) }.value
            }
            return
        }
        let path = config + "/history.jsonl"
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.read(path, folder: folder) }.value
            entries[key] = found
        }
    }

    nonisolated private static func read(_ path: String, folder: String) -> [String] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let from = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? h.seek(toOffset: from)
        var data = (try? h.readToEnd()) ?? Data()
        // Started inside a line: from the next one.
        if from > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        return PromptHistory.entries(Data(data), project: folder)
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
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        var out: [String] = []
        for entry in conversation.reversed() + folder where seen.insert(entry).inserted {
            if words.isEmpty || entry.range(of: words, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                out.append(entry)
                if out.count == 60 { break }
            }
        }
        return out
    }
}
