import Foundation

/// Whether a file is in iCloud but not actually on this Mac.
///
/// Reading a single byte of such a file downloads all of it, so anything that
/// is about to read or move a file asks this first. It is a round trip to the
/// file provider daemon, about a millisecond per file in an iCloud folder, so
/// it is for the handful of files about to be touched, never the scan walk.
/// The scan does its own version of this check, once per media file, after
/// the cheap filters.
public enum ICloudPlaceholder {

    /// True when `path` is an iCloud item whose current contents are not
    /// downloaded. A status iCloud does not report counts as not downloaded:
    /// skipping a file costs nothing, reading a placeholder costs a download.
    public static func isNotDownloaded(_ path: String) -> Bool {
        // A fresh URL, so a status cached on some older URL object for this
        // path cannot answer for a file that has been evicted since.
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return isNotDownloaded(
            isUbiquitous: values?.isUbiquitousItem,
            status: values?.ubiquitousItemDownloadingStatus)
    }

    /// The decision itself, apart from the lookup, so it can be tested.
    ///
    /// Only an item iCloud claims counts. A volume iCloud knows nothing about
    /// (an exFAT card, a disk image) answers nil rather than false, and
    /// treating that as evicted would refuse every move on every external
    /// drive.
    static func isNotDownloaded(
        isUbiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?
    ) -> Bool {
        guard isUbiquitous == true else { return false }
        return status != .current
    }
}
