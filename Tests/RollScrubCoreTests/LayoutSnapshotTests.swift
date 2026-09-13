import SwiftUI
import XCTest

@testable import RollScrubApp
@testable import RollScrubCore

/// Renders the comparison view offscreen to a PNG so the layout can be
/// inspected without a display. Opt in with:
///   ROLLSCRUB_SNAPSHOT_DIR=/some/dir swift test --filter LayoutSnapshot
@MainActor
final class LayoutSnapshotTests: XCTestCase {

    private var scratchState: URL?

    override func setUp() {
        super.setUp()
        scratchState = ScratchStateDirectory.begin()
    }

    override func tearDown() {
        ScratchStateDirectory.end(scratchState)
        super.tearDown()
    }


    func testRenderComparisonView() async throws {
        guard let directory = ProcessInfo.processInfo.environment["ROLLSCRUB_SNAPSHOT_DIR"] else {
            throw XCTSkip("set ROLLSCRUB_SNAPSHOT_DIR to render snapshots")
        }
        let manifestPath = ProcessInfo.processInfo.environment["ROLLSCRUB_MANIFEST"]
        try XCTSkipIf(manifestPath == nil, "set ROLLSCRUB_MANIFEST to a real manifest")

        let session = ReviewSession()
        session.load(manifestURL: URL(fileURLWithPath: manifestPath!))
        XCTAssertFalse(session.items.isEmpty)

        // A photo pair and a video pair exercise both layouts.
        let photo = session.items.first { !$0.isVideo && !$0.isResolved }
        let video = session.items.first { $0.isVideo && !$0.isResolved }

        for (name, item) in [("photo", photo), ("video", video)] {
            guard let item else { continue }
            // Warm the cache so the render shows real previews, not spinners.
            _ = await ThumbnailLoader.shared.image(for: item.keepURL, size: 900)
            _ = await ThumbnailLoader.shared.image(for: item.candidateURL, size: 900)

            let view = ComparisonView(item: item, session: session)
                .frame(width: 1400, height: 900)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2

            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                XCTFail("could not render \(name)")
                continue
            }
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("comparison-\(name).png")
            try png.write(to: url)
            print("wrote \(url.path)")
        }
    }
}
