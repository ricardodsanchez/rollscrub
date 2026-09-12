import AVFoundation
import XCTest

@testable import DupSweepApp
@testable import DupSweepCore

/// Playback is the one thing in the review window that cannot be checked from
/// a snapshot, so it is checked here against the real clips on the drive.
///   DUPSWEEP_MANIFEST=/path/to/manifest.json swift test --filter Playback
@MainActor
final class PlaybackTests: XCTestCase {

    private func firstVideoPair() throws -> (kept: URL, parked: URL) {
        guard let path = ProcessInfo.processInfo.environment["DUPSWEEP_MANIFEST"] else {
            throw XCTSkip("set DUPSWEEP_MANIFEST to a real manifest")
        }
        let session = ReviewSession()
        session.load(manifestURL: URL(fileURLWithPath: path))
        guard let item = session.items.first(where: {
            $0.isVideo
                && FileManager.default.fileExists(atPath: $0.keepURL.path)
                && FileManager.default.fileExists(atPath: $0.candidateURL.path)
        }) else {
            throw XCTSkip("no video pair with both files present")
        }
        return (item.keepURL, item.candidateURL)
    }

    private func advanced(_ player: AVPlayer, seconds: TimeInterval = 2.5) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return player.currentTime().seconds > 0.05 && player.rate > 0
    }

    func testPlayerStartsWhenItemIsReadyFirst() async throws {
        let pair = try firstVideoPair()
        let item = AVPlayerItem(url: pair.kept)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        // Wait for readiness rather than seeking blind.
        for _ in 0..<50 where item.status != .readyToPlay {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(item.status, .readyToPlay, "player item never became ready")
        player.play()

        let playing = await advanced(player)
        print("ready-then-play: rate=\(player.rate) time=\(player.currentTime().seconds)")
        player.pause()
        XCTAssertTrue(playing, "playback did not advance for \(pair.kept.lastPathComponent)")
    }

    func testBothClipsInAPairPlay() async throws {
        let pair = try firstVideoPair()
        var players: [AVPlayer] = []
        for url in [pair.kept, pair.parked] {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            for _ in 0..<50 where item.status != .readyToPlay {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            players.append(player)
        }
        players.forEach { $0.play() }
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        for (index, player) in players.enumerated() {
            XCTAssertGreaterThan(
                player.currentTime().seconds, 0.05,
                "clip \(index) did not advance")
            player.pause()
        }
    }
}
