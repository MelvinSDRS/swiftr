import Foundation

/// Frame kinds of the core's framed mode (schema/README.md, "Framed mode").
public enum FrameKind: UInt8, Sendable {
    case data = 0
    case credit = 1
    case close = 2
    case resize = 3
    case focus = 4
    case facts = 5
    /// Terminal-generated replies, not human activity. Only once negotiated.
    case automaticInput = 6
}

enum FrameCodec {
    static let headerSize = 9
    static let maxPayload = 16 * 1024 * 1024

    /// `[channel u32 LE][kind u8][len u32 LE][payload]`
    static func encode(channel: UInt32, kind: FrameKind, payload: UnsafeRawBufferPointer) -> Data {
        var d = Data(capacity: headerSize + payload.count)
        withUnsafeBytes(of: channel.littleEndian) { d.append(contentsOf: $0) }
        d.append(kind.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: payload)
        return d
    }

    static func encode(channel: UInt32, kind: FrameKind, payload: some ContiguousBytes) -> Data {
        payload.withUnsafeBytes { encode(channel: channel, kind: kind, payload: $0) }
    }
}

struct RawFrame {
    let channel: UInt32
    let kind: UInt8
    let payload: ArraySlice<UInt8>
}

enum FrameError: Error, CustomStringConvertible {
    case tooLarge(Int)

    var description: String {
        switch self {
        case .tooLarge(let n): "frame of \(n) bytes is over the 16 MiB limit"
        }
    }
}

/// Cuts a byte stream into frames. One reader thread owns it.
struct FrameReader {
    private var buffer: [UInt8] = []
    private var start = 0

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start >= 1 << 20 {
            buffer.removeFirst(start)
            start = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// The next whole frame, or nil until more bytes come. Use the frame
    /// before the next `append`: its payload shares this buffer.
    mutating func next() throws -> RawFrame? {
        let available = buffer.count - start
        guard available >= FrameCodec.headerSize else { return nil }
        let b = start
        let channel = UInt32(buffer[b]) | UInt32(buffer[b + 1]) << 8 | UInt32(buffer[b + 2]) << 16 | UInt32(buffer[b + 3]) << 24
        let kind = buffer[b + 4]
        let length = Int(UInt32(buffer[b + 5]) | UInt32(buffer[b + 6]) << 8 | UInt32(buffer[b + 7]) << 16 | UInt32(buffer[b + 8]) << 24)
        guard length <= FrameCodec.maxPayload else { throw FrameError.tooLarge(length) }
        guard available >= FrameCodec.headerSize + length else { return nil }
        let p = b + FrameCodec.headerSize
        start = p + length
        return RawFrame(channel: channel, kind: kind, payload: buffer[p ..< p + length])
    }
}

/// Newline-separated JSON in a byte stream whose chunks may split lines anywhere.
struct LineSplitter {
    private var pending: [UInt8] = []

    mutating func push(_ bytes: UnsafeRawBufferPointer, line: (UnsafeRawBufferPointer) -> Void) {
        var from = 0
        for i in 0 ..< bytes.count where bytes[i] == 0x0A {
            if pending.isEmpty {
                line(UnsafeRawBufferPointer(rebasing: bytes[from ..< i]))
            } else {
                pending.append(contentsOf: bytes[from ..< i])
                pending.withUnsafeBytes { line($0) }
                pending.removeAll(keepingCapacity: true)
            }
            from = i + 1
        }
        if from < bytes.count {
            pending.append(contentsOf: bytes[from...])
        }
    }
}
