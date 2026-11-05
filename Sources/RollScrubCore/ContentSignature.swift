import CryptoKit
import Foundation

/// File content comparison.
///
/// Both entry points use POSIX I/O into fixed, reusable buffers rather than
/// `FileHandle`/`Data`. That is not micro-optimisation: `FileHandle.read`
/// hands back autoreleased objects, and inside `concurrentPerform` the
/// autorelease pools do not drain until the whole parallel block finishes, so
/// streaming a 15 GB video accumulates every 1 MB chunk it ever read. That
/// costs gigabytes of resident memory and gets the process killed.
public enum ContentSignature {

    public static let blockSize = 131_072  // 128 KB
    static let wholeFileThreshold: Int64 = 262_144  // 256 KB
    static let compareChunk = 1 << 20  // 1 MB

    // MARK: - Cheap signature (candidate filter only)

    /// SHA-256 over the first 128 KB + the last 128 KB + the byte size.
    ///
    /// Reading only head and tail keeps I/O tiny: a 14 GB video costs the same
    /// 256 KB as a 300 KB one. This is only ever a *filter* — it cannot see a
    /// difference confined to the middle of a file, so a match here is never
    /// enough to call two files duplicates. `verifyIdentical` is the authority.
    public static func compute(path: String, size: Int64) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // A file can go online-only at any point after the scan saw it.
        // Opening it is free; reading it would download it.
        guard !CloudPlaceholder.isNotDownloaded(openFile: fd) else { return nil }

        let capacity = min(Int(size), blockSize)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(capacity, 1), alignment: 64)
        defer { buffer.deallocate() }

        var hasher = SHA256()

        if size <= wholeFileThreshold {
            // Small enough that the head+tail shortcut buys nothing — hash it all.
            var offset: Int64 = 0
            while offset < size {
                let want = min(capacity, Int(size - offset))
                let got = readFully(fd, buffer, want, at: offset)
                guard got == want else { return nil }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: got))
                offset += Int64(got)
            }
        } else {
            for offset in [0, size - Int64(blockSize)] {
                let got = readFully(fd, buffer, blockSize, at: offset)
                guard got == blockSize else { return nil }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: got))
            }
        }

        // Fold the size in so files differing only in length can never collide.
        hasher.update(data: Data(String(size).utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Authoritative comparison

    /// True only when every byte of both files matches.
    ///
    /// Returns false if either file cannot be read, so an unreadable file is
    /// never reported as a duplicate.
    public static func verifyIdentical(_ pathA: String, _ pathB: String) -> Bool {
        if pathA == pathB { return true }

        let fdA = open(pathA, O_RDONLY)
        guard fdA >= 0 else { return false }
        defer { close(fdA) }
        let fdB = open(pathB, O_RDONLY)
        guard fdB >= 0 else { return false }
        defer { close(fdB) }
        // Checked on the files actually opened, so neither a symlink nor an
        // eviction since the last check can slip a download past it.
        guard !CloudPlaceholder.isNotDownloaded(openFile: fdA),
              !CloudPlaceholder.isNotDownloaded(openFile: fdB)
        else { return false }

        // One-shot sequential streaming: read ahead, and keep these pages out
        // of the unified buffer cache so a 250 GB pass does not evict
        // everything else the machine is using.
        for fd in [fdA, fdB] {
            _ = fcntl(fd, F_RDAHEAD, 1)
            _ = fcntl(fd, F_NOCACHE, 1)
        }

        let bufferA = UnsafeMutableRawPointer.allocate(byteCount: compareChunk, alignment: 64)
        let bufferB = UnsafeMutableRawPointer.allocate(byteCount: compareChunk, alignment: 64)
        defer {
            bufferA.deallocate()
            bufferB.deallocate()
        }

        var offset: Int64 = 0
        while true {
            let gotA = readFully(fdA, bufferA, compareChunk, at: offset)
            let gotB = readFully(fdB, bufferB, compareChunk, at: offset)
            if gotA < 0 || gotB < 0 { return false }  // read error
            if gotA != gotB { return false }          // different lengths
            if gotA == 0 { return true }              // both at EOF, all bytes matched
            if memcmp(bufferA, bufferB, gotA) != 0 { return false }
            offset += Int64(gotA)
        }
    }

    // MARK: - I/O

    /// Reads up to `count` bytes at `offset`, looping over short reads.
    /// Returns the byte count read (0 at EOF), or -1 on error.
    private static func readFully(
        _ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, at offset: Int64
    ) -> Int {
        var total = 0
        while total < count {
            let got = pread(fd, buffer.advanced(by: total), count - total, off_t(offset) + off_t(total))
            if got < 0 {
                if errno == EINTR { continue }
                return -1
            }
            if got == 0 { break }  // EOF
            total += got
        }
        return total
    }
}
