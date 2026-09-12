import Foundation

/// Read-only duplicate scanner. Nothing here mutates the filesystem.
public final class DuplicateScanner {

    private let config: ScanConfig
    private let progress: ((ScanPhase) -> Void)?

    public init(config: ScanConfig, progress: ((ScanPhase) -> Void)? = nil) {
        self.config = config
        self.progress = progress
    }

    public func scan() -> ScanResult {
        let startedAt = Date()
        let clock = DispatchTime.now()

        let files = enumerateMedia()

        // Only sizes shared by 2+ files can possibly contain duplicates. On a
        // real drive this throws away ~95% of the work before any file is read.
        let candidates = sizeCollisions(among: files)

        let signed = signatures(for: candidates)

        // The signature is only a cheap filter. Nothing below is reported as a
        // duplicate until every byte has been compared.
        let clusters = cluster(signed)
        let confirmed = verify(clusters)
        let groups = buildGroups(from: confirmed)

        let clusteredFiles = clusters.reduce(0) { $0 + $1.count }
        let confirmedFiles = confirmed.reduce(0) { $0 + $1.count }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - clock.uptimeNanoseconds) / 1e9
        return ScanResult(
            roots: config.roots,
            includes: config.includes,
            startedAt: startedAt,
            duration: elapsed,
            filesScanned: files.count,
            unreadableFiles: candidates.count - signed.count,
            filesRejectedByVerification: clusteredFiles - confirmedFiles,
            groups: groups
        )
    }

    // MARK: - Step 1: enumerate and filter

    private func enumerateMedia() -> [MediaFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .nameKey]
        let keySet = Set(keys)
        let fm = FileManager.default
        var files: [MediaFile] = []

        for scanRoot in config.scanRoots {
            guard let enumerator = fm.enumerator(
                at: scanRoot,
                includingPropertiesForKeys: keys,
                options: [],  // no .skipsHiddenFiles — skip rules are explicit below
                errorHandler: { _, _ in true }  // unreadable subtree: keep going
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
                let name = values.name ?? url.lastPathComponent

                if values.isDirectory == true {
                    if SkipRules.shouldPrune(directoryNamed: name) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                guard values.isRegularFile == true else { continue }
                guard !SkipRules.shouldSkip(fileNamed: name) else { continue }
                guard let size = values.fileSize, size > 0 else { continue }
                guard let kind = MediaKind(pathExtension: url.pathExtension) else { continue }

                files.append(MediaFile(path: url.path, size: Int64(size), kind: kind))
                if files.count % 2000 == 0 {
                    progress?(.enumerating(filesFound: files.count))
                }
            }
        }

        progress?(.enumerating(filesFound: files.count))
        return files
    }

    // MARK: - Step 2: bucket by exact byte size

    private func sizeCollisions(among files: [MediaFile]) -> [MediaFile] {
        var bySize: [Int64: [MediaFile]] = [:]
        for file in files {
            bySize[file.size, default: []].append(file)
        }
        return bySize.values.filter { $0.count > 1 }.flatMap { $0 }
    }

    // MARK: - Step 3: content signatures (parallel, ~256 KB read per file)

    private func signatures(for candidates: [MediaFile]) -> [(MediaFile, String)] {
        guard !candidates.isEmpty else { return [] }

        var computed = [String?](repeating: nil, count: candidates.count)
        let total = candidates.count
        let counter = ProgressCounter(total: total) { [progress] done, total in
            progress?(.hashing(done: done, total: total))
        }

        computed.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: total) { index in
                let file = candidates[index]
                buffer[index] = ContentSignature.compute(path: file.path, size: file.size)
                counter.increment()
            }
        }

        progress?(.hashing(done: total, total: total))
        return zip(candidates, computed).compactMap { file, signature in
            signature.map { (file, $0) }
        }
    }

    // MARK: - Step 4: cluster on the cheap signature

    private func cluster(_ signed: [(MediaFile, String)]) -> [[MediaFile]] {
        progress?(.grouping)

        struct Key: Hashable {
            let size: Int64
            let signature: String
        }

        var buckets: [Key: [MediaFile]] = [:]
        for (file, signature) in signed {
            buckets[Key(size: file.size, signature: signature), default: []].append(file)
        }
        return buckets.values.filter { $0.count > 1 }.map { $0 }
    }

    // MARK: - Step 5: confirm every cluster byte for byte

    /// Splits each candidate cluster into true equivalence classes by comparing
    /// actual file contents. A cluster whose members only *look* alike through
    /// the head+tail signature is broken apart here, and singletons are dropped.
    private func verify(_ clusters: [[MediaFile]]) -> [[MediaFile]] {
        guard !clusters.isEmpty else { return [] }

        let total = clusters.count
        let counter = ProgressCounter(total: total) { [progress] done, total in
            progress?(.verifying(done: done, total: total))
        }

        var results = [[[MediaFile]]](repeating: [], count: total)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: total) { index in
                buffer[index] = Self.partitionByContent(clusters[index])
                counter.increment()
            }
        }

        progress?(.verifying(done: total, total: total))
        return results.flatMap { $0 }.filter { $0.count > 1 }
    }

    /// Groups files that compare equal byte for byte. Each file is tested
    /// against one representative per class already found, so the common
    /// two-file cluster costs exactly one comparison.
    static func partitionByContent(_ cluster: [MediaFile]) -> [[MediaFile]] {
        var classes: [[MediaFile]] = []
        for file in cluster {
            if let index = classes.firstIndex(where: {
                ContentSignature.verifyIdentical($0[0].path, file.path)
            }) {
                classes[index].append(file)
            } else {
                classes.append([file])
            }
        }
        return classes
    }

    // MARK: - Step 6: pick a keeper

    private func buildGroups(from confirmed: [[MediaFile]]) -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        for members in confirmed {
            let paths = members.map(\.path).sorted()
            let keep = KeepSelector.chooseKeep(from: paths)
            groups.append(
                DuplicateGroup(
                    kind: members[0].kind,
                    size: members[0].size,
                    keep: keep,
                    remove: paths.filter { $0 != keep }
                )
            )
        }

        // Biggest win first, then stable by path.
        groups.sort {
            $0.reclaimableBytes != $1.reclaimableBytes
                ? $0.reclaimableBytes > $1.reclaimableBytes
                : $0.keep < $1.keep
        }
        return groups
    }
}

/// Thread-safe progress tally that reports at most every 1%.
private final class ProgressCounter {
    private let lock = NSLock()
    private var done = 0
    private let total: Int
    private let step: Int
    private let report: (Int, Int) -> Void

    init(total: Int, report: @escaping (Int, Int) -> Void) {
        self.total = total
        self.step = max(1, total / 100)
        self.report = report
    }

    func increment() {
        lock.lock()
        done += 1
        let shouldReport = done % step == 0
        let snapshot = done
        lock.unlock()
        if shouldReport { report(snapshot, total) }
    }
}
