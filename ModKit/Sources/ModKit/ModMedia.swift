import AppKit
import Foundation

/// Mods' pictures: SVG icons (drawn in the text's color) and images.
final class ModImages {
    private struct RasterKey: Hashable {
        var path: String
        var width: Int
        var height: Int
    }

    private let find: (String) -> URL?
    private var images: [String: NSImage?] = [:]
    private var rasters: [RasterKey: CGImage] = [:]

    /// `find`: a mod's path for a picture (`mods/vault/key.svg`) to its file.
    init(find: @escaping (String) -> URL?) {
        self.find = find
    }

    func image(_ path: String) -> NSImage? {
        if let hit = images[path] { return hit }
        let image = find(path).flatMap { NSImage(contentsOf: $0) }
        images[path] = image
        return image
    }

    func size(_ path: String) -> CGSize? { image(path)?.size }

    /// Forget what was read: a mod's files changed.
    func reset() {
        images = [:]
        rasters = [:]
    }

    private func raster(_ path: String, size: CGSize, scale: CGFloat) -> CGImage? {
        let key = RasterKey(path: path, width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)))
        guard key.width > 0, key.height > 0 else { return nil }
        if let hit = rasters[key] { return hit }
        guard let image = image(path),
              let context = CGContext(data: nil, width: key.width, height: key.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        // The whole picture, kept in shape, in the middle.
        let own = image.size
        var target = CGRect(x: 0, y: 0, width: key.width, height: key.height)
        if own.width > 0, own.height > 0 {
            let fit = min(target.width / own.width, target.height / own.height)
            let fitted = CGSize(width: own.width * fit, height: own.height * fit)
            target = CGRect(x: (target.width - fitted.width) / 2, y: (target.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
        }
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let made = context.makeImage() else { return nil }
        if rasters.count > 600 { rasters.removeAll() }
        rasters[key] = made
        return made
    }

    /// Draws in a flipped context. `tint`: the one color of an icon.
    func draw(_ path: String, in rect: CGRect, tint: NSColor?, scale: CGFloat, context: CGContext) {
        guard rect.width > 0, rect.height > 0, let image = raster(path, size: rect.size, scale: scale) else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let local = CGRect(origin: .zero, size: rect.size)
        if let tint {
            // The picture's shape, filled with the color.
            context.clip(to: local)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.draw(image, in: local)
            context.setBlendMode(.sourceIn)
            context.setFillColor(tint.cgColor)
            context.fill(local)
            context.endTransparencyLayer()
        } else {
            context.interpolationQuality = .high
            context.draw(image, in: local)
        }
        context.restoreGState()
    }
}

/// `TextView.markdown`: headings, lists, code, quotes, and the usual marks
/// inside a line.
enum ModMarkdown {
    private struct Key: Hashable {
        var text: String
        var size: CGFloat
        var family: String?
    }

    private static var cache: [Key: NSAttributedString] = [:]

    static func attributed(_ node: ModNode) -> NSAttributedString {
        let style = node.textStyle
        let key = Key(text: node.text ?? "", size: style.size, family: style.family)
        if let hit = cache[key] { return hit }
        let out = NSMutableAttributedString()
        let base = ModFonts.font(style)
        var mono = style
        mono.family = ModFonts.monoFamily
        mono.size = (style.size * 0.92).rounded()
        let code = ModFonts.font(mono)
        var inCode = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = style.size * 0.5
        paragraph.lineHeightMultiple = 1.15

        func inline(_ line: String, font: NSFont) -> NSAttributedString {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            guard let parsed = try? AttributedString(markdown: line, options: options) else {
                return NSAttributedString(string: line, attributes: [.font: font])
            }
            let made = NSMutableAttributedString()
            for run in parsed.runs {
                var runFont = font
                let intent = run.inlinePresentationIntent ?? []
                if intent.contains(.code) { runFont = code }
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: traits) }
                var attributes: [NSAttributedString.Key: Any] = [.font: runFont]
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = link; attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                made.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            return made
        }

        for raw in (node.text ?? "").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }
            let piece: NSMutableAttributedString
            if inCode {
                piece = NSMutableAttributedString(string: raw, attributes: [.font: code])
            } else if let heading = trimmed.range(of: #"^#{1,6} "#, options: .regularExpression) {
                let level = trimmed.distance(from: trimmed.startIndex, to: heading.upperBound) - 1
                var big = style
                big.weight = 600
                big.size = (style.size * [1.5, 1.3, 1.15, 1, 1, 1][min(level, 6) - 1]).rounded()
                piece = NSMutableAttributedString(attributedString: inline(String(trimmed[heading.upperBound...]), font: ModFonts.font(big)))
            } else if let bullet = trimmed.range(of: #"^([-*+]|\d+[.)]) "#, options: .regularExpression) {
                let mark = trimmed[bullet].first!.isNumber ? String(trimmed[bullet]) : "•  "
                piece = NSMutableAttributedString(string: mark, attributes: [.font: base])
                piece.append(inline(String(trimmed[bullet.upperBound...]), font: base))
                let indent = NSMutableParagraphStyle()
                indent.headIndent = style.size * 1.1
                indent.firstLineHeadIndent = CGFloat(raw.prefix { $0 == " " }.count) * style.size * 0.3
                indent.paragraphSpacing = style.size * 0.2
                indent.lineHeightMultiple = 1.15
                piece.addAttribute(.paragraphStyle, value: indent, range: NSRange(location: 0, length: piece.length))
            } else if trimmed.hasPrefix("> ") {
                piece = NSMutableAttributedString(attributedString: inline(String(trimmed.dropFirst(2)), font: NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)))
            } else {
                piece = NSMutableAttributedString(attributedString: inline(raw, font: base))
            }
            if piece.length > 0, piece.attribute(.paragraphStyle, at: 0, effectiveRange: nil) == nil {
                piece.addAttribute(.paragraphStyle, value: inCode ? NSParagraphStyle.default : paragraph, range: NSRange(location: 0, length: piece.length))
            }
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: base])) }
            out.append(piece)
        }
        if cache.count > 200 { cache.removeAll() }
        cache[key] = out
        return out
    }

    static func size(of node: ModNode, width: CGFloat) -> CGSize {
        let bounds = attributed(node).boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    /// Draws in a flipped context.
    static func draw(_ node: ModNode, in rect: CGRect, color: NSColor, context: CGContext) {
        let text = NSMutableAttributedString(attributedString: attributed(node))
        text.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: text.length))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }
}
