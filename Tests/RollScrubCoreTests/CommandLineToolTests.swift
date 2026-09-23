import XCTest

@testable import RollScrubApp

/// The installer writes into `/usr/local/bin`, a directory shared with
/// Homebrew and with whatever anyone has built by hand. The decision of what
/// it may overwrite is therefore the whole risk in this feature, and it is
/// separated from the filesystem so every branch can be exercised here rather
/// than discovered on somebody's machine.
final class CommandLineToolTests: XCTestCase {

    private let wanted = "/Applications/RollScrub.app/Contents/MacOS/rollscrub"

    /// The case that must never become automatic. Someone's own `rollscrub` —
    /// built from source, installed by Homebrew, or an unrelated tool sharing
    /// the name — is not ours to delete, and silently replacing it would
    /// destroy work with no way back.
    func testARealFileAtThePathIsNeverTreatedAsReplaceable() {
        XCTAssertEqual(
            CommandLineTool.classify(
                symlinkDestination: nil, isSymlink: false, exists: true, wanted: wanted),
            .occupiedByRealFile)
    }

    func testAnEmptyPathIsFreeToTake() {
        XCTAssertEqual(
            CommandLineTool.classify(
                symlinkDestination: nil, isSymlink: false, exists: false, wanted: wanted),
            .absent)
    }

    /// Installing twice must not ask for a password the second time, and must
    /// not report that it did something it did not do.
    func testOurOwnLinkIsRecognisedRatherThanRewritten() {
        XCTAssertEqual(
            CommandLineTool.classify(
                symlinkDestination: wanted, isSymlink: true, exists: true, wanted: wanted),
            .alreadyCorrect)
    }

    /// Someone moved the app, or installed over an older copy. The link is
    /// ours and points somewhere wrong, so repointing it is the whole job.
    func testALinkToADifferentCopyIsRepointed() {
        let old = "/Users/someone/Applications/RollScrub.app/Contents/MacOS/rollscrub"
        XCTAssertEqual(
            CommandLineTool.classify(
                symlinkDestination: old, isSymlink: true, exists: true, wanted: wanted),
            .staleSymlink(destination: old))
    }

    /// A link whose target has been deleted — the app was thrown away and
    /// reinstalled. `fileExists` follows symlinks and so reports nothing
    /// there; reading it as `absent` would be harmless, but reading it as a
    /// real file would strand the user with a dead `rollscrub` forever and no
    /// way to fix it from the menu.
    func testALinkWhoseTargetIsGoneIsStillOursToRepoint() {
        XCTAssertEqual(
            CommandLineTool.classify(
                symlinkDestination: "/Volumes/GoneAway/RollScrub.app/Contents/MacOS/rollscrub",
                isSymlink: true, exists: false, wanted: wanted),
            .staleSymlink(destination: "/Volumes/GoneAway/RollScrub.app/Contents/MacOS/rollscrub"))
    }

    /// A symlink we cannot read the destination of is still a symlink, and
    /// still not somebody's file. Falling through to `occupiedByRealFile`
    /// would leave the menu item permanently unable to repair itself.
    func testAnUnreadableSymlinkIsNotMistakenForARealFile() {
        XCTAssertEqual(
            CommandLineTool.classify(
                symlinkDestination: nil, isSymlink: true, exists: true, wanted: wanted),
            .staleSymlink(destination: ""))
    }
}
