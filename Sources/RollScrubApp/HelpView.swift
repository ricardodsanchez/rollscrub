import RollScrubCore
import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                HelpSection("Scanning") {
                    HelpText("Choose **Scan Folders…** and pick one or more folders or "
                             + "drives. To select several at once, open a folder that "
                             + "contains them — your home folder, for example — then "
                             + "⌘-click each one before choosing Scan.")
                    HelpText("Passing more than one folder finds duplicates *across* all "
                             + "of them, not just within each one separately. A photo in "
                             + "your Pictures folder and the same photo on an external "
                             + "drive show up as one pair.")
                    HelpText("Scanning only reads. Nothing is moved, changed, or deleted "
                             + "while a scan runs.")
                    HelpText("Files kept in iCloud but not downloaded to this Mac are "
                             + "counted and skipped, never compared. Reading a single byte "
                             + "of one downloads the whole file, so a scan would otherwise "
                             + "pull your library back over the network just to look at it. "
                             + "To include them, download them in Finder first and scan again.")
                }

                HelpSection("How matches are found") {
                    HelpText("Files are grouped by exact byte size first, then by a "
                             + "signature read from the start and end of each file. "
                             + "Anything still grouped together is then compared in "
                             + "full — every byte.")
                    HelpText("Nothing is ever shown as a duplicate on the strength of the "
                             + "signature alone. Files that merely look alike are split "
                             + "apart by that final comparison and never presented as a "
                             + "pair. This is why RollScrub will not flag two similar "
                             + "photos from the same burst: they are different files.")
                }

                HelpSection("Reviewing pairs") {
                    HelpText("Each pair shows the copy being kept on the left and the "
                             + "duplicate under judgement on the right, with the full path "
                             + "of each so you can tell which is which. For videos, "
                             + "**Play both** starts the two clips together.")
                    HelpText("Marking a pair changes nothing on disk. Decisions are only "
                             + "carried out when you press the button at the bottom right.")

                    ShortcutTable(rows: [
                        ("D", "Mark the duplicate for removal"),
                        ("K", "Keep both, leave them where they are"),
                        ("U", "Clear the mark on this pair"),
                        ("↓", "Next pair"),
                        ("↑", "Previous pair"),
                    ])
                }

                HelpSection("What happens when you apply") {
                    HelpText("Files marked for removal go to the **Trash**, never a direct "
                             + "delete — they stay recoverable from the Finder until you "
                             + "empty it.")
                    HelpText("Immediately before each file goes, it is compared byte for "
                             + "byte against the copy being kept one more time. If the "
                             + "copy being kept has gone missing, or the two no longer "
                             + "match, that file is left exactly where it is and reported "
                             + "under **Failed**.")
                    HelpText("Files stored in iCloud that have not been downloaded yet are "
                             + "skipped rather than silently pulled down or removed from "
                             + "your other devices. Open one in the Finder, then use "
                             + "**Retry failed**.")
                }

                HelpSection("Photo libraries are left alone") {
                    HelpText("RollScrub never looks inside a **Photos**, **Lightroom**, "
                             + "**Aperture** or **Final Cut Pro** library. Each of those "
                             + "keeps your originals and its own generated copies together "
                             + "under a database, so the copies are meant to be identical "
                             + "to files elsewhere — and removing one leaves the app "
                             + "pointing at a file that is no longer there. Apple's own "
                             + "guidance is not to alter a photo library's contents in the "
                             + "Finder at all.")
                    HelpText("For duplicates **inside** your Photos library, use Photos' "
                             + "own Duplicates view, in the sidebar under Utilities. It "
                             + "merges duplicates rather than deleting files, so keywords, "
                             + "albums and edits survive. Lightroom has duplicate-finding "
                             + "plugins that work the same way, through its catalogue.")
                    HelpText("RollScrub is for everything outside those libraries: exports, "
                             + "card dumps, backup drives, Downloads, iCloud Drive — where "
                             + "copies pile up and nothing is keeping track.")
                }

                HelpSection("Your progress is saved") {
                    HelpText("Marks are remembered per scan, so closing the window and "
                             + "coming back to a long review picks up where you left off.")
                }

                HelpSection("Command line") {
                    HelpText("RollScrub also ships as a command-line tool for scripted or "
                             + "very large sweeps. It writes a text and CSV report and, "
                             + "with `--move`, sets duplicates aside in a review folder "
                             + "inside whichever drive each was found on — never deleting, "
                             + "and reversible with `--undo`.")
                    CodeBlock("rollscrub ~/Pictures \"/Volumes/Extreme Pro\"")
                    HelpText("Run `rollscrub --help` for the full list of options.")
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 620, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(AppInfo.name) Help").font(.title2.weight(.semibold))
            Text("Finding and removing duplicate photos and videos, safely.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pieces

private struct HelpSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
    }
}

/// Markdown so the copy can carry emphasis without hand-built attributed strings.
private struct HelpText: View {
    let markdown: String

    init(_ markdown: String) { self.markdown = markdown }

    var body: some View {
        Text(.init(markdown))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CodeBlock: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct ShortcutTable: View {
    let rows: [(key: String, meaning: String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            ForEach(rows, id: \.key) { row in
                GridRow {
                    Text(row.key)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .frame(width: 26)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(row.meaning).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 2)
    }
}
