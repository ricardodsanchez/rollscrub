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

    // MARK: - Managed libraries

    /// The scanner refuses to walk a library, but Mover takes whatever groups
    /// it is given. If one ever names a file inside a Photos library, moving
    /// it breaks the catalogue that points at it, and Photos shows a blank
    /// thumbnail months later with no record of why.
    func testWillNotMoveAFileOutOfAManagedLibrary() throws {
        let keep = try write("Loose/holiday.jpg", "same bytes")
        let inside = try write("Photos Library.photoslibrary/originals/0/holiday.jpg", "same bytes")

        let outcome = try Mover(root: root).move(groups: [group(keep: keep, remove: [inside])])

        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertTrue(exists(inside), "a file inside a library must stay where its app put it")
        XCTAssertTrue(outcome.skipped.first?.reason.contains("Photos Library.photoslibrary") == true,
                      "the skip must name the library: \(outcome.skipped.first?.reason ?? "none")")
    }

    /// The other way round is no safer. Setting the user's own copy aside
    /// because a library holds the same bytes leaves the photo resting on a
    /// derivative that Photos may regenerate or purge whenever it likes.
    func testWillNotSetAFileAsideInFavourOfALibrarysCopy() throws {
        let inside = try write("Photos Library.photoslibrary/resources/derivatives/a.jpg", "same bytes")
        let loose = try write("Loose/a.jpg", "same bytes")

        let outcome = try Mover(root: root).move(groups: [group(keep: inside, remove: [loose])])

        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertTrue(exists(loose), "the user's own copy must not be traded for a library's")
        XCTAssertTrue(outcome.skipped.first?.reason.contains("library") == true,
                      "unexpected reason: \(outcome.skipped.first?.reason ?? "none")")
    }

    /// A review folder that is a link into a library, left by a user or by
    /// some sync tool, makes the move file the user's photo inside a package
    /// whose app does not know it is there, beside the manifest needed to
    /// undo it. The file never leaves the drive, so the volume check passes.
    func testWillNotMoveIntoAManagedLibraryThroughALinkedReviewFolder() throws {
        let keep = try write("Loose/a.jpg", "same bytes")
        let dupe = try write("Loose/a copy.jpg", "same bytes")
        let library = root.appendingPathComponent("Photos Library.photoslibrary/private")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: reviewDir, withDestinationURL: library)

        let outcome = try Mover(root: root).move(groups: [group(keep: keep, remove: [dupe])])

        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertTrue(exists(dupe), "the file must stay where it is")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), [],
                       "nothing may be written inside the library")
        XCTAssertTrue(outcome.skipped.first?.reason.contains("library") == true,
                      "unexpected reason: \(outcome.skipped.first?.reason ?? "none")")
    }

    /// The same Music media folder, reached by a group that did not come
    /// from the walk, or by a scan root inside it.
    func testWillNotMoveAFileOutOfMusicsMediaFolder() throws {
        try write("Music/Music Library.musiclibrary/Library.musicdb", "db")
        let inside = try write("Music/Media.localized/Music Videos/a.mov", "same bytes")
        let keep = try write("Downloads/a.mov", "same bytes")

        let outcome = try Mover(root: root).move(groups: [group(keep: keep, remove: [inside])])

        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertTrue(exists(inside), "Music finds this file by its path")
        XCTAssertNotNil(SkipRules.managedLibrary(containing: inside.path))
        XCTAssertNil(SkipRules.managedLibrary(containing: keep.path))
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
            XCTAssertTrue(skip.reason.contains("not downloaded to this Mac"), skip.reason)
        }
        XCTAssertTrue(exists(evictedDupe))
        XCTAssertTrue(exists(dupeB))
    }

    /// The rule behind the check. An exFAT card or a disk image answers nil
    /// for "is this in iCloud", and reading nil as evicted would refuse every
    /// move on every external drive. An iCloud file whose status is missing,
    /// or downloaded but stale, is not safe to read.
    func testOnlyAFileICloudClaimsAndHasNotFullyDownloadedCountsAsEvicted() {
        XCTAssertFalse(CloudPlaceholder.isNotDownloaded(isUbiquitous: nil, status: nil),
                       "a drive iCloud knows nothing about is not evicted")
        XCTAssertFalse(CloudPlaceholder.isNotDownloaded(isUbiquitous: false, status: nil))
        XCTAssertFalse(CloudPlaceholder.isNotDownloaded(isUbiquitous: true, status: .current))
        XCTAssertTrue(CloudPlaceholder.isNotDownloaded(isUbiquitous: true, status: .notDownloaded))
        XCTAssertTrue(CloudPlaceholder.isNotDownloaded(isUbiquitous: true, status: .downloaded),
                      "an out-of-date local copy is fetched again when read")
        XCTAssertTrue(CloudPlaceholder.isNotDownloaded(isUbiquitous: true, status: nil),
                      "an iCloud file whose status is unknown must not be read")
    }

    /// Dropbox, OneDrive and Google Drive keep online-only files as dataless
    /// files, which iCloud's own status knows nothing about. Reading one,
    /// as the byte-for-byte check does, downloads all of it. The flag is
    /// also the cheap half: a flagged file must be answered without the
    /// millisecond round trip to the file provider.
    func testAFileMarkedDatalessIsOnlineOnlyWithoutAskingICloud() throws {
        let neverAsked: () -> (isUbiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?) = {
            XCTFail("a dataless file must not cost a file provider round trip")
            return (nil, nil)
        }
        XCTAssertTrue(CloudPlaceholder.isNotDownloaded(
            flags: UInt32(SF_DATALESS) | UInt32(UF_COMPRESSED), cloudStatus: neverAsked))
        XCTAssertFalse(CloudPlaceholder.isNotDownloaded(
            flags: UInt32(UF_COMPRESSED) | UInt32(UF_HIDDEN), cloudStatus: { (nil, nil) }),
                       "ordinary flags on a local file are not a placeholder")
        XCTAssertTrue(CloudPlaceholder.isNotDownloaded(
            flags: 0, cloudStatus: { (true, .notDownloaded) }),
                      "without the flag, iCloud's own answer still counts")
        XCTAssertFalse(CloudPlaceholder.isNotDownloaded(flags: nil, cloudStatus: { (nil, nil) }))

        let local = try write("Local/a.jpg", "on this Mac")
        XCTAssertFalse(CloudPlaceholder.isNotDownloaded(local.path),
                       "a file written here is on this Mac")
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
