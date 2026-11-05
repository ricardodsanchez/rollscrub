import AVFoundation
import AppKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI

/// Generates previews through QuickLook, which is the only thing that reads
/// ARW, DNG and CR3 as well as it reads JPEG — and pulls a first frame out of
/// a video. Results are cached; the drive is external and slow to re-read.
@MainActor
final class ThumbnailLoader: ObservableObject {

    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        cache.countLimit = 240
    }

    private func key(_ url: URL, _ size: CGFloat) -> NSString {
        "\(url.path)|\(Int(size))" as NSString
    }

    func cached(_ url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, size))
    }

    func image(for url: URL, size: CGFloat, scale: CGFloat = 2) async -> NSImage? {
        let cacheKey = key(url, size)
        if let hit = cache.object(forKey: cacheKey) { return hit }

        if let existing = inFlight[cacheKey as String] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> { [cache] in
            let image = await Self.generate(url: url, size: size, scale: scale)
            if let image { cache.setObject(image, forKey: cacheKey) }
            return image
        }
        inFlight[cacheKey as String] = task
        let result = await task.value
        inFlight[cacheKey as String] = nil
        return result
    }

    // MARK: - Generation

    /// Reads real image content, never a file-type icon.
    ///
    /// QuickLook is deliberately the last resort: asking it for `.thumbnail`
    /// returns nothing for Sony ARW, and allowing `.all` makes it hand back the
    /// generic "ARW" document icon — identical for every raw file, and useless
    /// when the whole point is telling two photos apart. Image I/O reads the
    /// preview embedded in the raw file instead, which is both correct and
    /// faster than decoding the sensor data.
    nonisolated private static func generate(
        url: URL, size: CGFloat, scale: CGFloat
    ) async -> NSImage? {
        let maxPixel = size * scale
        // Every route below reads the file, and QuickLook does it outside the
        // kernel switch this process set, so an online-only file gets none.
        guard !OnlineOnly.isNotDownloaded(url) else { return nil }

        if MediaKindHelper.isVideo(url) {
            if let frame = await videoFrame(url: url, maxPixel: maxPixel) { return frame }
        } else {
            let image = await Task.detached(priority: .userInitiated) {
                embeddedPreview(url: url, maxPixel: maxPixel)
            }.value
            if let image { return image }
        }
        return await quickLookFallback(url: url, size: size, scale: scale)
    }

    nonisolated private static func embeddedPreview(url: URL, maxPixel: CGFloat) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // respect EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(
            cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated private static func videoFrame(url: URL, maxPixel: CGFloat) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // A second in, so the frame is not a black fade-in; then the very
        // start, for clips shorter than that.
        for seconds in [1.0, 0.0] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                return NSImage(
                    cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
        return nil
    }

    nonisolated private static func quickLookFallback(
        url: URL, size: CGFloat, scale: CGFloat
    ) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail)
        guard let cgImage = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request).cgImage
        else { return nil }
        return NSImage(
            cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// An async QuickLook preview with a stable placeholder, so rows do not jump
/// around while the drive catches up.
struct PreviewImage: View {
    let url: URL
    var size: CGFloat = 512
    var contentMode: ContentMode = .fit

    @State private var image: NSImage?
    @State private var didFail = false

    init(url: URL, size: CGFloat = 512, contentMode: ContentMode = .fit) {
        self.url = url
        self.size = size
        self.contentMode = contentMode
        // Start from the cache so navigating back to a pair you have already
        // seen paints instantly instead of flashing a spinner.
        _image = State(initialValue: ThumbnailLoader.shared.cached(url, size: size))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if didFail {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            image = nil
            didFail = false
            let loaded = await ThumbnailLoader.shared.image(for: url, size: size)
            image = loaded
            didFail = loaded == nil
        }
    }
}
