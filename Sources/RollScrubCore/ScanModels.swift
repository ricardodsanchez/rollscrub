import Foundation

public struct ScanConfig {
    public var roots: [URL]
    /// Subdirectories of every root to scan. Empty means each whole root.
    public var includes: [String]

    public init(roots: [URL], includes: [String] = []) {
        self.roots = roots
        self.includes = includes
    }

    public init(root: URL, includes: [String] = []) {
        self.init(roots: [root], includes: includes)
    }

    /// The directories actually walked.
    var scanRoots: [URL] {
        includes.isEmpty
            ? roots
            : roots.flatMap { root in includes.map { root.appendingPathComponent($0) } }
    }
}

public struct MediaFile {
    public let path: String
    public let size: Int64
    public let kind: MediaKind
}

public struct DuplicateGroup {
    public let kind: MediaKind
    public let size: Int64
    public let keep: String
    public let remove: [String]

    public var count: Int { remove.count + 1 }
    public var reclaimableBytes: Int64 { size * Int64(remove.count) }

    /// Every path in the group, keep first.
    public var allPaths: [String] { [keep] + remove }
}

public struct ScanResult {
    public let roots: [URL]
    public let includes: [String]
    public let startedAt: Date
    public let duration: TimeInterval
    public let filesScanned: Int
    public let unreadableFiles: Int
    /// Kept in iCloud but not present on this Mac. Reading one downloads it in
    /// full, so they are skipped rather than silently pulled over the network.
    public let notDownloadedFiles: Int
    /// Files the head+tail signature clustered together but that byte-for-byte
    /// comparison then rejected. Every one of these would have been a wrong
    /// REMOVE without the verification pass.
    public let filesRejectedByVerification: Int
    public let groups: [DuplicateGroup]

    public var redundantFileCount: Int {
        groups.reduce(0) { $0 + $1.remove.count }
    }

    public var reclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    public func groups(of kind: MediaKind) -> [DuplicateGroup] {
        groups.filter { $0.kind == kind }
    }

    public func reclaimableBytes(of kind: MediaKind) -> Int64 {
        groups(of: kind).reduce(0) { $0 + $1.reclaimableBytes }
    }
}

public enum ScanPhase {
    case enumerating(filesFound: Int)
    case hashing(done: Int, total: Int)
    case grouping
    case verifying(done: Int, total: Int)
}
