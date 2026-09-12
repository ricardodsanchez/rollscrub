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
