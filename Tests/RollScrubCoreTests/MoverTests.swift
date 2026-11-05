import XCTest

@testable import RollScrubCore

final class MoverTests: XCTestCase {

    private var root: URL!
    private var reviewDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollScrubMove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reviewDir = root.appendingPathComponent(SkipRules.reviewDirectoryName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relativePath: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func group(keep: URL, remove: [URL], size: Int64 = 12) -> DuplicateGroup {
        DuplicateGroup(kind: .photo, size: size, keep: keep.path, remove: remove.map(\.path))
    }

    /// A root reached through a symlink — /tmp and /var both are on macOS.
    /// Enumeration reports files at their resolved paths, so a root kept
    /// unresolved matches none of them and every file is skipped as "outside
    /// every scan root": `--move` reports success having moved nothing.
    func testMovesFilesWhenTheRootIsReachedThroughASymlink() throws {
        let keep = try write("Photos/keep.jpg", "same bytes")
        let dupe = try write("Photos/keep copy.jpg", "same bytes")

        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollScrubLink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }

        let outcome = try Mover(root: link).move(groups: [group(keep: keep, remove: [dupe])])

        XCTAssertEqual(outcome.skipped.count, 0,
                       "a symlinked root must not put every file outside itself")
        XCTAssertEqual(outcome.moved.count, 1)
        XCTAssertFalse(exists(dupe), "the duplicate should have been set aside")
        XCTAssertTrue(exists(keep))
    }

    // MARK: - The happy path

    func testMovesRedundantCopyAndPreservesStructure() throws {
        let keep = try write("Photos/2024/a.jpg", "identical")
        let dupe = try write("Photos/2025/a copy.jpg", "identical")

        let outcome = try Mover(root: root).move(groups: [group(keep: keep, remove: [dupe])])

        XCTAssertEqual(outcome.moved.count, 1)
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertTrue(exists(keep), "the surviving file must stay put")
        XCTAssertFalse(exists(dupe))
        // Original folder structure is mirrored under the review directory.
        XCTAssertTrue(exists(reviewDir.appendingPathComponent("Photos/2025/a copy.jpg")))
    }

    func testNothingIsEverDeleted() throws {
        let keep = try write("A/keep.jpg", "same")
        let dupe = try write("A/dupe.jpg", "same")

        _ = try Mover(root: root).move(groups: [group(keep: keep, remove: [dupe])])

        // Both files still exist on disk; one simply lives somewhere else now.
        XCTAssertTrue(exists(keep))
        XCTAssertTrue(exists(reviewDir.appendingPathComponent("A/dupe.jpg")))
    }

    // MARK: - Refusals

    func testRefusesToMoveWhenContentNoLongerMatches() throws {
        let keep = try write("A/keep.jpg", "original")
        let dupe = try write("A/dupe.jpg", "CHANGED SINCE THE SCAN")

        let outcome = try Mover(root: root).move(groups: [group(keep: keep, remove: [dupe])])

        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertTrue(outcome.skipped[0].reason.contains("byte-identical"))
        XCTAssertTrue(exists(dupe), "a file that failed verification must not be touched")
    }

    func testRefusesToMoveWhenTheKeepFileIsGone() throws {
        let keep = root.appendingPathComponent("A/vanished.jpg")
        let dupe = try write("A/dupe.jpg", "content")

        let outcome = try Mover(root: root).move(groups: [group(keep: keep, remove: [dupe])])

        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertTrue(outcome.skipped[0].reason.contains("missing"))
        XCTAssertTrue(exists(dupe), "never strand a file whose counterpart is gone")
    }

    func testNeverOverwritesAnExistingFileInTheReviewFolder() throws {
        // A previous run already parked a different file at the same relative path.
        let occupied = reviewDir.appendingPathComponent("A/dupe.jpg")
        try FileManager.default.createDirectory(
            at: occupied.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("PRIOR RUN — MUST SURVIVE".utf8).write(to: occupied)

        let keep = try write("A/keep.jpg", "same")
        let dupe = try write("A/dupe.jpg", "same")

        let outcome = try Mover(root: root).move(groups: [group(keep: keep, remove: [dupe])])

        XCTAssertEqual(outcome.moved.count, 1)
        XCTAssertEqual(
            try String(contentsOf: occupied, encoding: .utf8), "PRIOR RUN — MUST SURVIVE")
        XCTAssertTrue(exists(reviewDir.appendingPathComponent("A/dupe (2).jpg")))
    }

    func testPartialFailureStillMovesTheRest() throws {
        let keepA = try write("A/keepA.jpg", "aaa")
        let dupeA = try write("A/dupeA.jpg", "aaa")
        let keepB = try write("B/keepB.jpg", "bbb")
        let dupeB = try write("B/dupeB.jpg", "DIFFERENT")

        let outcome = try Mover(root: root).move(groups: [
            group(keep: keepA, remove: [dupeA]),
            group(keep: keepB, remove: [dupeB]),
        ])

        XCTAssertEqual(outcome.moved.count, 1)
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertFalse(exists(dupeA))
        XCTAssertTrue(exists(dupeB))
    }

    // MARK: - Drives

    /// A Mover that believes everything under `otherDrive` is a second
    /// volume. Paths reach the lookup already resolved, the way the real
    /// lookup sees them, so prefixes are compared in the same namespace.
    private func mover(otherDrive: URL) -> Mover {
        let other = otherDrive.resolvingSymlinksInPath().path
        return Mover(
            roots: [root],
            volumeOf: { url in
                url.path == other || url.path.hasPrefix(other + "/") ? "drive B" : "drive A"
            },
            isNotDownloaded: { _ in false })
    }

    /// `rollscrub /Volumes --move`, or a scan of a folder holding a mounted
    /// disk image: the duplicate is on one drive and the root's review folder
    /// on another. Moving it there is a copy onto that drive and a delete
    /// from its own, and an eject later strands it on the wrong disk.
    func testRefusesToMoveAFileOntoADifferentDrive() throws {
        let keep = try write("keep.jpg", "same bytes")
        let local = try write("Photos/keep copy.jpg", "same bytes")
        let mounted = root.appendingPathComponent("Mounted")
        let remote = try write("Mounted/DCIM/keep.jpg", "same bytes")

        let outcome = try mover(otherDrive: mounted)
            .move(groups: [group(keep: keep, remove: [local, remote])])

        XCTAssertEqual(outcome.moved.map(\.from), [local.path],
                       "the copy on the root's own drive should still be set aside")
        XCTAssertEqual(outcome.skipped.map(\.path), [remote.path])
        XCTAssertTrue(outcome.skipped.first?.reason.contains("different drive") == true,
                      outcome.skipped.first?.reason ?? "nothing was skipped")
        XCTAssertTrue(exists(remote), "a file must never leave the drive it was found on")
        XCTAssertFalse(exists(reviewDir.appendingPathComponent("Mounted/DCIM/keep.jpg")))
    }

    /// A review folder left behind as a link to another drive sends every
    /// move through the link and onto that drive. Looking up the link's own
    /// volume instead of where it points would wave all of them through.
    func testRefusesToMoveThroughAReviewFolderThatLinksToAnotherDrive() throws {
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollScrubElsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: reviewDir, withDestinationURL: elsewhere)

        let keep = try write("A/keep.jpg", "same")
        let dupe = try write("A/dupe.jpg", "same")

        let outcome = try mover(otherDrive: elsewhere)
            .move(groups: [group(keep: keep, remove: [dupe])])

        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertTrue(outcome.skipped.first?.reason.contains("different drive") == true,
                      outcome.skipped.first?.reason ?? "nothing was skipped")
        XCTAssertTrue(exists(dupe))
        XCTAssertFalse(exists(elsewhere.appendingPathComponent("A/dupe.jpg")))
    }

    /// If the drive cannot be identified, a move might be a copy and delete
    /// across drives. Not knowing is a reason to leave the file alone.
    func testRefusesToMoveWhenTheDriveCannotBeIdentified() throws {
        let keep = try write("A/keep.jpg", "same")
        let dupe = try write("A/dupe.jpg", "same")

        let outcome = try Mover(
            roots: [root], volumeOf: { _ in nil }, isNotDownloaded: { _ in false }
        ).move(groups: [group(keep: keep, remove: [dupe])])

        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertTrue(outcome.skipped.first?.reason.contains("same drive") == true,
                      outcome.skipped.first?.reason ?? "nothing was skipped")
        XCTAssertTrue(exists(dupe))
    }

    // MARK: - iCloud

    /// A file iCloud evicted after the scan still has a name and a size, and
    /// the byte-for-byte check reads all of it, which downloads all of it:
    /// gigabytes over the network as a side effect of tidying up. Either side
    /// of the pair being evicted means neither is read.
    ///
    /// The pairs differ on purpose. If the comparison ran before the iCloud
    /// check, it would have read the file and refused it as changed, and the
    /// reason would say so instead of naming iCloud.
    func testWillNotReadAFileICloudHasNotDownloaded() throws {
        let keepA = try write("A/keep.jpg", "same")
        let evictedDupe = try write("A/dupe.jpg", "placeholder")
        let evictedKeep = try write("B/keep.jpg", "placeholder")
        let dupeB = try write("B/dupe.jpg", "other")
        let evicted: Set<String> = [evictedDupe.path, evictedKeep.path]

        let outcome = try Mover(
            roots: [root], volumeOf: { _ in "one drive" },
            isNotDownloaded: { evicted.contains($0) }
        ).move(groups: [
            group(keep: keepA, remove: [evictedDupe]),
            group(keep: evictedKeep, remove: [dupeB]),
        ])

        XCTAssertTrue(outcome.moved.isEmpty, "an evicted file on either side must stop the move")
        XCTAssertEqual(outcome.skipped.count, 2)
        for skip in outcome.skipped {
            XCTAssertTrue(skip.reason.contains("iCloud"), skip.reason)
        }
        XCTAssertTrue(exists(evictedDupe))
        XCTAssertTrue(exists(dupeB))
    }

    /// The rule behind the check. An exFAT card or a disk image answers nil
    /// for "is this in iCloud", and reading nil as evicted would refuse every
    /// move on every external drive. An iCloud file whose status is missing,
    /// or downloaded but stale, is not safe to read.
    func testOnlyAFileICloudClaimsAndHasNotFullyDownloadedCountsAsEvicted() {
        XCTAssertFalse(ICloudPlaceholder.isNotDownloaded(isUbiquitous: nil, status: nil),
                       "a drive iCloud knows nothing about is not evicted")
        XCTAssertFalse(ICloudPlaceholder.isNotDownloaded(isUbiquitous: false, status: nil))
        XCTAssertFalse(ICloudPlaceholder.isNotDownloaded(isUbiquitous: true, status: .current))
        XCTAssertTrue(ICloudPlaceholder.isNotDownloaded(isUbiquitous: true, status: .notDownloaded))
        XCTAssertTrue(ICloudPlaceholder.isNotDownloaded(isUbiquitous: true, status: .downloaded),
                      "an out-of-date local copy is fetched again when read")
        XCTAssertTrue(ICloudPlaceholder.isNotDownloaded(isUbiquitous: true, status: nil),
                      "an iCloud file whose status is unknown must not be read")
    }

    // MARK: - Undo

    func testUndoRestoresEveryFile() throws {
        let keep = try write("Photos/2024/a.jpg", "identical")
        let dupe = try write("Photos/2025/a copy.jpg", "identical")
        let dupePath = dupe.path

        let outcome = try Mover(root: root).move(groups: [group(keep: keep, remove: [dupe])])
        let manifest = try XCTUnwrap(outcome.manifestURL)
        XCTAssertFalse(exists(dupe))

        let undo = try Mover.undo(manifestURL: manifest)

        XCTAssertEqual(undo.restored, 1)
        XCTAssertTrue(undo.skipped.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dupePath))
        XCTAssertEqual(try String(contentsOf: dupe, encoding: .utf8), "identical")
    }

    func testUndoWillNotClobberSomethingBackAtTheOriginalPath() throws {
        let keep = try write("A/keep.jpg", "same")
        let dupe = try write("A/dupe.jpg", "same")

        let outcome = try Mover(root: root).move(groups: [group(keep: keep, remove: [dupe])])
        let manifest = try XCTUnwrap(outcome.manifestURL)

        // Something new appears at the original location before the undo runs.
        try Data("NEW FILE".utf8).write(to: dupe)

        let undo = try Mover.undo(manifestURL: manifest)

        XCTAssertEqual(undo.restored, 0)
        XCTAssertEqual(undo.skipped.count, 1)
        XCTAssertEqual(try String(contentsOf: dupe, encoding: .utf8), "NEW FILE")
        XCTAssertTrue(exists(reviewDir.appendingPathComponent("A/dupe.jpg")))
    }

    func testManifestRecordsWhatItVerifiedAgainst() throws {
        let keep = try write("A/keep.jpg", "same")
        let dupe = try write("A/dupe.jpg", "same")

        let outcome = try Mover(root: root).move(groups: [group(keep: keep, remove: [dupe])])
        let record = try XCTUnwrap(outcome.moved.first)

        XCTAssertEqual(record.from, dupe.path)
        XCTAssertEqual(record.verifiedAgainst, keep.path)
    }

    // MARK: - Re-scanning after a move

    func testReviewFolderIsExcludedFromLaterScans() throws {
        let keep = try write("A/keep.jpg", "same")
        let dupe = try write("A/dupe.jpg", "same")
        _ = try Mover(root: root).move(groups: [group(keep: keep, remove: [dupe])])

        // The parked copy must not be re-paired with the original still in place.
        let result = DuplicateScanner(config: ScanConfig(root: root)).scan()

        XCTAssertEqual(result.filesScanned, 1)
        XCTAssertTrue(result.groups.isEmpty)
    }
}
