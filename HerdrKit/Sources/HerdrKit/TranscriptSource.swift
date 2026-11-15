import Darwin
import Foundation

/// Where a transcript's lines come from: a file on this machine, or one on
/// another machine read through the core. Both read from the end, since
/// transcripts can reach a gigabyte.
public protocol TranscriptSource: Sendable {
    /// The last lines: about `lines` of them, at most about `maxBytes`.
    func openTail(lines: Int, maxBytes: Int) async throws -> [Data]
    /// Lines written since the last read; nil when the file was replaced or
    /// cut, and must be opened again.
    func readNew() async throws -> [Data]?
    /// Lines before the first one read so far.
    func readEarlier(lines: Int, maxBytes: Int) async throws -> [Data]
    /// Everything before the first line read is read.
    var atStart: Bool { get async }
}

public enum TranscriptSourceError: Error, Sendable {
    case notOpen
}

// MARK: - This machine

/// A transcript file on this machine.
public actor TranscriptFile: TranscriptSource {
    public let url: URL
    /// Read no further than this byte: the part of an earlier file still in
    /// a conversation (`CodexHistoryBase`). Such a part gets no new lines.
    public let end: UInt64?
    private var handle: FileHandle?
    /// Where the first line read starts.
    private var head: UInt64 = 0
    /// Just after the last complete line read.
    private var tail: UInt64 = 0
    private var identity: (device: Int32, inode: UInt64)?

    /// Reads past this many bytes come in pieces.
    static let chunk = 1 << 20

    public init(url: URL, end: UInt64? = nil) {
        self.url = url
        self.end = end
    }

    public var atStart: Bool { head == 0 }

    public func openTail(lines: Int, maxBytes: Int) throws -> [Data] {
        try? handle?.close()
        let h = try FileHandle(forReadingFrom: url)
        handle = h
        identity = Self.identity(url)
        let size = min(try h.seekToEnd(), end ?? .max)
        let w = try window(endingAt: size, lines: lines, maxBytes: maxBytes)
        head = w.start
        tail = w.end
        return w.lines
    }

    public func readNew() throws -> [Data]? {
        guard let h = handle else { throw TranscriptSourceError.notOpen }
        if end != nil { return [] }
        // Replaced (another inode) or cut: start over.
        if let now = Self.identity(url), let was = identity, now != was { return nil }
        let size = try h.seekToEnd()
        if size < tail { return nil }
        guard size > tail else { return [] }
        try h.seek(toOffset: tail)
        let data = try h.read(upToCount: Int(min(size - tail, 256 << 20))) ?? Data()
        let (lines, rest) = data.splitLines()
        tail += UInt64(data.count - rest.count)
        return lines
    }

    public func readEarlier(lines: Int, maxBytes: Int) throws -> [Data] {
        guard head > 0 else { return [] }
        let w = try window(endingAt: head, lines: lines, maxBytes: maxBytes)
        head = w.start
        return w.lines
    }

    /// The complete lines that end at or before `end`: the last `lines` of
    /// them, or fewer when they pass `maxBytes`, but at least one.
    private func window(endingAt end: UInt64, lines want: Int, maxBytes: Int) throws -> (lines: [Data], start: UInt64, end: UInt64) {
        guard let h = handle else { throw TranscriptSourceError.notOpen }
        var pos = end
        var chunks: [Data] = []
        var bytes = 0
        var newlines = 0
        // Back from the end until enough lines, enough bytes, or the start;
        // always far enough to hold one whole line.
        while pos > 0, (newlines <= want && bytes < maxBytes) || newlines < 2 {
            let size = min(UInt64(Self.chunk), pos)
            pos -= size
            try h.seek(toOffset: pos)
            let chunk = try h.read(upToCount: Int(size)) ?? Data()
            newlines += chunk.withUnsafeBytes { raw in
                var n = 0
                var i = 0
                guard let base = raw.baseAddress else { return 0 }
                while i < raw.count, let hit = memchr(base + i, 0x0A, raw.count - i) {
                    n += 1
                    i = base.distance(to: UnsafeRawPointer(hit)) + 1
                }
                return n
            }
            chunks.append(chunk)
            bytes += chunk.count
        }
        var data = Data(capacity: bytes)
        for chunk in chunks.reversed() { data.append(chunk) }
        var start = pos
        // A line cut by where reading began.
        if pos > 0 {
            guard let nl = data.firstIndex(of: 0x0A) else { return ([], end, end) }
            start += UInt64(nl - data.startIndex + 1)
            data = data[(nl + 1)...]
        }
        var (lines, rest) = data.splitLines()
        let stop = start + UInt64(data.count - rest.count)
        if lines.count > want {
            let keep = lines.suffix(want)
            start += UInt64(keep.first!.startIndex - data.startIndex)
            lines = Array(keep)
        }
        return (lines, start, stop)
    }

    private static func identity(_ url: URL) -> (device: Int32, inode: UInt64)? {
        var s = stat()
        guard stat(url.path, &s) == 0 else { return nil }
        return (s.st_dev, s.st_ino)
    }
}

// MARK: - Another machine

/// A transcript file on another machine, read with the core's `file.read`
/// (whole lines, at most 8 MB a call).
public actor RemoteTranscript: TranscriptSource {
    public typealias Call = @Sendable (_ method: String, _ params: JSON) async throws -> JSON

    public let machine: String
    public let path: String
    /// Read no further than this line (from 1), as `TranscriptFile.end`.
    public let lastLine: Int?
    private let call: Call
    /// The first line read (from 1), and the next one to read.
    private var first = 1
    private var next = 1

    public init(machine: String, path: String, lastLine: Int? = nil, call: @escaping Call) {
        self.machine = machine
        self.path = path
        self.lastLine = lastLine
        self.call = call
    }

    public var atStart: Bool { first <= 1 }

    private func read(offset: Int, limit: Int?) async throws -> (text: String, first: Int, last: Int, lines: Int) {
        var params: JSON = ["on": .string(machine), "path": .string(path), "offset": .int(Int64(offset))]
        if let limit { params["limit"] = .int(Int64(limit)) }
        let r = try await call("file.read", params)
        return (r["text"]?.string ?? "", r["first"]?.int ?? offset, r["last"]?.int ?? 0, r["lines"]?.int ?? 0)
    }

    /// Lines `from` up to `through`, page by page; stops before a last line
    /// still being written. Returns them and the next line to read.
    private func lines(from: Int, through: Int) async throws -> (lines: [Data], next: Int) {
        var out: [Data] = []
        var o = from
        while o <= through {
            let r = try await read(offset: o, limit: through - o + 1)
            guard r.last >= r.first else { break }
            let (lines, rest) = Data(r.text.utf8).splitLines()
            out += lines
            if !rest.isEmpty { return (out, r.last) }
            o = r.last + 1
        }
        return (out, o)
    }

    public func openTail(lines want: Int, maxBytes: Int) async throws -> [Data] {
        let total = min(try await read(offset: 1, limit: 0).lines, lastLine ?? .max)
        first = max(1, total - want + 1)
        let (lines, after) = try await self.lines(from: first, through: total)
        next = after
        return lines
    }

    public func readNew() async throws -> [Data]? {
        if lastLine != nil { return [] }
        let total = try await read(offset: 1, limit: 0).lines
        if total < next - 1 { return nil }
        guard total >= next else { return [] }
        let (lines, after) = try await self.lines(from: next, through: total)
        next = after
        return lines
    }

    public func readEarlier(lines want: Int, maxBytes: Int) async throws -> [Data] {
        guard first > 1 else { return [] }
        let from = max(1, first - want)
        let (lines, _) = try await self.lines(from: from, through: first - 1)
        first = from
        return lines
    }
}
