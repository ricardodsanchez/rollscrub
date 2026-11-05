import AVFoundation
import Foundation
import ImageIO

/// The facts worth showing next to a preview when deciding what to keep.
struct FileMetadata {
    var sizeBytes: Int64 = 0
    var pixelSize: CGSize?
    var captured: Date?
    var modified: Date?
    var duration: TimeInterval?

    var dimensionsText: String? {
        guard let pixelSize, pixelSize.width > 0 else { return nil }
        return "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }

    var durationText: String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func load(for url: URL) async -> FileMetadata {
        var meta = FileMetadata()

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        meta.sizeBytes = Int64(values?.fileSize ?? 0)
        meta.modified = values?.contentModificationDate
        // Size and date come from the directory entry; everything else opens
        // the file, which would download an online-only one.
        guard !OnlineOnly.isNotDownloaded(url) else { return meta }

        if MediaKindHelper.isVideo(url) {
            let asset = AVURLAsset(url: url)
            meta.duration = try? await CMTimeGetSeconds(asset.load(.duration))
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                meta.pixelSize = size
            }
            if let date = try? await asset.load(.creationDate),
               let value = try? await date.load(.dateValue) {
                meta.captured = value
            }
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any] {
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            meta.pixelSize = CGSize(width: width, height: height)

            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                meta.captured = formatter.date(from: original)
            }
        }
        return meta
    }
}

enum MediaKindHelper {
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "3gp", "mpg", "mpeg",
        "wmv", "webm", "insv",
    ]
    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
}
