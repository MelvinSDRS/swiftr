import Foundation
import Testing
@testable import HerdrKit

@Suite struct FileMentionTests {
    @Test func typedWord() {
        #expect(FileMention.typed("@") == "")
        #expect(FileMention.typed("look at @Sources/Ap") == "Sources/Ap")
        #expect(FileMention.typed("line one\n@read") == "read")
        #expect(FileMention.typed("(@notes") == "notes")
        // Not a mention: an address, or a word already finished.
        #expect(FileMention.typed("write to me@mail.com") == nil)
        #expect(FileMention.typed("@notes.txt and") == nil)
        #expect(FileMention.typed("no mention") == nil)
    }

    @Test func completion() {
        #expect(FileMention.complete("see @Ap", with: "Sources/App.swift") == "see @Sources/App.swift ")
        #expect(FileMention.complete("@So", with: "Sources/") == "@Sources/")
        #expect(FileMention.complete("@my", with: "my notes.txt") == "@\"my notes.txt\" ")
    }

    @Test func index() {
        let index = FileMention.Index(files: ["README.md", "Sources/App/App.swift", "Sources/App/AppModel.swift", "Tests/AppTests.swift", "Sources/Kit/Mapper.swift"])
        // Folders join the files.
        #expect(index.paths.contains("Sources/"))
        #expect(index.paths.contains("Sources/App/"))
        #expect(!index.paths.contains("README.md/"))
        // The top, folders first.
        #expect(index.matching("") == ["Tests/", "Sources/", "README.md"])
        // A name that is the word, then names that start with it, then hold it.
        #expect(Array(index.matching("app").prefix(4)) == ["Sources/App/", "Sources/App/App.swift", "Tests/AppTests.swift", "Sources/App/AppModel.swift"])
        // A path.
        #expect(index.matching("sources/k").first == "Sources/Kit/")
        // Letters in order.
        #expect(index.matching("apmod").first == "Sources/App/AppModel.swift")
        #expect(index.matching("zzz").isEmpty)
    }

    /// Paths with accents are searched as text, the others as bytes: both
    /// give the same order, and only the best are kept.
    @Test func indexWithAccents() {
        let index = FileMention.Index(files: [
            "README.md", "Docs/Été.md", "Docs/etape.md", "Sources/Données/Modèle.swift",
            "Sources/App/App.swift", "Sources/App/AppModel.swift", "Tests/AppTests.swift",
        ])
        #expect(index.matching("été") == ["Docs/Été.md"])
        #expect(index.matching("ete") == ["Docs/etape.md", "Tests/AppTests.swift"])
        #expect(index.matching("donn") == ["Sources/Données/", "Sources/Données/Modèle.swift"])
        #expect(index.matching("mod") == ["Sources/Données/Modèle.swift", "Sources/App/AppModel.swift"])
        #expect(index.matching("é") == ["Docs/Été.md", "Sources/Données/", "Sources/Données/Modèle.swift"])
        #expect(index.matching("md") == ["Docs/Été.md", "Docs/etape.md", "README.md", "Sources/App/AppModel.swift", "Sources/Données/Modèle.swift"])
        #expect(index.matching("app", limit: 2) == ["Sources/App/", "Sources/App/App.swift"])
        #expect(index.matching("app", limit: 0).isEmpty)
    }

    @Test func listingRuns() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "a/node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: ".hidden"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a/one.txt", "two's.txt", "a/node_modules/x.js", ".hidden/y.txt"] {
            try Data("x".utf8).write(to: folder.appending(path: name))
        }
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", FileMention.listing(folder: folder.path)]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let files = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
        #expect(files == ["a/one.txt", "two's.txt"])
    }
}
