import Foundation

/// Decides which file in a duplicate group is the one to keep.
///
/// Every file in a group is byte-identical, so this only decides which *name*
/// survives — nothing is lost whichever way it goes.
///
/// Order of preference:
///   1. A filename that does not look like a copy.
///   2. A filename in the library's rename convention — the renamed file wins
///      over the untouched camera original, so `20221208---2.MP4` survives
///      and `C0118.MP4` is the one removed.
///   3. The longest filename, so the most descriptive rename wins:
///      `20240807-Leica-LEICA Q2-Tokyo-L1020661.DNG` over the terser variant.
///   4. Longest full path, then alphabetical, so the choice is stable.
public enum KeepSelector {

    /// The library's rename convention: a 6- or 8-digit date prefix, as in
    /// `20240807-Leica-LEICA Q2-Tokyo-L1020661.DNG` or `202207-Sony7III-…`.
    static let renamedPattern = #"^\d{6,8}[-_]"#

    public static func looksRenamed(filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension
        return stem.range(of: renamedPattern, options: .regularExpression) != nil
    }

    /// Copy markers, deliberately narrow.
    ///
    /// Trailing numbers are *not* markers on their own — they are sequence
    /// numbers or empty fields in the rename convention. `<date>--<location>-<n>`
    /// collapses to `20220718---2-38` when the location is blank, and
    /// `20230924-LEICA Q2-Seattle-8` and `video_…_6553752_0` are originals.
    /// Only spellings a camera or the rename scheme never produces count.
    static let copyPatterns = [
        #" \d{1,2}$"#,                       // "IMG_8672 2"   (Finder's own)
        #"[ _-]?\(\d{1,2}\)$"#,              // "photo (1)"
        #"[ _-]cop(y|ie)([ _-]\d{1,2})?$"#,  // "photo copy", "photo copy 2"
        #"^\d{1,2}_"#,                       // "16_20251214-LEICA Q2-…"
    ]

    public static func looksLikeCopy(filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        return copyPatterns.contains {
            stem.range(of: $0, options: .regularExpression) != nil
        }
    }

    /// Trailing markers that mean "copy of" only when removing them leaves the
    /// name of another file in the same group.
    ///
    /// This is the relative counterpart to `looksLikeCopy`, and it can be far
    /// more aggressive precisely because it is relative. A bare trailing `-2`
    /// is an ordinary part of the rename convention — `20230924-LEICA
    /// Q2-Seattle-8` is an original — so the absolute test above must never
    /// look for it. But when `…-5802-2.DNG` sits in a group that also contains
    /// `…-5802.DNG`, the longer name is that file's copy and nothing else.
    static let derivedSuffixPattern =
        #"[ _-]\(?\d{1,3}\)?$|[ _-]?cop(y|ie)([ _-]\d{1,3})?$"#

    static func stem(ofPath path: String) -> String {
        (((path as NSString).lastPathComponent) as NSString)
            .deletingPathExtension
            .lowercased()
    }

    /// True when `stem` is another group member's name plus a copy marker.
    static func isDerived(_ stem: String, from others: Set<String>) -> Bool {
        guard let marker = stem.range(
            of: derivedSuffixPattern, options: [.regularExpression, .caseInsensitive])
        else { return false }
        let base = String(stem[stem.startIndex..<marker.lowerBound])
        return !base.isEmpty && base != stem && others.contains(base)
    }

    /// Returns the path to keep. `paths` must be non-empty.
    public static func chooseKeep(from paths: [String]) -> String {
        let stems = Set(paths.map(stem(ofPath:)))

        // "Is this a copy?" is asked two ways: of the name alone, and of the
        // name against the rest of the group. Either answer disqualifies it,
        // so a file whose name is just an original's with "-2" on the end
        // stops winning the longest-name tiebreak below.
        func isCopy(_ path: String) -> Bool {
            looksLikeCopy(filename: (path as NSString).lastPathComponent)
                || isDerived(stem(ofPath: path), from: stems)
        }

        return paths.min { lhs, rhs in
            let lhsName = (lhs as NSString).lastPathComponent
            let rhsName = (rhs as NSString).lastPathComponent

            let lhsCopy = isCopy(lhs)
            let rhsCopy = isCopy(rhs)
            if lhsCopy != rhsCopy { return !lhsCopy }

            let lhsRenamed = looksRenamed(filename: lhsName)
            let rhsRenamed = looksRenamed(filename: rhsName)
            if lhsRenamed != rhsRenamed { return lhsRenamed }

            if lhsName.count != rhsName.count { return lhsName.count > rhsName.count }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs < rhs
        }!
    }
}
