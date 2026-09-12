import XCTest

@testable import RollScrubApp
@testable import RollScrubCore

/// Previews are the whole point of the review window, and RAW is 83% of this
/// library — so this checks real ARW/DNG/MP4 files off the drive rather than
/// trusting that QuickLook "probably handles it".
///   ROLLSCRUB_MANIFEST=/path/to/manifest.json swift test --filter ThumbnailLoader
@MainActor
final class ThumbnailLoaderTests: XCTestCase {

    private func manifestItems() throws -> [ReviewItem] {
        guard let path = ProcessInfo.processInfo.environment["ROLLSCRUB_MANIFEST"] else {
            throw XCTSkip("set ROLLSCRUB_MANIFEST to a real manifest")
        }
        let session = ReviewSession()
        session.load(manifestURL: URL(fileURLWithPath: path))
        return session.items
    }

    func testGeneratesPreviewsForEveryFileTypeInTheLibrary() async throws {
        let items = try manifestItems()
        try XCTSkipIf(items.isEmpty, "manifest was empty")

        var checked: Set<String> = []
        for item in items where FileManager.default.fileExists(atPath: item.keepURL.path) {
            let ext = item.keepURL.pathExtension.uppercased()
            guard !checked.contains(ext) else { continue }
            checked.insert(ext)

            let image = await ThumbnailLoader.shared.image(for: item.keepURL, size: 900)
            XCTAssertNotNil(image, "no preview generated for a .\(ext) file: \(item.keepURL.path)")
            if let image {
                XCTAssertGreaterThan(image.size.width, 0, ".\(ext) preview had zero width")
            }
            if checked.count >= 6 { break }
        }
        XCTAssertFalse(checked.isEmpty, "no readable files found to test")
        print("generated previews for: \(checked.sorted().joined(separator: ", "))")
    }

    /// Guards against the failure that is worse than no preview: a preview that
    /// renders, but is the generic file-type icon. Every raw file would then
    /// look identical, and the review window would be quietly useless.
    func testPreviewsShowRealContentNotFileTypeIcons() async throws {
        let items = try manifestItems()
        try XCTSkipIf(items.isEmpty, "manifest was empty")

        for ext in ["ARW", "DNG", "MP4"] {
            // A group of three copies yields two records sharing one kept file,
            // so compare distinct paths or this compares a file with itself.
            var seen: Set<String> = []
            let matching = items.filter {
                $0.keepURL.pathExtension.uppercased() == ext
                    && FileManager.default.fileExists(atPath: $0.keepURL.path)
                    && seen.insert($0.keepURL.path).inserted
            }
            guard matching.count >= 2 else { continue }

            let first = await ThumbnailLoader.shared.image(for: matching[0].keepURL, size: 400)
            let second = await ThumbnailLoader.shared.image(for: matching[1].keepURL, size: 400)
            let firstData = try XCTUnwrap(first?.tiffRepresentation, "no .\(ext) preview")
            let secondData = try XCTUnwrap(second?.tiffRepresentation, "no .\(ext) preview")

            XCTAssertNotEqual(
                firstData, secondData,
                "two different .\(ext) files produced pixel-identical previews — "
                + "that means a file-type icon, not the actual image")
        }
    }
}
