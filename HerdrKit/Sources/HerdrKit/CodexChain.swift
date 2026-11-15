import Foundation

/// When the person goes back to an earlier message (Esc Esc, Enter), Codex
/// 0.167 starts a new session file for the same thread:
/// `rollout-<time>-<thread>_<part>.jsonl`. Its first line names the file
/// before it and where the conversation leaves that file:
/// `"history_base":{"thread_id":"<part>","end_ordinal_exclusive":27,"end_byte_offset":41857}`.
/// Line numbers (`ordinal`) run on from file to file, so the new file
/// starts at 27. Going back to the very first message starts a file with
/// no base.
public struct CodexHistoryBase: Sendable, Equatable {
    /// The earlier file's id: the end of its name (`_<part>.jsonl`, or the
    /// thread's own id for the first file).
    public var part: String
    /// Its lines before this `ordinal` are still in the conversation.
    public var endOrdinal: Int
    /// Where that line starts in the file, when Codex says.
    public var endByte: Int?

    public init(part: String, endOrdinal: Int, endByte: Int?) {
        self.part = part
        self.endOrdinal = endOrdinal
        self.endByte = endByte
    }

    /// The base a session file's first line (`session_meta`) names; nil
    /// for any other line, or a file that starts the conversation.
    public static func parse(_ line: Data) -> CodexHistoryBase? {
        guard line.prefix(300).range(of: Data("\"session_meta\"".utf8)) != nil,
              line.range(of: Data("\"history_base\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let base = (object["payload"] as? [String: Any])?["history_base"] as? [String: Any],
              let part = base["thread_id"] as? String, !part.isEmpty,
              let end = (base["end_ordinal_exclusive"] as? NSNumber)?.intValue
        else { return nil }
        return CodexHistoryBase(part: part, endOrdinal: end, endByte: (base["end_byte_offset"] as? NSNumber)?.intValue)
    }

    /// A line's `ordinal`, read near its start.
    public static func ordinal(of line: Data) -> Int? {
        let head = line.prefix(120)
        guard let r = head.range(of: Data("\"ordinal\":".utf8)) else { return nil }
        var n = 0
        var digits = 0
        for byte in head[r.upperBound...] {
            guard byte >= 0x30, byte <= 0x39 else { break }
            n = n * 10 + Int(byte - 0x30)
            digits += 1
        }
        return digits > 0 ? n : nil
    }
}

/// A Codex conversation across its session files: the one Codex writes
/// now, then, further back, the part of each earlier file still in the
/// conversation (`CodexHistoryBase`). New lines come from the newest file only.
public actor CodexChain: TranscriptSource {
    /// Opens the part of an earlier file still in the conversation; nil
    /// when the file can't be found.
    public typealias Opener = @Sendable (CodexHistoryBase) async throws -> (any TranscriptSource)?

    private let current: any TranscriptSource
    private let opener: Opener
    /// Earlier files opened, nearest first.
    private var parts: [any TranscriptSource] = []
    /// The base the oldest file read whole names, not opened yet.
    private var nextBase: CodexHistoryBase?
    /// Files named so far: a base naming one again ends the chain.
    private var seen: Set<String> = []

    public init(current: any TranscriptSource, opener: @escaping Opener) {
        self.current = current
        self.opener = opener
    }

    public var atStart: Bool {
        get async {
            guard nextBase == nil else { return false }
            return await (parts.last ?? current).atStart
        }
    }

    public func openTail(lines: Int, maxBytes: Int) async throws -> [Data] {
        parts = []
        nextBase = nil
        seen = []
        var out = try await current.openTail(lines: lines, maxBytes: maxBytes)
        if await current.atStart { note(out.first) }
        var bytes = out.reduce(0) { $0 + $1.count }
        // A file started by going back holds little: fill from the ones before.
        while out.count < lines, bytes < maxBytes, await !atStart {
            let more = try await earlier(lines: lines - out.count, maxBytes: maxBytes - bytes)
            if more.isEmpty { break }
            out = more + out
            bytes += more.reduce(0) { $0 + $1.count }
        }
        return out
    }

    public func readNew() async throws -> [Data]? {
        try await current.readNew()
    }

    public func readEarlier(lines: Int, maxBytes: Int) async throws -> [Data] {
        try await earlier(lines: lines, maxBytes: maxBytes)
    }

    private func earlier(lines: Int, maxBytes: Int) async throws -> [Data] {
        let oldest = parts.last ?? current
        if await !oldest.atStart {
            let got = try await oldest.readEarlier(lines: lines, maxBytes: maxBytes)
            if await oldest.atStart { note(got.first) }
            return got
        }
        guard let base = nextBase else { return [] }
        nextBase = nil
        guard let source = try await opener(base) else { return [] }
        parts.append(source)
        let got = try await source.openTail(lines: lines, maxBytes: maxBytes)
        if await source.atStart { note(got.first) }
        return got
    }

    /// A file's first line, read: the base it names comes next.
    private func note(_ first: Data?) {
        guard let base = first.flatMap(CodexHistoryBase.parse), parts.count < 64, seen.insert(base.part).inserted else { return }
        nextBase = base
    }
}
