import Foundation

public enum ReportWriter {

    /// 1024-based, one decimal — matches the Python prototype's `human()`.
    public static func humanSize(_ bytes: Int64) -> String {
        var value = Double(bytes)
        for unit in ["B", "KB", "MB", "GB", "TB"] {
            if value < 1024 { return String(format: "%.1f %@", value, unit) }
            value /= 1024
        }
        return String(format: "%.1f PB", value)
    }

    /// Right-align `text` in a field of `width`.
    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width
            ? text
            : String(repeating: " ", count: width - text.count) + text
    }

    static func grouped(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    // MARK: - Plain-text report

    public static func text(for result: ScanResult) -> String {
        var out = ""

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"

        out += "RollScrub report\n"
        out += String(repeating: "=", count: 60) + "\n\n"
        out += "Roots scanned   : \(result.roots.map(\.path).joined(separator: ", "))\n"
        out += "Included        : "
            + (result.includes.isEmpty ? "(entire root)" : result.includes.joined(separator: ", "))
            + "\n"
        out += "Scanned at      : \(stamp.string(from: result.startedAt))\n"
        out += String(format: "Duration        : %.1fs\n\n", result.duration)

        out += "Media files scanned : \(grouped(result.filesScanned))\n"
        out += "Duplicate groups    : \(grouped(result.groups.count))\n"
        out += "Redundant files     : \(grouped(result.redundantFileCount))\n"
        out += "Reclaimable         : \(humanSize(result.reclaimableBytes))"
        out += " (\(grouped(Int(result.reclaimableBytes))) bytes)\n"
        if result.unreadableFiles > 0 {
            out += "Unreadable (skipped): \(grouped(result.unreadableFiles))\n"
        }
        if result.filesRejectedByVerification > 0 {
            out += "Rejected by verify  : \(grouped(result.filesRejectedByVerification))"
            out += "  (looked identical, differed on full compare)\n"
        }
        out += "\n"

        out += "Breakdown\n"
        out += String(repeating: "-", count: 60) + "\n"
        for kind in [MediaKind.photo, .video] {
            let groups = result.groups(of: kind)
            let redundant = groups.reduce(0) { $0 + $1.remove.count }
            let label = (kind == .photo ? "photos" : "videos").padding(
                toLength: 8, withPad: " ", startingAt: 0)
            out += "  \(label)"
            out += pad(grouped(groups.count), 7) + " groups"
            out += pad(grouped(redundant), 8) + " redundant"
            out += pad(humanSize(result.reclaimableBytes(of: kind)), 12) + "\n"
        }
        out += "\n"

        out += "Duplicate groups (largest reclaimable first)\n"
        out += String(repeating: "-", count: 60) + "\n"
        for (index, group) in result.groups.enumerated() {
            out += "\n[\(index + 1)] \(group.kind.rawValue)  \(humanSize(group.size))"
            out += "  x\(group.count) copies  ->  \(humanSize(group.reclaimableBytes)) reclaimable\n"
            for path in group.allPaths.sorted() {
                let action = path == group.keep ? "KEEP  " : "REMOVE"
                out += "    \(action)  \(path)\n"
            }
        }

        out += "\n"
        out += String(repeating: "-", count: 60) + "\n"
        out += "Nothing was moved or deleted. This scan was read-only.\n"
        out += "Every group above was confirmed byte for byte: files were clustered by\n"
        out += "size and a head+tail signature, then compared in full. No file is listed\n"
        out += "as REMOVE unless all of its bytes match the KEEP file exactly.\n"
        return out
    }

    // MARK: - CSV sidecar

    public static func csv(for result: ScanResult) -> String {
        var out = "group,type,size_bytes,size_human,action,full_path\n"
        for (index, group) in result.groups.enumerated() {
            for path in group.allPaths.sorted() {
                let action = path == group.keep ? "KEEP" : "REMOVE"
                let fields = [
                    String(index + 1),
                    group.kind.rawValue,
                    String(group.size),
                    humanSize(group.size),
                    action,
                    path,
                ]
                out += fields.map(escapeCSV).joined(separator: ",") + "\n"
            }
        }
        return out
    }

    /// RFC 4180 quoting — paths on this drive contain spaces and can contain commas.
    static func escapeCSV(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
