import XCTest

@testable import RollScrubCore

final class KeepSelectorTests: XCTestCase {

    func testCopyStyleNamesAreDetected() {
        for name in [
            "IMG_8672 2.MOV",
            "photo (1).jpg",
            "photo copy.jpg",
            "photo copy 2.jpg",
            "16_20251214-LEICA Q2-NewYorkCity-1040694.DNG",
        ] {
            XCTAssertTrue(
                KeepSelector.looksLikeCopy(filename: name), "\(name) should look like a copy")
        }
    }

    func testCameraOriginalsAreNotMistakenForCopies() {
        // A trailing number is a sequence number, not a duplicate marker.
        for name in [
            "C0106.MP4",
            "A7C2_0663.MP4",
            "IMG_8672.MOV",
            "20260125-ILCE-7CM2-Seattle-00684.ARW",
            "20260102-LEICA Q2-Cancun-1050162.DNG",
            "20230924-LEICA Q2-Seattle-8.DNG",
            "DJI_0152.MOV",
            "video_20210905100426_6553752_0.MOV",
        ] {
            XCTAssertFalse(KeepSelector.looksLikeCopy(filename: name), "\(name) is an original")
        }
    }

    /// `<date>--<location>-<seq>` collapses to `20220718---2-38` when the
    /// location field is blank. That is the rename convention, not a copy.
    func testEmptyLocationFieldIsNotACopyMarker() {
        for name in ["20220916---2.MP4", "20220912---2-2.MP4", "20220718---2-38.MP4"] {
            XCTAssertFalse(KeepSelector.looksLikeCopy(filename: name), "\(name) is a rename")
            XCTAssertTrue(KeepSelector.looksRenamed(filename: name), "\(name) is a rename")
        }
    }

    func testRenamedFileBeatsCameraOriginal() {
        for (renamed, original) in [
            ("/Volumes/D/Video/2022/12/20221208---2.MP4", "/Volumes/D/Video/2022/12/C0118.MP4"),
            ("/Volumes/D/Video/2022/09/20220916---2.MP4", "/Volumes/D/Video/2022/09/C0106.MP4"),
            ("/Volumes/D/Video/2022/07/202207-Sony7III-Spain094.MP4",
             "/Volumes/D/Video/2022/07/C7794.MP4"),
        ] {
            XCTAssertEqual(KeepSelector.chooseKeep(from: [renamed, original]), renamed)
            XCTAssertEqual(KeepSelector.chooseKeep(from: [original, renamed]), renamed)
        }
    }

    func testCopyMarkerOutranksTheRenamePreference() {
        // A Finder copy of a renamed file loses to a clean camera original.
        let keep = KeepSelector.chooseKeep(from: [
            "/Volumes/D/Video/2022/12/20221208---2 2.MP4",
            "/Volumes/D/Video/2022/12/C0118.MP4",
        ])
        XCTAssertEqual(keep, "/Volumes/D/Video/2022/12/C0118.MP4")
    }

    func testKeepsTheMostDescriptiveNameWhenNeitherLooksLikeACopy() {
        let keep = KeepSelector.chooseKeep(from: [
            "/Volumes/D/Photos/2024/08/20240807-LEICA Q2-Tokyo-1020661.DNG",
            "/Volumes/D/Photos/2024/08/20240807-Leica-LEICA Q2-Tokyo-L1020661.DNG",
        ])
        XCTAssertEqual(keep, "/Volumes/D/Photos/2024/08/20240807-Leica-LEICA Q2-Tokyo-L1020661.DNG")
    }

    func testTieBreaksAlphabeticallyForStability() {
        let paths = ["/a/zzz.jpg", "/a/aaa.jpg", "/a/mmm.jpg"]
        XCTAssertEqual(KeepSelector.chooseKeep(from: paths), "/a/aaa.jpg")
        XCTAssertEqual(KeepSelector.chooseKeep(from: paths.reversed()), "/a/aaa.jpg")
    }

    func testAllCopyLikeNamesStillYieldAKeeper() {
        let keep = KeepSelector.chooseKeep(from: ["/a/xx 2.jpg", "/a/x 3.jpg"])
        XCTAssertEqual(keep, "/a/xx 2.jpg")
    }
}

final class ReportWriterTests: XCTestCase {

    func testHumanSizeMatchesPrototypeFormatting() {
        XCTAssertEqual(ReportWriter.humanSize(15_057_894_811), "14.0 GB")
        XCTAssertEqual(ReportWriter.humanSize(10_804_774_279), "10.1 GB")
        XCTAssertEqual(ReportWriter.humanSize(5_742_135_223), "5.3 GB")
        XCTAssertEqual(ReportWriter.humanSize(1_409_318_829), "1.3 GB")
        XCTAssertEqual(ReportWriter.humanSize(512), "512.0 B")
    }

    func testCSVQuotesPathsContainingCommas() {
        XCTAssertEqual(ReportWriter.escapeCSV("/a/plain.jpg"), "/a/plain.jpg")
        XCTAssertEqual(ReportWriter.escapeCSV("/a/Trip, Spain.jpg"), "\"/a/Trip, Spain.jpg\"")
        XCTAssertEqual(ReportWriter.escapeCSV("/a/say \"hi\".jpg"), "\"/a/say \"\"hi\"\".jpg\"")
    }

    func testCSVHasExpectedHeaderAndRows() {
        let group = DuplicateGroup(
            kind: .video, size: 1000, keep: "/a/C0001.mp4", remove: ["/a/C0001 2.mp4"])
        let result = ScanResult(
            roots: [URL(fileURLWithPath: "/a")], includes: [], startedAt: Date(), duration: 1,
            filesScanned: 2, unreadableFiles: 0, filesRejectedByVerification: 0, groups: [group])

        let lines = ReportWriter.csv(for: result).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "group,type,size_bytes,size_human,action,full_path")
        XCTAssertEqual(lines[1], "1,video,1000,1000.0 B,REMOVE,/a/C0001 2.mp4")
        XCTAssertEqual(lines[2], "1,video,1000,1000.0 B,KEEP,/a/C0001.mp4")
    }
}
