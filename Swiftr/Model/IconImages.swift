import AppKit

/// Images chosen as space icons: Swiftr keeps a 128-pixel square PNG copy of
/// each, so the original can move or go.
enum IconImages {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Swiftr").appending(path: "icons")
    }

    private static var cache: [String: NSImage] = [:]

    /// The copy kept under `name`; nil once it is gone.
    static func image(_ name: String) -> NSImage? {
        if let image = cache[name] { return image }
        guard let image = NSImage(contentsOf: folder.appending(path: name)) else { return nil }
        cache[name] = image
        return image
    }

    /// Copies the image at `url`, fitted into a square, and returns the
    /// copy's name; nil when it can't be read or written.
    static func save(from url: URL) -> String? {
        guard let source = NSImage(contentsOf: url), let image = square(source, side: 128),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appending(path: name), options: .atomic)
        } catch {
            return nil
        }
        return name
    }

    /// `source` fitted into a square `side` pixels wide, centred on a clear ground.
    nonisolated static func square(_ source: NSImage, side: Int) -> CGImage? {
        guard source.size.width > 0, source.size.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let box = CGFloat(side)
        let scale = min(box / source.size.width, box / source.size.height)
        let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        source.draw(in: NSRect(x: (box - size.width) / 2, y: (box - size.height) / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    static func remove(_ names: some Sequence<String>) {
        for name in names {
            cache[name] = nil
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}
