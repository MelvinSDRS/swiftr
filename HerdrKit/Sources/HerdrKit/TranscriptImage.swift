import CryptoKit
import Foundation
import Synchronization

/// A picture in a conversation, as a file on this machine: one a
/// transcript holds, saved once into `folder` under its hash, or one the
/// agent named by its path.
public struct TranscriptImage: Sendable, Hashable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Where pictures taken out of transcripts go; the app points it at
    /// its caches.
    public static var folder: URL {
        get { store.withLock { $0.folder } }
        set { store.withLock { $0 = Store(folder: newValue) } }
    }

    /// This run's folder in `root`, named after the process: each running
    /// app (a test build too) keeps its pictures apart, and removes them
    /// when it quits. They come back from the transcripts, which still
    /// hold them, the next time a conversation is read.
    public static func runFolder(in root: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> URL {
        root.appending(path: "run-\(pid)", directoryHint: .isDirectory)
    }

    /// Removes what runs that ended left in `root` (a run killed has no time
    /// to clean up), and loose pictures from before runs had folders. The
    /// folders of runs still going stay.
    public static func removeLeftovers(in root: URL, keeping pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                       running: (Int32) -> Bool = TranscriptImage.isRunning) {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let name = entry.lastPathComponent
            if name.hasPrefix("run-"), let other = Int32(name.dropFirst(4)), other == pid || running(other) { continue }
            try? fm.removeItem(at: entry)
        }
    }

    /// Whether a process with this id is running.
    public static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// What `Transcript.slim` leaves of a long picture: this, then the
    /// saved file's name.
    static let mark = "herdr-picture:"

    /// The picture a transcript gives as a string: a data URL
    /// (`data:image/png;base64,…`), bare base64 (`iVBOR…`), a mark `slim`
    /// left, or a file (`file:///…`, `/…`). `mime` says what bare base64 is
    /// when its first bytes don't.
    static func from(_ s: String, mime: String? = nil) -> TranscriptImage? {
        if s.hasPrefix(mark) {
            return TranscriptImage(url: folder.appending(path: String(s.dropFirst(mark.count)), directoryHint: .notDirectory))
        }
        if s.hasPrefix("file://") { return URL(string: s).map(TranscriptImage.init) }
        // Bytes before paths: a JPEG's base64 starts with `/` too.
        if let name = Array(s.utf8).withUnsafeBytes({ saved($0, mime: mime) }) {
            return TranscriptImage(url: folder.appending(path: name, directoryHint: .notDirectory))
        }
        if s.hasPrefix("/") { return TranscriptImage(url: URL(filePath: s)) }
        return nil
    }

    /// The file's name for the picture in `text` (a data URL, or bare
    /// base64 that starts as a PNG, JPEG, GIF or WebP does), saved into
    /// `folder` unless it is there already; nil when `text` holds no
    /// picture.
    static func saved(_ text: UnsafeRawBufferPointer, mime: String? = nil) -> String? {
        guard let (payload, type) = picture(in: text, mime: mime) else { return nil }
        let key = SHA256.hash(data: payload).prefix(16).map { String(format: "%02x", $0) }.joined()
        let name = key + "." + type
        let (folder, known) = store.withLock { ($0.folder, $0.known.contains(name)) }
        if known { return name }
        let file = folder.appending(path: name, directoryHint: .notDirectory)
        if !FileManager.default.fileExists(atPath: file.path) {
            // Bytes a JSON writer escaped (`\/`) are skipped like any other.
            guard let data = Data(base64Encoded: Data(payload), options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        }
        store.withLock { if $0.folder == folder { $0.known.insert(name) } }
        return name
    }

    /// The base64 in `text` and the file type it makes, if it is a picture.
    /// `text` may still be as JSON wrote it, with `\/` for `/`.
    private static func picture(in text: UnsafeRawBufferPointer, mime: String?) -> (UnsafeRawBufferPointer, String)? {
        let head = String(decoding: text.prefix(64).filter { $0 != UInt8(ascii: "\\") }, as: UTF8.self)
        if head.hasPrefix("data:image/") {
            // `data:image/png;base64,` then the bytes; base64 has no comma.
            let kind = head.dropFirst(11).prefix { $0 != "," }
            guard kind.hasSuffix(";base64"), let comma = text.prefix(96).firstIndex(of: UInt8(ascii: ",")) else { return nil }
            return (UnsafeRawBufferPointer(rebasing: text[(comma + 1)...]), fileType(String(kind.dropLast(7))))
        }
        for (start, type) in magic where head.hasPrefix(start) {
            // RIFF holds sounds too: only `RIFF….WEBP`.
            if type == "webp", !head.dropFirst(12).hasPrefix("RUJQ") { continue }
            return (text, type)
        }
        // Other kinds the line names: only if it reads as base64, not as a path.
        if let mime, mime.hasPrefix("image/"), text.count >= 64, head.utf8.allSatisfy(isBase64) {
            return (text, fileType(String(mime.dropFirst(6))))
        }
        return nil
    }

    private static func isBase64(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "="), UInt8(ascii: "\n"), UInt8(ascii: "\r"): true
        default: false
        }
    }

    /// How base64 starts for each kind of picture.
    private static let magic = [("iVBORw0KGgo", "png"), ("/9j/", "jpg"), ("R0lGOD", "gif"), ("UklGR", "webp")]

    private static func fileType(_ subtype: String) -> String {
        switch subtype.lowercased() {
        case "jpeg", "jpg", "pjpeg": "jpg"
        case "svg+xml": "svg"
        case let s where !s.isEmpty && s.allSatisfy({ $0.isLetter || $0.isNumber }): s
        default: "img"
        }
    }

    private struct Store {
        var folder: URL
        /// Files known to be in `folder`.
        var known: Set<String> = []
    }

    private static let store = Mutex(Store(folder: URL.temporaryDirectory.appending(path: "herdr-pictures", directoryHint: .isDirectory)))
}
