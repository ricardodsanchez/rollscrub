import Foundation
import XCTest

@testable import RollScrubApp

/// Redirects ReviewSession's saved decisions and its Trash into a throwaway
/// directory for the life of one test, and deletes it afterwards.
///
/// Without this a test run leaves `scan-<hash>.json` files in the real
/// `~/Library/Application Support/RollScrub/`, keyed to temp folders that no
/// longer exist, and sends every fixture Apply removes to the developer's
/// own Trash. Nothing breaks, which is what makes it worth guarding: the
/// mess is invisible, permanent, and grows every time the suite runs.
@MainActor
enum ScratchStateDirectory {

    /// Call from `setUp`. Returns the directory so `tearDown` can remove it.
    static func begin(_ label: String = #function) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollScrubState-\(UUID().uuidString)", isDirectory: true)
        ReviewSession.stateDirectoryOverride = url
        let trash = trashDirectory(in: url)
        ReviewSession.trashOverride = { urls in
            var failures: [URL: String] = [:]
            for url in urls {
                do {
                    try FileManager.default.createDirectory(
                        at: trash, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(
                        at: url,
                        to: trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)"))
                } catch {
                    failures[url] = error.localizedDescription
                }
            }
            return failures
        }
        return url
    }

    /// Where Apply's "Trash" puts files during a test.
    static func trashDirectory(in state: URL) -> URL {
        state.appendingPathComponent("Trash", isDirectory: true)
    }

    /// Call from `tearDown`, with whatever `begin()` returned.
    static func end(_ url: URL?) {
        ReviewSession.stateDirectoryOverride = nil
        ReviewSession.trashOverride = nil
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
