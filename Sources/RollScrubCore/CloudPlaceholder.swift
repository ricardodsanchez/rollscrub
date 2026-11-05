import Foundation

/// Whether a file is kept in the cloud but not actually on this Mac.
///
/// Reading a single byte of such a file downloads all of it, so anything that
/// is about to read or move a file asks this first. iCloud Drive, Dropbox,
/// OneDrive and Google Drive all keep online-only files the same way on
/// current macOS: as "dataless" files, which the file system marks with
/// `SF_DATALESS`. That mark is read with one `lstat`, about 5 µs, and is
/// asked first. Only a file without it goes on to iCloud's own status, a
/// round trip to the file provider daemon costing about a millisecond in an
/// iCloud folder, which still covers anything iCloud reports that the mark
/// does not.
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
        if let flags, flags & UInt32(SF_DATALESS) != 0 { return true }
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

    /// The file's own flags, without following a symlink, or nil when it
    /// cannot be read. `lstat` reads the inode only; it never downloads.
    private static func fileFlags(_ path: String) -> UInt32? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_flags
    }
}
