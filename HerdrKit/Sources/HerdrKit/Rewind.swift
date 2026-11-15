import Foundation

/// `/rewind` (Esc Esc in Claude Code) lists the messages it can go back
/// to, each cut to a line. Matched with the transcript's prompts, they tell
/// Messages mode which one it goes back to.
public enum Rewind {
    /// The prompt that option `index` of the list stands for, among
    /// `prompts` (id and words, oldest first): of the prompts its label fits,
    /// the one as far from the end as the option is from the end of the list
    /// among options with the same words. `labels`: the list, `(current)` last.
    public static func prompt(for index: Int, labels: [String], in prompts: [(id: String, text: String)]) -> String? {
        guard labels.indices.contains(index), labels[index] != "(current)" else { return nil }
        let label = key(labels[index])
        let cut = labels[index].hasSuffix("…") || labels[index].hasSuffix("...")
        // The same words further down: as many prompts to pass from the end.
        let later = labels[(index + 1)...].filter { $0 != "(current)" && key($0) == label }.count
        var seen = 0
        for p in prompts.reversed() where fits(label, cut: cut, p.text) {
            if seen == later { return p.id }
            seen += 1
        }
        return nil
    }

    /// Whether a line of the list names a message of these words.
    public static func names(_ label: String, _ text: String) -> Bool {
        fits(key(label), cut: label.hasSuffix("…") || label.hasSuffix("..."), text)
    }

    /// Two messages the list shows alike.
    public static func alike(_ a: String, _ b: String) -> Bool {
        key(a) == key(b)
    }

    /// Words as the list shows them: pictures' tags out, spaces and lines
    /// made one space, the `…` of a cut line off.
    static func key(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\[Image #\d+\]"#, with: " ", options: .regularExpression)
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if t.hasSuffix("…") { t.removeLast() } else if t.hasSuffix("...") { t.removeLast(3) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The label is the prompt's words, or their start when the list cut them,
    /// or the first of its lines.
    static func fits(_ label: String, cut: Bool, _ text: String) -> Bool {
        let words = key(text)
        if words == label { return true }
        if cut { return !label.isEmpty && words.hasPrefix(label) }
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map { key(String($0)) } ?? ""
        return !first.isEmpty && first == label
    }

    /// Which of OpenCode's timeline rows naming a message is it. Its search
    /// sorts rows by how well they match, not by date: same-worded messages
    /// are told apart by the time beside each (`1:16 PM`, `13:16`).
    /// `sent`: when the message was sent. Nil when the times can't tell.
    public static func openCodePick(times: [String], sent: Date?, calendar: Calendar = .current) -> Int? {
        if times.count == 1 { return 0 }
        guard let sent else { return nil }
        let c = calendar.dateComponents([.hour, .minute], from: sent)
        guard let hour = c.hour, let minute = c.minute else { return nil }
        let shown = times.map(minutes)
        let same = shown.indices.filter { shown[$0] == hour * 60 + minute }
        if same.count == 1 { return same[0] }
        guard same.isEmpty else { return nil }
        // OpenCode on another machine shows its own clock: hours apart.
        let close = shown.indices.filter { shown[$0].map { $0 % 60 == minute } ?? false }
        return close.count == 1 ? close[0] : nil
    }

    /// A time of day as minutes since midnight: `1:16 PM`, `13:16`, `13 h 16`.
    static func minutes(_ text: String) -> Int? {
        guard let m = text.firstMatch(of: /(\d{1,2})\s?[:h.]\s?(\d{2})(?:\s*([AaPp])\.?[Mm])?/),
              var hour = Int(m.1), let minute = Int(m.2), hour < 24, minute < 60
        else { return nil }
        if let half = m.3 {
            hour = hour % 12 + (half.lowercased() == "p" ? 12 : 0)
        }
        return hour * 60 + minute
    }
}
