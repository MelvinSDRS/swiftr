import Foundation

/// A mod's file, turned from an ES module into a function JavaScriptCore can
/// call: JavaScriptCore's public API runs scripts, not modules.
///
/// Only the module's own statements change (`import`, `export`, and
/// `import(…)`); every other byte stays where it was, line for line, so an
/// error still names the right line.
///
///     import { div } from "gpui-kit";      const {div} = __req("gpui-kit");
///     export default class A extends View  class A extends View
///     export const N = 1;                  const N = 1;
///                                          …; __exp.default = A; __exp.N = N;
public nonisolated enum ModSource {
    /// The names the function takes: `__req(name)` gives a module's exports,
    /// `__exp` is this module's, `__import(name)` is `import(name)`, `__meta`
    /// is `import.meta`.
    public static let parameters = ["__req", "__exp", "__import", "__meta"]

    /// The module as the text of a function expression.
    public static func function(from source: String) -> String {
        var scanner = Scanner(Array(source.utf8))
        scanner.run()
        return scanner.output()
    }

    /// The modules a file imports, in order, each once.
    public static func imports(of source: String) -> [String] {
        var scanner = Scanner(Array(source.utf8))
        scanner.run()
        return scanner.requested
    }

    private struct Edit {
        var range: Range<Int>
        var text: String
    }

    private enum Token: Equatable {
        case none
        case punct(UInt8)
        /// A word a regular expression may follow (`return /x/`).
        case keyword
        /// A name, a number, a string: a `/` after it divides.
        case value
    }

    private struct Scanner {
        let s: [UInt8]
        var i = 0
        var depth = 0
        var prev = Token.none
        var newlineSincePrev = true
        /// Brace depths at which a template's `${` opened.
        var templates: [Int] = []
        var edits: [Edit] = []
        /// `__exp.x = y;` for function declarations, which exist from the
        /// module's first line.
        var early: [String] = []
        var late: [String] = []
        var requested: [String] = []
        var counter = 0

        init(_ bytes: [UInt8]) { s = bytes }

        // MARK: Reading

        func at(_ k: Int) -> UInt8 { k < s.count ? s[k] : 0 }

        static func isIdentStart(_ c: UInt8) -> Bool {
            (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 || c == 36 || c >= 0x80
        }

        static func isIdent(_ c: UInt8) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }

        static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

        func text(_ r: Range<Int>) -> String { String(decoding: s[r], as: UTF8.self) }

        /// The end of the string that starts at `k`.
        func stringEnd(_ k: Int) -> Int {
            let quote = s[k]
            var j = k + 1
            while j < s.count {
                if s[j] == 92 { j += 2; continue }
                if s[j] == quote || s[j] == 10 { return j + 1 }
                j += 1
            }
            return s.count
        }

        /// Past spaces and comments from `k`.
        func skipTrivia(_ k: Int) -> Int {
            var j = k
            while j < s.count {
                let c = s[j]
                if Scanner.isSpace(c) { j += 1 }
                else if c == 47, at(j + 1) == 47 { while j < s.count, s[j] != 10 { j += 1 } }
                else if c == 47, at(j + 1) == 42 {
                    j += 2
                    while j < s.count, !(s[j] == 42 && at(j + 1) == 47) { j += 1 }
                    j = min(s.count, j + 2)
                } else { break }
            }
            return j
        }

        func word(at k: Int) -> Range<Int>? {
            guard k < s.count, Scanner.isIdentStart(s[k]) else { return nil }
            var j = k + 1
            while j < s.count, Scanner.isIdent(s[j]) { j += 1 }
            return k..<j
        }

        func isWord(_ w: String, at k: Int) -> Bool {
            guard let r = word(at: k) else { return false }
            return r.count == w.utf8.count && text(r) == w
        }

        /// Past a regular expression that starts at `k`.
        func regexEnd(_ k: Int) -> Int {
            var j = k + 1
            var inClass = false
            while j < s.count {
                let c = s[j]
                if c == 92 { j += 2; continue }
                if c == 10 { return j }
                if c == 91 { inClass = true } else if c == 93 { inClass = false } else if c == 47, !inClass { j += 1; break }
                j += 1
            }
            while j < s.count, Scanner.isIdent(s[j]) { j += 1 }
            return j
        }

        /// Past a template's text from `k`, to after its closing backtick or
        /// after a `${`.
        mutating func templateText(from k: Int) -> Int {
            var j = k
            while j < s.count {
                let c = s[j]
                if c == 92 { j += 2; continue }
                if c == 96 { return j + 1 }
                if c == 36, at(j + 1) == 123 {
                    templates.append(depth)
                    depth += 1
                    return j + 2
                }
                j += 1
            }
            return s.count
        }

        static let regexWords: Set<String> = ["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await"]

        // MARK: The pass

        mutating func run() {
            // #!/usr/bin/env node
            if at(0) == 35, at(1) == 33 {
                var end = 0
                while end < s.count, s[end] != 10 { end += 1 }
                edits.append(Edit(range: 0..<end, text: ""))
                i = end
            }
            while i < s.count {
                let c = s[i]
                if c == 10 { newlineSincePrev = true; i += 1; continue }
                if Scanner.isSpace(c) { i += 1; continue }
                if c == 47, at(i + 1) == 47 || at(i + 1) == 42 {
                    let end = skipTrivia(i)
                    if s[i..<end].contains(10) { newlineSincePrev = true }
                    i = end
                    continue
                }
                if c == 34 || c == 39 { i = stringEnd(i); note(.value); continue }
                if c == 96 {
                    let open = templates.count
                    i = templateText(from: i + 1)
                    note(templates.count > open ? .punct(123) : .value)
                    continue
                }
                if c == 47 {
                    let divides: Bool
                    switch prev {
                    case .value: divides = true
                    case .punct(let p): divides = p == 41 || p == 93
                    default: divides = false
                    }
                    if divides { i += 1; note(.punct(47)) } else { i = regexEnd(i); note(.value) }
                    continue
                }
                if c == 123 || c == 40 || c == 91 { depth += 1; i += 1; note(.punct(c)); continue }
                if c == 125 || c == 41 || c == 93 {
                    depth -= 1
                    i += 1
                    if c == 125, let open = templates.last, open == depth {
                        templates.removeLast()
                        let open = templates.count
                        i = templateText(from: i)
                        note(templates.count > open ? .punct(123) : .value)
                    } else {
                        note(.punct(c))
                    }
                    continue
                }
                if let r = word(at: i) {
                    let w = text(r)
                    let afterDot = prev == .punct(46)
                    let starts = depth == 0 && !afterDot && (prev == .none || prev == .punct(59) || prev == .punct(125) || newlineSincePrev)
                    if w == "import", !afterDot {
                        let next = skipTrivia(r.upperBound)
                        if at(next) == 40 {
                            edits.append(Edit(range: r, text: "__import"))
                        } else if at(next) == 46, isWord("meta", at: skipTrivia(next + 1)) {
                            // import.meta: `url` and `dirname`, for a mod that finds its own files.
                            edits.append(Edit(range: r.lowerBound..<word(at: skipTrivia(next + 1))!.upperBound, text: "__meta"))
                        } else if starts, at(next) != 46, let end = importStatement(from: r.lowerBound, clause: next) {
                            i = end
                            note(.punct(59))
                            continue
                        }
                    } else if w == "export", starts, let end = exportStatement(from: r.lowerBound, after: r.upperBound) {
                        i = end
                        continue
                    }
                    i = r.upperBound
                    note(Scanner.regexWords.contains(w) ? .keyword : .value)
                    continue
                }
                if c >= 48 && c <= 57 {
                    var j = i + 1
                    while j < s.count, Scanner.isIdent(s[j]) || s[j] == 46 { j += 1 }
                    i = j
                    note(.value)
                    continue
                }
                i += 1
                note(.punct(c))
            }
        }

        mutating func note(_ token: Token) {
            prev = token
            newlineSincePrev = false
        }

        /// The replacement, with as many line breaks as what it replaces.
        func padded(_ replacement: String, over range: Range<Int>) -> String {
            let lines = s[range].reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            return replacement.replacingOccurrences(of: "\n", with: " ") + String(repeating: "\n", count: lines)
        }

        mutating func request(_ name: String) {
            if !requested.contains(name) { requested.append(name) }
        }

        /// A string literal at `k`: its content and its end.
        func literal(at k: Int) -> (String, Int)? {
            guard at(k) == 34 || at(k) == 39 else { return nil }
            let end = stringEnd(k)
            guard end - 1 > k else { return nil }
            return (text((k + 1)..<(end - 1)), end)
        }

        static func quoted(_ name: String) -> String {
            "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }

        /// `{ a, b as c, default as d }` at `k` (on its brace): pairs of the
        /// name outside and the name inside, and the end.
        func names(at k: Int) -> ([(String, String)], Int)? {
            guard at(k) == 123 else { return nil }
            var j = skipTrivia(k + 1)
            var out: [(String, String)] = []
            while j < s.count, s[j] != 125 {
                let first: String
                if let (name, end) = literal(at: j) { first = name; j = end }
                else if let r = word(at: j) { first = text(r); j = r.upperBound }
                else { return nil }
                j = skipTrivia(j)
                var second = first
                if isWord("as", at: j) {
                    j = skipTrivia(j + 2)
                    if let (name, end) = literal(at: j) { second = name; j = end }
                    else if let r = word(at: j) { second = text(r); j = r.upperBound }
                    else { return nil }
                    j = skipTrivia(j)
                }
                out.append((first, second))
                if at(j) == 44 { j = skipTrivia(j + 1) }
            }
            guard at(j) == 125 else { return nil }
            return (out, j + 1)
        }

        /// Past an optional `;` (and `with { … }`) on the statement's line.
        func statementEnd(_ k: Int) -> Int {
            var j = k
            while j < s.count, s[j] == 32 || s[j] == 9 { j += 1 }
            if isWord("with", at: j) || isWord("assert", at: j) {
                var m = skipTrivia(word(at: j)!.upperBound)
                if at(m) == 123 {
                    while m < s.count, s[m] != 125 { m += 1 }
                    j = min(s.count, m + 1)
                    while j < s.count, s[j] == 32 || s[j] == 9 { j += 1 }
                }
            }
            if at(j) == 59 { j += 1 }
            return j
        }

        static func property(_ name: String) -> String {
            let bytes = Array(name.utf8)
            let plain = !bytes.isEmpty && isIdentStart(bytes[0]) && bytes.allSatisfy(isIdent)
            return plain ? "." + name : "[" + quoted(name) + "]"
        }

        mutating func importStatement(from start: Int, clause: Int) -> Int? {
            var j = clause
            // import "side-effect";
            if let (name, end) = literal(at: j) {
                let stop = statementEnd(end)
                request(name)
                edits.append(Edit(range: start..<stop, text: padded("__req(\(Scanner.quoted(name)));", over: start..<stop)))
                return stop
            }
            counter += 1
            let module = "__m\(counter)"
            var lines: [String] = []
            if let r = word(at: j), text(r) != "from" || !isLiteralAfterFrom(r.upperBound) {
                lines.append("const \(text(r)) = \(module).default;")
                j = skipTrivia(r.upperBound)
                if at(j) == 44 { j = skipTrivia(j + 1) }
            }
            if at(j) == 42 {
                j = skipTrivia(j + 1)
                guard isWord("as", at: j) else { return nil }
                j = skipTrivia(j + 2)
                guard let r = word(at: j) else { return nil }
                lines.append("const \(text(r)) = \(module);")
                j = skipTrivia(r.upperBound)
            } else if at(j) == 123 {
                guard let (pairs, end) = names(at: j) else { return nil }
                if !pairs.isEmpty {
                    let parts = pairs.map { outside, inside in outside == inside ? inside : "\(Scanner.quoted(outside)): \(inside)" }
                    lines.append("const {\(parts.joined(separator: ", "))} = \(module);")
                }
                j = skipTrivia(end)
            }
            guard isWord("from", at: j) else { return nil }
            j = skipTrivia(j + 4)
            guard let (name, end) = literal(at: j) else { return nil }
            let stop = statementEnd(end)
            request(name)
            let text = "const \(module) = __req(\(Scanner.quoted(name))); " + lines.joined(separator: " ")
            edits.append(Edit(range: start..<stop, text: padded(text, over: start..<stop)))
            return stop
        }

        /// `import from from "x"` is legal: `from` is a default import there.
        func isLiteralAfterFrom(_ k: Int) -> Bool {
            let j = skipTrivia(k)
            return at(j) == 34 || at(j) == 39
        }

        mutating func exportStatement(from start: Int, after: Int) -> Int? {
            var j = skipTrivia(after)
            // export * from "m";  export * as ns from "m";
            if at(j) == 42 {
                j = skipTrivia(j + 1)
                var namespace: String?
                if isWord("as", at: j) {
                    j = skipTrivia(j + 2)
                    guard let r = word(at: j) else { return nil }
                    namespace = text(r)
                    j = skipTrivia(r.upperBound)
                }
                guard isWord("from", at: j) else { return nil }
                j = skipTrivia(j + 4)
                guard let (name, end) = literal(at: j) else { return nil }
                let stop = statementEnd(end)
                request(name)
                let text = namespace.map { "__exp\(Scanner.property($0)) = __req(\(Scanner.quoted(name)));" }
                    ?? "__star(__exp, __req(\(Scanner.quoted(name))));"
                edits.append(Edit(range: start..<stop, text: padded(text, over: start..<stop)))
                note(.punct(59))
                return stop
            }
            // export { a, b as c };  export { a } from "m";
            if at(j) == 123 {
                guard let (pairs, end) = names(at: j) else { return nil }
                var k = skipTrivia(end)
                if isWord("from", at: k) {
                    k = skipTrivia(k + 4)
                    guard let (name, stopLiteral) = literal(at: k) else { return nil }
                    let stop = statementEnd(stopLiteral)
                    request(name)
                    counter += 1
                    let module = "__m\(counter)"
                    let sets = pairs.map { "__exp\(Scanner.property($0.1)) = \(module)\(Scanner.property($0.0));" }
                    let text = "const \(module) = __req(\(Scanner.quoted(name))); " + sets.joined(separator: " ")
                    edits.append(Edit(range: start..<stop, text: padded(text, over: start..<stop)))
                    note(.punct(59))
                    return stop
                }
                let stop = statementEnd(end)
                for (inside, outside) in pairs { late.append("__exp\(Scanner.property(outside)) = \(inside);") }
                edits.append(Edit(range: start..<stop, text: padded("", over: start..<stop)))
                note(.punct(59))
                return stop
            }
            if isWord("default", at: j) {
                let afterDefault = skipTrivia(j + 7)
                var k = afterDefault
                if isWord("async", at: k) { k = skipTrivia(k + 5) }
                if isWord("function", at: k) || isWord("class", at: k) {
                    let isFunction = isWord("function", at: k)
                    var n = skipTrivia(word(at: k)!.upperBound)
                    if at(n) == 42 { n = skipTrivia(n + 1) }
                    if let r = word(at: n), text(r) != "extends" {
                        // A named declaration keeps its name in the module.
                        edits.append(Edit(range: start..<afterDefault, text: padded("", over: start..<afterDefault)))
                        if isFunction { early.append("__exp.default = \(text(r));") } else { late.append("__exp.default = \(text(r));") }
                        return afterDefault
                    }
                }
                edits.append(Edit(range: start..<afterDefault, text: padded("__exp.default = ", over: start..<afterDefault)))
                return afterDefault
            }
            // export const a = 1, b = 2;  export function f() {}  export class C {}
            var k = j
            if isWord("async", at: k) { k = skipTrivia(k + 5) }
            if isWord("function", at: k) || isWord("class", at: k) {
                let isFunction = isWord("function", at: k)
                var n = skipTrivia(word(at: k)!.upperBound)
                if at(n) == 42 { n = skipTrivia(n + 1) }
                guard let r = word(at: n) else { return nil }
                edits.append(Edit(range: start..<j, text: padded("", over: start..<j)))
                if isFunction { early.append("__exp.\(text(r)) = \(text(r));") } else { late.append("__exp.\(text(r)) = \(text(r));") }
                return j
            }
            if isWord("const", at: j) || isWord("let", at: j) || isWord("var", at: j) {
                for name in declared(from: word(at: j)!.upperBound) { late.append("__exp.\(name) = \(name);") }
                edits.append(Edit(range: start..<j, text: padded("", over: start..<j)))
                return j
            }
            return nil
        }

        /// The names a `const` / `let` / `var` statement declares, read from
        /// after its keyword. Reads ahead only: the pass scans the statement
        /// again as ordinary code.
        func declared(from k: Int) -> [String] {
            var names: [String] = []
            var sub = Scanner(s)
            sub.i = k
            var expectName = true
            var localDepth = 0
            var patternDepth: Int?
            var lastSignificant: UInt8 = 0
            while sub.i < s.count {
                let c = s[sub.i]
                if c == 10 {
                    // A line break ends the statement unless the line plainly goes on.
                    if localDepth == 0, !expectName {
                        let next = at(skipTrivia(sub.i))
                        let goesOn = [46, 44, 63, 58, 43, 45, 42, 47, 37, 38, 124, 94, 60, 62, 61, 40, 91, 96].contains(next)
                        let open = [61, 44, 43, 45, 42, 47, 37, 38, 124, 94, 60, 62, 63, 58, 40, 91, 123, 46, 33, 126].contains(lastSignificant)
                        if !goesOn && !open { break }
                    }
                    sub.i += 1
                    continue
                }
                if Scanner.isSpace(c) { sub.i += 1; continue }
                if c == 47, at(sub.i + 1) == 47 || at(sub.i + 1) == 42 { sub.i = skipTrivia(sub.i); continue }
                if c == 34 || c == 39 { sub.i = stringEnd(sub.i); lastSignificant = 34; sub.prev = .value; continue }
                if c == 96 {
                    // Templates: skip whole, nested expressions included.
                    var nested = 0
                    var j = sub.i + 1
                    while j < s.count {
                        if s[j] == 92 { j += 2; continue }
                        if nested == 0, s[j] == 96 { j += 1; break }
                        if nested == 0, s[j] == 36, at(j + 1) == 123 { nested = 1; j += 2; continue }
                        if nested > 0 {
                            if s[j] == 123 { nested += 1 } else if s[j] == 125 { nested -= 1 }
                            else if s[j] == 34 || s[j] == 39 { j = stringEnd(j); continue }
                        }
                        j += 1
                    }
                    sub.i = j
                    lastSignificant = 96
                    sub.prev = .value
                    continue
                }
                if c == 47 {
                    let divides: Bool
                    switch sub.prev {
                    case .value: divides = true
                    case .punct(let p): divides = p == 41 || p == 93
                    default: divides = false
                    }
                    if divides { sub.i += 1; sub.prev = .punct(47); lastSignificant = 47 } else { sub.i = regexEnd(sub.i); sub.prev = .value; lastSignificant = 34 }
                    continue
                }
                if c == 123 || c == 40 || c == 91 {
                    if expectName, localDepth == 0, c != 40 { patternDepth = 0 }
                    localDepth += 1
                    sub.i += 1
                    sub.prev = .punct(c)
                    lastSignificant = c
                    continue
                }
                if c == 125 || c == 41 || c == 93 {
                    if localDepth == 0 { break }
                    localDepth -= 1
                    if localDepth == 0, patternDepth != nil { patternDepth = nil; expectName = false }
                    sub.i += 1
                    sub.prev = .punct(c)
                    lastSignificant = c
                    continue
                }
                if c == 59, localDepth == 0 { break }
                if c == 44, localDepth == 0 { expectName = true; sub.i += 1; sub.prev = .punct(c); lastSignificant = c; continue }
                if let r = word(at: sub.i) {
                    let w = text(r)
                    if expectName, localDepth == 0 {
                        names.append(w)
                        expectName = false
                    } else if patternDepth != nil {
                        // In a pattern: `a`, `k: a`, `a = 1`, `...a`. A name
                        // followed by `:` is a key.
                        let next = at(skipTrivia(r.upperBound))
                        let previous = lastSignificant
                        if next != 58, previous == 123 || previous == 91 || previous == 44 || previous == 58 || previous == 46 { names.append(w) }
                    }
                    sub.i = r.upperBound
                    sub.prev = Scanner.regexWords.contains(w) ? .keyword : .value
                    lastSignificant = 97
                    continue
                }
                if c >= 48 && c <= 57 {
                    var j = sub.i + 1
                    while j < s.count, Scanner.isIdent(s[j]) || s[j] == 46 { j += 1 }
                    sub.i = j
                    sub.prev = .value
                    lastSignificant = 48
                    continue
                }
                sub.i += 1
                sub.prev = .punct(c)
                lastSignificant = c
            }
            return names
        }

        func output() -> String {
            var out = [UInt8]()
            out.reserveCapacity(s.count + 256)
            out.append(contentsOf: Array("(function (\(ModSource.parameters.joined(separator: ", "))) { \"use strict\"; \(early.joined(separator: " ")) ".utf8))
            var position = 0
            for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where edit.range.lowerBound >= position {
                out.append(contentsOf: s[position..<edit.range.lowerBound])
                out.append(contentsOf: Array(edit.text.utf8))
                position = edit.range.upperBound
            }
            out.append(contentsOf: s[position...])
            out.append(contentsOf: Array("\n;\(late.joined(separator: " "))\n})".utf8))
            return String(decoding: out, as: UTF8.self)
        }
    }
}
