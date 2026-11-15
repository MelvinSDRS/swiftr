import HerdrKit
import ImageIO
import QuickLook
import SwiftUI

/// The person's pictures over their message, as the Codex app shows them:
/// small squares in a row on their side. A click opens one in Quick Look.
struct PromptPictures: View {
    let pictures: [TranscriptImage]
    let size: Double

    var body: some View {
        // 80 points at the Codex app's 13-point text.
        let side = size * 80 / 13
        PictureRow(pictures: pictures, spacing: size * 0.6) { picture in
            PictureThumb(picture: picture, width: side, height: side, crop: true, corner: size * 0.62)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// What a tool's result showed (a screenshot read, an image viewed): as
/// it is, no taller than a few lines of text.
struct ResultPictures: View {
    let pictures: [TranscriptImage]
    let size: Double

    var body: some View {
        PictureRow(pictures: pictures, spacing: size * 0.6) { picture in
            PictureThumb(picture: picture, width: size * 31, height: size * 15, crop: false, corner: size * 0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the agent's tools showed it in a finished turn, over its answer,
/// as the Codex app shows them: "Viewed an image" over the pictures. The
/// Codex app keeps them folded; here they show until a click on the line.
struct ViewedPictures: View {
    let pictures: [TranscriptImage]
    let size: Double
    @State private var shown = true

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.6) {
            TurnHeader(text: pictures.count == 1 ? "Viewed an image" : "Viewed \(pictures.count) images",
                       open: shown, size: size) { shown.toggle() }
            if shown {
                ResultPictures(pictures: pictures, size: size)
            }
        }
    }
}

/// Pictures side by side, scrolled sideways when they don't fit; a click
/// on one opens it in Quick Look, the others a key away.
private struct PictureRow<Thumb: View>: View {
    let pictures: [TranscriptImage]
    let spacing: Double
    @ViewBuilder let thumb: (TranscriptImage) -> Thumb
    @State private var shown: URL?

    var body: some View {
        let row = HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(pictures.enumerated()), id: \.offset) { _, picture in
                Button { shown = picture.url } label: { thumb(picture) }
                    .buttonStyle(.plain)
                    .help(picture.url.lastPathComponent)
            }
        }
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal) { row }
                .scrollIndicators(.never)
        }
        .quickLookPreview($shown, in: pictures.map(\.url))
    }
}

/// One picture, drawn from a copy made small enough for its box: filling
/// a square, or whole within a box.
struct PictureThumb: View {
    let picture: TranscriptImage
    let width: Double
    let height: Double
    /// Fills the box, cut to it; else whole, as small as it needs.
    let crop: Bool
    let corner: Double
    @State private var image: CGImage?
    @State private var failed = false

    init(picture: TranscriptImage, width: Double, height: Double, crop: Bool, corner: Double) {
        self.picture = picture
        self.width = width
        self.height = height
        self.crop = crop
        self.corner = corner
        // Drawn before at this size: no blank frame while it loads again.
        _image = State(initialValue: PictureCache.cached(picture.url, box: Self.box(width, height), crop: crop))
    }

    /// The box in pixels, for a screen at twice the points.
    private static func box(_ width: Double, _ height: Double) -> CGSize {
        CGSize(width: (width * 2).rounded(.up), height: (height * 2).rounded(.up))
    }

    var body: some View {
        let box = frame
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: crop ? .fill : .fit)
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: min(box.width, box.height) * 0.3))
                    .foregroundStyle(.tertiary)
                    .help("This picture is no longer on this Mac: \(picture.url.path)")
            } else {
                Color.primary.opacity(0.05)
            }
        }
        .frame(width: box.width, height: box.height)
        .clipShape(.rect(cornerRadius: corner))
        .overlay {
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .contentShape(.rect(cornerRadius: corner))
        .task(id: picture) {
            guard image == nil else { return }
            image = await PictureCache.thumbnail(picture.url, box: Self.box(width, height), crop: crop)
            failed = image == nil
        }
    }

    /// The square, or the picture's own shape within the box once known.
    private var frame: CGSize {
        guard !crop, let image, image.width > 0, image.height > 0 else {
            return crop ? CGSize(width: width, height: height) : CGSize(width: height * 4 / 3, height: height)
        }
        let aspect = Double(image.width) / Double(image.height)
        let h = min(height, width / aspect)
        return CGSize(width: h * aspect, height: h)
    }
}

/// Small copies of pictures, made once per size and kept while memory allows.
enum PictureCache {
    /// NSCache is safe from any thread.
    private nonisolated(unsafe) static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 256 << 20
        return cache
    }()

    private nonisolated static func key(_ url: URL, _ box: CGSize, _ crop: Bool) -> NSString {
        "\(url.path)#\(Int(box.width))x\(Int(box.height))\(crop ? "c" : "")" as NSString
    }

    static func cached(_ url: URL, box: CGSize, crop: Bool) -> CGImage? {
        cache.object(forKey: key(url, box, crop))
    }

    /// A copy just big enough to fill `box` (`crop`) or to fit in it,
    /// turned as the picture says; nil when the file is gone or no picture.
    static func thumbnail(_ url: URL, box: CGSize, crop: Bool) async -> CGImage? {
        if let hit = cached(url, box: box, crop: crop) { return hit }
        let made = await Task.detached(priority: .userInitiated) { () -> SendableImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let size = pixelSize(source), size.width > 0, size.height > 0
            else { return nil }
            // The longest side that makes the other cover the box, or fit it; never bigger than the picture.
            let scale = min(1, crop ? max(box.width / size.width, box.height / size.height) : min(box.width / size.width, box.height / size.height))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, Int((max(size.width, size.height) * scale).rounded(.up))),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            cache.setObject(image, forKey: key(url, box, crop), cost: image.bytesPerRow * image.height)
            return SendableImage(image: image)
        }.value
        return made?.image
    }

    /// The picture's size in pixels, as it shows once turned upright.
    private nonisolated static func pixelSize(_ source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        // Orientations 5 to 8 turn the picture a quarter.
        let turned = ((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        return turned ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// A CGImage, which never changes, handed back from the task that made it.
    private struct SendableImage: @unchecked Sendable {
        let image: CGImage
    }
}
