import Foundation

/// A mod or a layout someone shared, brought in from its link: a page of
/// herdr.dev's gallery (`herdr.dev/mods/<owner>/<name>`) or a folder on
/// GitHub. The files are copied into Swiftr's home and nothing else: no
/// mod runs here, none is allowed, and nothing the person has is replaced.
public nonisolated enum ModFetch {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Where a link points.
    public enum Link: Equatable, Sendable {
        /// A page of herdr.dev's gallery; it names the folder on GitHub.
        case gallery(kind: String, owner: String, name: String)
        case github(Repo)
    }

    /// A folder of a GitHub repository.
    public struct Repo: Equatable, Sendable {
        public var owner: String
        public var name: String
        /// The branch or tag; nil for the default branch.
        public var ref: String?
        /// The folder inside, "" for the whole repository.
        public var path: String

        var archive: URL { URL(string: "https://github.com/\(owner)/\(name)/archive/\(ref ?? "HEAD").tar.gz")! }
        /// The folder's address, as a browser takes it.
        var shown: String { "github.com/\(owner)/\(name)" + (ref.map { "/tree/\($0)" + (path.isEmpty ? "" : "/\(path)") } ?? "") }
    }

    /// What was copied, and what was left.
    public struct Added: Sendable {
        public var link: String
        public var mods: [String] = []
        public var layouts: [String] = []
        /// Why something there was not copied, one line each.
        public var skipped: [String] = []
        public var reports: [String: ModScan.Report] = [:]

        /// For a person, or an agent's terminal.
        public var summary: String {
            var lines: [String] = []
            for name in mods {
                guard let report = reports[name] else { continue }
                lines.append("Added mod \(name) (\(report.files) \(report.files == 1 ? "file" : "files"), \(report.lines) lines)")
                lines.append(report.needs.isEmpty ? "  Only draws its panel." : "  Asks: " + report.needs.sentences.joined(separator: "; "))
                if !report.programs.isEmpty { lines.append("  Programs: " + report.programs.joined(separator: ", ")) }
                if !report.sites.isEmpty { lines.append("  Sites: " + report.sites.joined(separator: ", ")) }
            }
            for name in layouts { lines.append("Added layout \(name)") }
            for line in skipped { lines.append("Left out: \(line)") }
            if mods.isEmpty, layouts.isEmpty { lines.append("Nothing added.") }
            if !mods.isEmpty { lines.append("A mod stays off until you allow it in Swiftr: Settings › Mods.") }
            if !layouts.isEmpty { lines.append("Pick the layout in Swiftr: Settings › Mods.") }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: The link

    private static let word = "[A-Za-z0-9._-]+"

    private static func groups(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    /// The link in what the person pasted: the address alone, or herdr.dev's
    /// whole line ("Read …, then add this mod: herdr.dev/mods/…"). Only
    /// herdr.dev and github.com.
    public static func link(in text: String) -> Link? {
        let start = "(?<![A-Za-z0-9.-])(?:https?://)?(?:www\\.)?"
        if let found = groups(start + "herdr\\.dev/(mods|layouts)/(\(word))/(\(word))", in: text),
           let kind = found[1], let owner = found[2], let name = found[3] {
            return .gallery(kind: kind, owner: owner, name: name)
        }
        if let found = groups(start + "github\\.com/(\(word))/(\(word))(?:/tree/(\(word))((?:/\(word))*))?", in: text),
           let owner = found[1], var name = found[2] {
            if name.hasSuffix(".git") { name.removeLast(4) }
            let path = (found[4] ?? "").split(separator: "/").map(String.init)
            guard !name.isEmpty, !path.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
            return .github(Repo(owner: owner, name: name, ref: found[3], path: path.joined(separator: "/")))
        }
        return nil
    }

    /// The GitHub folder a gallery page names: a folder of one of the
    /// owner's repositories, or a whole repository of theirs. The page's
    /// other links (herdr's own, the owner's profile) are not it.
    static func repo(inPage html: String, owner: String) -> Repo? {
        let theirs = "https://github\\.com/(?i:\(NSRegularExpression.escapedPattern(for: owner)))/\(word)"
        for pattern in [theirs + "/tree/\(word)(?:/\(word))*", theirs] {
            if let found = groups(pattern, in: html), let address = found[0], case .github(let repo)? = link(in: address) { return repo }
        }
        return nil
    }

    // MARK: Fetching

    private static let hosts: Set<String> = ["herdr.dev", "github.com", "codeload.github.com"]
    /// More than any mod or layout weighs; a repository this big is not one.
    static let archiveLimit = 30 << 20
    static let unpackedLimit = 300 << 20
    static let unpackedFiles = 20_000

    private static func download(_ url: URL, limit: Int) async throws -> URL {
        let request = URLRequest(url: url, timeoutInterval: 30)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let unreachable = { (error: Error) in Failure("Couldn't reach \(url.host() ?? "the site"): \(error.localizedDescription)") }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(for: request) } catch { throw unreachable(error) }
        guard let http = response as? HTTPURLResponse, let host = http.url?.host(), hosts.contains(host) else {
            throw Failure("\(url.host() ?? "The site") sent the request somewhere else.")
        }
        guard http.statusCode == 200 else {
            throw Failure(http.statusCode == 404 ? "Nothing at \(url.absoluteString)." : "\(host) answered \(http.statusCode).")
        }
        // Read as it comes, and dropped the moment it passes the limit.
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw Failure("More than \(limit >> 20) MB: too much for a mod or a layout.") }
            }
        } catch let failure as Failure { throw failure } catch { throw unreachable(error) }
        let file = FileManager.default.temporaryDirectory.appending(path: "swiftr-fetch-\(UUID().uuidString)")
        try data.write(to: file)
        return file
    }

    /// Runs the system's tar, cut after `seconds`: an archive made to
    /// unpack without end is dropped.
    private static func tar(_ arguments: [String], seconds: Double = 30) -> (ok: Bool, output: String) {
        let tar = Process(), pipe = Pipe()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = arguments
        tar.standardOutput = pipe
        tar.standardError = FileHandle.nullDevice
        guard (try? tar.run()) != nil else { return (false, "") }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { if tar.isRunning { tar.terminate() } }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        return (tar.terminationStatus == 0, String(decoding: output, as: UTF8.self))
    }

    /// Copies what the link holds into `home` (`~/.config/swiftr`).
    public static func add(link text: String, to home: URL, reserved: Set<String> = reservedNames) async throws -> Added {
        guard let link = link(in: text) else {
            throw Failure("That is not a link Swiftr can add from: a herdr.dev/mods or herdr.dev/layouts page, or a folder on github.com.")
        }
        let repo: Repo
        switch link {
        case .github(let given): repo = given
        case .gallery(let kind, let owner, let name):
            let page = try await download(URL(string: "https://herdr.dev/\(kind)/\(owner)/\(name)/")!, limit: 4 << 20)
            defer { try? FileManager.default.removeItem(at: page) }
            guard let html = try? String(contentsOf: page, encoding: .utf8), let found = Self.repo(inPage: html, owner: owner) else {
                throw Failure("herdr.dev/\(kind)/\(owner)/\(name) names no folder on GitHub.")
            }
            repo = found
        }
        let archive = try await download(repo.archive, limit: archiveLimit)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftr-add-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: scratch)
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // What it would unpack to, before anything is unpacked: the fifth
        // word of each line of the listing is a file's size.
        let listing = tar(["-tvzf", archive.path])
        let sizes = listing.output.split(separator: "\n").map { line in Int(line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(4).first ?? "") ?? 0 }
        guard listing.ok else { throw Failure("Couldn't open what \(repo.shown) sent.") }
        guard sizes.count <= unpackedFiles, sizes.reduce(0, +) <= unpackedLimit else {
            throw Failure("\(repo.shown) unpacks to more than \(unpackedLimit >> 20) MB: too much for a mod or a layout.")
        }
        // bsdtar leaves out entries that would land outside the folder.
        let unpacked = tar(["-xzf", archive.path, "-C", scratch.path])
        let tops = ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).filter { !$0.hasPrefix(".") }
        guard unpacked.ok, tops.count == 1 else { throw Failure("Couldn't open what \(repo.shown) sent.") }
        var base = scratch.appending(path: tops[0])
        if !repo.path.isEmpty { base = base.appending(path: repo.path) }
        guard isFolder(base) else { throw Failure("No folder \(repo.path) in github.com/\(repo.owner)/\(repo.name).") }
        return try install(from: base, named: repo.path.isEmpty ? repo.name : (repo.path as NSString).lastPathComponent, link: repo.shown, to: home, reserved: reserved)
    }

    // MARK: Copying in

    /// Names Swiftr keeps: herdr-app's own parts, which Swiftr draws itself,
    /// and its built-in panel.
    public static let reservedNames: Set<String> = WindowLayout.shipped.union(["changes"])

    private static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func isFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private static func isName(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.range(of: "^\(word)$", options: .regularExpression) != nil
    }

    /// What a shared folder holds, copied into `home`: a mod (the folder
    /// has `main.js`), or `mods/<name>/` folders and `layouts/<name>.json`
    /// files, as herdr.dev's are laid out. Never over something there.
    static func install(from base: URL, named fallback: String, link: String, to home: URL, reserved: Set<String> = reservedNames) throws -> Added {
        var added = Added(link: link)
        var mods: [(name: String, folder: URL)] = []
        var layouts: [URL] = []
        if isFile(base.appending(path: "main.js")) {
            mods.append((fallback, base))
        } else {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: base.appending(path: "mods").path)) ?? []).sorted() {
                let folder = base.appending(path: "mods/\(name)")
                if isFolder(folder), isFile(folder.appending(path: "main.js")) { mods.append((name, folder)) }
            }
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: base.appending(path: "layouts").path)) ?? []).sorted() where name.hasSuffix(".json") {
                let file = base.appending(path: "layouts/\(name)")
                if isFile(file) { layouts.append(file) }
            }
        }
        guard !mods.isEmpty || !layouts.isEmpty else {
            throw Failure("No mod or layout at \(link): a mod is a folder that holds main.js, a layout a file in layouts/.")
        }
        for (name, folder) in mods {
            guard isName(name) else { added.skipped.append("\(name): not a name a mod can have"); continue }
            // A layout brings its own copies of these; Swiftr draws them itself.
            guard !reserved.contains(name) else { added.skipped.append("\(name): Swiftr has its own"); continue }
            let target = home.appending(path: "mods/\(name)")
            guard !FileManager.default.fileExists(atPath: target.path) else {
                added.skipped.append("\(name): you have a mod of that name. Remove it first to take this one.")
                continue
            }
            do {
                try copy(folder, to: target)
                // Where it came from, and a mark that it is not the person's
                // own work: Swiftr asks before it runs, whatever was allowed
                // under this name before.
                let mark: [String: Any] = ["link": link, "id": UUID().uuidString]
                try JSONSerialization.data(withJSONObject: mark, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: target.appending(path: sourceFile), options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: target)
                added.skipped.append("\(name): \(error)")
                continue
            }
            added.mods.append(name)
            added.reports[name] = ModScan.report(folder: target)
        }
        for file in layouts {
            let name = file.deletingPathExtension().lastPathComponent
            guard isName(name) else { added.skipped.append("\(name): not a name a layout can have"); continue }
            let target = home.appending(path: "layouts/\(name).json")
            guard !FileManager.default.fileExists(atPath: target.path) else {
                added.skipped.append("layout \(name): you have a layout of that name")
                continue
            }
            guard let data = try? Data(contentsOf: file), data.count <= 1 << 20, (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                added.skipped.append("layout \(name): not a layout file")
                continue
            }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try data.write(to: target, options: .atomic) } catch { added.skipped.append("layout \(name): \(error.localizedDescription)"); continue }
            added.layouts.append(name)
        }
        if isFile(base.appending(path: "keys.json")) {
            added.skipped.append("keys.json: your keys are yours to change. Copy the ones you want from \(link).")
        }
        return added
    }

    /// A mod's folder, its plain files only: links are left out, they could
    /// point anywhere on this Mac.
    private static func copy(_ folder: URL, to target: URL) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let root = folder.standardizedFileURL.path
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys) else { return }
        var files = 0, bytes = 0
        while let url = walker.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            let inside = String(path.dropFirst(root.count + 1))
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if [".git", "node_modules"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                try FileManager.default.createDirectory(at: target.appending(path: inside), withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                files += 1
                bytes += values.fileSize ?? 0
                guard files <= 2000, bytes <= 40 << 20 else { throw Failure("too many files for a mod") }
                try FileManager.default.copyItem(at: url, to: target.appending(path: inside))
            }
        }
    }

    // MARK: Where a mod came from

    static let sourceFile = ".source.json"

    private static func source(of folder: URL) -> [String: Any]? {
        (try? Data(contentsOf: folder.appending(path: sourceFile))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The mark of a mod that came from a link: nil for one the person made
    /// or copied in themselves. A new copy has a new mark.
    public static func token(of folder: URL) -> String? { source(of: folder)?["id"] as? String }

    /// The link a mod came from.
    public static func origin(of folder: URL) -> String? { source(of: folder)?["link"] as? String }
}
