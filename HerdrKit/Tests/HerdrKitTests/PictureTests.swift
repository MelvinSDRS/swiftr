import Foundation
import Testing
@testable import HerdrKit

/// Pictures in transcripts: saved once as files, named on their items.
@Suite(.serialized) struct PictureTests {
    static let folder = URL.temporaryDirectory.appending(path: "herdr-picture-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() {
        TranscriptImage.folder = Self.folder
    }

    /// A file's first bytes, then `count` more: only how base64 starts says
    /// what a picture is.
    static func picture(_ signature: [UInt8], _ count: Int, seed: UInt8 = 1) -> Data {
        var bytes = signature
        var x = seed
        for _ in 0 ..< count {
            x = x &* 31 &+ 7
            bytes.append(x)
        }
        return Data(bytes)
    }

    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]

    /// A Claude Code line, compact and with `/` unescaped, as Claude Code writes it.
    static func claude(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    static func prompt(_ id: String, _ blocks: [[String: Any]]) -> Data {
        claude(["type": "user", "uuid": id, "message": ["role": "user", "content": blocks]])
    }

    static func image(_ data: Data, mime: String) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": mime, "data": data.base64EncodedString()]]
    }

    @Test func aBigPictureGoesToAFileBeforeParsing() throws {
        let bytes = Self.picture(Self.png, 60_000)
        let line = Self.prompt("u1", [["type": "text", "text": "[Image #1] look"], Self.image(bytes, mime: "image/png")])
        // The line keeps a mark in place of 80 KB of base64.
        #expect(Transcript.slim(line).count < 600)
        var t = Transcript()
        t.append([line])
        let item = try #require(t.items.first)
        #expect(item.kind == .prompt("[Image #1] look", images: 1))
        let picture = try #require(item.pictures.first)
        #expect(picture.url.pathExtension == "png")
        #expect(picture.url.deletingLastPathComponent().lastPathComponent == Self.folder.lastPathComponent)
        #expect(try Data(contentsOf: picture.url) == bytes)
    }

    @Test func aSmallPictureToo_andTheSamePictureIsOneFile() throws {
        let bytes = Self.picture(Self.jpeg, 300)
        var t = Transcript()
        t.append([
            Self.prompt("u1", [Self.image(bytes, mime: "image/jpeg")]),
            Self.prompt("u2", [["type": "text", "text": "again"], Self.image(bytes, mime: "image/jpeg")]),
        ])
        #expect(t.items.count == 2)
        let first = try #require(t.items[0].pictures.first)
        #expect(first.url.pathExtension == "jpg")
        #expect(try Data(contentsOf: first.url) == bytes)
        #expect(t.items[1].pictures == [first])
    }

    @Test func aToolsPicture() throws {
        let bytes = Self.picture(Self.png, 50_000, seed: 9)
        var t = Transcript()
        t.append([
            Self.claude(["type": "assistant", "uuid": "a1", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_1", "name": "Read", "input": ["file_path": "/tmp/shot.png"]],
            ]]]),
            Self.prompt("u1", [["type": "tool_result", "tool_use_id": "toolu_1", "content": [Self.image(bytes, mime: "image/png")]]]),
        ])
        guard case .tool(let call) = t.items.first?.kind else {
            Issue.record("no tool")
            return
        }
        #expect(call.result?.images == 1)
        let picture = try #require(call.result?.pictures.first)
        #expect(try Data(contentsOf: picture.url) == bytes)
    }

    @Test func notAPicture() {
        // Long base64 that starts as no picture does is cut, as any long string.
        let line = Self.prompt("u1", [["type": "text", "text": String(repeating: "QUJD", count: 20_000)]])
        let slim = String(decoding: Transcript.slim(line), as: UTF8.self)
        #expect(slim.contains("…"))
        #expect(!slim.contains(TranscriptImage.mark))
        // A source without data has none.
        var t = Transcript()
        t.append([Self.prompt("u2", [["type": "image", "source": [:]], ["type": "text", "text": "what is this?"]])])
        #expect(t.items.first?.kind == .prompt("what is this?", images: 1))
        #expect(t.items.first?.pictures == [])
    }

    @Test func codexPicturesAndViewedFiles() throws {
        let bytes = Self.picture(Self.png, 40_000, seed: 3)
        func line(_ ordinal: Int, _ item: [String: Any]) -> Data {
            let payload = try! JSONSerialization.data(withJSONObject: ["type": "item_completed", "item": item], options: [.withoutEscapingSlashes])
            return Data("{\"timestamp\":\"2026-11-12T14:51:39.243Z\",\"ordinal\":\(ordinal),\"type\":\"event_msg\",\"payload\":".utf8) + payload + Data("}".utf8)
        }
        let t = Transcript.parse([
            line(1, ["type": "UserMessage", "id": "m1", "content": [
                ["type": "text", "text": "what is wrong here?"],
                ["type": "image", "image_url": "data:image/png;base64," + bytes.base64EncodedString()],
            ]]),
            line(2, ["type": "ImageView", "id": "v1", "path": "file:///Users/me/shot%201.png"]),
        ], format: .codex)
        #expect(t.items.count == 2)
        #expect(t.items[0].kind == .prompt("what is wrong here?", images: 1))
        let picture = try #require(t.items[0].pictures.first)
        #expect(try Data(contentsOf: picture.url) == bytes)
        guard case .tool(let call) = t.items[1].kind else {
            Issue.record("no tool")
            return
        }
        #expect(call.result?.pictures == [TranscriptImage(url: URL(filePath: "/Users/me/shot 1.png"))])
    }

    @Test func escapedSlashesStillReadAsAPicture() throws {
        // JSONSerialization writes `\/`: a JPEG's base64 starts `\/9j\/`.
        let bytes = Self.picture(Self.jpeg, 40_000, seed: 5)
        let line = try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": "u1", "message": ["role": "user", "content": [Self.image(bytes, mime: "image/jpeg")]]])
        #expect(String(decoding: line, as: UTF8.self).contains("\\/9j\\/"))
        var t = Transcript()
        t.append([line])
        let picture = try #require(t.items.first?.pictures.first)
        #expect(try Data(contentsOf: picture.url) == bytes)
    }

    @Test func eachRunKeepsItsOwnAndLeftoversGo() throws {
        let fm = FileManager.default
        let root = URL.temporaryDirectory.appending(path: "herdr-picture-runs-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: root) }
        #expect(TranscriptImage.runFolder(in: root, pid: 42) == root.appending(path: "run-42", directoryHint: .isDirectory))
        // This run (42), another still going (7), one that ended (9), loose pictures from before runs had folders.
        for name in ["run-42", "run-7", "run-9", "run-x"] {
            try fm.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        try Data([1]).write(to: root.appending(path: "run-9/a.png"))
        try Data([2]).write(to: root.appending(path: "0123abcd.png"))
        TranscriptImage.removeLeftovers(in: root, keeping: 42) { $0 == 7 }
        #expect(Set(try fm.contentsOfDirectory(atPath: root.path)) == ["run-42", "run-7"])
        // No folder yet: nothing to do.
        TranscriptImage.removeLeftovers(in: root.appending(path: "none"), keeping: 42) { _ in false }
        #expect(TranscriptImage.isRunning(ProcessInfo.processInfo.processIdentifier))
    }
}
