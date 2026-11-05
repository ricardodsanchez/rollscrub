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

    /// The same corruption, for every other app that keeps media in a package
    /// it catalogues. An iPhoto library is still on disk after Photos migrates
    /// it, holding the same masters as the new library, so a home-folder scan
    /// pairs the two and offers one of them up for removal.
    func testEveryKindOfManagedLibraryIsSkipped() throws {
        let bytes = payload(seed: 46, count: 300_000)
        try write("Loose/clip.mov", bytes: bytes)
        let libraries = [
            "iPhoto Library.photolibrary/Masters/2012/clip.mov",
            "iMovie Library.imovielibrary/Event/Original Media/clip.mov",
            "iMovie Theater.theater/Shared/clip.mov",
            "Capture One.cocatalog/Originals/clip.mov",
            "TV Library.tvlibrary/Media/clip.mov",
            "Music Library.musiclibrary/Media/clip.mov",
        ]
        for path in libraries { try write(path, bytes: bytes) }

        let result = scan()

        XCTAssertEqual(result.filesScanned, 1,
                       "only the loose clip is outside a library; found \(result.filesScanned)")
        XCTAssertTrue(result.groups.isEmpty)
    }

    /// A Dropbox or OneDrive folder full of online-only photos still lists
    /// every name and size. Hashing them would download the lot, so each is
    /// counted in the report and left out. The lookup is the slow part in an
    /// iCloud folder, so it must only be asked about files that already look
    /// like media: asking it of every entry made a Documents scan take
    /// minutes.
    func testCountsAndSkipsAFileThatIsOnlyInTheCloud() throws {
        let bytes = payload(seed: 47, count: 300_000)
        let local = try write("Dropbox/beach.jpg", bytes: bytes)
        let online = try write("Dropbox/beach copy.jpg", bytes: bytes)
        try write("Dropbox/notes.txt", bytes: bytes)
        var asked: [String] = []

        let result = DuplicateScanner(config: ScanConfig(root: root), isNotDownloaded: { path in
            asked.append((path as NSString).lastPathComponent)
            // The walk reports /private/var/..., the fixture says /var/...
            return (path as NSString).lastPathComponent == online.lastPathComponent
        }).scan()

        XCTAssertEqual(result.notDownloadedFiles, 1, "the online-only file must be counted")
        XCTAssertEqual(result.filesScanned, 1)
        XCTAssertTrue(result.groups.isEmpty, "an online-only file must not be read to pair it")
        XCTAssertEqual(Set(asked), [local.lastPathComponent, online.lastPathComponent],
                       "only media files may cost a cloud lookup")
    }

    /// Music and TV keep their media beside the library package, not in it,
    /// and find each file by its path. A home-folder scan pairs a music video
    /// in there with the copy you downloaded, and moving the Music one leaves
    /// a track that says it cannot be found. A Media folder of your own, with
    /// no library beside it, must still be scanned.
    func testMusicTVAndITunesMediaFoldersAreSkipped() throws {
        let bytes = payload(seed: 48, count: 300_000)
        try write("Downloads/video.mov", bytes: bytes)
        try write("Music/Music/Music Library.musiclibrary/Library.musicdb", bytes: Data("db".utf8))
        try write("Music/Music/Media.localized/Music Videos/video.mov", bytes: bytes)
        try write("Movies/TV/TV Library.tvlibrary/Library.tvdb", bytes: Data("db".utf8))
        try write("Movies/TV/Media.localized/Home Videos/video.mov", bytes: bytes)
        try write("Music/iTunes/iTunes Library.itl", bytes: Data("itl".utf8))
        try write("Music/iTunes/iTunes Media/Movies/video.mov", bytes: bytes)
        try write("Projects/Site/Media/video.mov", bytes: bytes)

        let result = scan()

        XCTAssertEqual(result.filesScanned, 2,
                       "only Downloads and the ordinary Media folder are scanned")
        XCTAssertEqual(Set(result.groups.flatMap(\.allPaths).map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent
        }), ["Downloads", "Media"])
    }

    /// Pruning only happens to directories met on the way down, so a library
    /// handed over as the root itself was walked in full. Photos keeps an
    /// original and its derivative byte-identical in there, and `--move` then
    /// took one of them out, corrupting the library without a word.
    func testWillNotWalkALibraryGivenAsTheScanRoot() throws {
        let bytes = payload(seed: 41, count: 300_000)
        let library = root.appendingPathComponent("Photos Library.photoslibrary")
        try write("Photos Library.photoslibrary/originals/0/holiday.jpg", bytes: bytes)
        try write("Photos Library.photoslibrary/resources/derivatives/holiday.jpg", bytes: bytes)

        let result = DuplicateScanner(config: ScanConfig(root: library)).scan()

        XCTAssertEqual(result.filesScanned, 0, "a library passed as the root must not be walked")
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.managedLibraryRoots, [library],
                       "the report must say what was refused, not show a clean result")
    }

    /// `rollscrub ~/Pictures --include "Photos Library.photoslibrary/originals"`
    /// starts the walk inside the library, below the one directory the prune
    /// would have caught. The other includes must still be scanned: refusing
    /// one root is not a reason to drop the rest. The suffix is upper case
    /// because Finder treats it as the same package either way.
    func testWillNotWalkAnIncludeThatReachesIntoALibrary() throws {
        let bytes = payload(seed: 42, count: 300_000)
        try write("Loose/holiday.jpg", bytes: payload(seed: 43, count: 300_000))
        try write("Old.APLIBRARY/Masters/2019/holiday.jpg", bytes: bytes)
        try write("Old.APLIBRARY/Masters/2020/holiday.jpg", bytes: bytes)

        let result = DuplicateScanner(config: ScanConfig(
            root: root, includes: ["Old.APLIBRARY/Masters", "Loose"])).scan()

        XCTAssertEqual(result.filesScanned, 1, "only the include outside the library is walked")
        XCTAssertTrue(result.groups.isEmpty,
                      "two masters inside an Aperture library are not duplicates to remove")
        XCTAssertEqual(result.managedLibraryRoots.map(\.lastPathComponent), ["Masters"])
    }

    /// The system follows a symlink in the middle of a path, so a root of
    /// `Linked/originals`, where Linked points at a library, walks the
    /// library's originals although no part of the path as typed names one.
    func testWillNotWalkARootThatReachesALibraryThroughASymlink() throws {
        let bytes = payload(seed: 44, count: 300_000)
        try write("Photos Library.photoslibrary/originals/0/holiday.jpg", bytes: bytes)
        try write("Photos Library.photoslibrary/originals/1/holiday.jpg", bytes: bytes)
        let link = root.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appendingPathComponent("Photos Library.photoslibrary"))

        let result = DuplicateScanner(config: ScanConfig(
            root: link.appendingPathComponent("originals"))).scan()

        XCTAssertEqual(result.filesScanned, 0, "a link into a library leads into a library")
        XCTAssertTrue(result.groups.isEmpty)
    }

    /// `..` after a symlink goes up from wherever the link led, not from the
    /// link. `--include "Linked/.."`, with Linked pointing at a library's
    /// originals, walks the library itself, while the same path tidied up as
    /// text reads as the harmless folder holding the link.
    func testWillNotWalkAnIncludeThatClimbsIntoALibraryFromInsideIt() throws {
        let bytes = payload(seed: 45, count: 300_000)
        try write("Photos Library.photoslibrary/originals/0/holiday.jpg", bytes: bytes)
        try write("Photos Library.photoslibrary/resources/holiday.jpg", bytes: bytes)
        let outer = root.appendingPathComponent("Outer")
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: outer.appendingPathComponent("Linked"),
            withDestinationURL: root.appendingPathComponent("Photos Library.photoslibrary/originals"))

        let result = DuplicateScanner(config: ScanConfig(root: outer, includes: ["Linked/.."])).scan()

        XCTAssertEqual(result.filesScanned, 0, "Linked/.. is the library, whatever the text says")
        XCTAssertTrue(result.groups.isEmpty)
    }

    /// A home folder with a few checked-out projects in it holds far more
    /// files under .git, .build and node_modules than everywhere else put
    /// together, and none of them are anyone's photos. Walking them made a
    /// scan of Documents take minutes instead of seconds.
    func testToolingAndHiddenDirectoriesAreNotWalked() throws {
        let bytes = payload(seed: 33, count: 300_000)
        try write("Trip/beach.jpg", bytes: bytes)
        try write(".git/annex/beach.jpg", bytes: bytes)
        try write(".build/checkouts/Thing/beach.jpg", bytes: bytes)
        try write("webapp/node_modules/pkg/assets/beach.jpg", bytes: bytes)
        try write("ios/Pods/Lib/beach.jpg", bytes: bytes)
        try write("py/__pycache__/beach.jpg", bytes: bytes)

        let result = scan()

        XCTAssertEqual(result.filesScanned, 1,
                       "only the real photo is media; the rest is machine-generated")
        XCTAssertTrue(result.groups.isEmpty,
                      "a build artefact is not a duplicate of the user's photo")
    }

    /// Pruning hidden *directories* must not start skipping hidden files: a
    /// photo named with a leading dot is still the user's photo.
    func testHiddenFilesAreStillScanned() throws {
        let bytes = payload(seed: 34, count: 300_000)
        try write("Trip/.hidden-beach.jpg", bytes: bytes)
        try write("Trip/beach.jpg", bytes: bytes)

        let result = scan()

        XCTAssertEqual(result.filesScanned, 2)
        XCTAssertEqual(result.groups.count, 1,
                       "a hidden file is still a duplicate of its visible twin")
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
