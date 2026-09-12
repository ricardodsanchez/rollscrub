import Foundation

/// Whether a file is a photo or a video, decided purely by extension.
/// Anything not in these lists is not media and is never scanned.
public enum MediaKind: String, Sendable {
    case photo
    case video

    static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
    ]

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "3gp", "mpg", "mpeg",
        "wmv", "webm", "insv",
    ]

    public init?(pathExtension: String) {
        let ext = pathExtension.lowercased()
        if MediaKind.photoExtensions.contains(ext) {
            self = .photo
        } else if MediaKind.videoExtensions.contains(ext) {
            self = .video
        } else {
            return nil
        }
    }
}
