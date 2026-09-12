import XCTest

@testable import RollScrubApp
@testable import RollScrubCore

@MainActor
final class ReviewSessionTests: XCTestCase {

    private var root: URL!
    private var reviewDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollScrubReview-\(UUID().uuidString)")
        reviewDir = root.appendingPathComponent(SkipRules.reviewDirectoryName)
        try FileManager.default.createDirectory(at: reviewDir, withIntermediateDirectories: true)
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

    // MARK: - Scanned sources

    /// Builds a folder with `count` duplicate pairs and scans it.
    private func scanFixture(count: Int) throws -> ScanResult {
        for index in 0..<count {
            let payload = String(repeating: "payload\(index)", count: 40_000)
            try write("Photos/original\(index).jpg", payload)
            try write("Copies/original\(index) 2.jpg", payload)
        }
        return DuplicateScanner(config: ScanConfig(root: root)).scan()
    }

    func testScanResultBecomesReviewablePairs() throws {
        let result = try scanFixture(count: 3)
        let session = ReviewSession()
        session.load(scanResult: result, root: root)

        XCTAssertTrue(session.isLoaded)
        XCTAssertEqual(session.items.count, 3)
        XCTAssertEqual(session.undecidedCount, 3)
        // The copy-suffixed name is the one offered up for removal.
        for item in session.items {
            XCTAssertTrue(item.candidateURL.lastPathComponent.contains(" 2"))
            XCTAssertNil(item.originalPath, "a scanned file was never moved anywhere")
        }
    }

    /// The whole premise: scanning and marking must not touch the filesystem.
    func testScanningAndMarkingChangeNothingOnDisk() throws {
        let result = try scanFixture(count: 3)
        let before = try FileManager.default
            .subpathsOfDirectory(atPath: root.path).sorted()

        let session = ReviewSession()
        session.load(scanResult: result, root: root)
        session.markAllPending(as: .discard)

        let after = try FileManager.default
            .subpathsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(before, after, "marking must not move or delete anything")
        XCTAssertEqual(session.resolvedCount, 0, "nothing is resolved until apply runs")
    }

    /// Finding nothing is a clean result, not a failure. It must never raise
    /// the error alert.
    func testCleanScanIsNotAnError() throws {
        try write("Photos/only-one.jpg", String(repeating: "unique", count: 40_000))
        try write("Photos/also-unique.jpg", String(repeating: "different", count: 40_000))
        let result = DuplicateScanner(config: ScanConfig(root: root)).scan()
        XCTAssertTrue(result.groups.isEmpty, "fixture should contain no duplicates")

        let session = ReviewSession()
        session.load(scanResult: result, root: root)

        XCTAssertNil(session.errorMessage, "a clean scan must not report an error")
        XCTAssertTrue(session.isLoaded)
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertEqual(session.scanSummary?.filesScanned, 2)
        XCTAssertEqual(session.scanSummary?.folderName, root.lastPathComponent)
    }

    /// A failure has to be inspectable: reachable through its own filter, and
    /// carrying a reason the user can act on.
    func testFailuresAreReportedWithAReasonAndCanBeRetried() async throws {
        let result = try scanFixture(count: 2)
        let session = ReviewSession()
        session.load(scanResult: result, root: root)
        session.markAllPending(as: .discard)

        // Break one of them so it cannot be removed.
        let doomed = session.items[0]
        try FileManager.default.removeItem(at: doomed.keepURL)
        await session.apply()

        XCTAssertEqual(session.failedCount, 1)
        let failed = try XCTUnwrap(session.item(id: doomed.id))
        XCTAssertNotNil(failed.failureReason, "a failure must explain itself")
        XCTAssertTrue(exists(failed.candidateURL), "a failed file must be left untouched")

        session.filter = .failed
        XCTAssertEqual(session.filtered.count, 1)
        XCTAssertEqual(session.count(for: .failed), 1)

        session.retryFailed()
        XCTAssertEqual(session.failedCount, 0)
        XCTAssertEqual(session.item(id: doomed.id)?.state, .pending)
    }

    func testKeepDecisionLeavesAScannedFileWhereItIs() async throws {
        let result = try scanFixture(count: 1)
        let session = ReviewSession()
        session.load(scanResult: result, root: root)
        let item = session.items[0]
        session.mark(item.id, as: .keep)

        await session.apply()

        XCTAssertTrue(exists(item.candidateURL), "keeping must not move the file")
        XCTAssertTrue(exists(item.keepURL))
        XCTAssertEqual(session.item(id: item.id)?.state, .kept)
    }

    func testApplyRefusesWhenTheKeeperIsGone() async throws {
        let result = try scanFixture(count: 1)
        let session = ReviewSession()
        session.load(scanResult: result, root: root)
        let item = session.items[0]
        session.mark(item.id, as: .discard)

        try FileManager.default.removeItem(at: item.keepURL)
        await session.apply()

        XCTAssertTrue(exists(item.candidateURL), "must not delete the last remaining copy")
        guard case .failed = session.item(id: item.id)?.state else {
            return XCTFail("expected a failure state")
        }
    }

    func testApplyRefusesWhenContentNoLongerMatches() async throws {
        let result = try scanFixture(count: 1)
        let session = ReviewSession()
        session.load(scanResult: result, root: root)
        let item = session.items[0]
        session.mark(item.id, as: .discard)

        try Data("something else entirely".utf8).write(to: item.candidateURL)
        await session.apply()

        XCTAssertTrue(exists(item.candidateURL), "a changed file must not be removed")
        guard case .failed = session.item(id: item.id)?.state else {
            return XCTFail("expected a failure state")
        }
    }

    // MARK: - Manifest sources (older --move runs)

    @discardableResult
    private func makeManifest(count: Int, parkedPresent: Set<Int> = []) throws -> URL {
        var records: [MoveRecord] = []
        for index in 0..<count {
            let kept = root.appendingPathComponent("Photos/kept\(index).jpg")
            let origin = root.appendingPathComponent("Photos/dupe\(index).jpg")
            let parked = reviewDir.appendingPathComponent("Photos/dupe\(index).jpg")
            for url in [kept, parked]
            where parkedPresent.isEmpty || parkedPresent.contains(index) || url == kept {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("payload\(index)".utf8).write(to: url)
            }
            records.append(MoveRecord(
                from: origin.path, to: parked.path, sizeBytes: 100,
                verifiedAgainst: kept.path))
        }
        let manifest = MoveManifest(root: root.path, createdAt: Date(), records: records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = reviewDir.appendingPathComponent("_rollscrub_manifest_test.json")
        try encoder.encode(manifest).write(to: url)
        return url
    }

    func testLoadsEveryPairFromTheManifest() throws {
        let url = try makeManifest(count: 5)
        let session = ReviewSession()
        session.load(manifestURL: url)

        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(session.items.count, 5)
        XCTAssertEqual(session.undecidedCount, 5)
        XCTAssertEqual(session.items[0].keepURL.lastPathComponent, "kept0.jpg")
        XCTAssertNotNil(session.items[0].originalPath, "a parked file remembers where it came from")
    }

    func testFilesAlreadyDealtWithOutsideTheAppAreNotPending() throws {
        let url = try makeManifest(count: 4, parkedPresent: [0, 1])
        let session = ReviewSession()
        session.load(manifestURL: url)

        XCTAssertEqual(session.undecidedCount, 2)
        XCTAssertEqual(session.resolvedCount, 2)
    }

    func testKeepRestoresAParkedFile() async throws {
        let url = try makeManifest(count: 1)
        let session = ReviewSession()
        session.load(manifestURL: url)
        let item = session.items[0]
        session.mark(item.id, as: .keep)

        await session.apply()

        XCTAssertTrue(exists(URL(fileURLWithPath: item.originalPath!)))
        XCTAssertEqual(session.item(id: item.id)?.state, .restored)
    }

    func testFindsNewestManifestFromDriveRoot() throws {
        _ = try makeManifest(count: 2)
        let session = ReviewSession()
        session.loadManifest(inRoot: root)
        XCTAssertEqual(session.items.count, 2)
    }

    func testReportsMissingManifestClearly() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("Empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let session = ReviewSession()
        session.loadManifest(inRoot: empty)
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertNotNil(session.errorMessage)
    }

    // MARK: - Queue behaviour

    func testMarkingMovesThroughTheQueue() throws {
        let url = try makeManifest(count: 3)
        let session = ReviewSession()
        session.load(manifestURL: url)
        session.selection = session.filtered.first?.id

        session.markSelectionAndAdvance(.discard)
        XCTAssertEqual(session.markedForDiscard.count, 1)
        XCTAssertNotNil(session.selection)

        session.markSelectionAndAdvance(.keep)
        XCTAssertEqual(session.markedForKeep.count, 1)
        XCTAssertEqual(session.undecidedCount, 1)
    }

    func testFilterCountsMatchTheLists() throws {
        let url = try makeManifest(count: 4)
        let session = ReviewSession()
        session.load(manifestURL: url)
        session.mark(session.items[0].id, as: .discard)
        session.mark(session.items[1].id, as: .keep)

        XCTAssertEqual(session.count(for: .pending), 2)
        XCTAssertEqual(session.count(for: .discard), 1)
        XCTAssertEqual(session.count(for: .keep), 1)
        XCTAssertEqual(session.count(for: .all), 4)

        for filter in ReviewSession.Filter.allCases {
            session.filter = filter
            XCTAssertEqual(
                session.filtered.count, session.count(for: filter),
                "count disagrees with the list for \(filter.rawValue)")
        }
    }

    func testReclaimableReflectsOnlyWhatIsMarkedForRemoval() throws {
        let url = try makeManifest(count: 4)
        let session = ReviewSession()
        session.load(manifestURL: url)

        XCTAssertEqual(session.reclaimableBytes, 0)
        session.mark(session.items[0].id, as: .discard)
        session.mark(session.items[1].id, as: .discard)
        session.mark(session.items[2].id, as: .keep)
        XCTAssertEqual(session.reclaimableBytes, 200)
    }

    func testDecisionsSurviveReopening() throws {
        let url = try makeManifest(count: 3)
        let first = ReviewSession()
        first.load(manifestURL: url)
        first.mark(first.items[0].id, as: .discard)
        first.mark(first.items[1].id, as: .keep)

        let second = ReviewSession()
        second.load(manifestURL: url)

        XCTAssertEqual(second.markedForDiscard.count, 1)
        XCTAssertEqual(second.markedForKeep.count, 1)
        XCTAssertEqual(second.undecidedCount, 1)
    }
}
