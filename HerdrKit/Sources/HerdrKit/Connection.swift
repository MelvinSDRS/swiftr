import Foundation
import Synchronization

/// An error from the core (JSON-RPC error with a stable `kind`), or a local one.
public struct CoreError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public var code: Int
    public var message: String
    /// The core's stable kind (`not_found`, `conflict`, `unavailable`...), or
    /// a local one: `lost`, `timeout`, `endpoint`, `posix`, `needs_update`.
    public var kind: String?
    public var hint: String?

    public init(kind: String, message: String, hint: String? = nil) {
        self.code = -1
        self.message = message
        self.kind = kind
        self.hint = hint
    }

    init(json: JSON) {
        code = json["code"]?.int ?? -1
        message = json["message"]?.string ?? "core error"
        kind = json["data"]?["kind"]?.string
        hint = json["data"]?["hint"]?.string
    }

    public var description: String { message }
    public var errorDescription: String? { message }

    public static func lost(_ why: String) -> CoreError { CoreError(kind: "lost", message: why) }

    static func posix(_ what: String) -> CoreError {
        CoreError(kind: "posix", message: "\(what): \(String(cString: strerror(errno)))")
    }
}

/// Receives one stream (an attach or an event subscription). Every call
/// comes on the connection's reader thread, in order.
public protocol StreamSink: AnyObject, Sendable {
    /// The core accepted the stream; frames follow.
    func streamOpened(channel: UInt32, connection: CoreConnection, result: JSON)
    func streamData(_ bytes: UnsafeRawBufferPointer)
    /// Core → observer RESIZE (only with `resize_notifications`).
    func streamResize(cols: Int, rows: Int)
    /// The stream ended: the core's reason, or nil when the connection dropped.
    func streamClosed(reason: JSON?)
}

/// One framed connection to a core: JSON-RPC calls on channel 0, streams on
/// the others. Reads on its own thread; sinks get stream bytes there directly.
public final class CoreConnection: Sendable {
    public let hello: JSON
    public let features: Set<String>
    public let endpoint: CoreEndpoint

    private let transport: FDTransport
    private let state = Mutex(State())

    private struct Pending: Sendable {
        let continuation: CheckedContinuation<JSON, any Error>
        let onResult: (@Sendable (JSON) -> Void)?
    }

    private struct State: Sendable {
        var nextID: Int64 = 1
        var pending: [Int64: Pending] = [:]
        var sinks: [UInt32: any StreamSink] = [:]
        var closed: String?
        var lostHandlers: [@Sendable (String) -> Void] = []
    }

    private init(transport: FDTransport, hello: JSON, endpoint: CoreEndpoint) {
        self.transport = transport
        self.hello = hello
        self.endpoint = endpoint
        self.features = Set(hello["features"]?.stringArray ?? [])
    }

    /// The core's name for itself (its host name by default).
    public var coreName: String { hello["core"]?["name"]?.string ?? "" }
    public var coreID: String { hello["core"]?["id"]?.string ?? "" }
    public var version: String { hello["version"]?.string ?? "" }

    /// The API generation Swiftr speaks: it turns away cores of a later one.
    public static let generation = 1

    /// Connects, says hello and switches to framed mode.
    public static func connect(to endpoint: CoreEndpoint) async throws -> CoreConnection {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CoreConnection, any Error>) in
            let thread = Thread {
                do {
                    let transport = try endpoint.open()
                    let line = Data(#"{"jsonrpc":"2.0","id":0,"method":"hello","params":{"framed":true}}"#.utf8 + [0x0A])
                    let reply: JSON
                    let leftover: [UInt8]
                    do {
                        (reply, leftover) = try transport.handshake(line, timeout: 15)
                    } catch {
                        transport.close()
                        transport.finish()
                        throw error
                    }
                    if let error = reply["error"] {
                        transport.close()
                        transport.finish()
                        throw CoreError(json: error)
                    }
                    let hello = reply["result"] ?? .null
                    let generation = hello["generation"]?.int ?? 0
                    if generation > CoreConnection.generation {
                        transport.close()
                        transport.finish()
                        throw CoreError(kind: "needs_update", message: "This core speaks API generation \(generation): update Swiftr.")
                    }
                    let connection = CoreConnection(transport: transport, hello: hello, endpoint: endpoint)
                    connection.startReading(leftover: leftover)
                    cont.resume(returning: connection)
                } catch {
                    cont.resume(throwing: error)
                }
            }
            thread.name = "swiftr.core.connect"
            thread.start()
        }
    }

    public var isClosed: Bool { state.withLock { $0.closed != nil } }

    /// Runs once when the connection drops (at once if it already has).
    public func onLost(_ handler: @escaping @Sendable (String) -> Void) {
        let closed = state.withLock { s -> String? in
            if let c = s.closed { return c }
            s.lostHandlers.append(handler)
            return nil
        }
        if let closed { handler(closed) }
    }

    public func close() {
        transport.close()
    }

    // MARK: Calls

    public func call(_ method: String, _ params: JSON = [:], timeout: Duration? = .seconds(30)) async throws -> JSON {
        try await call(method, params, timeout: timeout, onResult: nil)
    }

    private func call(_ method: String, _ params: JSON, timeout: Duration?, onResult: (@Sendable (JSON) -> Void)?) async throws -> JSON {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSON, any Error>) in
            let started: Result<Int64, CoreError> = state.withLock { s in
                if let closed = s.closed { return .failure(.lost(closed)) }
                let id = s.nextID
                s.nextID += 1
                s.pending[id] = Pending(continuation: cont, onResult: onResult)
                return .success(id)
            }
            switch started {
            case .failure(let error):
                cont.resume(throwing: error)
            case .success(let id):
                let message: JSON = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params]
                send(channel: 0, kind: .data, payload: message.data())
                if let timeout {
                    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
                        guard let self, let p = self.state.withLock({ $0.pending.removeValue(forKey: id) }) else { return }
                        p.continuation.resume(throwing: CoreError(kind: "timeout", message: "\(method): no answer after \(Int(seconds)) s"))
                    }
                }
            }
        }
    }

    // MARK: Streams

    public struct Attachment: Sendable {
        public let channel: UInt32
        /// Engine replies may go as AUTOMATIC_INPUT: both the core's hello and
        /// this attach said so (schema/README.md, "Attach streams").
        public let automaticInput: Bool
        public let resizeNotifications: Bool
        public let terminal: JSON
    }

    /// Attaches to a terminal. Its sink gets the first paint, then live output.
    /// `observe`: watch only; never type, resize or take the size.
    public func attach(_ terminal: String, cols: Int, rows: Int, history: Int = 2000, display: JSON? = nil, observe: Bool = false, sink: any StreamSink) async throws -> Attachment {
        var params: JSON = ["terminal": .string(terminal), "cols": JSON(cols), "rows": JSON(rows), "history": JSON(history)]
        if let display { params["display"] = display }
        if observe { params["observe"] = true }
        let result = try await call("terminal.attach", params, timeout: .seconds(60), onResult: register(sink))
        guard let channel = result["channel"]?.int64 else {
            throw CoreError(kind: "protocol", message: "terminal.attach returned no channel")
        }
        let automatic = features.contains("automatic_input") && result["automatic_input"]?.bool == true
        return Attachment(channel: UInt32(channel), automaticInput: automatic, resizeNotifications: result["resize_notifications"]?.bool == true, terminal: result["terminal"] ?? .null)
    }

    /// Subscribes to events; returns the snapshot (`seq`, `terminals`).
    public func subscribe(_ params: JSON = [:], sink: any StreamSink) async throws -> JSON {
        let result = try await call("events.subscribe", params, timeout: .seconds(60), onResult: register(sink))
        if let channel = result["channel"]?.int64 {
            credit(UInt32(channel), 1024 * 1024)
        }
        return result
    }

    /// Registers the sink on the reader thread as the reply arrives, before
    /// the stream's first frame can.
    private func register(_ sink: any StreamSink) -> @Sendable (JSON) -> Void {
        { [weak self] result in
            guard let self, let channel = result["channel"]?.int64 else { return }
            let ch = UInt32(channel)
            self.state.withLock { $0.sinks[ch] = sink }
            sink.streamOpened(channel: ch, connection: self, result: result)
        }
    }

    public func send(channel: UInt32, kind: FrameKind, payload: some ContiguousBytes) {
        transport.send(FrameCodec.encode(channel: channel, kind: kind, payload: payload))
    }

    /// Typing (DATA).
    public func input(_ channel: UInt32, _ bytes: some ContiguousBytes) {
        send(channel: channel, kind: .data, payload: bytes)
    }

    public func credit(_ channel: UInt32, _ count: Int) {
        guard count > 0 else { return }
        withUnsafeBytes(of: UInt32(clamping: count).littleEndian) { send(channel: channel, kind: .credit, payload: Data($0)) }
    }

    public func resize(_ channel: UInt32, cols: Int, rows: Int) {
        var p = Data(capacity: 4)
        withUnsafeBytes(of: UInt16(clamping: cols).littleEndian) { p.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(clamping: rows).littleEndian) { p.append(contentsOf: $0) }
        send(channel: channel, kind: .resize, payload: p)
    }

    public func focus(_ channel: UInt32, _ focused: Bool) {
        send(channel: channel, kind: .focus, payload: [UInt8(focused ? 1 : 0)])
    }

    /// The viewer's colors and cell size, which the core answers queries with.
    public func facts(_ channel: UInt32, _ display: JSON) {
        send(channel: channel, kind: .facts, payload: display.data())
    }

    /// Leaves a stream; the core answers with an empty CLOSE.
    public func detach(_ channel: UInt32) {
        _ = state.withLock { $0.sinks.removeValue(forKey: channel) }
        send(channel: channel, kind: .close, payload: Data())
    }

    // MARK: Reading

    private func startReading(leftover: [UInt8]) {
        let thread = Thread { [self] in readLoop(leftover: leftover) }
        thread.name = "swiftr.core.read"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func readLoop(leftover: [UInt8]) {
        var reader = FrameReader()
        var why = "the core closed the connection"
        let size = 256 * 1024
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        do {
            if !leftover.isEmpty {
                leftover.withUnsafeBytes { reader.append($0) }
                while let frame = try reader.next() { dispatch(frame) }
            }
            while true {
                let n = transport.read(into: buffer)
                if n <= 0 {
                    if n < 0 { why = "read failed: \(String(cString: strerror(errno)))" }
                    break
                }
                reader.append(UnsafeRawBufferPointer(rebasing: buffer[0 ..< n]))
                while let frame = try reader.next() { dispatch(frame) }
            }
        } catch {
            why = "\(error)"
        }
        transport.finish()
        fail(why)
    }

    private func dispatch(_ frame: RawFrame) {
        if frame.channel == 0 {
            guard frame.kind == FrameKind.data.rawValue,
                  let message = frame.payload.withUnsafeBytes({ try? JSON(bytes: $0) }),
                  let id = message["id"]?.int64,
                  let pending = state.withLock({ $0.pending.removeValue(forKey: id) })
            else { return }
            if let error = message["error"], !error.isNull {
                pending.continuation.resume(throwing: CoreError(json: error))
            } else {
                let result = message["result"] ?? .null
                pending.onResult?(result)
                pending.continuation.resume(returning: result)
            }
            return
        }
        guard let sink = state.withLock({ $0.sinks[frame.channel] }) else { return }
        switch FrameKind(rawValue: frame.kind) {
        case .data:
            frame.payload.withUnsafeBytes { sink.streamData($0) }
        case .close:
            _ = state.withLock { $0.sinks.removeValue(forKey: frame.channel) }
            let reason = frame.payload.isEmpty ? JSON.object([:]) : (frame.payload.withUnsafeBytes { try? JSON(bytes: $0) } ?? .null)
            sink.streamClosed(reason: reason)
        case .resize:
            guard frame.payload.count >= 4 else { return }
            let p = frame.payload.startIndex
            let cols = Int(UInt16(frame.payload[p]) | UInt16(frame.payload[p + 1]) << 8)
            let rows = Int(UInt16(frame.payload[p + 2]) | UInt16(frame.payload[p + 3]) << 8)
            sink.streamResize(cols: cols, rows: rows)
        default:
            break
        }
    }

    private func fail(_ why: String) {
        let (pending, sinks, handlers) = state.withLock { s -> ([Pending], [any StreamSink], [@Sendable (String) -> Void]) in
            if s.closed == nil { s.closed = why }
            let p = Array(s.pending.values)
            let k = Array(s.sinks.values)
            let h = s.lostHandlers
            s.pending.removeAll()
            s.sinks.removeAll()
            s.lostHandlers.removeAll()
            return (p, k, h)
        }
        for p in pending { p.continuation.resume(throwing: CoreError.lost(why)) }
        for s in sinks { s.streamClosed(reason: nil) }
        for h in handlers { h(why) }
    }
}

/// Reads an `events.subscribe` stream: whole JSON lines, handed over in order.
public final class EventFeed: StreamSink, @unchecked Sendable {
    // Reader thread only.
    private var lines = LineSplitter()
    private var channel: UInt32 = 0
    private weak var connection: CoreConnection?

    private let deliver: @Sendable ([JSON]) -> Void
    private let ended: @Sendable (JSON?) -> Void

    public init(deliver: @escaping @Sendable ([JSON]) -> Void, ended: @escaping @Sendable (JSON?) -> Void) {
        self.deliver = deliver
        self.ended = ended
    }

    public func streamOpened(channel: UInt32, connection: CoreConnection, result: JSON) {
        self.channel = channel
        self.connection = connection
    }

    public func streamData(_ bytes: UnsafeRawBufferPointer) {
        var batch: [JSON] = []
        lines.push(bytes) { line in
            if line.count > 0, let message = try? JSON(bytes: line) { batch.append(message) }
        }
        if !batch.isEmpty { deliver(batch) }
        connection?.credit(channel, bytes.count)
    }

    public func streamResize(cols: Int, rows: Int) {}

    public func streamClosed(reason: JSON?) {
        ended(reason)
    }
}
