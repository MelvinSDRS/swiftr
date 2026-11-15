import Foundation
import Synchronization

/// Where a core listens, and how to start it when it doesn't.
public struct CoreEndpoint: Sendable, Hashable {
    /// The core session (`HC_SESSION`), "default" unless set.
    public var session: String
    /// The client socket (schema/README.md and docs/security.md, "State and endpoints").
    public var socketPath: String
    /// `hc`, used only when the socket doesn't answer: `hc connect` starts the core.
    public var hcPath: String
    /// The environment `hc connect` gets (and so the core it may start).
    public var environment: [String: String]

    public init(session: String, socketPath: String, hcPath: String, environment: [String: String]) {
        self.session = session
        self.socketPath = socketPath
        self.hcPath = hcPath
        self.environment = environment
    }

    /// This machine's core for `session` (nil: `HC_SESSION`, else "default").
    public static func local(session: String? = nil) -> CoreEndpoint {
        let env = ProcessInfo.processInfo.environment
        let nonEmpty = { (key: String) -> String? in env[key].flatMap { $0.isEmpty ? nil : $0 } }
        let session = session.flatMap { $0.isEmpty ? nil : $0 } ?? nonEmpty("HC_SESSION") ?? "default"
        let home = NSHomeDirectory()
        let socket: String
        if let s = nonEmpty("HC_SOCKET") {
            socket = s
        } else if let runtime = nonEmpty("XDG_RUNTIME_DIR") {
            socket = "\(runtime)/herdr-core/\(session).sock"
        } else {
            let state = nonEmpty("XDG_STATE_HOME") ?? "\(home)/.local/state"
            socket = "\(state)/herdr-core/\(session)/\(session).sock"
        }
        let hc = installedHC(environment: env) ?? hcCandidates(environment: env)[0]

        // A Finder-launched app has a thin environment; a core it starts
        // passes this on to every shell, so give it what a login would.
        var e = env
        if session != "default" { e["HC_SESSION"] = session }
        let path = e["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let dirs = [nonEmpty("HC_INSTALL_DIR"), "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"].compactMap { $0 }
        let extra = dirs.filter { !path.split(separator: ":").contains(Substring($0)) }
        e["PATH"] = (extra + [path]).joined(separator: ":")
        if e["LANG"] == nil {
            let id = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
            e["LANG"] = (id.isEmpty ? "en_US" : id.components(separatedBy: "@")[0]) + ".UTF-8"
        }
        return CoreEndpoint(session: session, socketPath: socket, hcPath: hc, environment: e)
    }

    /// Where `hc` may be, in the order Swiftr looks: where herdr's installer
    /// puts it (~/.local/bin, as `herdr-core` alone when another `hc` was on
    /// the PATH), then Homebrew's. `HC_INSTALL_DIR`, which moves the
    /// installer, is the only place looked at when set.
    public static func hcCandidates(environment env: [String: String]) -> [String] {
        if let dir = env["HC_INSTALL_DIR"], !dir.isEmpty { return ["\(dir)/hc", "\(dir)/herdr-core"] }
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/hc", "\(home)/.local/bin/herdr-core", "/opt/homebrew/bin/hc", "/usr/local/bin/hc"]
    }

    /// The first `hc` this Mac has; nil when herdr-core isn't installed.
    public static func installedHC(environment: [String: String]) -> String? {
        hcCandidates(environment: environment).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The socket, else `hc connect` (which starts the core if needed).
    func open() throws -> FDTransport {
        do {
            return try FDTransport.socket(path: socketPath)
        } catch {
            #if os(macOS)
            return try FDTransport.hcConnect(path: hcPath, environment: environment)
            #else
            throw error
            #endif
        }
    }
}

/// Blocking byte I/O on file descriptors: a Unix socket, or the pipes of
/// `hc connect`. The connection reads on its own thread and writes on a queue.
final class FDTransport: @unchecked Sendable {
    let readFD: Int32
    let writeFD: Int32
    private let isSocket: Bool
    #if os(macOS)
    private let process: Process?
    private let pipes: [Pipe]
    #endif
    private let closed = Mutex(false)
    private let finished = Mutex(false)
    /// Writes in order, and the socket closes behind the last one, so a
    /// queued write never lands on a reused descriptor.
    private let writeQueue = DispatchQueue(label: "swiftr.core.write", qos: .userInteractive)

    #if os(macOS)
    private init(readFD: Int32, writeFD: Int32, isSocket: Bool, process: Process?, pipes: [Pipe]) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.isSocket = isSocket
        self.process = process
        self.pipes = pipes
    }
    #else
    private init(readFD: Int32, writeFD: Int32, isSocket: Bool) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.isSocket = isSocket
    }
    #endif

    static func socket(path: String) throws -> FDTransport {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoreError.posix("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw CoreError(kind: "endpoint", message: "socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let error = CoreError.posix("connect \(path)")
            Darwin.close(fd)
            throw error
        }
        #if os(macOS)
        return FDTransport(readFD: fd, writeFD: fd, isSocket: true, process: nil, pipes: [])
        #else
        return FDTransport(readFD: fd, writeFD: fd, isSocket: true)
        #endif
    }

    #if os(macOS)
    static func hcConnect(path: String, environment: [String: String]) throws -> FDTransport {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["connect"]
        p.environment = environment
        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            throw CoreError(kind: "endpoint", message: "cannot run \(path) connect: \(error.localizedDescription)")
        }
        let w = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(w, F_SETNOSIGPIPE, 1)
        return FDTransport(readFD: output.fileHandleForReading.fileDescriptor, writeFD: w, isSocket: false, process: p, pipes: [input, output])
    }
    #endif

    /// Bytes read into `buffer`: > 0, 0 at the end, < 0 on error.
    func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        while true {
            let n = Darwin.read(readFD, buffer.baseAddress, buffer.count)
            if n < 0 && errno == EINTR { continue }
            return n
        }
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(writeFD, base + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    throw CoreError.posix("write")
                }
            }
        }
    }

    /// Queues `data` for writing; a failed write closes the transport.
    func send(_ data: Data) {
        writeQueue.async { [self] in
            guard !closed.withLock({ $0 }) else { return }
            do {
                try writeAll(data)
            } catch {
                close()
            }
        }
    }

    /// Sends one line and reads the reply line, before the reader thread
    /// starts. Returns the reply and any bytes that came after it.
    func handshake(_ line: Data, timeout: TimeInterval) throws -> (JSON, [UInt8]) {
        if isSocket {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(readFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        defer {
            if isSocket {
                var zero = timeval(tv_sec: 0, tv_usec: 0)
                setsockopt(readFD, SOL_SOCKET, SO_RCVTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        try writeAll(line)
        var acc: [UInt8] = []
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = read(into: buf)
            if n <= 0 {
                throw n == 0 ? CoreError.lost("the core closed the connection during hello") : CoreError.posix("hello")
            }
            acc.append(contentsOf: UnsafeRawBufferPointer(rebasing: buf[0 ..< n]))
            if let nl = acc.firstIndex(of: 0x0A) {
                let reply = try JSON(data: Data(acc[0 ..< nl]))
                return (reply, Array(acc[(nl + 1)...]))
            }
        }
    }

    /// Wakes the reader; it closes the descriptors on its way out.
    func close() {
        let first = closed.withLock { c -> Bool in
            defer { c = true }
            return !c
        }
        guard first else { return }
        if isSocket {
            Darwin.shutdown(readFD, SHUT_RDWR)
        } else {
            #if os(macOS)
            if let process, process.isRunning { process.terminate() }
            #endif
        }
    }

    /// Called once by the reader thread when it stops.
    func finish() {
        let first = finished.withLock { f -> Bool in
            defer { f = true }
            return !f
        }
        guard first else { return }
        close()
        if isSocket {
            let fd = readFD
            writeQueue.async { Darwin.close(fd) }
        }
        // Pipes close their descriptors when released.
    }
}
