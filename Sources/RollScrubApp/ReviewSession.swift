import CryptoKit
import RollScrubCore
import Foundation
import SwiftUI

/// One duplicate awaiting a verdict: the copy that will stay, and the copy
/// under judgement.
struct ReviewItem: Identifiable {
    enum Decision: String, Codable {
        case undecided
        /// Send the duplicate to the Trash.
        case discard
        /// Leave it alone. For a file parked by an older `--move` run, this
        /// also puts it back where it came from.
        case keep
    }

    enum State: Equatable {
        case pending
        case trashed
        case restored
        case kept
        /// The file is no longer there — already handled outside the app.
        case gone
        case failed(String)
    }

    enum Origin {
        /// Found by a scan and still sitting in the library.
        case inPlace
        /// Moved aside by an earlier `rollscrub --move`.
        case parked(MoveRecord)
    }

    let id: String
    /// The copy that stays.
    let keepURL: URL
    /// The copy that will go to the Trash if you mark it for removal.
    let candidateURL: URL
    let sizeBytes: Int64
    let origin: Origin
    var decision: Decision = .undecided
    var state: State = .pending

    /// Where a parked copy came from; nil when the file was never moved.
    var originalPath: String? {
        if case .parked(let record) = origin { return record.from }
        return nil
    }
    var filename: String { candidateURL.lastPathComponent }
    /// What to call the pair as a whole. The keeper's name, because a header
    /// spanning both panes that reads "…-2.DNG" while the pane beneath it says
    /// the file being kept is "….DNG" looks like the app picked the wrong one.
    var pairName: String { keepURL.lastPathComponent }
    /// The folder the duplicate sits in, for telling apart same-named files
    /// found under different scanned roots.
    var folderName: String { candidateURL.deletingLastPathComponent().lastPathComponent }
    var isVideo: Bool { MediaKind(pathExtension: candidateURL.pathExtension) == .video }
    var isResolved: Bool { state != .pending }

    /// Why this file was left alone, when it was.
    var failureReason: String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }
}

@MainActor
final class ReviewSession: ObservableObject {

    enum Filter: String, CaseIterable, Identifiable {
        case pending = "To review"
        case discard = "Marked remove"
        case keep = "Marked keep"
        case failed = "Failed"
        case resolved = "Done"
        case all = "All"
        var id: String { rawValue }
    }

    @Published private(set) var items: [ReviewItem] = []
    @Published var filter: Filter = .pending
    @Published var selection: ReviewItem.ID?
    /// What is loaded: a scanned folder, or a manifest from an older run.
    @Published private(set) var sourceDescription: String?
    @Published private(set) var isLoaded = false
    /// Set when the items came from a scan, so a clean result can be reported
    /// as a result rather than as a failure.
    @Published private(set) var scanSummary: ScanSummary?

    struct ScanSummary {
        let roots: [URL]
        let filesScanned: Int
        let duration: TimeInterval
        var folderName: String {
            roots.count == 1
                ? roots[0].lastPathComponent
                : "\(roots.count) folders"
        }
    }

    @Published var errorMessage: String?
    @Published private(set) var isApplying = false

    private var stateURL: URL?

    // MARK: - Loading from a scan

    func load(scanResult: ScanResult, roots: [URL]) {
        let fileManager = FileManager.default
        items = scanResult.groups.flatMap { group in
            group.remove.map { path in
                var item = ReviewItem(
                    id: path,
                    keepURL: URL(fileURLWithPath: group.keep),
                    candidateURL: URL(fileURLWithPath: path),
                    sizeBytes: group.size,
                    origin: .inPlace)
                if !fileManager.fileExists(atPath: path) { item.state = .gone }
                return item
            }
        }
        sourceDescription = roots.map(\.path).joined(separator: ", ")
        scanSummary = ScanSummary(
            roots: roots,
            filesScanned: scanResult.filesScanned,
            duration: scanResult.duration)
        stateURL = Self.stateFileForScan(roots: roots)
        applySavedDecisions()
        isLoaded = true
        errorMessage = nil
        resetSelection()
    }

    func load(scanResult: ScanResult, root: URL) {
        load(scanResult: scanResult, roots: [root])
    }

    // MARK: - Loading from an older --move manifest

    func load(manifestURL url: URL) {
        do {
            let manifest = try Mover.readManifest(at: url)
            let fileManager = FileManager.default

            items = manifest.records.map { record in
                var item = ReviewItem(
                    id: record.to,
                    keepURL: URL(fileURLWithPath: record.verifiedAgainst),
                    candidateURL: URL(fileURLWithPath: record.to),
                    sizeBytes: record.sizeBytes,
                    origin: .parked(record))
                if !fileManager.fileExists(atPath: record.to) {
                    item.state = fileManager.fileExists(atPath: record.from) ? .restored : .gone
                }
                return item
            }
            sourceDescription = url.deletingLastPathComponent().path
            scanSummary = nil
            stateURL = url.deletingLastPathComponent()
                .appendingPathComponent("_rollscrub_review_state.json")
            applySavedDecisions()
            isLoaded = true
            errorMessage = nil
            resetSelection()
        } catch {
            errorMessage = "Could not read that manifest: \(error.localizedDescription)"
        }
    }

    func loadManifest(inRoot root: URL) {
        let reviewDir = root.lastPathComponent == SkipRules.reviewDirectoryName
            ? root
            : root.appendingPathComponent(SkipRules.reviewDirectoryName)

        let matches = (try? FileManager.default.contentsOfDirectory(
            at: reviewDir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("_rollscrub_manifest_") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []

        guard let newest = matches.first else {
            errorMessage = "No RollScrub manifest found in \(reviewDir.path)"
            return
        }
        load(manifestURL: newest)
    }

    private func resetSelection() {
        let first = filtered.first?.id
        Task { @MainActor in self.selection = first }
    }

    // MARK: - Derived

    var filtered: [ReviewItem] {
        switch filter {
        case .pending:  return items.filter { !$0.isResolved && $0.decision == .undecided }
        case .discard:  return items.filter { !$0.isResolved && $0.decision == .discard }
        case .keep:     return items.filter { !$0.isResolved && $0.decision == .keep }
        case .failed:   return items.filter { $0.failureReason != nil }
        case .resolved: return items.filter(\.isResolved)
        case .all:      return items
        }
    }

    /// Computed without touching `filter` — mutating published state while a
    /// view body is being evaluated causes update loops.
    func count(for filter: Filter) -> Int {
        switch filter {
        case .pending:  return undecidedCount
        case .discard:  return markedForDiscard.count
        case .keep:     return markedForKeep.count
        case .failed:   return failedCount
        case .resolved: return resolvedCount
        case .all:      return items.count
        }
    }

    /// Puts failed items back in the queue so Apply can try them again — after
    /// the cause is dealt with, e.g. downloading a file iCloud had evicted.
    func retryFailed() {
        for index in items.indices where items[index].failureReason != nil {
            items[index].state = .pending
        }
        filter = .discard
        selection = filtered.first?.id
    }

    var markedForDiscard: [ReviewItem] {
        items.filter { !$0.isResolved && $0.decision == .discard }
    }
    var markedForKeep: [ReviewItem] {
        items.filter { !$0.isResolved && $0.decision == .keep }
    }
    var reclaimableBytes: Int64 {
        markedForDiscard.reduce(0) { $0 + $1.sizeBytes }
    }
    var undecidedCount: Int {
        items.filter { !$0.isResolved && $0.decision == .undecided }.count
    }
    var resolvedCount: Int { items.filter(\.isResolved).count }
    var trashedCount: Int { items.filter { $0.state == .trashed }.count }
    var restoredCount: Int { items.filter { $0.state == .restored }.count }
    var keptCount: Int { items.filter { $0.state == .kept }.count }
    var goneCount: Int { items.filter { $0.state == .gone }.count }
    var failedCount: Int {
        items.filter { if case .failed = $0.state { return true } else { return false } }.count
    }
    var bytesCleared: Int64 {
        items.filter { $0.state == .trashed || $0.state == .gone }
            .reduce(0) { $0 + $1.sizeBytes }
    }
    var isComplete: Bool { !items.isEmpty && resolvedCount == items.count }

    func item(id: ReviewItem.ID?) -> ReviewItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    // MARK: - Marking (never touches the filesystem)

    func mark(_ id: ReviewItem.ID, as decision: ReviewItem.Decision) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].decision = decision
        saveDecisions()
    }

    func markSelection(_ decision: ReviewItem.Decision) {
        guard let selection else { return }
        mark(selection, as: decision)
    }

    func markSelectionAndAdvance(_ decision: ReviewItem.Decision) {
        guard let current = selection else { return }
        let index = filtered.firstIndex { $0.id == current }
        mark(current, as: decision)

        let next = filtered
        if let index {
            selection = next.indices.contains(index) ? next[index].id
                : next.indices.contains(index - 1) ? next[index - 1].id
                : next.first?.id
        } else {
            selection = next.first?.id
        }
    }

    func markAllPending(as decision: ReviewItem.Decision) {
        for index in items.indices where !items[index].isResolved {
            items[index].decision = decision
        }
        saveDecisions()
    }

    func selectNext(by offset: Int) {
        let visible = filtered
        guard !visible.isEmpty else { return }
        guard let current = selection,
              let index = visible.firstIndex(where: { $0.id == current })
        else {
            selection = visible.first?.id
            return
        }
        selection = visible[min(max(index + offset, 0), visible.count - 1)].id
    }

    // MARK: - Applying — the only place files are touched

    /// Trashes everything marked for removal. Deletion is always to the Trash,
    /// never an unlink, so a wrong call is recoverable from the Finder.
    ///
    /// Before each file goes, its counterpart is re-checked byte for byte:
    /// nothing is removed unless an identical copy is verifiably still there.
    func apply() async {
        isApplying = true
        defer { isApplying = false }

        var trashable: [ReviewItem] = []
        for item in markedForDiscard {
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
            guard FileManager.default.fileExists(atPath: item.keepURL.path) else {
                items[index].state = .failed("the copy it duplicates is missing")
                continue
            }
            // An iCloud file that is only a placeholder cannot be compared or
            // trashed reliably, and the system error for it says nothing useful.
            if let stranded = Self.icloudPlaceholderReason(for: item) {
                items[index].state = .failed(stranded)
                continue
            }
            let identical = await Task.detached(priority: .userInitiated) {
                ContentSignature.verifyIdentical(item.keepURL.path, item.candidateURL.path)
            }.value
            guard identical else {
                items[index].state = .failed("no longer byte-identical to the copy being kept")
                continue
            }
            trashable.append(item)
        }

        if !trashable.isEmpty {
            let failures = await Self.moveToTrash(trashable.map(\.candidateURL))
            for item in trashable {
                guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
                if let reason = failures[item.candidateURL] {
                    items[index].state = .failed(reason)
                } else {
                    items[index].state = .trashed
                }
            }
        }

        for item in markedForKeep {
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
            switch item.origin {
            case .inPlace:
                // Nothing to do; the file was never moved.
                items[index].state = .kept
            case .parked(let record):
                do {
                    try Mover.restore(record)
                    items[index].state = .restored
                } catch let error as Mover.RestoreError {
                    items[index].state = .failed(error.reason)
                } catch {
                    items[index].state = .failed(error.localizedDescription)
                }
            }
        }

        saveDecisions()
        selection = filtered.first?.id
    }

    /// Returns a reason when either side of the pair is in iCloud but not
    /// actually downloaded. Reading such a file would force a download, and
    /// deleting it removes it from every device — neither should happen
    /// silently as a side effect of a duplicate sweep.
    private static func icloudPlaceholderReason(for item: ReviewItem) -> String? {
        for url in [item.candidateURL, item.keepURL] {
            guard let values = try? url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]),
                values.isUbiquitousItem == true
            else { continue }
            if values.ubiquitousItemDownloadingStatus != .current {
                return "iCloud has not downloaded this file yet — open it once in "
                    + "Finder, then use Retry failed"
            }
        }
        return nil
    }

    private static func moveToTrash(_ urls: [URL]) async -> [URL: String] {
        await withCheckedContinuation { continuation in
            var failures: [URL: String] = [:]
            let group = DispatchGroup()
            for url in urls {
                group.enter()
                NSWorkspace.shared.recycle([url]) { _, error in
                    if let error { failures[url] = error.localizedDescription }
                    group.leave()
                }
            }
            group.notify(queue: .main) { continuation.resume(returning: failures) }
        }
    }

    // MARK: - Decision persistence

    /// Scans have no folder of their own to write to, so their progress lives
    /// in Application Support keyed by the scanned paths. Sorted first so the
    /// same set of folders keys the same file regardless of pick order.
    private static func stateFileForScan(roots: [URL]) -> URL? {
        let key = roots.map(\.path).sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(key.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        else { return nil }
        let directory = support.appendingPathComponent("RollScrub", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("scan-\(digest).json")
    }

    private func saveDecisions() {
        guard let stateURL else { return }
        let map = Dictionary(
            uniqueKeysWithValues: items.filter { $0.decision != .undecided }
                .map { ($0.id, $0.decision) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(map).write(to: stateURL, options: .atomic)
    }

    private func applySavedDecisions() {
        guard let stateURL, let data = try? Data(contentsOf: stateURL),
              let saved = try? JSONDecoder().decode([String: ReviewItem.Decision].self, from: data)
        else { return }
        for index in items.indices {
            if let decision = saved[items[index].id] { items[index].decision = decision }
        }
    }
}
