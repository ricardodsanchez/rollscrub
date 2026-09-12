import Foundation

/// One redundant file set aside, recorded so the move can be undone.
public struct MoveRecord: Codable {
    public let from: String
    public let to: String
    public let sizeBytes: Int64
    /// The file that stayed behind and was matched against, byte for byte.
    public let verifiedAgainst: String
}

public struct MoveManifest: Codable {
    public let root: String
    public let createdAt: Date
    public let records: [MoveRecord]
}

public struct SkippedMove {
    public let path: String
    public let reason: String
}

public struct MoveOutcome {
    public let moved: [MoveRecord]
    public let skipped: [SkippedMove]
    /// One manifest per root that actually received a file.
    public let manifestURLs: [URL]

    public var bytesMoved: Int64 { moved.reduce(0) { $0 + $1.sizeBytes } }
    public var manifestURL: URL? { manifestURLs.first }
}

public struct UndoOutcome {
    public let restored: Int
    public let skipped: [SkippedMove]
}

public enum MoveProgress {
    case verifying(done: Int, total: Int)
    case moving(done: Int, total: Int)
}

/// Moves redundant copies into a review folder on the same volume they were
/// found on.
///
/// Nothing is deleted, ever. A same-volume move is a rename: instant, and
/// reversible through `undo` using the manifest written alongside the files.
/// Each root gets its own review folder and its own manifest, so a file never
/// has to cross onto a different volume — and stays reversible — even when
/// several roots (possibly on different drives) are scanned together.
public final class Mover {

    private let roots: [URL]
    private let reviewDirectoryName: String
    private let progress: ((MoveProgress) -> Void)?
    private let fileManager = FileManager.default

    public init(
        roots: [URL],
        reviewDirectoryName: String = SkipRules.reviewDirectoryName,
        progress: ((MoveProgress) -> Void)? = nil
    ) {
        // Longest path first, so a root nested inside another root (an
        // unusual but valid thing to pass) is matched before its parent.
        self.roots = roots.map { $0.standardized }.sorted { $0.path.count > $1.path.count }
        self.reviewDirectoryName = reviewDirectoryName
        self.progress = progress
    }

    public convenience init(
        root: URL,
        reviewDirectoryName: String = SkipRules.reviewDirectoryName,
        progress: ((MoveProgress) -> Void)? = nil
    ) {
        self.init(roots: [root], reviewDirectoryName: reviewDirectoryName, progress: progress)
    }

    /// Sets aside every REMOVE file in `groups`.
    ///
    /// A file is moved only when all three hold: its KEEP counterpart is still
    /// on disk, the two still compare equal across every byte, and the
    /// destination is unoccupied. Anything else is skipped and reported —
    /// a failure never costs you a file.
    public func move(groups: [DuplicateGroup]) throws -> MoveOutcome {
        var moved: [MoveRecord] = []
        var movedByRoot: [URL: [MoveRecord]] = [:]
        var skipped: [SkippedMove] = []

        let candidates = groups.flatMap { group in
            group.remove.map { (path: $0, keep: group.keep, size: group.size) }
        }
        let total = candidates.count

        for (index, candidate) in candidates.enumerated() {
            progress?(.verifying(done: index, total: total))

            // The survivor must still be there — never set a file aside if the
            // copy that justifies removing it has itself gone missing.
            guard fileManager.fileExists(atPath: candidate.keep) else {
                skipped.append(SkippedMove(
                    path: candidate.path,
                    reason: "the file it duplicates is missing: \(candidate.keep)"))
                continue
            }
            guard fileManager.fileExists(atPath: candidate.path) else {
                skipped.append(SkippedMove(path: candidate.path, reason: "no longer on disk"))
                continue
            }
            // Re-confirm at the moment of the move, not just at scan time.
            guard ContentSignature.verifyIdentical(candidate.keep, candidate.path) else {
                skipped.append(SkippedMove(
                    path: candidate.path,
                    reason: "no longer byte-identical to \(candidate.keep)"))
                continue
            }
            guard let (owningRoot, relative) = rootAndRelativePath(of: candidate.path) else {
                skipped.append(SkippedMove(
                    path: candidate.path, reason: "is outside every scan root"))
                continue
            }

            let reviewDirectory = owningRoot.appendingPathComponent(reviewDirectoryName)
            let destination = availableDestination(in: reviewDirectory, for: relative)
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                progress?(.moving(done: index, total: total))
                try fileManager.moveItem(atPath: candidate.path, toPath: destination.path)
            } catch {
                skipped.append(SkippedMove(
                    path: candidate.path,
                    reason: "move failed: \(error.localizedDescription)"))
                continue
            }

            let record = MoveRecord(
                from: candidate.path,
                to: destination.path,
                sizeBytes: candidate.size,
                verifiedAgainst: candidate.keep)
            moved.append(record)
            movedByRoot[owningRoot, default: []].append(record)
        }

        progress?(.moving(done: total, total: total))

        // One manifest per root that received files, so each stays reversible
        // without reading the file back across a volume boundary.
        let manifestURLs = try movedByRoot.map { root, records in
            try writeManifest(records, root: root)
        }
        return MoveOutcome(moved: moved, skipped: skipped, manifestURLs: manifestURLs)
    }

    // MARK: - Undo

    /// Puts every file in a manifest back where it came from.
    /// A file whose original location is occupied again is left alone.
    public static func undo(manifestURL: URL) throws -> UndoOutcome {
        let manifest = try readManifest(at: manifestURL)
        var restored = 0
        var skipped: [SkippedMove] = []

        for record in manifest.records {
            do {
                try restore(record)
                restored += 1
            } catch let error as RestoreError {
                skipped.append(SkippedMove(path: record.to, reason: error.reason))
            } catch {
                skipped.append(SkippedMove(
                    path: record.to, reason: "restore failed: \(error.localizedDescription)"))
            }
        }
        return UndoOutcome(restored: restored, skipped: skipped)
    }

    public struct RestoreError: Error {
        public let reason: String
    }

    /// Puts a single parked file back where it came from. Never overwrites:
    /// if something now occupies the original path, the file stays parked.
    public static func restore(_ record: MoveRecord) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: record.to) else {
            throw RestoreError(reason: "not in the review folder")
        }
        guard !fileManager.fileExists(atPath: record.from) else {
            throw RestoreError(reason: "something is already at the original path")
        }
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: record.from).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fileManager.moveItem(atPath: record.to, toPath: record.from)
    }

    public static func readManifest(at url: URL) throws -> MoveManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MoveManifest.self, from: try Data(contentsOf: url))
    }

    // MARK: - Paths

    /// The root a path was found under, and its path relative to that root.
    /// `roots` is sorted longest-first so a nested root wins over its parent.
    private func rootAndRelativePath(of path: String) -> (URL, String)? {
        let standardizedPath = URL(fileURLWithPath: path).standardized.path
        for root in roots {
            var prefix = root.path
            if !prefix.hasSuffix("/") { prefix += "/" }
            guard standardizedPath.hasPrefix(prefix) else { continue }
            let relative = String(standardizedPath.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }
            return (root, relative)
        }
        return nil
    }

    /// Mirrors the original folder structure under the review directory,
    /// disambiguating rather than overwriting if something is already there.
    private func availableDestination(in reviewDirectory: URL, for relativePath: String) -> URL {
        let base = reviewDirectory.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: base.path) else { return base }

        let ext = base.pathExtension
        let stem = base.deletingPathExtension().path
        var counter = 2
        while true {
            let candidate = ext.isEmpty
                ? URL(fileURLWithPath: "\(stem) (\(counter))")
                : URL(fileURLWithPath: "\(stem) (\(counter)).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private func writeManifest(_ records: [MoveRecord], root: URL) throws -> URL {
        let reviewDirectory = root.appendingPathComponent(reviewDirectoryName)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = reviewDirectory.appendingPathComponent(
            "_dupsweep_manifest_\(stamp.string(from: Date())).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifest = MoveManifest(
            root: root.path, createdAt: Date(), records: records)

        try fileManager.createDirectory(at: reviewDirectory, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: url, options: .atomic)
        return url
    }
}
