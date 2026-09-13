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
    /// Packages whose contents belong to an application's own database.
    ///
    /// Each of these keeps originals and generated derivatives side by side and
    /// tracks them in a catalogue. The derivatives are legitimately identical to
    /// files elsewhere, so a sweep finds "duplicates" that the owning app is
    /// relying on — and removing them corrupts the library, silently, with the
    /// damage only surfacing later. Photos has its own Duplicates view for the
    /// job this app would otherwise be doing badly.
    /// Lightroom Classic is unaffected: it keeps a .lrcat catalogue beside
    /// ordinary folders of originals, and those folders scan normally. Only
    /// Lightroom's packaged .lrlibrary manages its contents this way.
    public static let managedLibrarySuffixes = [
        ".fcpbundle",          // Final Cut Pro
        ".photoslibrary",      // Photos
        ".aplibrary",          // Aperture
        ".migratedaplibrary",  // Aperture, after migration
        ".lrlibrary",          // Lightroom
    ]

    /// Directories full of machine-generated files that are never anyone's
    /// photos, and are frequently enormous. A Documents folder with a few
    /// checked-out projects in it holds far more files in here than in the
    /// whole rest of the tree.
    public static let toolingDirectoryNames: Set<String> = [
        "node_modules",
        "Pods",
        "DerivedData",
        "__pycache__",
    ]

    public static func shouldPrune(directoryNamed name: String) -> Bool {
        if systemDirectoryNames.contains(name) { return true }
        if toolingDirectoryNames.contains(name) { return true }

        // Hidden directories hold application state, caches and version
        // control — .git, .build, .venv, .cache. Nobody keeps the photos they
        // want deduplicated inside one, and walking them is most of the cost
        // of scanning a home folder. Hidden *files* are still examined; this
        // only stops the scanner descending.
        if name.hasPrefix(".") && name != "." && name != ".." { return true }

        let lowered = name.lowercased()
        return managedLibrarySuffixes.contains { lowered.hasSuffix($0) }
    }

    /// True when this file is skipped regardless of its extension.
    /// `._` files are AppleDouble resource-fork stubs, not real media.
    public static func shouldSkip(fileNamed name: String) -> Bool {
        name.hasPrefix("._")
    }
}
