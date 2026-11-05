import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import RollScrubApp
@testable import RollScrubCore

@MainActor
final class OnlineOnlyPreviewTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollScrubPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        OnlineOnly.check = CloudPlaceholder.isNotDownloaded
        try? FileManager.default.removeItem(at: directory)
    }

    private func writePNG() throws -> URL {
        let url = directory.appendingPathComponent("photo.png")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// A file on this Mac at scan time can be evicted before anyone opens the
    /// review. Showing its thumbnail or reading its dimensions downloads all
    /// of it, so the pane gets size and date from the directory entry and
    /// nothing else. The same file once local must preview as normal, or
    /// this would pass by never previewing anything.
    func testAnOnlineOnlyFileIsNotOpenedToPreviewIt() async throws {
        let url = try writePNG()

        OnlineOnly.check = { _ in true }
        let thumbnail = await ThumbnailLoader.shared.image(for: url, size: 64)
        let metadata = await FileMetadata.load(for: url)
        XCTAssertNil(thumbnail, "an online-only file must not be decoded for a thumbnail")
        XCTAssertNil(metadata.pixelSize, "nor opened to read its dimensions")
        XCTAssertGreaterThan(metadata.sizeBytes, 0, "its size comes from the directory entry")

        OnlineOnly.check = { _ in false }
        let local = await ThumbnailLoader.shared.image(for: url, size: 64)
        XCTAssertNotNil(local, "the same file on this Mac gets a preview")
        let localMetadata = await FileMetadata.load(for: url)
        XCTAssertEqual(localMetadata.pixelSize, CGSize(width: 64, height: 48))
    }
}
