import RollScrubCore
import Foundation
import SwiftUI

/// Runs the scan engine off the main thread and reports progress.
///
/// Scanning is entirely read-only: it enumerates, hashes and byte-compares,
/// and never moves or deletes anything. Files are only ever touched later,
/// when the review window applies your decisions.
@MainActor
final class ScanCoordinator: ObservableObject {

    @Published private(set) var isScanning = false
    @Published private(set) var headline = ""
    @Published private(set) var detail = ""
    /// nil while the work has no meaningful percentage yet.
    @Published private(set) var fraction: Double?
    @Published private(set) var elapsed: TimeInterval = 0

    private var task: Task<Void, Never>?
    private var startedAt: Date?
    private var ticker: Timer?

    func scan(roots: [URL]) async -> ScanResult? {
        guard !isScanning, !roots.isEmpty else { return nil }
        isScanning = true
        headline = "Looking for media files…"
        detail = roots.map(\.path).joined(separator: ", ")
        fraction = nil
        startedAt = Date()
        startTicking()
        defer {
            isScanning = false
            stopTicking()
        }

        let update: @Sendable (ScanPhase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.report(phase) }
        }

        let config = ScanConfig(roots: roots)
        return await Task.detached(priority: .userInitiated) {
            DuplicateScanner(config: config, progress: update).scan()
        }.value
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func report(_ phase: ScanPhase) {
        switch phase {
        case .enumerating(let found):
            headline = "Looking for media files…"
            detail = "\(found.formatted()) found"
            fraction = nil
        case .hashing(let done, let total):
            headline = "Checking possible duplicates…"
            detail = "\(done.formatted()) of \(total.formatted())"
            fraction = total > 0 ? Double(done) / Double(total) : nil
        case .grouping:
            headline = "Grouping matches…"
            detail = ""
            fraction = nil
        case .verifying(let done, let total):
            headline = "Comparing every byte…"
            detail = "\(done.formatted()) of \(total.formatted()) groups"
            fraction = total > 0 ? Double(done) / Double(total) : nil
        }
    }

    private func startTicking() {
        elapsed = 0
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }
}
