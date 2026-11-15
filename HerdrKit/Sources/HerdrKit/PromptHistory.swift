import Foundation

/// Claude Code's record of what was sent: `<config>/history.jsonl`, one line
/// a message, with the folder Claude ran in (`project`) and pasted texts
/// kept beside it (`[Pasted text #1 +14 lines]` → `pastedContents["1"]`).
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
