import AppKit
import HerdrKit
import SwiftUI

extension EnvironmentValues {
    /// How far a wide table may reach past the column's right edge: the
    /// pane's margin beside the conversation's column; 0 elsewhere.
    @Entry var tableReach: CGFloat = 0
}

/// A Markdown table, close to the Codex app's: the header over a line,
/// faint lines between rows and bars between columns, no box around it.
/// It fills the width it gets, and
/// its columns share it as a web page's do: each as wide as its text when
/// there is room, else the longer ones wrap first, never inside a word.
/// In the conversation a wide table also takes the room beside the
/// column; what is still too wide scrolls sideways, the hidden side
/// faded. Copy shows on hover.
struct TableBlock: View {
    @Environment(\.codeFamily) private var codeFamily
    @Environment(\.linksPaths) private var linksPaths
    @Environment(\.tableReach) private var tableReach
    #if DEBUG
    @Environment(\.flatRender) private var flat
    #else
    private let flat = false
    #endif
    let header: [String]
    let alignments: [MarkdownAlignment]
    let rows: [[String]]
    let size: Double
    /// May reach past the column's right edge: the conversation's own texts.
    var reachesOut = false
    @State private var hovering = false
    @State private var hidden = HiddenSides()
    @State private var copied = false

    /// The text's size: as the Codex app's, a step under the answers'.
    private var font: Double { size * 0.92 }
    /// Between two columns.
    private var gap: Double { size * 1.5 }
    /// Kept free after the header's last cell, for Copy.
    private var room: Double { size * 2.2 }

    private var showsCopy: Bool {
        #if DEBUG
        if HoverActions.debugShown { return true }
        #endif
        return hovering || copied
    }

    var body: some View {
        let metrics = TableMetrics.of(header: header, rows: rows, font: font, code: codeFamily)
        TableReach(natural: metrics.natural(gap: gap, room: room), reach: reachesOut ? tableReach : 0) {
            scroller(metrics)
                .overlay(alignment: .topTrailing) {
                    if showsCopy {
                        // Its middle on the header's: the header's padding and half its line, less half the button.
                        BlockCopyButton(size: size, help: "Copy Table", copied: $copied) {
                            BlockCopy.put(text: MarkdownTable.markdown(header: header, alignments: alignments, rows: rows),
                                          html: MarkdownTable.html(header: header, alignments: alignments, rows: rows))
                        }
                        .padding(.top, max(0, size * 0.5 + font * 0.6 - size * 0.9))
                        .transition(.opacity)
                    }
                }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }

    @ViewBuilder private func scroller(_ metrics: TableMetrics) -> some View {
        if flat {
            // As the scroll view shows it at its start: words whole, the rest cut off.
            TableReach(natural: metrics.least(gap: gap, room: room), reach: .infinity) { grid(metrics) }
                .clipped()
        } else {
            let least = metrics.least(gap: gap, room: room)
            ScrollView(.horizontal) {
                // As wide as the scroll view, or as its words need.
                grid(metrics)
                    .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in max(length, least) }
            }
            .scrollIndicators(.automatic)
            .onScrollGeometryChange(for: HiddenSides.self) { geo in
                HiddenSides(
                    leading: geo.contentOffset.x > 0.5,
                    trailing: geo.contentOffset.x + geo.containerSize.width < geo.contentSize.width - 0.5
                )
            } action: { _, sides in
                hidden = sides
            }
            .mask { fade }
        }
    }

    /// Opaque but where columns are out of sight: those sides fade out.
    private var fade: some View {
        let width = size * 2.5
        return HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.1), .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: hidden.leading ? width : 0)
            Rectangle()
            LinearGradient(colors: [.black, .black.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
                .frame(width: hidden.trailing ? width : 0)
        }
        .animation(.easeOut(duration: 0.15), value: hidden)
    }

    private func grid(_ metrics: TableMetrics) -> some View {
        TableGrid(columns: header.count, gap: gap, headerPad: size * 0.5, rowPad: size * 0.62, room: room, alignments: alignments) {
            ForEach(header.indices, id: \.self) { c in
                cell(header[c], row: 0, column: c, weight: .semibold, narrowest: metrics.narrowest[0][c])
            }
            TableRule(strong: true)
                .layoutValue(key: TablePartKey.self, value: .rule(row: 0))
            ForEach(rows.indices, id: \.self) { r in
                ForEach(header.indices, id: \.self) { c in
                    cell(rows[r].indices.contains(c) ? rows[r][c] : "", row: r + 1, column: c, weight: .regular,
                         narrowest: metrics.narrowest[r + 1][c])
                }
                if r < rows.count - 1 {
                    TableRule(strong: false)
                        .layoutValue(key: TablePartKey.self, value: .rule(row: r + 1))
                }
            }
            ForEach(Array(header.indices.dropFirst()), id: \.self) { c in
                TableRule(strong: false)
                    .layoutValue(key: TablePartKey.self, value: .bar(column: c))
            }
        }
    }

    private func cell(_ text: String, row: Int, column: Int, weight: Font.Weight, narrowest: CGFloat) -> some View {
        let alignment = alignments.indices.contains(column) ? alignments[column] : .leading
        return Text(MarkdownCache.inline(MarkdownTable.shown(text), size: font, weight: weight, code: codeFamily, digits: true, paths: linksPaths))
            .lineSpacing(font * 0.3)
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .layoutValue(key: TablePartKey.self, value: .cell(row: row, column: column))
            .layoutValue(key: NarrowestKey.self, value: narrowest)
    }
}

/// Which sides of a table scrolled sideways have columns out of sight.
private struct HiddenSides: Equatable {
    var leading = false
    var trailing = false
}

/// The line under the header, or a fainter one between rows.
private struct TableRule: View {
    let strong: Bool

    var body: some View {
        Rectangle().fill(Color.primary.opacity(strong ? 0.2 : 0.08))
    }
}

// MARK: - Layout

/// What a view is in a table: a cell (row 0 is the header), the line
/// under a row, or the bar before a column.
private nonisolated enum TablePart: Equatable {
    case cell(row: Int, column: Int)
    case rule(row: Int)
    case bar(column: Int)
}

private nonisolated struct TablePartKey: LayoutValueKey {
    static let defaultValue = TablePart.rule(row: -1)
}

/// How narrow a cell may go without breaking a word.
private nonisolated struct NarrowestKey: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// Cells in rows and columns, with lines between rows and bars between
/// columns. The table fills the width it gets; each
/// column takes its text's width, its share of what is left over, or,
/// when the text is too wide, a width between its widest word and its
/// widest line, in proportion to how much it has to wrap. A row is as
/// tall as its tallest cell, so wrapped cells push the next row down.
private struct TableGrid: Layout {
    let columns: Int
    let gap: CGFloat
    /// Above and under the header's text.
    let headerPad: CGFloat
    /// Above and under a row's text.
    let rowPad: CGFloat
    /// Kept free after the header's last cell.
    let room: CGFloat
    let alignments: [MarkdownAlignment]

    struct Cache {
        /// Subview indexes by row and column; -1 for none.
        var cells: [[Int]] = []
        /// The subview index of the line under each row.
        var rules: [Int: Int] = [:]
        /// The subview index of the bar before each column.
        var bars: [Int: Int] = [:]
        /// Per column: its widest line, and its widest word.
        var widest: [CGFloat] = []
        var narrowest: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        var cache = Cache()
        var found: [Int: [Int: Int]] = [:]
        for (i, view) in subviews.enumerated() {
            switch view[TablePartKey.self] {
            case .cell(let row, let column): found[row, default: [:]][column] = i
            case .rule(let row): cache.rules[row] = i
            case .bar(let column): cache.bars[column] = i
            }
        }
        let rowCount = (found.keys.max() ?? -1) + 1
        cache.cells = (0 ..< rowCount).map { r in (0 ..< columns).map { c in found[r]?[c] ?? -1 } }
        cache.widest = Array(repeating: 0, count: columns)
        cache.narrowest = Array(repeating: 0, count: columns)
        for (r, row) in cache.cells.enumerated() {
            for (c, i) in row.enumerated() where i >= 0 {
                let extra = extra(row: r, column: c)
                let line = subviews[i].sizeThatFits(.unspecified).width.rounded(.up) + extra
                cache.widest[c] = max(cache.widest[c], line)
                cache.narrowest[c] = max(cache.narrowest[c], min(subviews[i][NarrowestKey.self] + extra, line))
            }
        }
        return cache
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    /// The header's last cell keeps `room` free.
    private func extra(row: Int, column: Int) -> CGFloat {
        row == 0 && column == columns - 1 ? room : 0
    }

    private var gaps: CGFloat { gap * CGFloat(max(0, columns - 1)) }

    /// Each column's width when the table is `width` wide; their widest
    /// lines when it may be as wide as it likes (see `MarkdownTable.widths`).
    func widths(_ width: CGFloat?, _ cache: Cache) -> [CGFloat] {
        MarkdownTable.widths(widest: cache.widest.map(Double.init), narrowest: cache.narrowest.map(Double.init),
                             width: width.map(Double.init), gap: Double(gap)).map { CGFloat($0) }
    }

    /// Each row's height, its padding in.
    private func heights(_ widths: [CGFloat], _ subviews: Subviews, _ cache: Cache) -> [CGFloat] {
        cache.cells.enumerated().map { r, row in
            var tallest: CGFloat = 0
            for (c, i) in row.enumerated() where i >= 0 {
                tallest = max(tallest, subviews[i].sizeThatFits(proposal(widths[c] - extra(row: r, column: c))).height)
            }
            return tallest.rounded(.up) + 2 * (r == 0 ? headerPad : rowPad)
        }
    }

    private func proposal(_ width: CGFloat) -> ProposedViewSize {
        ProposedViewSize(width: max(1, width), height: nil)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let widths = widths(proposal.width, cache)
        let heights = heights(widths, subviews, cache)
        return CGSize(width: widths.reduce(0, +) + gaps, height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let widths = widths(bounds.width, cache)
        let heights = heights(widths, subviews, cache)
        var y = bounds.minY
        for (r, row) in cache.cells.enumerated() {
            let pad = r == 0 ? headerPad : rowPad
            var x = bounds.minX
            for (c, i) in row.enumerated() {
                defer { x += widths[c] + gap }
                guard i >= 0 else { continue }
                let width = widths[c] - extra(row: r, column: c)
                let used = subviews[i].sizeThatFits(self.proposal(width)).width
                let shift: CGFloat = switch alignments.indices.contains(c) ? alignments[c] : .leading {
                case .leading: 0
                case .center: (width - used) / 2
                case .trailing: width - used
                }
                subviews[i].place(at: CGPoint(x: x + max(0, shift), y: y + pad), anchor: .topLeading, proposal: self.proposal(width))
            }
            y += heights[r]
            if let rule = cache.rules[r] {
                subviews[rule].place(at: CGPoint(x: bounds.minX, y: y - 1), anchor: .topLeading,
                                     proposal: ProposedViewSize(width: bounds.width, height: 1))
            }
        }
        // Bars in the middle of the gaps, from the header's top to the last row's bottom.
        var left = bounds.minX
        for c in 0 ..< columns {
            if let bar = cache.bars[c] {
                subviews[bar].place(at: CGPoint(x: (left - gap / 2).rounded(), y: bounds.minY), anchor: .topLeading,
                                    proposal: ProposedViewSize(width: 1, height: y - bounds.minY))
            }
            left += widths[c] + gap
        }
        // Lines under rows that aren't there, bars before columns that aren't: out of sight.
        for (row, i) in cache.rules where !cache.cells.indices.contains(row) {
            subviews[i].place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
        }
        for (column, i) in cache.bars where column <= 0 || column >= columns {
            subviews[i].place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
        }
    }
}

/// Its view as wide as offered, or wider when it would like to be, up to
/// `reach` past the right edge: a wide table takes the room beside the
/// column. Its own size stays as offered, so what is around it doesn't move.
private struct TableReach: Layout {
    /// How wide the view would like to be.
    let natural: CGFloat
    let reach: CGFloat

    private func width(_ offered: CGFloat) -> CGFloat {
        min(max(offered, natural), offered + max(0, reach))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        guard let offered = proposal.width, offered.isFinite else { return view.sizeThatFits(proposal) }
        let height = view.sizeThatFits(ProposedViewSize(width: width(offered), height: nil)).height
        return CGSize(width: offered, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: width(bounds.width), height: bounds.height))
    }
}

// MARK: - Measures

/// A table's text as AppKit measures it, known before layout: how wide
/// the table would like to be, and how narrow it can go.
private struct TableMetrics {
    /// By row (0 the header) and column: the widest line.
    var lines: [[CGFloat]]
    /// By row and column: the widest word, or `longestWord`.
    var narrowest: [[CGFloat]]

    /// A word wider than this many points may break, rather than widen
    /// its column: a long path or address.
    static func longestWord(_ font: Double) -> CGFloat { font * 13 }

    /// Each column's widest cell in `widths`, the header's last cell with
    /// `room` after it, and the gaps between them.
    private func total(_ widths: [[CGFloat]], gap: CGFloat, room: CGFloat) -> CGFloat {
        let columns = widths.first?.count ?? 0
        let widest = (0 ..< columns).map { c in
            widths.indices.map { r in widths[r][c] + (r == 0 && c == columns - 1 ? room : 0) }.max() ?? 0
        }
        return widest.reduce(0, +) + gap * CGFloat(max(0, columns - 1))
    }

    /// The table on one line per row; a few points over, as a word that
    /// just fits would otherwise go to the next line.
    func natural(gap: CGFloat, room: CGFloat) -> CGFloat {
        total(lines, gap: gap, room: room) + 3 * CGFloat(lines.first?.count ?? 0)
    }

    /// The narrowest the table goes without breaking a word.
    func least(gap: CGFloat, room: CGFloat) -> CGFloat {
        total(narrowest, gap: gap, room: room)
    }

    private struct Key: Hashable {
        let header: [String]
        let rows: [[String]]
        let font: Double
        let code: String
    }

    private static var cache: [Key: TableMetrics] = [:]

    static func of(header: [String], rows: [[String]], font: Double, code: String) -> TableMetrics {
        let key = Key(header: header, rows: rows, font: font, code: code)
        if let hit = cache[key] { return hit }
        var lines: [[CGFloat]] = []
        var narrowest: [[CGFloat]] = []
        for (r, row) in ([header] + rows).enumerated() {
            var wide: [CGFloat] = []
            var word: [CGFloat] = []
            for c in header.indices {
                let text = row.indices.contains(c) ? row[c] : ""
                let styled = MarkdownCache.inline(MarkdownTable.shown(text), size: font, weight: r == 0 ? .semibold : .regular, code: code, digits: true)
                let measured = measure(styled, font: font, header: r == 0, code: code)
                wide.append(measured.line)
                word.append(min(measured.word, longestWord(font)))
            }
            lines.append(wide)
            narrowest.append(word)
        }
        let metrics = TableMetrics(lines: lines, narrowest: narrowest)
        if cache.count > 200 { cache.removeAll(keepingCapacity: true) }
        cache[key] = metrics
        return metrics
    }

    /// The widest line of `text` and its widest word, drawn in the fonts
    /// `MarkdownCache.inline` gives it.
    private static func measure(_ text: AttributedString, font: Double, header: Bool, code: String) -> (line: CGFloat, word: CGFloat) {
        let drawn = NSMutableAttributedString()
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            let strong = intent.contains(.stronglyEmphasized)
            let face: NSFont
            if intent.contains(.code) {
                let plain = Preferences.font(family: code, size: font * 0.92)
                face = strong || header ? NSFontManager.shared.convert(plain, toHaveTrait: .boldFontMask) : plain
            } else {
                let weight: NSFont.Weight = header ? (strong ? .bold : .semibold) : (strong ? .semibold : .regular)
                face = .monospacedDigitSystemFont(ofSize: font, weight: weight)
            }
            drawn.append(NSAttributedString(string: String(text[run.range].characters), attributes: [.font: face]))
        }
        let string = drawn.string as NSString
        func width(_ start: Int, _ end: Int) -> CGFloat {
            end > start ? drawn.attributedSubstring(from: NSRange(location: start, length: end - start)).size().width.rounded(.up) : 0
        }
        var line: CGFloat = 0
        var word: CGFloat = 0
        var lineStart = 0
        var wordStart = 0
        for i in 0 ... string.length {
            let c: unichar = i < string.length ? string.character(at: i) : 10
            if c == 10 || c == 13 {
                line = max(line, width(lineStart, i))
                lineStart = i + 1
            }
            if c == 10 || c == 13 || c == 32 || c == 9 {
                word = max(word, width(wordStart, i))
                wordStart = i + 1
            }
        }
        return (line, word)
    }
}

// MARK: - Copy

/// Copy over a block (a table, a quote): a drop of glass that shows a
/// check a moment once the block is on the pasteboard.
struct BlockCopyButton: View {
    let size: Double
    let help: String
    /// Set a moment after a click: the block keeps the button in sight.
    @Binding var copied: Bool
    let copy: () -> Void

    var body: some View {
        Button {
            copy()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: size * 0.8))
                .frame(width: size * 1.8, height: size * 1.8)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .paneGlass(.regular.interactive(), in: .circle)
        .help(help)
    }
}

/// A block on the pasteboard: as Markdown for text, as HTML for apps that
/// take formatting (Notes, Mail, Pages, Numbers, Jira).
enum BlockCopy {
    static func put(text: String, html: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.html, .string], owner: nil)
        board.setString(html, forType: .html)
        board.setString(text, forType: .string)
    }
}
