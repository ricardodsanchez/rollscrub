import Foundation
import RollScrubCore

/// Previews read files: a thumbnail decodes the image, the details pane opens
/// the video, the player streams it. On an online-only file each of those
/// downloads the whole thing, and a file that was on this Mac at scan time
/// can be evicted before anyone looks at it. The kernel switch set at launch
/// stops this process downloading, but QuickLook makes thumbnails in a
/// process of its own, so previews ask first.
enum OnlineOnly {
    /// Injectable because a test cannot make a file online-only.
    static var check: (String) -> Bool = CloudPlaceholder.isNotDownloaded

    static func isNotDownloaded(_ url: URL) -> Bool { check(url.path) }
}
