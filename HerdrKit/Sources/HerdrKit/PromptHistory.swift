import Foundation

/// Claude Code's record of what was sent: `<config>/history.jsonl`, one line
/// a message, with the folder Claude ran in (`project`) and pasted texts
/// kept beside it (`[Pasted text #1 +14 lines]` → `pastedContents["1"]`).
/// Codex, OpenCode and Gemini CLI keep their own (`codexEntries`…).
public enum PromptHistory {
    /// The messages sent from `project`, newest first, each once, with
    /// their pasted texts put back; at most `limit`. `data` holds whole lines.
    public static func entries(_ data: Data, project: String, limit: Int = 300) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for line in data.splitLines().lines.reversed() {
            guard out.count < limit else { break }
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  o["project"] as? String == project,
                  var text = o["display"] as? String
            else { continue }
            if let pasted = o["pastedContents"] as? [String: Any], !pasted.isEmpty { text = expand(text, pasted) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            out.append(text)
        }
        return out
    }

    /// What `machine.exec` runs to read another machine's history: the
    /// lines sent from `project` in the file's last `tailBytes`, the newest 500.
    public static func remoteLine(config: String, project: String, tailBytes: Int) -> String {
        let name = (try? JSONSerialization.data(withJSONObject: project, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\(project)\""
        return "tail -c \(tailBytes) \(AgentLaunch.quoted(config + "/history.jsonl")) 2>/dev/null"
            + " | grep -F \(AgentLaunch.quoted("\"project\":" + name)) | tail -n 500"
    }

    /// One session's lines in `data` (whole lines), oldest first: the words
    /// with their pasted texts put back, and when they were written (ms).
    public static func session(_ data: Data, id: String) -> [(text: String, timestamp: Int64)] {
        data.splitLines().lines.compactMap { line in
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  o["sessionId"] as? String == id, var text = o["display"] as? String
            else { return nil }
            if let pasted = o["pastedContents"] as? [String: Any], !pasted.isEmpty { text = expand(text, pasted) }
            return (text, (o["timestamp"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// What `machine.exec` runs to read another machine's lines of session
    /// `id` in the file's last `tailBytes`, the newest 20. `id` is hex and dashes.
    public static func remoteSessionLine(config: String, id: String, tailBytes: Int) -> String {
        "tail -c \(tailBytes) \(AgentLaunch.quoted(config + "/history.jsonl")) 2>/dev/null"
            + " | grep -F \(AgentLaunch.quoted("\"sessionId\":\"" + id + "\"")) | tail -n 20"
    }

    // MARK: The other agents' records

    /// Codex's `<home>/history.jsonl`, every folder's (`{"session_id",
    /// "ts","text"}` a line): the messages, newest first, each once.
    public static func codexEntries(_ data: Data, limit: Int = 300) -> [String] {
        newestFirst(jsonLines(data).compactMap { line in
            ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["text"] as? String
        }, limit: limit)
    }

    /// OpenCode's `prompt-history.jsonl` under its state folder, every
    /// folder's: the messages (not its shell's commands), newest first, each
    /// once, each `[Pasted ~N lines]` put back as the text it stands for.
    public static func openCodeEntries(_ data: Data, limit: Int = 300) -> [String] {
        newestFirst(jsonLines(data).compactMap { line in
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  var text = o["text"] as? String,
                  (o["mode"] as? String ?? "normal") == "normal"
            else { return nil }
            if let pasted = o["pasted"] as? [[String: Any]], !pasted.isEmpty { text = expandOpenCode(text, pasted) }
            return text
        }, limit: limit)
    }

    /// Gemini CLI's `logs.json` in a project's folder under `<.gemini>/tmp`
    /// (one list of `{"type","message","timestamp"}`): what the person
    /// wrote, newest first, each once.
    public static func geminiEntries(_ data: Data, limit: Int = 300) -> [String] {
        guard let all = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let said = all.compactMap { o -> (time: String, text: String)? in
            guard o["type"] as? String == "user", let text = o["message"] as? String else { return nil }
            return (o["timestamp"] as? String ?? "", text)
        }
        // ISO 8601 times sort as text; the list's order settles ties.
        let oldestFirst = said.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
        return newestFirst(oldestFirst.map(\.element.text), limit: limit)
    }

    /// What `machine.exec` runs to read Codex's record on another machine
    /// (`home` from the home folder, or whole): its newest 500 lines.
    public static func codexRemoteLine(home: String, tailBytes: Int) -> String {
        "tail -c \(tailBytes) \(AgentLaunch.quoted(home + "/history.jsonl")) 2>/dev/null | tail -n 500"
    }

    /// What `machine.exec` runs to read OpenCode's record on another
    /// machine, under the state folder sh finds there: its newest 300 lines.
    public static func openCodeRemoteLine(tailBytes: Int) -> String {
        #"tail -c \#(tailBytes) "${XDG_STATE_HOME:-$HOME/.local/state}/opencode/prompt-history.jsonl" 2>/dev/null | tail -n 300"#
    }

    /// What `machine.exec` runs to read a Gemini project's `logs.json` on
    /// another machine: all of it, at most `maxBytes`.
    public static func geminiRemoteLine(project: String, maxBytes: Int) -> String {
        "head -c \(maxBytes) \(AgentLaunch.quoted(project + "/logs.json")) 2>/dev/null"
    }

    /// `said`, oldest first, as the newest first: trimmed, each once, at most `limit`.
    static func newestFirst(_ said: [String], limit: Int) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for text in said.reversed() {
            guard out.count < limit else { break }
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            out.append(text)
        }
        return out
    }

    /// The lines of `data`, the last one too when no line break ends it.
    static func jsonLines(_ data: Data) -> [Data] {
        let split = data.splitLines()
        return split.rest.isEmpty ? split.lines : split.lines + [split.rest]
    }

    /// Each paste's mark in OpenCode's text (`source`: `start` and `end` in
    /// UTF-16, the mark's `text`) replaced by what was pasted.
    static func expandOpenCode(_ text: String, _ pasted: [[String: Any]]) -> String {
        let marks = pasted.compactMap { p -> (start: Int, end: Int, mark: String?, content: String)? in
            guard let content = p["text"] as? String, let source = p["source"] as? [String: Any],
                  let start = (source["start"] as? NSNumber)?.intValue, let end = (source["end"] as? NSNumber)?.intValue
            else { return nil }
            return (start, end, source["text"] as? String, content)
        }
        var out = text as NSString
        // From the last mark back: the places before it stay right.
        for m in marks.sorted(by: { $0.start > $1.start }) {
            let range = NSRange(location: m.start, length: m.end - m.start)
            if m.start >= 0, m.end >= m.start, NSMaxRange(range) <= out.length, m.mark.map({ out.substring(with: range) == $0 }) ?? true {
                out = out.replacingCharacters(in: range, with: m.content) as NSString
            } else if let mark = m.mark, case let found = out.range(of: mark), found.location != NSNotFound {
                out = out.replacingCharacters(in: found, with: m.content) as NSString
            }
        }
        return out as String
    }

    /// Each `[Pasted text #N …]` replaced by the text it stands for, when kept.
    static func expand(_ text: String, _ pasted: [String: Any]) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"\[Pasted text #(\d+)[^\]]*\]"#) else { return text }
        var out = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let number = Range(match.range(at: 1), in: text),
                  let entry = pasted[String(text[number])] as? [String: Any],
                  entry["type"] as? String ?? "text" == "text",
                  let content = entry["content"] as? String
            else { continue }
            out.replaceSubrange(whole, with: content)
        }
        return out
    }
}
