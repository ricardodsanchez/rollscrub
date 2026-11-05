import Darwin
import XCTest

@testable import RollScrubCore

final class CloudPlaceholderTests: XCTestCase {

    /// The kernel switch is what turns a check RollScrub forgot into a failed
    /// read instead of a download of the whole file. If it silently stops
    /// being set, nothing else notices until someone's data plan does.
    func testRefusingDownloadsSetsTheKernelPolicyForTheProcess() {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let before = getiopolicy_np(type, IOPOL_SCOPE_PROCESS)
        defer { _ = setiopolicy_np(type, IOPOL_SCOPE_PROCESS, before) }

        XCTAssertTrue(CloudPlaceholder.refuseDownloadsForThisProcess())
        XCTAssertEqual(getiopolicy_np(type, IOPOL_SCOPE_PROCESS),
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    /// An undo manifest in an iCloud folder can be evicted like any file.
    /// With the process refusing downloads, reading it would fail and block
    /// undo, so manifests are read with downloads allowed on that thread
    /// alone. The process-wide refusal must still be in force afterwards.
    func testAllowingDownloadsLiftsTheRefusalForOneReadOnly() throws {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let processBefore = getiopolicy_np(type, IOPOL_SCOPE_PROCESS)
        let threadBefore = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        defer { _ = setiopolicy_np(type, IOPOL_SCOPE_PROCESS, processBefore) }
        CloudPlaceholder.refuseDownloadsForThisProcess()

        let inside = CloudPlaceholder.allowingDownloads { getiopolicy_np(type, IOPOL_SCOPE_THREAD) }

        XCTAssertEqual(inside, IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        XCTAssertEqual(getiopolicy_np(type, IOPOL_SCOPE_THREAD), threadBefore,
                       "the thread must go back to what it was")
        XCTAssertEqual(getiopolicy_np(type, IOPOL_SCOPE_PROCESS),
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF, "the process refusal stays")
    }

    /// The real lookups, against a real online-only file. A test cannot make
    /// one, so it is opt-in: point ROLLSCRUB_DATALESS_FILE at a small file
    /// that iCloud, Dropbox or OneDrive keeps online only (`ls -lO` shows
    /// "dataless"). Small, because a broken check downloads it. The kernel
    /// switch is set to allow downloads for the duration, so this tests the
    /// checks themselves and not the backstop behind them.
    func testRecognisesARealOnlineOnlyFileWithoutDownloadingIt() throws {
        guard let path = ProcessInfo.processInfo.environment["ROLLSCRUB_DATALESS_FILE"] else {
            throw XCTSkip("set ROLLSCRUB_DATALESS_FILE to a small online-only file")
        }
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let before = getiopolicy_np(type, IOPOL_SCOPE_PROCESS)
        _ = setiopolicy_np(type, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        defer { _ = setiopolicy_np(type, IOPOL_SCOPE_PROCESS, before) }

        XCTAssertTrue(CloudPlaceholder.isNotDownloaded(path), "the flag lookup must see it")

        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollScrubDatalessLink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertTrue(CloudPlaceholder.isNotDownloaded(link.path),
                      "a link is read through, so it is checked through")

        let size = Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size]
            as? NSNumber)?.int64Value ?? 1)
        XCTAssertNil(ContentSignature.compute(path: path, size: size),
                     "hashing must refuse an online-only file")
        XCTAssertFalse(ContentSignature.verifyIdentical(link.path, path),
                       "comparing must refuse it too")

        XCTAssertTrue(CloudPlaceholder.isNotDownloaded(path),
                      "the file must still be online-only afterwards")
    }
}
