import AppKit
import QuickLookThumbnailing

/// What a space shows in the sidebar.
enum SpaceLook {
    case symbol(String)
    case image(NSImage)
    /// The first letter of its title, on a color `hash` picks.
    case letter(String, hash: UInt32)
}

/// What the search for a logo in a space's folder found.
enum FolderLogo {
    case none
    /// The logo, and the file it came from.
    case image(NSImage, file: String)
}

/// A logo found in one of a space's folders, which “Icon” offers.
struct LogoChoice: Identifiable {
    var folder: String
    var image: NSImage
    var id: String { folder }
}

/// A project's own logo, found in its folder: its app icon, its site's icon
/// or its logo, under the names projects give them.
enum ProjectLogo {
    /// File names, best first. An Icon Composer `AppIcon.icon`, the pictures
    /// in an Xcode `AppIcon.appiconset`, then other Icon Composer icons come
    /// before them all.
    nonisolated static let names = [
        "appicon.icns",
        "apple-touch-icon.png", "apple-touch-icon-precomposed.png",
        "icon.svg", "favicon.svg",
        "icon-1024.png", "icon-512.png", "android-chrome-512x512.png", "icon.png", "icon-192.png", "android-chrome-192x192.png",
        "logo.svg", "logo.png",
        "favicon.png", "favicon.ico",
    ]

    /// Folders that hold what tools made or fetched, not the project's own files.
    nonisolated static let skipped: Set<String> = [
        "node_modules", "build", "dist", "target", "deriveddata", "pods", "carthage", "vendor", "venv",
        "__pycache__", "site-packages", "staticfiles", "coverage",
    ]

    /// Where to look on another machine. herdr-core only reads text files
    /// there, so only SVGs.
    nonisolated static let remotePaths = [
        "icon.svg", "favicon.svg", "logo.svg",
        "public/icon.svg", "public/favicon.svg", "public/logo.svg",
        "static/favicon.svg", "static/logo.svg",
        "assets/icon.svg", "assets/logo.svg",
        "app/icon.svg", "src/app/icon.svg",
        "web/public/favicon.svg", "docs/logo.svg", ".github/logo.svg",
    ]

    /// The logo in `folder` on this Mac, as a small square PNG, and its
    /// file; nil when it has none. It reads the disk: call it off the main
    /// thread.
    nonisolated static func find(in folder: String) async -> (file: String, png: Data)? {
        for url in candidates(in: folder).prefix(8) {
            if let image = await picture(at: url), let png = thumbnail(of: image) { return (url.path, png) }
        }
        return nil
    }

    /// The picture in `url`. An Icon Composer icon is layers: QuickLook
    /// draws them as one picture, as the Finder shows it, where Xcode 26 or
    /// later is installed.
    private nonisolated static func picture(at url: URL) async -> NSImage? {
        guard url.pathExtension.lowercased() == "icon" else { return NSImage(contentsOf: url) }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64), scale: 2, representationTypes: .thumbnail)
        guard let drawn = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
              let tile = withoutMargin(drawn.cgImage)
        else { return nil }
        return NSImage(cgImage: tile, size: NSSize(width: tile.width, height: tile.height))
    }

    /// `image` without the clear border around it. QuickLook draws an app
    /// icon inside one, as the Dock does: kept, it would make the logo
    /// smaller than the others.
    private nonisolated static func withoutMargin(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var left = width, top = height, right = -1, bottom = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 0 {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        guard right >= left else { return nil }
        // The context's first row in memory is the picture's top one, where
        // cropping counts from too.
        return image.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1))
    }

    /// Files under `folder`, three folders deep at most, whose names say
    /// they are the project's icon: best name first, then the least deep.
    nonisolated static func candidates(in folder: String) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var found: [(rank: Int, depth: Int, bytes: Int, path: String, url: URL)] = []
        var queue = [(url: URL(filePath: folder, directoryHint: .isDirectory), depth: 0)]
        var looked = 0
        while !queue.isEmpty, looked < 600 {
            let (dir, depth) = queue.removeFirst()
            looked += 1
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else { continue }
            let appIcon = dir.lastPathComponent == "AppIcon.appiconset"
            for item in items {
                guard let values = try? item.resourceValues(forKeys: keys) else { continue }
                let name = item.lastPathComponent.lowercased()
                if values.isDirectory == true {
                    if (name as NSString).pathExtension == "icon" {
                        // Several icons: Xcode's default name is the app's.
                        found.append((name == "appicon.icon" ? 0 : 1, depth, 0, item.path, item))
                    } else if depth < 3, values.isSymbolicLink != true, !skip(name) {
                        queue.append((item, depth + 1))
                    }
                    continue
                }
                let rank = appIcon && name.hasSuffix(".png") ? 0 : names.firstIndex(of: name).map { $0 + 2 }
                if let rank { found.append((rank, depth, values.fileSize ?? 0, item.path, item)) }
            }
        }
        // The biggest file breaks a tie: it is most often the sharpest.
        return found.sorted { ($0.rank, $0.depth, -$0.bytes, $0.path) < ($1.rank, $1.depth, -$1.bytes, $1.path) }.map(\.url)
    }

    /// `image` as a 64-pixel square PNG; nil unless it is about square, as
    /// a wide logo with its name would be too small to read.
    nonisolated static func thumbnail(of image: NSImage) -> Data? {
        let ratio = image.size.width / max(image.size.height, 1)
        guard (0.8...1.25).contains(ratio), let square = IconImages.square(image, side: 64) else { return nil }
        return NSBitmapImageRep(cgImage: square).representation(using: .png, properties: [:])
    }

    /// A number drawn from `title`, the same at each launch (unlike `hashValue`).
    nonisolated static func hash(of title: String) -> UInt32 {
        title.lowercased().utf8.reduce(2_166_136_261 as UInt32) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    private nonisolated static func skip(_ name: String) -> Bool {
        if name.hasPrefix(".") { return name != ".github" }
        if skipped.contains(name) { return true }
        // Bundles: Xcode's own files, apps and the like.
        return ["xcodeproj", "xcworkspace", "app", "framework", "bundle", "lproj"]
            .contains((name as NSString).pathExtension)
    }
}
