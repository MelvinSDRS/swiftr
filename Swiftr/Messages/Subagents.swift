import Foundation
import HerdrKit
import SwiftUI

// Sub-agents' own steps. Claude Code writes each sub-agent's transcript
// beside its session's: `<session>/subagents/agent-<id>.jsonl`, with
// `agent-<id>.meta.json` naming the Agent call that started it
// (`toolUseId`). The Agent call's result names the id once it comes.

extension EnvironmentValues {
    /// The conversation the rows belong to: an Agent row reads its sub-agent's steps through it.
    @Entry var transcriptFeed: TranscriptFeed?
}

extension TranscriptFeed {
    /// Where the sub-agent the Agent call `callID` started writes its steps;
    /// nil when it can't be found (yet).
    func subagentSource(callID: String, agentID: String?) async -> (any TranscriptSource)? {
        guard let s = session, s.format == .claude, s.path.hasSuffix(".jsonl") else { return nil }
        let folder = String(s.path.dropLast(".jsonl".count)) + "/subagents"
        var id = agentID ?? subagentIDs[callID]
        if id == nil {
            id = await Self.findSubagent(callID: callID, in: folder, machine: s.machine, connection: connection)
            if let id { subagentIDs[callID] = id }
        }
        guard let id, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let path = folder + "/agent-\(id).jsonl"
        if let machine = s.machine {
            guard let c = connection else { return nil }
            return RemoteTranscript(machine: machine, path: path) { method, params in
                try await c.call(method, params, timeout: .seconds(60))
            }
        }
        return TranscriptFile(url: URL(filePath: path))
    }

    /// The call a running sub-agent waits on for permission: the newest
    /// call named `tool` without a result in the sub-agents' transcripts
    /// whose meta file doesn't say `finished`.
    func subagentCall(named tool: String) async -> ToolCall? {
        guard let s = session, s.format == .claude, s.path.hasSuffix(".jsonl") else { return nil }
        let folder = String(s.path.dropLast(".jsonl".count)) + "/subagents"
        let c = connection
        let ids: [String] = await {
            if let machine = s.machine {
                guard let c, let r = try? await c.call("machine.exec", ["on": .string(machine), "line": .string("grep -L '\"finished\":true' \(folder)/*.meta.json 2>/dev/null | head -8"), "timeout": 10]),
                      let out = r["stdout"]?.string.flatMap({ Data(base64Encoded: $0) })
                else { return [] }
                return String(decoding: out, as: UTF8.self).split(separator: "\n").compactMap { Self.agentID(fromMeta: String($0)) }
            }
            return await Task.detached {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                return names.filter { name in
                    guard name.hasSuffix(".meta.json"), let data = FileManager.default.contents(atPath: folder + "/" + name) else { return false }
                    let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    return meta?["finished"] as? Bool != true
                }.compactMap { Self.agentID(fromMeta: $0) }
            }.value
        }()
        var found: [ToolCall] = []
        for id in ids.prefix(8) {
            guard let src = await subagentSource(callID: "", agentID: id),
                  let lines = try? await src.openTail(lines: 200, maxBytes: 2 << 20)
            else { continue }
            let t = await Task.detached { Transcript.parse(lines, format: .claude, sidechain: true) }.value
            found += t.openCalls.filter { $0.name == tool || ToolRow.label($0.name) == tool }
        }
        return found.last
    }

    nonisolated private static func agentID(fromMeta file: String) -> String? {
        let name = (file as NSString).lastPathComponent
        guard name.hasPrefix("agent-"), name.hasSuffix(".meta.json") else { return nil }
        return String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
    }

    /// How the background run the Agent call `callID` started ended, once
    /// its notice came: its status and how long it took.
    func backgroundEnd(_ callID: String) -> (status: String, milliseconds: Int?)? {
        for row in rows.reversed() {
            guard case .item(let item) = row, case .notice(.task(_, let status, _, let ms, _, let use)) = item.kind, use == callID else { continue }
            if let ms { return (status, ms) }
            // A command's notice says nothing of how long: from its call to its notice.
            guard let end = item.time, let start = callTime(callID), end >= start else { return (status, nil) }
            return (status, Int(((end - start) * 1000).rounded()))
        }
        return nil
    }

    /// When the call `id` was written.
    private func callTime(_ id: String) -> Double? {
        for row in rows where row.holdsCall(id) {
            switch row {
            case .item(let item): return item.time
            case .activity(_, let items):
                return items.first { if case .tool(let call) = $0.kind { call.id == id } else { false } }?.time
            }
        }
        return nil
    }

    /// The id in the name of the meta file whose `toolUseId` is `callID`.
    nonisolated private static func findSubagent(callID: String, in folder: String, machine: String?, connection: CoreConnection?) async -> String? {
        let key = "\"toolUseId\":\"\(callID)\""
        func id(_ file: String) -> String? { agentID(fromMeta: file) }
        if let machine {
            // Ids are letters and digits; the call's id too: safe in the line.
            guard callID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }), let c = connection,
                  let r = try? await c.call("machine.exec", ["on": .string(machine), "line": .string("grep -l '\(key)' \(folder)/*.meta.json 2>/dev/null | head -1"), "timeout": 10]),
                  let out = r["stdout"]?.string.flatMap({ Data(base64Encoded: $0) })
            else { return nil }
            return id(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return await Task.detached {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasSuffix(".meta.json") {
                guard let data = FileManager.default.contents(atPath: folder + "/" + name),
                      String(decoding: data, as: UTF8.self).replacingOccurrences(of: " ", with: "").contains(key)
                else { continue }
                return id(name)
            }
            return nil
        }.value
    }
}

/// One sub-agent's transcript, read as it grows while its row is open.
@MainActor @Observable
final class SubagentLog {
    private(set) var rows: [TranscriptRow] = []
    /// Its transcript was found and read.
    private(set) var found = false
    @ObservationIgnored private var transcript = Transcript()
    @ObservationIgnored private var source: (any TranscriptSource)?

    /// Reads the steps, then what comes, every second and a half until the view goes.
    func follow(_ feed: TranscriptFeed, call: ToolCall) async {
        while !Task.isCancelled {
            if source == nil {
                if let src = await feed.subagentSource(callID: call.id, agentID: call.result?.agent?.id),
                   let lines = try? await src.openTail(lines: 600, maxBytes: 4 << 20)
                {
                    transcript = await Task.detached { Transcript.parse(lines, format: .claude, sidechain: true) }.value
                    source = src
                    found = true
                    rows = transcript.rows
                }
            } else if let src = source {
                do {
                    if let lines = try await src.readNew() {
                        if !lines.isEmpty {
                            transcript.append(lines)
                            rows = transcript.rows
                        }
                    } else {
                        source = nil
                    }
                } catch {
                    source = nil
                }
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }
}

/// What a sub-agent did, under its Agent row: its tool calls and its
/// words, as the conversation shows Claude's, without the task it was given.
struct SubagentSteps: View {
    @Environment(\.transcriptFeed) private var feed
    let call: ToolCall
    let size: Double
    let folder: String
    @State private var log = SubagentLog()

    var body: some View {
        let shown = log.rows.filter { row in
            if case .item(let item) = row, case .prompt = item.kind { return false }
            return true
        }
        VStack(alignment: .leading, spacing: 0) {
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shown) { row in
                        MessageRow(row: row, live: running && row.id == shown.last?.id, size: size * 0.92, folder: folder)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 2)
                }
                .environment(\.showsRowTimes, false)
            } else if running, feed != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(log.found ? "Starting…" : "Looking for its steps…")
                }
                .font(.system(size: size * 0.85))
                .foregroundStyle(.secondary)
            } else {
                // Something to show, so the steps are looked for.
                Color.clear.frame(height: 0)
            }
        }
        .task(id: call.id) {
            guard let feed else { return }
            await log.follow(feed, call: call)
        }
    }

    /// No result yet, or launched to run on its own and not ended yet.
    private var running: Bool {
        guard let result = call.result else { return true }
        guard result.agent?.background == true else { return false }
        return feed?.backgroundEnd(call.id) == nil
    }
}
