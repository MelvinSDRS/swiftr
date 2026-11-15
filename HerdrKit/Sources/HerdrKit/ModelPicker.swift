import Foundation

/// Claude Code's model picker (`/model`, ⌥P), as 2.1.322 draws it:
///
///       Select model
///       Switch between Claude models. Your pick becomes the default for new sessions. …
///         1.  Default (recommended)  Opus 5.5 · Best for everyday, complex tasks
///         …
///       ❯ 5.  Haiku 5.5 ✔            Fastest for quick answers
///         ▸   More models
///       ◐ Medium effort (default) ←/→ to adjust
///       Enter to set as default · s to use this session only · Esc to cancel
///
/// Arrows move its cursor; ← and → change the effort of the model under
/// it. Enter on `More models` opens the older ones (`6.` on) in a window
/// that scrolls: `↑` and `↓` beside its edge rows, `… +5 models` under it.
/// Enter on a model makes it the default for new sessions too; `s` takes
/// it for this session only. `✔`: the model this session uses.
extension ScreenPrompt {
    public struct ModelPicker: Sendable, Equatable {
        /// The `More models` row is on screen, open (`▾`) or not, the
        /// cursor on it or not, under model `moreAfter`.
        public var moreShown = false
        public var moreOpen = false
        public var moreFocused = false
        public var moreAfter = 0
        /// The window hides rows above its first, and this many models under its last.
        public var hiddenAbove = false
        public var hiddenBelow = 0
        /// The effort of the model under the cursor: its mark (`◐`), its
        /// name (`Medium`), and whether it is that model's own default.
        public var effortMark: String?
        public var effort: String?
        public var effortIsDefault = false
        /// Other lines under the list, such as the warning the top effort shows.
        public var notes: [String] = []
        /// What the picker says it does, under its title, without its
        /// advice for the command line (`specify with --model`).
        public var about = ""
    }

    /// `text`'s sentences, but those that name a command-line flag (`--model`).
    static func withoutFlagAdvice(_ text: String) -> String {
        text.components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" --") }
            .map { $0.hasSuffix(".") ? $0 : $0 + "." }
            .joined(separator: " ")
    }

    /// The model picker from its `Select model` line down to its hint
    /// (`… · Esc to cancel`); nil when the screen shows none.
    static func modelPicker(_ lines: [String]) -> ScreenPrompt? {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        guard let top = lines.lastIndex(where: { trim($0) == "Select model" }),
              let hint = lines.indices.last(where: { $0 > top && trim(lines[$0]).hasSuffix("Esc to cancel") })
        else { return nil }
        var picker = ModelPicker()
        var options: [Option] = []
        var about: [String] = []
        // The list's first row: model 1 when nothing hides above it.
        var firstRow: Int?
        var listed = false
        for line in lines[(top + 1) ..< hint] {
            let t = trim(line)
            guard !t.isEmpty else { continue }
            if let o = option(line) {
                if !listed { firstRow = o.number }
                listed = true
                var (name, aside) = columns(o.label)
                var inUse: Bool?
                if name.hasSuffix(" ✔") {
                    name = String(name.dropLast(2))
                    inUse = true
                }
                options.append(Option(number: o.number, label: name, detail: aside, focused: o.focused, checked: inUse))
                continue
            }
            // `❯ ▸   More models`, `↑ ▾   More models`
            var s = Substring(t)
            var focused = false
            while let f = s.first, "❯›>↑↓".contains(f) {
                if f != "↑", f != "↓" { focused = true }
                s = s.dropFirst().drop { $0 == " " }
            }
            if let f = s.first, f == "▸" || f == "▾", trim(String(s.dropFirst())) == "More models" {
                if !listed { firstRow = 0 }
                listed = true
                picker.moreShown = true
                picker.moreOpen = f == "▾"
                picker.moreFocused = focused
                picker.moreAfter = options.last?.number ?? 0
                continue
            }
            if let m = t.wholeMatch(of: /… \+(\d+) models?/) {
                picker.hiddenBelow = Int(m.1) ?? 0
                continue
            }
            if let m = t.wholeMatch(of: /(\S)\s+(\S+) effort( \(default\))?(?:\s+←\/→ to adjust)?/) {
                picker.effortMark = String(m.1)
                picker.effort = String(m.2)
                picker.effortIsDefault = m.3 != nil
                continue
            }
            if listed { picker.notes.append(t) } else { about.append(t) }
        }
        guard listed else { return nil }
        // `More models` first in the window: the models before it scrolled away.
        if picker.moreShown, picker.moreAfter == 0, let next = options.first { picker.moreAfter = next.number - 1 }
        picker.hiddenAbove = firstRow != 1
        picker.about = withoutFlagAdvice(about.joined(separator: " "))
        var prompt = ScreenPrompt(question: ["Select model"] + about, options: options, footer: trim(lines[hint]))
        prompt.modelPicker = picker
        return prompt
    }

    /// Where model `number`'s row sits in the picker's whole list, from 0:
    /// the first models, `More models`, then the others. Off screen, that
    /// row is above every model shown (the window shows it with the first ones).
    func pickerPosition(_ number: Int) -> Int? {
        guard let p = modelPicker else { return nil }
        let moreAbove = p.moreShown ? number > p.moreAfter : p.hiddenAbove
        return moreAbove ? number : number - 1
    }

    /// Where the picker's cursor is, from 0; nil when no row shows it.
    var pickerCursor: Int? {
        guard let p = modelPicker else { return nil }
        if p.moreFocused { return p.moreAfter }
        return options.first(where: \.focused).flatMap { pickerPosition($0.number) }
    }

    /// Arrow presses that bring the picker's cursor to model `number`, or
    /// to `More models` (nil); nil when the screen can't tell.
    public func pickerMoves(to number: Int?) -> [String]? {
        guard let p = modelPicker, let at = pickerCursor else { return nil }
        let to: Int
        if let number {
            guard let n = pickerPosition(number) else { return nil }
            to = n
        } else {
            guard p.moreShown else { return nil }
            to = p.moreAfter
        }
        let move = to - at
        return Array(repeating: move > 0 ? "down" : "up", count: abs(move))
    }

    /// The arrow that brings the picker's cursor a row nearer model
    /// `number`, or `More models` (nil); nil once there, or when it can't tell.
    public func pickerStep(toward number: Int?) -> String? {
        guard let p = modelPicker else { return nil }
        let focused = options.first(where: \.focused)?.number
        if let number {
            if p.moreFocused { return number > p.moreAfter ? "down" : "up" }
            guard let f = focused, f != number else { return nil }
            return number > f ? "down" : "up"
        }
        guard !p.moreFocused, let f = focused else { return nil }
        if p.moreShown { return f > p.moreAfter ? "up" : "down" }
        return p.hiddenAbove ? "up" : nil
    }
}
