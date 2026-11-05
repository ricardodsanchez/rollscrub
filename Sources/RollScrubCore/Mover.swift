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

    /// Answers which volume a path is on, or nil when it cannot tell.
    typealias VolumeLookup = (URL) -> AnyHashable?

    private let roots: [URL]
    private let reviewDirectoryName: String
    private let progress: ((MoveProgress) -> Void)?
    private let volumeOf: VolumeLookup
    private let isNotDownloaded: (String) -> Bool
    private let fileManager = FileManager.default

    public convenience init(
        roots: [URL],
        reviewDirectoryName: String = SkipRules.reviewDirectoryName,
        progress: ((MoveProgress) -> Void)? = nil
    ) {
        self.init(
            roots: roots,
            reviewDirectoryName: reviewDirectoryName,
            progress: progress,
            volumeOf: Mover.volumeIdentifier(of:),
            isNotDownloaded: ICloudPlaceholder.isNotDownloaded)
    }

    /// The lookups are injectable because a test cannot mount a second volume
    /// or evict a file from iCloud.
    init(
        roots: [URL],
        reviewDirectoryName: String = SkipRules.reviewDirectoryName,
        progress: ((MoveProgress) -> Void)? = nil,
        volumeOf: @escaping VolumeLookup,
        isNotDownloaded: @escaping (String) -> Bool
    ) {
        // Symlinks are resolved, not merely standardized. Enumeration reports
        // files at their resolved paths, so a root given as /tmp or /var —
        // both symlinks on macOS — never prefix-matches the /private/... paths
        // coming back, and every single file is skipped as outside the root.
        //
        // Longest path first, so a root nested inside another root (an
        // unusual but valid thing to pass) is matched before its parent.
        self.roots = roots
            .map { $0.resolvingSymlinksInPath().standardized }
            .sorted { $0.path.count > $1.path.count }
        self.reviewDirectoryName = reviewDirectoryName
        self.progress = progress
        self.volumeOf = volumeOf
        self.isNotDownloaded = isNotDownloaded
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
    /// A file is moved only when all of these hold: its KEEP counterpart is
    /// still on disk, neither file is inside a managed library, neither file
    /// is an iCloud placeholder, the review folder
    /// is on the file's own volume, the two still compare equal across every
    /// byte, and the destination is unoccupied. Anything else is skipped and
    /// reported. A failure never costs you a file.
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

            // The scanner refuses to walk a library, but a group can reach
            // here by other routes, so this is the last gate. Moving a file
            // out of a library corrupts its catalogue. Keeping a library's copy
            // instead of the user's own is no better: the owning app can
            // regenerate or delete its derivatives whenever it likes, and the
            // photo goes with them.
            if let library = SkipRules.managedLibrary(containing: candidate.path) {
                skipped.append(SkippedMove(
                    path: candidate.path,
                    reason: "is inside \(library.path), a library its app manages; "
                        + "moving anything out of it corrupts the library"))
                continue
            }
            if let library = SkipRules.managedLibrary(containing: candidate.keep) {
                skipped.append(SkippedMove(
                    path: candidate.path,
                    reason: "the file it duplicates is inside \(library.path), "
                        + "a library whose app can change or remove it at any time"))
                continue
            }

            guard let (owningRoot, relative) = rootAndRelativePath(of: candidate.path) else {
                skipped.append(SkippedMove(
                    path: candidate.path, reason: "is outside every scan root"))
                continue
            }

            let reviewDirectory = owningRoot.appendingPathComponent(reviewDirectoryName)
            let destination = availableDestination(in: reviewDirectory, for: relative)

            // A move onto another volume is a copy followed by a delete of the
            // original, which is exactly what this program promises never to
            // do. It happens when a scan root has a mount point under it
            // (`rollscrub /Volumes --move`, a mounted disk image), so the file
            // is on one drive and its root's review folder on another.
            // Compared folder to folder: a mount point is always a directory,
            // so a file is on the volume of the folder holding it, and the
            // move lands on the volume of the deepest existing folder on the
            // way to its destination. Symlinks are resolved first: a review
            // folder that links to another drive puts the file on that drive,
            // whatever volume the link itself sits on. Refused when either
            // volume cannot be told.
            let landingFolder = nearestExistingAncestor(of: destination.deletingLastPathComponent())
            let fileVolume = volumeOf(URL(fileURLWithPath: candidate.path)
                .deletingLastPathComponent().resolvingSymlinksInPath())
            let landingVolume = volumeOf(landingFolder.resolvingSymlinksInPath())
            guard let fileVolume, let landingVolume, fileVolume == landingVolume else {
                skipped.append(SkippedMove(
                    path: candidate.path,
                    reason: fileVolume == nil || landingVolume == nil
                        ? "could not confirm it is on the same drive as \(reviewDirectory.path)"
                        : "is on a different drive from \(reviewDirectory.path); "
                            + "scan that drive as a root of its own to move it"))
                continue
            }

            // Nor into one. A review folder that is a link into a library
            // would file the user's photo inside a package its app does not
            // know about. The destination does not exist yet, and symlink
            // resolution gives up on a missing path, so the deepest folder
            // that does exist is the one asked about: that is where the file
            // physically lands. The rest of the path only mirrors where the
            // file came from, which the checks above have already cleared.
            if let library = SkipRules.managedLibrary(containing: landingFolder.path) {
                skipped.append(SkippedMove(
                    path: candidate.path,
                    reason: "its review folder leads into \(library.path), "
                        + "a library its app manages"))
                continue
            }

            // Reading an evicted iCloud file downloads the whole thing, and
            // the comparison below reads every byte of both. A file can be
            // evicted between the scan and the move, so this is asked again
            // here, of the two files about to be read and nothing else.
            if let evicted = [candidate.path, candidate.keep].first(where: isNotDownloaded) {
                skipped.append(SkippedMove(
                    path: candidate.path,
                    reason: "iCloud has not downloaded \(evicted); "
                        + "open it once in Finder, then run --move again"))
                continue
            }

            // Re-confirm at the moment of the move, not just at scan time.
            guard ContentSignature.verifyIdentical(candidate.keep, candidate.path) else {
                skipped.append(SkippedMove(
                    path: candidate.path,
                    reason: "no longer byte-identical to \(candidate.keep)"))
                continue
            }

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

    /// The volume a directory is on. Read through a fresh URL so a cached
    /// value cannot answer for a mount that has changed since.
    static func volumeIdentifier(of url: URL) -> AnyHashable? {
        let fresh = URL(fileURLWithPath: url.path)
        guard let identifier = try? fresh.resourceValues(forKeys: [.volumeIdentifierKey])
            .volumeIdentifier as? NSObject
        else { return nil }
        return AnyHashable(identifier)
    }

    /// The deepest directory on the way to `url` that already exists. Folders
    /// created under it to mirror the original layout land on its volume, so
    /// this is the directory whose volume a move into `url` ends up on.
    private func nearestExistingAncestor(of url: URL) -> URL {
        var current = url
        while !fileManager.fileExists(atPath: current.path), current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        return current
    }

    /// The root a path was found under, and its path relative to that root.
    /// `roots` is sorted longest-first so a nested root wins over its parent.
    private func rootAndRelativePath(of path: String) -> (URL, String)? {
        // Resolved the same way the roots are, so both sides of the prefix
        // comparison are in the same namespace.
        let standardizedPath = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath().standardized.path
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
            "_rollscrub_manifest_\(stamp.string(from: Date())).json")

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
