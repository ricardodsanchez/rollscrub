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
    /// Lightroom's packaged .lrlibrary manages its contents this way. Capture
    /// One sessions are the same: a .cosessiondb file beside ordinary folders,
    /// so only its packaged .cocatalog is listed.
    public static let managedLibrarySuffixes = [
        ".fcpbundle",          // Final Cut Pro
        ".photoslibrary",      // Photos
        ".photolibrary",       // iPhoto, still on disk after Photos migrates it
        ".aplibrary",          // Aperture
        ".migratedaplibrary",  // Aperture, after migration
        ".lrlibrary",          // Lightroom
        ".imovielibrary",      // iMovie
        ".theater",            // iMovie Theater, older iMovie's shared copies
        ".cocatalog",          // Capture One catalogue
        ".tvlibrary",          // TV's database; its media is beside it, see below
        ".musiclibrary",       // Music's database; likewise
    ]

    /// Music and TV keep their media in an ordinary folder next to the
    /// library package, not inside it: `~/Music/Music/Media.localized` beside
    /// `Music Library.musiclibrary`, `~/Movies/TV/Media.localized` beside
    /// `TV Library.tvlibrary`, and on a Mac upgraded from iTunes,
    /// `iTunes Media` beside `iTunes Library.itl`. Each app tracks those
    /// files by path, so moving one breaks its entry. Such a folder is only
    /// treated as managed when one of these sits beside it; a folder of your
    /// own called Media is scanned as usual.
    static let appMediaFolderNames: Set<String> = ["media", "media.localized", "itunes media"]
    static let appMediaOwnerSuffixes = [".musiclibrary", ".tvlibrary", ".itl"]

    /// True when `url` is a Music, TV or iTunes media folder. Lists the parent
    /// only for a folder with one of those three names, so it costs one
    /// directory read per such folder and nothing for any other.
    public static func isAppMediaFolder(_ url: URL) -> Bool {
        guard appMediaFolderNames.contains(url.lastPathComponent.lowercased()) else { return false }
        let parent = url.deletingLastPathComponent().path
        guard let siblings = try? FileManager.default.contentsOfDirectory(atPath: parent)
        else { return false }
        return siblings.contains { sibling in
            let lowered = sibling.lowercased()
            return appMediaOwnerSuffixes.contains { lowered.hasSuffix($0) }
        }
    }

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

        return isManagedLibrary(named: name)
    }

    /// True when a directory with this name is a managed library package.
    /// Case-insensitive, as Finder and the owning apps are.
    public static func isManagedLibrary(named name: String) -> Bool {
        let lowered = name.lowercased()
        return managedLibrarySuffixes.contains { lowered.hasSuffix($0) }
    }

    /// The managed library, or Music, TV or iTunes media folder, that `path`
    /// is, or sits inside, or nil.
    ///
    /// The walk prunes a library it meets on the way down, but it never sees
    /// the folders above its starting point. A scan root or `--include` that
    /// is already inside a library would be walked in full, and every
    /// derivative in there offered up for removal, so roots are checked here
    /// before anything is walked, and files again before anything is moved.
    ///
    /// Checked twice: as given, and with symlinks resolved, so a link that
    /// leads into a library is caught as well as a library under a link.
    /// Costs a handful of `lstat` calls per path, so it is for roots and move
    /// candidates, never for every entry of a walk.
    public static func managedLibrary(containing path: String) -> URL? {
        let given = URL(fileURLWithPath: path)
        // Resolved from the path as typed, not after `.standardized`, which
        // collapses `..` as text. The system follows a link first and then
        // goes up from wherever it led, so `Linked/..`, with Linked pointing
        // into a library, is the library itself. A path with any missing part
        // comes back unresolved, leaving the check on the path as given;
        // nothing is read or moved from a path that does not exist.
        for url in [given.standardized, given.resolvingSymlinksInPath()] {
            // Plain strings: appending to a file URL can stat each component.
            let components = url.pathComponents
            for (index, name) in components.enumerated() {
                let folder = URL(fileURLWithPath: NSString.path(
                    withComponents: Array(components[...index])))
                if isManagedLibrary(named: name) || isAppMediaFolder(folder) { return folder }
            }
        }
        return nil
    }

    /// True when this file is skipped regardless of its extension.
    /// `._` files are AppleDouble resource-fork stubs, not real media.
    public static func shouldSkip(fileNamed name: String) -> Bool {
        name.hasPrefix("._")
    }
}
