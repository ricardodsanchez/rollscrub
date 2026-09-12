import XCTest

@testable import RollScrubCore

final class ScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollScrubTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ relativePath: String, bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    /// Deterministic pseudo-random payload, big enough to exercise head+tail hashing.
    private func payload(seed: UInt8, count: Int) -> Data {
        var data = Data(count: count)
        for index in 0..<count {
            data[index] = UInt8((Int(seed) &+ index &* 31) % 251)
        }
        return data
    }

    private func scan() -> ScanResult {
        DuplicateScanner(config: ScanConfig(root: root)).scan()
    }

    // MARK: - (a) byte-identical files are flagged

    func testIdenticalFilesFormOneGroup() throws {
        let bytes = payload(seed: 7, count: 400_000)
        try write("A/IMG_0001.jpg", bytes: bytes)
        try write("B/IMG_0001 2.jpg", bytes: bytes)

        let result = scan()

        XCTAssertEqual(result.filesScanned, 2)
        XCTAssertEqual(result.groups.count, 1)
        let group = try XCTUnwrap(result.groups.first)
        XCTAssertEqual(group.count, 2)
        XCTAssertEqual(group.kind, .photo)
        XCTAssertEqual(group.size, 400_000)
        XCTAssertEqual(group.reclaimableBytes, 400_000)
        // "IMG_0001 2.jpg" looks like a copy, so the clean name is kept.
        XCTAssertEqual((group.keep as NSString).lastPathComponent, "IMG_0001.jpg")
        XCTAssertEqual(group.remove.count, 1)
    }

    // MARK: - (b) same size, different content is NOT flagged

    func testSameSizeDifferentContentIsNotFlagged() throws {
        try write("A/one.jpg", bytes: payload(seed: 1, count: 400_000))
        try write("A/two.jpg", bytes: payload(seed: 2, count: 400_000))

        let result = scan()

        XCTAssertEqual(result.filesScanned, 2)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.reclaimableBytes, 0)
    }

    func testSameSizeDifferentContentBelowWholeFileThresholdIsNotFlagged() throws {
        // Under 256 KB the whole file is hashed, so any difference is caught.
        try write("A/small-one.jpg", bytes: payload(seed: 3, count: 200_000))
        try write("A/small-two.jpg", bytes: payload(seed: 4, count: 200_000))

        XCTAssertTrue(scan().groups.isEmpty)
    }

    /// The case the head+tail signature cannot see: identical size, identical
    /// first and last 128 KB, one differing byte in the middle. The mandatory
    /// verification pass must reject it.
    func testMiddleOnlyDifferenceIsRejectedByVerification() throws {
        let a = payload(seed: 9, count: 600_000)
        var b = a
        b[300_000] = a[300_000] &+ 1
        let urlA = try write("A/mid-a.jpg", bytes: a)
        let urlB = try write("A/mid-b.jpg", bytes: b)

        // Precondition: the cheap signature really does collide here.
        XCTAssertEqual(
            ContentSignature.compute(path: urlA.path, size: 600_000),
            ContentSignature.compute(path: urlB.path, size: 600_000),
            "test is meaningless unless the signature collides")

        let result = scan()
        XCTAssertTrue(result.groups.isEmpty, "verification must reject a middle-only difference")
        XCTAssertEqual(result.filesRejectedByVerification, 2)
    }

    /// A cluster of three where only two match must yield a group of two,
    /// not a group of three and not nothing.
    func testPartialClusterIsSplitNotDiscarded() throws {
        let a = payload(seed: 13, count: 600_000)
        var odd = a
        odd[300_000] = a[300_000] &+ 1
        try write("A/real-one.jpg", bytes: a)
        try write("A/real-two.jpg", bytes: a)
        try write("A/imposter.jpg", bytes: odd)

        let result = scan()

        XCTAssertEqual(result.groups.count, 1)
        let group = try XCTUnwrap(result.groups.first)
        XCTAssertEqual(group.count, 2)
        XCTAssertFalse(
            group.allPaths.contains { $0.hasSuffix("imposter.jpg") },
            "the odd file out must not appear in the group")
        XCTAssertEqual(result.filesRejectedByVerification, 1)
    }

    func testVerificationLeavesGenuineDuplicatesIntact() throws {
        let bytes = payload(seed: 14, count: 900_000)
        try write("A/orig.jpg", bytes: bytes)
        try write("B/orig 2.jpg", bytes: bytes)
        try write("C/orig 3.jpg", bytes: bytes)

        let result = scan()

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].count, 3)
        XCTAssertEqual(result.filesRejectedByVerification, 0)
    }

    // MARK: - (c) skip rules

    func testAppleDoubleFilesAreSkipped() throws {
        let bytes = payload(seed: 5, count: 300_000)
        try write("A/photo.jpg", bytes: bytes)
        try write("A/._photo.jpg", bytes: bytes)

        let result = scan()

        XCTAssertEqual(result.filesScanned, 1)
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testFinalCutBundleContentsAreSkipped() throws {
        let bytes = payload(seed: 6, count: 300_000)
        try write("Video/clip.mov", bytes: bytes)
        try write("FCP/Project.fcpbundle/Media/clip.mov", bytes: bytes)
        try write("FCP/Project.fcpbundle/Media/Nested/clip.mov", bytes: bytes)

        let result = scan()

        XCTAssertEqual(result.filesScanned, 1, "nothing inside a .fcpbundle may be scanned")
        XCTAssertTrue(result.groups.isEmpty)
    }

    /// Photos keeps originals and its own derivatives inside the package and
    /// tracks them in a database. Sweeping in there offers up files Photos is
    /// relying on, and removing them corrupts the library — the same reason
    /// Final Cut bundles are left alone.
    func testManagedPhotoLibrariesAreSkipped() throws {
        let bytes = payload(seed: 21, count: 300_000)
        try write("Loose/holiday.jpg", bytes: bytes)
        try write("Photos Library.photoslibrary/originals/0/holiday.jpg", bytes: bytes)
        try write("Photos Library.photoslibrary/resources/derivatives/holiday.jpg", bytes: bytes)
        try write("Old.aplibrary/Masters/holiday.jpg", bytes: bytes)
        try write("Lightroom Library.lrlibrary/originals/2024/holiday.jpg", bytes: bytes)

        let result = scan()

        XCTAssertEqual(result.filesScanned, 1,
                       "nothing inside a managed photo library may be scanned")
        XCTAssertTrue(result.groups.isEmpty,
                      "a managed library's own copies are not duplicates to remove")
    }

    func testZeroByteFilesAreSkipped() throws {
        try write("A/empty-one.jpg", bytes: Data())
        try write("A/empty-two.jpg", bytes: Data())

        let result = scan()

        XCTAssertEqual(result.filesScanned, 0)
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testSystemDirectoriesAreSkipped() throws {
        let bytes = payload(seed: 8, count: 300_000)
        try write("Photos/keep.jpg", bytes: bytes)
        try write(".Spotlight-V100/keep.jpg", bytes: bytes)
        try write(".Trashes/keep.jpg", bytes: bytes)

        XCTAssertEqual(scan().filesScanned, 1)
    }

    func testNonMediaFilesAreIgnored() throws {
        let bytes = payload(seed: 10, count: 300_000)
        try write("A/notes.txt", bytes: bytes)
        try write("A/archive.zip", bytes: bytes)

        let result = scan()
        XCTAssertEqual(result.filesScanned, 0)
        XCTAssertTrue(result.groups.isEmpty)
    }

    // MARK: - includes

    func testIncludesLimitTheScan() throws {
        let bytes = payload(seed: 11, count: 300_000)
        try write("Photos/a.jpg", bytes: bytes)
        try write("Photos/b.jpg", bytes: bytes)
        try write("Other/c.jpg", bytes: bytes)

        let config = ScanConfig(root: root, includes: ["Photos"])
        let result = DuplicateScanner(config: config).scan()

        XCTAssertEqual(result.filesScanned, 2)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].count, 2)
    }

    // MARK: - grouping arithmetic

    func testThreeCopiesReclaimTwiceTheSize() throws {
        let bytes = payload(seed: 12, count: 500_000)
        try write("A/C7794.mp4", bytes: bytes)
        try write("A/trip 2.mp4", bytes: bytes)
        try write("A/trip 3.mp4", bytes: bytes)

        let result = scan()
        let group = try XCTUnwrap(result.groups.first)

        XCTAssertEqual(group.kind, .video)
        XCTAssertEqual(group.count, 3)
        XCTAssertEqual(result.redundantFileCount, 2)
        XCTAssertEqual(group.reclaimableBytes, 1_000_000)
        XCTAssertEqual((group.keep as NSString).lastPathComponent, "C7794.mp4")
    }
}
