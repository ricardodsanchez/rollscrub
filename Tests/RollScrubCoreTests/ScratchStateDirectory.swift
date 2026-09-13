import Foundation
import XCTest

@testable import RollScrubApp

/// Redirects ReviewSession's saved decisions into a throwaway directory for
/// the life of one test, and deletes it afterwards.
///
/// Without this a test run leaves `scan-<hash>.json` files in the real
/// `~/Library/Application Support/RollScrub/`, keyed to temp folders that no
/// longer exist. Nothing breaks, which is what makes it worth guarding: the
/// mess is invisible, permanent, and grows every time the suite runs on a
/// developer's own Mac.
@MainActor
enum ScratchStateDirectory {

    /// Call from `setUp`. Returns the directory so `tearDown` can remove it.
    static func begin(_ label: String = #function) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollScrubState-\(UUID().uuidString)", isDirectory: true)
        ReviewSession.stateDirectoryOverride = url
        return url
    }

    /// Call from `tearDown`, with whatever `begin()` returned.
    static func end(_ url: URL?) {
        ReviewSession.stateDirectoryOverride = nil
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
