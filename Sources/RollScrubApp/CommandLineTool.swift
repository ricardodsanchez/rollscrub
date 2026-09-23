import Foundation

/// Putting the bundled `rollscrub` binary on the user's PATH.
///
/// The tool itself lives inside the app bundle, so it is signed, notarized and
/// updated with the app and can never drift from it. What it needs is a name on
/// PATH, and the only durable way to give it one without a privileged helper is
/// a symlink in `/usr/local/bin`.
///
/// A symlink rather than a copy, deliberately: a copy would be a second,
/// separately-signed binary that Sparkle never updates, so a customer on 1.4
/// could still be running 1.2 from the command line against a review manifest
/// written by the newer app. The link always resolves to whatever is installed.
enum CommandLineTool {

    static let linkDirectory = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
    static let linkURL = linkDirectory.appendingPathComponent("rollscrub")

    /// Where the CLI lives inside this bundle. Resolved at runtime rather than
    /// hardcoded, because the app runs from /Applications, ~/Applications, or
    /// wherever someone dragged it.
    static var bundledToolURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/rollscrub")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// What the installer found at the link path, and therefore what it may do.
    ///
    /// Modelled as a decision separate from acting on it so the rule can be
    /// tested without touching /usr/local/bin — and so the one case that must
    /// never be automatic, a real file somebody else put there, cannot be
    /// reached by accident.
    enum Existing: Equatable {
        /// Nothing there. Create the link.
        case absent
        /// Our own link, already pointing at this bundle. Nothing to do.
        case alreadyCorrect
        /// A symlink, but pointing elsewhere — an older copy of the app, or a
        /// bundle that has since moved. Safe to repoint.
        case staleSymlink(destination: String)
        /// A regular file or directory. Never touched: this is somebody's
        /// hand-built binary, a Homebrew install, or another tool that happens
        /// to share the name, and replacing it would destroy their work.
        case occupiedByRealFile
    }

    /// Decides from what is at the path, not from the filesystem directly, so
    /// every branch is reachable in a test.
    static func classify(
        symlinkDestination: String?, isSymlink: Bool, exists: Bool, wanted: String
    ) -> Existing {
        guard exists || isSymlink else { return .absent }
        guard isSymlink else { return .occupiedByRealFile }
        // A symlink whose target is gone still reports isSymlink, and is ours
        // to repoint — that is exactly the "app was replaced" case.
        guard let destination = symlinkDestination else {
            return .staleSymlink(destination: "")
        }
        return destination == wanted ? .alreadyCorrect
                                     : .staleSymlink(destination: destination)
    }

    static func existing(at url: URL = linkURL, wanting target: URL) -> Existing {
        let manager = FileManager.default
        let destination = try? manager.destinationOfSymbolicLink(atPath: url.path)
        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        // fileExists follows symlinks, so a link to a deleted app reads as
        // absent. lstat via attributesOfItem is what distinguishes them.
        let attributes = try? manager.attributesOfItem(atPath: url.path)
        let isSymlink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
        return classify(symlinkDestination: destination, isSymlink: isSymlink,
                        exists: exists, wanted: target.path)
    }

    enum Outcome: Equatable {
        case installed
        case alreadyInstalled
        /// Nothing was changed, and this is the command that would do it.
        case needsTerminal(reason: String, command: String)
    }

    /// Attempts the link, and never escalates on its own.
    ///
    /// `/usr/local/bin` is root-owned on a stock macOS and may not exist at
    /// all. Rather than ship a privileged helper — a permanent attack surface
    /// and a notarization entitlement, to save one paste — a failure hands
    /// back the exact command, which is honest about what it is asking for.
    static func install() -> Outcome {
        guard let tool = bundledToolURL else {
            return .needsTerminal(
                reason: "This copy of RollScrub does not contain the command-line tool.",
                command: "")
        }

        let command = "sudo mkdir -p \(linkDirectory.path) && "
            + "sudo ln -sf '\(tool.path)' '\(linkURL.path)'"

        switch existing(wanting: tool) {
        case .alreadyCorrect:
            return .alreadyInstalled
        case .occupiedByRealFile:
            return .needsTerminal(
                reason: "Something that is not a RollScrub link already exists at "
                    + "\(linkURL.path). It has been left alone.",
                command: "")
        case .absent, .staleSymlink:
            let manager = FileManager.default
            do {
                if !manager.fileExists(atPath: linkDirectory.path) {
                    try manager.createDirectory(at: linkDirectory,
                                                withIntermediateDirectories: true)
                }
                // Remove first: createSymbolicLink refuses an existing path,
                // and this branch has established it is a symlink of ours.
                try? manager.removeItem(at: linkURL)
                try manager.createSymbolicLink(at: linkURL, withDestinationURL: tool)
                return .installed
            } catch {
                return .needsTerminal(
                    reason: "\(linkDirectory.path) needs administrator permission.",
                    command: command)
            }
        }
    }
}
