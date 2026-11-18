import CryptoKit
import Foundation
import JavaScriptCore
import Network
import zlib

// What herdr-app's `buffer`, `crypto`, `zlib`, `net` and `websocket` modules
// need from the Mac: base64, hashes, random bytes, deflate, and client
// sockets. Sums take and give typed arrays; calls that answer later (files,
// sockets) carry bytes as base64 in their JSON.

/// Bytes between the script and the Mac as typed arrays, with no text in
/// between: the app runs scripts without a JIT, where a loop over a few
/// megabytes in JavaScript takes seconds.
nonisolated enum ModByteBridge {
    /// The bytes of a `Uint8Array` (a `Buffer` is one), copied.
    static func data(_ value: JSValue?) -> Data? {
        guard let value, let context = value.context?.jsGlobalContextRef, value.isObject, let object = JSValueToObject(context, value.jsValueRef, nil),
              JSValueGetTypedArrayType(context, object, nil) == kJSTypedArrayTypeUint8Array else { return nil }
        let length = JSObjectGetTypedArrayByteLength(context, object, nil)
        // The pointer is to the whole store the array is a window on.
        guard length > 0, let store = JSObjectGetTypedArrayBytesPtr(context, object, nil) else { return Data() }
        return Data(bytes: store + JSObjectGetTypedArrayByteOffset(context, object, nil), count: length)
    }

    /// A new `Uint8Array` holding these bytes.
    static func array(_ data: Data, in context: JSContext) -> JSValue? {
        guard let ref = context.jsGlobalContextRef, let array = JSObjectMakeTypedArray(ref, kJSTypedArrayTypeUint8Array, data.count, nil) else { return nil }
        if !data.isEmpty, let store = JSObjectGetTypedArrayBytesPtr(ref, array, nil) {
            data.copyBytes(to: store.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
        return JSValue(jsValueRef: array, in: context)
    }

    /// Base64 as people write it: with `-` and `_`, line breaks, or no
    /// padding. What follows the first `=` is left out.
    static func decode(_ text: String) -> Data {
        var clean: [UInt8] = []
        clean.reserveCapacity(text.utf8.count + 3)
        letters: for byte in text.utf8 {
            switch byte {
            case 65...90, 97...122, 48...57, 43, 47: clean.append(byte)
            case 45: clean.append(43)
            case 95: clean.append(47)
            case 61: break letters
            default: continue
            }
        }
        // A last letter by itself carries no whole byte.
        if clean.count % 4 == 1 { clean.removeLast() }
        while clean.count % 4 != 0 { clean.append(61) }
        return Data(base64Encoded: Data(clean)) ?? Data()
    }
}

/// Hashes and random bytes for `crypto`.
nonisolated enum ModCrypto {
    static let algorithms = ["md5", "sha1", "sha256", "sha384", "sha512"]

    /// `sha-256`, `SHA256` and `sha256` name the same hash.
    static func name(_ asked: String) -> String { asked.lowercased().replacingOccurrences(of: "-", with: "") }

    static func hash(_ algorithm: String, _ data: Data) -> Data? {
        switch name(algorithm) {
        case "md5": Data(Insecure.MD5.hash(data: data))
        case "sha1": Data(Insecure.SHA1.hash(data: data))
        case "sha256": Data(SHA256.hash(data: data))
        case "sha384": Data(SHA384.hash(data: data))
        case "sha512": Data(SHA512.hash(data: data))
        default: nil
        }
    }

    /// The most a script may ask for at once.
    static let randomLimit = 1 << 20

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: max(0, min(count, randomLimit)))
        if !bytes.isEmpty { _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) }
        return Data(bytes)
    }
}

/// Deflate and its reverse, in zlib's and gzip's wrapping, for `zlib`.
nonisolated enum ModZip {
    /// A few bytes can inflate to gigabytes: past this, the call fails.
    static let limit = 64 << 20

    static func deflate(_ data: Data, gzip: Bool) throws -> Data { try run(data, gzip: gzip, inflating: false) }
    static func inflate(_ data: Data, gzip: Bool) throws -> Data { try run(data, gzip: gzip, inflating: true) }

    private static func run(_ data: Data, gzip: Bool, inflating: Bool) throws -> Data {
        var stream = z_stream()
        // 15 bits of window; 16 more asks for gzip's header and check.
        let window: Int32 = gzip ? 31 : 15
        let size = Int32(MemoryLayout<z_stream>.size)
        let began = inflating
            ? inflateInit2_(&stream, window, ZLIB_VERSION, size)
            : deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, window, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, size)
        guard began == Z_OK else { throw ModError("zlib could not start") }
        defer { if inflating { inflateEnd(&stream) } else { deflateEnd(&stream) } }

        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        var input = [UInt8](data)
        let length = input.count
        var status = Z_OK
        try input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = uInt(length)
            repeat {
                let space = chunk.count
                status = chunk.withUnsafeMutableBufferPointer { target in
                    stream.next_out = target.baseAddress
                    stream.avail_out = uInt(space)
                    return inflating ? zlib.inflate(&stream, Z_NO_FLUSH) : zlib.deflate(&stream, Z_FINISH)
                }
                let made = space - Int(stream.avail_out)
                out.append(contentsOf: chunk[0..<made])
                if out.count > limit { throw ModError("zlib: more than \(limit >> 20) MB") }
                // No room left to read and nothing written: the data stops short.
                if status == Z_BUF_ERROR, made == 0 { throw ModError("zlib: unexpected end of data") }
            } while status == Z_OK || status == Z_BUF_ERROR
        }
        guard status == Z_STREAM_END else {
            throw ModError(inflating ? "zlib: incorrect data" : "zlib could not finish")
        }
        return out
    }
}

/// A socket a mod opened: closed with the mod, or when its leave to reach
/// the network goes.
nonisolated protocol ModSocket: AnyObject, Sendable {
    func shut()
    /// Nothing more will come through it: it no longer counts as open.
    var isOver: Bool { get }
}

/// One call's answer, given once whatever comes first (the answer, an
/// error, a time limit).
private nonisolated final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func give(_ result: Result<T, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

/// `net.connect(host, port)`: a TCP client.
nonisolated final class ModTCP: ModSocket, @unchecked Sendable {
    /// The most one `read` gives back.
    static let readLimit = 1 << 20

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "swiftr.mod.tcp")
    private let lock = NSLock()
    private var isShut = false
    /// The other side sent its last byte; this side may still write.
    private var isDone = false

    init?(host: String, port: Int) {
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port.rawValue > 0 else { return nil }
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }

    private var shutNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isShut
    }

    private var overNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isShut || isDone
    }

    var isOver: Bool {
        if overNow { return true }
        switch connection.state {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    func open(timeout: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready: once.give(.success(()))
                // Refused or unreachable: Network would wait for a better day.
                case .waiting(let error), .failed(let error):
                    connection.cancel()
                    once.give(.failure(ModError("net.connect: \(error.localizedDescription)")))
                case .cancelled: once.give(.failure(ModError("net.connect: closed")))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                guard connection.state != .ready else { return }
                connection.cancel()
                once.give(.failure(ModError("net.connect: no answer after \(Int(timeout)) s")))
            }
            connection.start(queue: queue)
        }
    }

    func write(_ data: Data) async throws {
        guard !shutNow else { throw ModError("net: the socket is closed") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: ModError("net: \(error.localizedDescription)")) } else { continuation.resume() }
            })
        }
    }

    /// The next bytes; nil once the other side is done or the socket shut.
    func read(max: Int) async throws -> Data? {
        guard !overNow else { return nil }
        let most = Swift.max(1, Swift.min(max, Self.readLimit))
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: most) { [weak self] data, _, isComplete, error in
                // The last bytes can come with the end: the reads after
                // them give nil, where Network would give an error.
                if isComplete, let self {
                    self.lock.lock()
                    self.isDone = true
                    self.lock.unlock()
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || self?.shutNow != false {
                    continuation.resume(returning: nil)
                } else if let error {
                    continuation.resume(throwing: ModError("net: \(error.localizedDescription)"))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func shut() {
        lock.lock()
        isShut = true
        lock.unlock()
        connection.cancel()
    }
}

/// `WebSocket.connect(url)`: a client, with no cookie or saved sign-in of
/// the app's.
nonisolated final class ModWebSocket: NSObject, ModSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Headers a mod may not set: the handshake's own, and credentials.
    static func refuses(header name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("sec-websocket-") || ["host", "connection", "upgrade", "content-length", "authorization", "proxy-authorization", "cookie"].contains(name)
    }

    private let lock = NSLock()
    private var opening: Once<Void>?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var isShut = false

    /// The request's own time limit, kept long: a feed can be quiet for
    /// hours, and URLSession has been said to end a silent socket by it.
    /// (On macOS 27.2 a 1 s limit left a 3 s silence alone, tried
    /// 2026-11-18; the handshake has its own timer below either way.)
    static let quietLimit: TimeInterval = 7 * 24 * 3600

    var isOver: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isShut || task?.state == .completed || (task.map { $0.closeCode != .invalid } ?? false)
    }

    func open(_ request: URLRequest, timeout: TimeInterval = 15) async throws {
        var request = request
        request.timeoutInterval = Self.quietLimit
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.quietLimit
        configuration.timeoutIntervalForResource = Self.quietLimit
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 << 20
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            lock.lock()
            opening = once
            self.session = session
            self.task = task
            lock.unlock()
            // The handshake has its own, short limit.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.stillOpening(once) else { return }
                self.shut()
                once.give(.failure(ModError("WebSocket.connect: no answer after \(Int(timeout)) s")))
            }
            task.resume()
        }
    }

    private func stillOpening(_ once: Once<Void>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return opening === once
    }

    private func opened(_ result: Result<Void, Error>) {
        lock.lock()
        let waiting = opening
        opening = nil
        lock.unlock()
        waiting?.give(result)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        opened(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        opened(.failure(ModError("WebSocket.connect: \(error?.localizedDescription ?? "closed")")))
    }

    private var live: URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return isShut ? nil : task
    }

    func read() async throws -> URLSessionWebSocketTask.Message {
        guard let task = live else { throw ModError("websocket: the socket is closed") }
        do { return try await task.receive() } catch { throw ModError("websocket: \(live == nil ? "the socket is closed" : error.localizedDescription)") }
    }

    func write(_ message: URLSessionWebSocketTask.Message) async throws {
        guard let task = live else { throw ModError("websocket: the socket is closed") }
        do { try await task.send(message) } catch { throw ModError("websocket: \(error.localizedDescription)") }
    }

    /// Sends the closing frame, then lets go of the connection.
    func close() {
        lock.lock()
        let task = isShut ? nil : self.task
        let session = self.session
        isShut = true
        self.session = nil
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        // The session holds this object until it is told to finish.
        session?.finishTasksAndInvalidate()
    }

    func shut() {
        lock.lock()
        let session = self.session
        isShut = true
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        opened(.failure(ModError("WebSocket.connect: closed")))
    }
}
