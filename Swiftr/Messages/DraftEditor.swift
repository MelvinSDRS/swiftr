import AppKit
import UniformTypeIdentifiers

/// ⌃G in the Messages field: the draft opens in the person's text editor,
/// as Claude Code and Codex open theirs from the terminal. Each save comes
/// back to the field; sending the message ends it.
@MainActor final class DraftEditor {
    static let shared = DraftEditor()

    /// The file each pane's draft is written in, while it is followed.
    private var files: [String: URL] = [:]

    /// Writes `text` to a Markdown file and opens it in the app that edits
    /// plain text (TextEdit unless the person chose another): the app set
    /// for Markdown may only show it. `apply` gets the file's text after
    /// each save, for an hour at most.
    func open(_ text: String, for address: String, agent: String, apply: @escaping (String) -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Swiftr Drafts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = address.replacingOccurrences(of: "/", with: "-")
        let url = dir.appending(path: "Message to \(agent) (\(name)).md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        files[address] = url
        let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        if let editor {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        // Editors save by replacing the file: its date says when, not a watch on it.
        Task { [weak self] in
            var seen = Self.date(url)
            for _ in 0 ..< 5_000 {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, self.files[address] == url else { return }
                let now = Self.date(url)
                guard now != seen, let saved = try? String(contentsOf: url, encoding: .utf8) else { continue }
                seen = now
                apply(saved.hasSuffix("\n") ? String(saved.dropLast()) : saved)
            }
        }
    }

    /// The message went: its file isn't followed anymore (the editor may
    /// still show it; the next ⌃G writes over it).
    func stop(_ address: String) {
        files[address] = nil
    }

    private static func date(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
