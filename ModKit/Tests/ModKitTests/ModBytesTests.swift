import AppKit
import Foundation
import Network
import Testing
@testable import ModKit

/// A listener on this Mac only, for the socket tests: it sends back what it
/// gets. TCP: on `bye` it answers `end` and closes. WebSocket: it keeps the
/// headers the client sent.
nonisolated final class Loopback: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "modkit.tests.loopback")
    private let lock = NSLock()
    private var held: [NWConnection] = []
    private var seen = 0
    private let webSocket: Bool

    /// The headers of the last WebSocket handshake.
    private final class Notes: @unchecked Sendable {
        let lock = NSLock()
        var headers: [String: String] = [:]
    }
    private let notes = Notes()

    init(webSocket: Bool = false) throws {
        self.webSocket = webSocket
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        if webSocket {
            let options = NWProtocolWebSocket.Options()
            // Set before the options join the stack, which copies them.
            options.setClientRequestHandler(queue) { [notes] _, headers in
                notes.lock.lock()
                for (name, value) in headers { notes.headers[name.lowercased()] = value }
                notes.lock.unlock()
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        listener = try NWListener(using: parameters, on: .any)
    }

    var connections: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func header(_ name: String) -> String? {
        notes.lock.lock()
        defer { notes.lock.unlock() }
        return notes.headers[name]
    }

    /// Starts listening; gives the port.
    func start() async throws -> Int {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock()
            self.seen += 1
            self.held.append(connection)
            self.lock.unlock()
            connection.start(queue: self.queue)
            if self.webSocket { self.echoMessages(connection) } else { self.echoBytes(connection) }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            nonisolated(unsafe) var answered = false
            listener.stateUpdateHandler = { [listener] state in
                guard !answered else { return }
                switch state {
                case .ready:
                    answered = true
                    continuation.resume(returning: Int(listener.port?.rawValue ?? 0))
                case .failed(let error):
                    answered = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func echoBytes(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let data, !data.isEmpty else { return }
            if data == Data("bye".utf8) {
                connection.send(content: Data("end".utf8), contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                return
            }
            connection.send(content: data, completion: .idempotent)
            if !isComplete, error == nil { self?.echoBytes(connection) }
        }
    }

    private func echoMessages(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard error == nil, let data, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else { return }
            if metadata.opcode == .text || metadata.opcode == .binary {
                let reply = NWConnection.ContentContext(identifier: "echo", metadata: [NWProtocolWebSocket.Metadata(opcode: metadata.opcode)])
                connection.send(content: data, contentContext: reply, isComplete: true, completion: .idempotent)
            }
            if metadata.opcode != .close { self?.echoMessages(connection) }
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let all = held
        held = []
        lock.unlock()
        for connection in all { connection.cancel() }
    }
}

/// `buffer`, `crypto`, `zlib`, `net`, `websocket`, and bytes in files.
@Suite(.serialized) struct ModBytesTests {
    /// A mod whose `work(props, say)` runs once; each `say(line)` is a line
    /// of its panel.
    private func home(_ imports: String, _ work: String) throws -> Home {
        try Home(["m": """
        import { View, div } from "gpui-kit";
        import { v_flex } from "gpui-base";
        \(imports)
        export default class M extends View {
          init(props, cx) {
            this.lines = [];
            const say = (line) => { this.lines.push(String(line)); cx.notify(); };
            this.go = async () => { \(work) };
            this.go().then(() => say("done"), (e) => say("failed: " + (e && e.message ? e.message : e)));
          }
          render() { return v_flex().size_full().children(this.lines.map((line) => div().child(line))); }
        }
        """])
    }

    /// Waits for the mod's last line to be `done` or a failure.
    private func lines(_ view: ModView, _ home: Home, until last: String = "done") async -> [String] {
        for _ in 0..<200 {
            await home.settle(0.05)
            view.renderNow()
            let texts = view.texts()
            if texts.last == last || texts.last?.hasPrefix("failed") == true { return texts }
        }
        return view.texts()
    }

    @Test func aBufferCodesTextAndBytes() async throws {
        let home = try home(#"import { Buffer } from "buffer";"#, #"""
          say(Buffer.from("héllo €😀").toString("hex"));
          say(Buffer.from("68c3a96c6c6f20e282acf09f9880", "hex").toString());
          say(Buffer.from("aGVsbG8=", "base64").toString() + " " + Buffer.from("hello").toString("base64"));
          say(Buffer.from([251, 255]).toString("base64url") + " " + Buffer.from("-_8", "base64url").toJSON().data.join());
          say(Buffer.concat([Buffer.from("a"), new Uint8Array([98, 99])]).toString() + " " + Buffer.byteLength("€"));
          say(Buffer.alloc(3, 1).toJSON().data.join() + " " + Buffer.from([1, 2, 3, 4]).readUInt32BE(0));
          const b = Buffer.from("hello");
          say([Buffer.isBuffer(b), b instanceof Uint8Array, Buffer.isBuffer(new Uint8Array(1)), b.subarray(1, 3).toString(), b.slice(3).toString()].join());
          say(Buffer.from([0xe9]).toString("latin1") + " " + Buffer.from([0xff, 0x41]).toString() + " " + Buffer.from("héllo", "utf16le").toString("hex"));
          say(Buffer.from("héllo", "latin1").toJSON().data.join() + " " + Buffer.compare(Buffer.from("a"), Buffer.from("b")) + " " + b.equals(Buffer.from("hello")));
          const shared = new Uint8Array([1, 2, 3]);
          const copy = Buffer.from(shared), over = Buffer.from(shared.buffer);
          shared[0] = 9;
          say(copy[0] + " " + over[0] + " " + typeof globalThis.Buffer);
        """#)
        let view = try home.view("m")
        #expect(await lines(view, home) == [
            "68c3a96c6c6f20e282acf09f9880",
            "héllo €😀",
            "hello aGVsbG8=",
            "-_8 251,255",
            "abc 3",
            "1,1,1 16909060",
            "true,true,false,el,lo",
            "é \u{fffd}A 6800e9006c006c006f00",
            "104,233,108,108,111 -1 true",
            "1 9 function",
            "done",
        ])
    }

    @Test func hashesAndRandomBytesAreTheSystems() async throws {
        let home = try home(#"""
        import { Buffer } from "buffer";
        import { createHash, randomBytes, randomUUID, webcrypto } from "crypto";
        """#, #"""
          say(createHash("sha256").update("abc").digest("hex"));
          say(createHash("sha1").update("a").update(Buffer.from("bc")).digest("hex"));
          say(createHash("md5").update("abc").digest("hex"));
          say(createHash("SHA-256").update("héllo").update(new Uint8Array([0, 255])).digest("hex"));
          say(createHash("sha512").update("abc").digest("hex").slice(0, 32) + " " + createHash("sha384").update("abc").digest("hex").slice(0, 32));
          const raw = createHash("sha256").update("abc").digest();
          say([Buffer.isBuffer(raw), raw.length, raw.toString("base64")].join());
          const a = randomBytes(8), b = randomBytes(8);
          say([a.length, Buffer.isBuffer(a), a.equals(b), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(randomUUID())].join());
          let refused = "no";
          try { createHash("whirlpool"); } catch (e) { refused = "yes"; }
          const filled = crypto.getRandomValues(new Uint8Array(16));
          say(refused + " " + filled.some((x) => x !== 0) + " " + (webcrypto === crypto));
          say(Buffer.from(await webcrypto.subtle.digest("SHA-1", Buffer.from("abc"))).toString("hex"));
        """#)
        let view = try home.view("m")
        #expect(await lines(view, home) == [
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "a9993e364706816aba3e25717850c26c9cd0d89d",
            "900150983cd24fb0d6963f7d28e17f72",
            "7e3c57f19795e31846e77f9ef007afd62f298589c5f80b2e5745ebec0f114d35",
            "ddaf35a193617abacc417349ae204131 cb00753f45a35e8bb5a03d699ac65007",
            "true,32,ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=",
            "8,true,false,true",
            "yes true true",
            "a9993e364706816aba3e25717850c26c9cd0d89d",
            "done",
        ])
    }

    /// The system's own gzip, both ways.
    private func gzip(_ arguments: [String], _ input: Data) throws -> Data {
        let process = Process(), into = Pipe(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = arguments
        process.standardInput = into
        process.standardOutput = out
        try process.run()
        into.fileHandleForWriting.write(input)
        try into.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    @Test func zlibMeetsTheSystemsGzip() async throws {
        let text = String(repeating: "Swiftr draws mods itself. ", count: 40) + "é€😀"
        let packed = try gzip(["-c"], Data(text.utf8))
        let home = try home(#"""
        import { Buffer } from "buffer";
        import { deflateSync, inflateSync, gzipSync, gunzipSync } from "zlib";
        """#, #"""
          say(gunzipSync(Buffer.from(props.packed, "base64")).toString() === props.text);
          say(gzipSync(props.text).toString("base64"));
          say(inflateSync(Buffer.from("789ccb48cdc9c90700062c0215", "hex")).toString());
          const z = deflateSync(props.text);
          say([Buffer.isBuffer(z), z[0].toString(16), z.length < props.text.length, inflateSync(z).toString() === props.text].join());
          for (const bad of [() => inflateSync(Buffer.from("not zlib")), () => gunzipSync(Buffer.from(props.packed, "base64").subarray(0, 20))]) {
            try { bad(); say("took it"); } catch (e) { say("threw"); }
          }
        """#)
        let view = try home.view("m", props: ["packed": packed.base64EncodedString(), "text": text])
        let lines = await lines(view, home)
        #expect(lines.count == 7)
        #expect(lines.first == "true")
        let theirs = try #require(Data(base64Encoded: lines[1]))
        #expect(String(decoding: try gzip(["-dc"], theirs), as: UTF8.self) == text)
        #expect(Array(lines[2...]) == ["hello", "true,78,true,true", "threw", "threw", "done"])
    }

    @Test func inflatingStopsAtALimit() throws {
        // 65 MB of zeros is a few kilobytes deflated.
        let bomb = try ModZip.deflate(Data(count: ModZip.limit + (1 << 20)), gzip: false)
        #expect(bomb.count < 1 << 20)
        #expect(throws: ModError.self) { try ModZip.inflate(bomb, gzip: false) }
        let fine = try ModZip.deflate(Data(count: 1 << 20), gzip: true)
        #expect(try ModZip.inflate(fine, gzip: true).count == 1 << 20)
    }

    @Test func aFileKeepsItsBytes() async throws {
        let home = try home(#"""
        import { Buffer } from "buffer";
        import { readFile, writeFile } from "fs/promises";
        """#, #"""
          const bytes = Buffer.from([0, 255, 128, 10, 195, 40]);
          await writeFile(props.folder + "/raw.bin", bytes);
          const back = await readFile(props.folder + "/raw.bin");
          say([back instanceof Uint8Array, back.length, Buffer.from(back).toString("hex")].join());
          await writeFile(props.folder + "/text.txt", "héllo");
          say(await readFile(props.folder + "/text.txt", "utf8"));
          say(typeof (await readFile(props.folder + "/text.txt", { encoding: "utf8" })));
          say(Buffer.from(await readFile(props.folder + "/text.txt")).toString("hex"));
          say(await readFile(props.folder + "/raw.bin", "hex"));
        """#)
        let folder = home.root.appending(path: "mods/m")
        let view = try home.view("m", props: ["folder": folder.path])
        #expect(await lines(view, home) == ["true,6,00ff800ac328", "héllo", "string", "68c3a96c6c6f", "00ff800ac328", "done"])
        #expect(try Data(contentsOf: folder.appending(path: "raw.bin")) == Data([0, 255, 128, 10, 195, 40]))
    }

    private let talker = #"""
      const socket = await connect("127.0.0.1", props.port);
      await socket.write("ping");
      say(Buffer.from(await socket.read(16)).toString());
      await socket.write(new Uint8Array([0, 255, 7]));
      say(Buffer.from(await socket.read()).toString("hex"));
      await socket.write("bye");
      say(Buffer.from(await socket.read()).toString());
      say(String(await socket.read()));
      socket.close();
      say(String(await socket.read()));
    """#

    @Test func aSocketTalksToAPort() async throws {
        let server = try Loopback()
        let port = try await server.start()
        defer { server.stop() }
        let home = try home(#"import { Buffer } from "buffer"; import { connect } from "net";"#, talker)
        let view = try home.view("m", granted: [.network], props: ["port": port])
        #expect(await lines(view, home) == ["ping", "00ff07", "end", "null", "null", "done"])
        #expect(server.connections == 1)
        #expect(home.center.loaded("m")?.openSockets == 0)
    }

    /// As `swiftr-mod check` runs a mod: every leave but the network.
    @Test func aModWithoutTheLeaveOpensNoSocket() async throws {
        let server = try Loopback(), web = try Loopback(webSocket: true)
        let port = try await server.start(), webPort = try await web.start()
        defer { server.stop(); web.stop() }
        let home = try home(#"import { connect } from "net"; import { WebSocket } from "websocket";"#, #"""
          for (const open of [() => connect("127.0.0.1", props.port), () => WebSocket.connect("ws://127.0.0.1:" + props.web + "/")]) {
            try { await open(); say("opened"); } catch (e) { say("refused"); }
          }
        """#)
        let view = try home.view("m", granted: [.programs, .readFiles, .writeFiles, .commands], props: ["port": port, "web": webPort])
        #expect(await lines(view, home) == ["refused", "refused", "done"])
        await home.settle(0.2)
        #expect(server.connections == 0)
        #expect(web.connections == 0)
        #expect(home.center.loaded("m")?.openSockets == 0)
        #expect(home.center.loaded("m")?.errors.contains { $0.contains("net.connect refused") } == true)
    }

    @Test func socketsEndWithTheLeaveAndTheMod() async throws {
        let server = try Loopback()
        let port = try await server.start()
        defer { server.stop() }
        let waiting = #"""
          const socket = await connect("127.0.0.1", props.port);
          say("open");
          say("read " + String(await socket.read()));
        """#
        let home = try home(#"import { connect } from "net";"#, waiting)
        var view = try home.view("m", granted: [.network], props: ["port": port])
        #expect(await lines(view, home, until: "open") == ["open"])
        #expect(home.center.loaded("m")?.openSockets == 1)
        // The leave goes: the socket closes and the read that waited ends.
        home.center.setGrant([], for: "m")
        #expect(home.center.loaded("m")?.openSockets == 0)
        #expect(await lines(view, home) == ["open", "read null", "done"])

        // A reload closes what the old script held.
        home.center.setGrant([.network], for: "m")
        home.center.reload("m")
        view = try home.view("m", granted: [.network], props: ["port": port])
        #expect(await lines(view, home, until: "open") == ["open"])
        let runtime = try #require(home.center.loaded("m"))
        #expect(runtime.openSockets == 1)
        home.center.reload("m")
        #expect(runtime.openSockets == 0)
    }

    @Test func aModHoldsOnlySoManySockets() async throws {
        let server = try Loopback()
        let port = try await server.start()
        defer { server.stop() }
        let home = try home(#"import { connect } from "net";"#, #"""
          let opened = 0;
          try { for (let i = 0; i < 20; i++) { await connect("127.0.0.1", props.port); opened++; } } catch (e) { say(e.message.includes("open already")); }
          say(opened);
        """#)
        let view = try home.view("m", granted: [.network], props: ["port": port])
        #expect(await lines(view, home) == ["true", "\(ModRuntime.socketLimit)", "done"])
        home.center.reload("m")
    }

    /// A mod that connects again each time the other side hangs up, and
    /// never closes, is not shut out at the 16th time.
    @Test func endedSocketsGiveTheirPlaceBack() async throws {
        let server = try Loopback()
        let port = try await server.start()
        defer { server.stop() }
        let home = try home(#"import { Buffer } from "buffer"; import { connect } from "net";"#, #"""
          let rounds = 0;
          for (let i = 0; i < 20; i++) {
            const socket = await connect("localhost", props.port);
            await socket.write("bye");
            while ((await socket.read()) !== null) {}
            rounds++;
          }
          say(rounds);
        """#)
        let view = try home.view("m", granted: [.network], props: ["port": port])
        #expect(await lines(view, home) == ["20", "done"])
        #expect(server.connections == 20)
        home.center.reload("m")
    }

    /// A socket that waits for news, with a read pending and nothing said
    /// for a while, still works after the wait.
    @Test func aQuietWebSocketStaysOpen() async throws {
        let server = try Loopback(webSocket: true)
        let port = try await server.start()
        defer { server.stop() }
        let home = try home(#"import { WebSocket } from "websocket";"#, #"""
          const ws = await WebSocket.connect("ws://127.0.0.1:" + props.port + "/");
          const news = ws.read();
          await cx.sleep(2500);
          await ws.write("late");
          say(await news);
        """#)
        let view = try home.view("m", granted: [.network], props: ["port": port])
        #expect(await lines(view, home) == ["late", "done"])
        home.center.reload("m")
    }

    @Test func aFileTooLongIsRefusedWhole() async throws {
        let limit = ModFiles.bytesLimit
        ModFiles.bytesLimit = 8
        defer { ModFiles.bytesLimit = limit }
        let home = try home(#"import { readFile, writeFile } from "fs/promises";"#, #"""
          await writeFile(props.folder + "/fits.bin", new Uint8Array(8));
          await writeFile(props.folder + "/long.bin", new Uint8Array(9));
          say((await readFile(props.folder + "/fits.bin")).length);
          try { say((await readFile(props.folder + "/long.bin")).length); } catch (e) { say("refused"); }
        """#)
        let view = try home.view("m", props: ["folder": home.root.appending(path: "mods/m").path])
        #expect(await lines(view, home) == ["8", "refused", "done"])
    }

    @Test func aWebSocketTalksBothKinds() async throws {
        let server = try Loopback(webSocket: true)
        let port = try await server.start()
        defer { server.stop() }
        let home = try home(#"import { Buffer } from "buffer"; import { WebSocket } from "websocket";"#, #"""
          const ws = await WebSocket.connect("ws://127.0.0.1:" + props.port + "/events", { headers: { Origin: "http://swiftr.test" } });
          await ws.write("héllo");
          const text = await ws.read();
          say(typeof text + " " + text);
          await ws.write(new Uint8Array([0, 255, 7]));
          const bytes = await ws.read();
          say((bytes instanceof Uint8Array) + " " + Buffer.from(bytes).toString("hex"));
          await ws.close();
          try { await ws.read(); say("read"); } catch (e) { say("closed"); }
          for (const open of [
            () => WebSocket.connect("http://127.0.0.1:" + props.port + "/"),
            () => WebSocket.connect("ws://127.0.0.1:" + props.port + "/", { headers: { Authorization: "Bearer x" } }),
            () => WebSocket.connect("ws://127.0.0.1:" + props.port + "/", { headers: { "Sec-WebSocket-Key": "x" } }),
            () => WebSocket.connect("ws://127.0.0.1:1/"),
          ]) { try { await open(); say("opened"); } catch (e) { say("refused"); } }
        """#)
        let view = try home.view("m", granted: [.network], props: ["port": port])
        #expect(await lines(view, home) == ["string héllo", "true 00ff07", "closed", "refused", "refused", "refused", "refused", "done"])
        #expect(server.connections == 1)
        #expect(server.header("origin") == "http://swiftr.test")
        #expect(home.center.loaded("m")?.openSockets == 0)
    }

    @Test func aPortNobodyListensOnRefuses() async throws {
        let server = try Loopback()
        let port = try await server.start()
        server.stop()
        let home = try home(#"import { connect } from "net";"#, #"""
          try { await connect("127.0.0.1", props.port); say("opened"); } catch (e) { say("refused"); }
          try { await connect("", 80); say("opened"); } catch (e) { say("refused"); }
        """#)
        let view = try home.view("m", granted: [.network], props: ["port": port])
        #expect(await lines(view, home) == ["refused", "refused", "done"])
        #expect(home.center.loaded("m")?.openSockets == 0)
    }

    @Test func theScanSeesSockets() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "modkit-scan-\(UUID().uuidString)")
        for (name, source) in [
            "tcp": #"import { connect } from "node:net"; export const go = () => connect("127.0.0.1", 6379);"#,
            "web": #"import { WebSocket } from "websocket"; export const go = () => WebSocket.connect("wss://events.example.com/feed");"#,
            "plain": #"import { createHash } from "crypto"; import { Buffer } from "buffer"; export const sum = (s) => createHash("sha256").update(s).digest("hex");"#,
        ] {
            let folder = root.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(source.utf8).write(to: folder.appending(path: "main.js"))
        }
        let tcp = ModScan.report(folder: root.appending(path: "tcp"))
        #expect(tcp.needs == [.network])
        #expect(tcp.sites == ["127.0.0.1"])
        let web = ModScan.report(folder: root.appending(path: "web"))
        #expect(web.needs == [.network])
        #expect(web.sites == ["events.example.com"])
        // Sums need nothing from the person.
        #expect(ModScan.report(folder: root.appending(path: "plain")).needs == [])
    }
}
