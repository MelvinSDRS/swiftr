import AppKit
import CoreText
import Foundation

/// The fonts mods ask for, by family, size and weight.
public enum ModFonts {
    private struct Key: Hashable {
        var family: String?
        var size: CGFloat
        var weight: Int
        var italic: Bool
    }

    private static var cache: [Key: NSFont] = [:]
    /// The mods' own font where they name none (herdr-app's `ui_font`):
    /// nil is the Mac's.
    public static var uiFamily: String?
    /// What `font_family` falls back to for a family this Mac lacks, when
    /// it looks like a terminal font.
    public static var monoFamily = "JetBrains Mono" { didSet { if monoFamily != oldValue { cache = [:] } } }

    private static func weight(_ value: Int) -> NSFont.Weight {
        switch value {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }

    private static func named(_ family: String, size: CGFloat, weight: NSFont.Weight, italic: Bool) -> NSFont? {
        var traits: [NSFontDescriptor.TraitKey: Any] = [.weight: weight.rawValue]
        if italic { traits[.symbolic] = NSFontDescriptor.SymbolicTraits.italic.rawValue }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: traits])
        guard let font = NSFont(descriptor: descriptor, size: size) else { return nil }
        // An unknown family comes back as another font.
        return font.familyName?.caseInsensitiveCompare(family) == .orderedSame ? font : nil
    }

    static func font(_ style: ModTextStyle) -> NSFont {
        let key = Key(family: style.family ?? uiFamily, size: style.size, weight: style.weight, italic: style.italic)
        if let hit = cache[key] { return hit }
        let w = weight(style.weight)
        var font: NSFont?
        if let family = key.family, !["system-ui", "system", ".systemfont", "sans-serif"].contains(family.lowercased()) {
            font = named(family, size: style.size, weight: w, italic: style.italic)
            if font == nil, family.lowercased().contains("mono") || family.lowercased() == "monospace" {
                font = named(monoFamily, size: style.size, weight: w, italic: style.italic)
                    ?? NSFont.monospacedSystemFont(ofSize: style.size, weight: w)
            }
        }
        var resolved = font ?? NSFont.systemFont(ofSize: style.size, weight: w)
        if font == nil, style.italic {
            resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .italicFontMask)
        }
        if cache.count > 512 { cache.removeAll() }
        cache[key] = resolved
        return resolved
    }
}

/// A node's text, measured and drawn with Core Text: one font, lines of one
/// height, the color given when it is drawn.
final class ModTextLayout {
    let text: String
    let style: ModTextStyle
    let font: NSFont
    private let attributed: NSAttributedString
    private let single: CTLine
    private let naturalWidth: CGFloat
    private let ascent: CGFloat
    private let descent: CGFloat
    private var wrappedWidth: CGFloat = -1
    private var wrapped: [CTLine] = []
    private lazy var typesetter = CTTypesetterCreateWithAttributedString(attributed)

    init(text: String, style: ModTextStyle) {
        self.text = text
        self.style = style
        font = ModFonts.font(style)
        attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            // The color comes from where it is drawn (a hover changes it).
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        single = CTLineCreateWithAttributedString(attributed)
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        naturalWidth = CGFloat(CTLineGetTypographicBounds(single, &a, &d, &l))
        ascent = font.ascender
        descent = -font.descender
    }

    private var wraps: Bool { !style.nowrap && style.clamp != 1 }

    private func lines(for width: CGFloat) -> [CTLine] {
        guard wraps, width.isFinite, naturalWidth > width + 0.5 || text.contains("\n") else {
            return text.contains("\n") && wraps ? breakLines(width: .greatestFiniteMagnitude) : [single]
        }
        if wrappedWidth == width { return wrapped }
        wrapped = breakLines(width: max(width, 1))
        wrappedWidth = width
        return wrapped
    }

    private func breakLines(width: CGFloat) -> [CTLine] {
        var out: [CTLine] = []
        var start = 0
        let length = attributed.length
        while start < length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(min(width, 1_000_000))))
            out.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
            if style.clamp > 0, out.count >= style.clamp { break }
        }
        return out.isEmpty ? [single] : out
    }

    /// The size the text wants within `width` (nil: as wide as it is).
    func measure(width: CGFloat?) -> CGSize {
        let height = style.lineHeightPx
        guard let width, wraps else { return CGSize(width: ceil(naturalWidth), height: height) }
        let lines = lines(for: width)
        if lines.count == 1 { return CGSize(width: ceil(min(naturalWidth, max(width, 0))), height: height) }
        var widest: CGFloat = 0
        for line in lines { widest = max(widest, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) }
        return CGSize(width: ceil(min(widest, width)), height: height * CGFloat(lines.count))
    }

    /// Draws in a flipped context (y down), in `color`.
    func draw(in rect: CGRect, color: NSColor, underline: Bool, context: CGContext, override: String? = nil) {
        var drawn = lines(for: rect.width)
        if let override {
            let other = NSAttributedString(string: override, attributes: attributed.attributes(at: 0, effectiveRange: nil))
            drawn = [CTLineCreateWithAttributedString(other)]
        }
        let lineHeight = style.lineHeightPx
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.setStrokeColor(color.cgColor)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        var top = rect.minY
        // Fewer lines than the box: the box's own height centers nothing;
        // text starts at its top, as in a browser.
        for (index, var line) in drawn.enumerated() {
            var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let last = index == drawn.count - 1
            let cut = style.ellipsis || style.clamp > 0
            if width > rect.width + 0.5, cut || !wraps, last || !wraps {
                if cut, let token = ellipsisLine(),
                   let truncated = CTLineCreateTruncatedLine(lineToEnd(from: line, isLast: last), Double(max(rect.width, 0)), .end, token) {
                    line = truncated
                    width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                }
            }
            var x = rect.minX
            switch style.align {
            case .center: x += (rect.width - width) / 2
            case .right: x += rect.width - width
            default: break
            }
            let baseline = top + (lineHeight - (ascent + descent)) / 2 + ascent
            if let behind = style.background {
                context.setFillColor(behind.cgColor)
                context.fill(CGRect(x: x, y: top, width: width, height: lineHeight))
                context.setFillColor(color.cgColor)
            }
            context.textPosition = CGPoint(x: x.rounded(.down), y: (baseline * 2).rounded() / 2)
            CTLineDraw(line, context)
            if style.strike { rule(from: x, to: x + width, y: baseline - ascent * 0.3, thick: max(1, font.pointSize / 14), wavy: false, context: context) }
            if underline, style.underlineWidth != 0 {
                let thick = style.underlineWidth ?? max(1, font.pointSize / 14)
                rule(from: x, to: x + width, y: baseline + max(1, descent * 0.4) + (thick - 1) / 2, thick: thick, wavy: style.wavy, context: context)
            }
            top += lineHeight
        }
        context.restoreGState()
    }

    /// A line under or through text, straight or in waves.
    private func rule(from start: CGFloat, to end: CGFloat, y: CGFloat, thick: CGFloat, wavy: Bool, context: CGContext) {
        context.setLineWidth(thick)
        let at = thick.truncatingRemainder(dividingBy: 2) == 1 ? y.rounded() + 0.5 : y.rounded()
        context.move(to: CGPoint(x: start, y: at))
        if wavy {
            let half = max(2, thick * 2), rise = max(1, thick)
            var x = start, up = true
            while x < end {
                let next = min(x + half, end)
                context.addQuadCurve(to: CGPoint(x: next, y: at), control: CGPoint(x: (x + next) / 2, y: at + (up ? -rise : rise)))
                x = next
                up.toggle()
            }
        } else {
            context.addLine(to: CGPoint(x: end, y: at))
        }
        context.strokePath()
    }

    /// The character under a point, for a selection. `rect`: where the
    /// text is drawn.
    func index(at point: CGPoint, in rect: CGRect) -> Int {
        let drawn = lines(for: rect.width)
        let height = style.lineHeightPx
        if point.y < rect.minY { return 0 }
        if point.y >= rect.minY + height * CGFloat(drawn.count) { return attributed.length }
        let row = min(max(Int((point.y - rect.minY) / height), 0), drawn.count - 1)
        let line = drawn[row]
        let found = CTLineGetStringIndexForPosition(line, CGPoint(x: point.x - start(of: line, in: rect), y: 0))
        return found == kCFNotFound ? CTLineGetStringRange(line).location : min(max(found, 0), attributed.length)
    }

    /// Where the characters of a range are drawn, a box per line.
    func rects(for range: NSRange, in rect: CGRect) -> [CGRect] {
        var out: [CGRect] = []
        let height = style.lineHeightPx
        for (row, line) in lines(for: rect.width).enumerated() {
            let own = CTLineGetStringRange(line)
            let from = max(range.location, own.location), to = min(range.location + range.length, own.location + own.length)
            guard to > from else { continue }
            let x0 = start(of: line, in: rect)
            let a = CTLineGetOffsetForStringIndex(line, from, nil), b = CTLineGetOffsetForStringIndex(line, to, nil)
            out.append(CGRect(x: x0 + a, y: rect.minY + CGFloat(row) * height, width: max(b - a, 2), height: height))
        }
        return out
    }

    private func start(of line: CTLine, in rect: CGRect) -> CGFloat {
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        switch style.align {
        case .center: return rect.minX + (rect.width - width) / 2
        case .right: return rect.maxX - width
        default: return rect.minX
        }
    }

    var length: Int { attributed.length }

    private func ellipsisLine() -> CTLine? {
        CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributed.attributes(at: 0, effectiveRange: nil)))
    }

    /// For the last line of a clamp: the rest of the text, so the cut shows
    /// there is more.
    private func lineToEnd(from line: CTLine, isLast: Bool) -> CTLine {
        guard isLast, style.clamp > 0 else { return line }
        let range = CTLineGetStringRange(line)
        guard range.location + range.length < attributed.length else { return line }
        return CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: attributed.length - range.location))
    }
}
