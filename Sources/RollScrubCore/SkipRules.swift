import Foundation

/// The directories and files the scanner refuses to look at.
///
/// `.fcpbundle` is the important one: Final Cut manages media inside its own
/// libraries, and files in there are legitimately identical to originals
/// elsewhere. Descending into one and "deduplicating" it corrupts the library.
public enum SkipRules {

    /// Where `--move` parks redundant copies. Scanning it would re-discover
    /// every file already set aside and pair it with the original still in
    /// place, so it is pruned like any system directory.
    public static let reviewDirectoryName = "_duplicates_review"

    public static let systemDirectoryNames: Set<String> = [
        ".Spotlight-V100",
        ".Trashes",
        ".TemporaryItems",
        "System Volume Information",
        ".fseventsd",
        ".DocumentRevisions-V100",
        reviewDirectoryName,
    ]

    /// True when the scanner must not descend into this directory.
    public static func shouldPrune(directoryNamed name: String) -> Bool {
        if systemDirectoryNames.contains(name) { return true }
        // Opaque media packages — never look inside.
        return name.lowercased().hasSuffix(".fcpbundle")
    }

    /// True when this file is skipped regardless of its extension.
    /// `._` files are AppleDouble resource-fork stubs, not real media.
    public static func shouldSkip(fileNamed name: String) -> Bool {
        name.hasPrefix("._")
    }
}
