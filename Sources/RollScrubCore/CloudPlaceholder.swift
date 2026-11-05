import Foundation

/// Whether a file is kept in the cloud but not actually on this Mac.
///
/// Reading a single byte of such a file downloads all of it, so anything that
/// is about to read or move a file asks this first. Current macOS keeps
/// online-only files from iCloud Drive as "dataless" files, which the file
/// system marks with `SF_DATALESS` (checked on real files). Dropbox and
/// OneDrive run on the same File Provider system and keep theirs the same
/// way; no copy of either was available to check. That mark is read with
/// one `stat`, about 5 µs, and is asked first. Only a file without it goes on
/// to iCloud's own status, a round trip to the file provider daemon costing
/// about a millisecond in an iCloud folder, which still covers anything
/// iCloud reports that the mark does not.
public enum CloudPlaceholder {

    /// True when `path` is an online-only file. A status the cloud does not
    /// report counts as not downloaded: skipping a file costs nothing,
    /// reading a placeholder costs a download.
    public static func isNotDownloaded(_ path: String) -> Bool {
        isNotDownloaded(flags: fileFlags(path), cloudStatus: {
            // A fresh URL, so a status cached on some older URL object for
            // this path cannot answer for a file that has been evicted since.
            let values = try? URL(fileURLWithPath: path).resourceValues(
                forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            return (values?.isUbiquitousItem, values?.ubiquitousItemDownloadingStatus)
        })
    }

    /// The decision itself, apart from the lookups, so it can be tested.
    /// `cloudStatus` is asked only when the flags have not already answered,
    /// because it is the expensive half.
    static func isNotDownloaded(
        flags: UInt32?,
        cloudStatus: () -> (isUbiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?)
    ) -> Bool {
        if let flags, isDataless(flags: flags) { return true }
        let cloud = cloudStatus()
        return isNotDownloaded(isUbiquitous: cloud.isUbiquitous, status: cloud.status)
    }

    /// iCloud's own answer. Only an item iCloud claims counts. A volume
    /// iCloud knows nothing about (an exFAT card, a disk image) answers nil
    /// rather than false, and treating that as evicted would refuse every
    /// move on every external drive.
    static func isNotDownloaded(
        isUbiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?
    ) -> Bool {
        guard isUbiquitous == true else { return false }
        return status != .current
    }

    /// True when a file already opened for reading is online-only. Asked by
    /// everything that reads file contents, right after `open` and before the
    /// first read: opening a dataless file does not download it, reading
    /// does, and this leaves no gap between the check and the open.
    public static func isNotDownloaded(openFile fd: Int32) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return false }
        return isDataless(flags: info.st_flags)
    }

    /// Makes the kernel refuse, rather than perform, any download this
    /// process would trigger by reading an online-only file: the read fails
    /// with EDEADLK and the file stays in the cloud (checked on a real iCloud
    /// file). The checks above decide what to skip; this is what makes a
    /// missed one fail instead of downloading. Called once at launch by the
    /// app and the CLI. Returns false if the system would not set it.
    @discardableResult
    public static func refuseDownloadsForThisProcess() -> Bool {
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
    }

    /// Runs `body` with downloads allowed again, on this thread only. For the
    /// few small files RollScrub must read wherever they live: an undo
    /// manifest or saved review state in an iCloud folder can be evicted
    /// like anything else, and refusing to download a few kilobytes there
    /// would stand between the user and undo. A thread's own setting wins
    /// over the process's (checked on a real iCloud file). `body` must not
    /// suspend, so it cannot resume on another thread.
    public static func allowingDownloads<T>(_ body: () throws -> T) rethrows -> T {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let before = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(type, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        defer {
            _ = setiopolicy_np(type, IOPOL_SCOPE_THREAD,
                               before < 0 ? IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT : before)
        }
        return try body()
    }

    static func isDataless(flags: UInt32) -> Bool {
        flags & UInt32(SF_DATALESS) != 0
    }

    /// The flags of the file `path` leads to, following a symlink the way the
    /// read will, or nil when it cannot be read. `stat` reads the inode only;
    /// it never downloads.
    private static func fileFlags(_ path: String) -> UInt32? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_flags
    }
}
