import AppKit
import SwiftUI

@main
struct RollScrubApp: App {
    // Owned here so the menu bar can drive the same session the window shows.
    @StateObject private var session = ReviewSession()
    @StateObject private var updater = Updater()
    @StateObject private var license = LicenseModel()
    @Environment(\.openWindow) private var openWindow

    /// Reports what happened in an alert, because a menu item that silently
    /// succeeds and a menu item that silently fails look identical — and this
    /// one usually cannot succeed without a password.
    private func installCommandLineTool() {
        let alert = NSAlert()
        switch CommandLineTool.install() {
        case .installed:
            alert.messageText = "Command line tool installed"
            alert.informativeText = "Open a new terminal window and run "
                + "`rollscrub --help`. It uses the licence you activated here."
        case .alreadyInstalled:
            alert.messageText = "Already installed"
            alert.informativeText = "`rollscrub` already points at this copy of "
                + "RollScrub."
        case .needsTerminal(let reason, let command):
            alert.messageText = "RollScrub cannot install it for you"
            alert.informativeText = command.isEmpty
                ? reason
                : "\(reason)\n\nRun this in Terminal:\n\n\(command)"
            if !command.isEmpty {
                alert.addButton(withTitle: "Copy Command")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                return
            }
        }
        alert.runModal()
    }

    var body: some Scene {
        Window("RollScrub Review", id: "review") {
            ContentView(session: session, license: license)
                .task {
                    // At launch, then an hourly wake for as long as the window
                    // is open. revalidateQuietly() reaches the network at most
                    // once a day whatever the outcome, so the wake costs a
                    // keychain read; it is what lets a session left open for
                    // weeks notice a refund or the end of the grace window
                    // instead of waiting for a relaunch.
                    while !Task.isCancelled {
                        license.revalidateQuietly()
                        try? await Task.sleep(for: .seconds(60 * 60))
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            // Starting another scan was reachable only from a toolbar icon and
            // from the screen you see once a review is finished — so mid-review
            // there was no way to point RollScrub somewhere else, and ⌘O, where
            // everyone looks first, did nothing.
            CommandGroup(replacing: .newItem) {
                Button("Scan Folders…") {
                    NotificationCenter.default.post(name: .scanFolders, object: nil)
                }
                .keyboardShortcut("o")

                Button("Open an Earlier Scan's Manifest…") {
                    NotificationCenter.default.post(name: .openManifest, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .appInfo) {
                Button("About RollScrub") { openWindow(id: "about") }
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)

                Divider()

                Button(license.isPro ? "Licence…" : "Unlock Removal…") {
                    license.unlockContext = nil
                    openWindow(id: "license")
                }

                Divider()

                Button("Install Command Line Tool…") { installCommandLineTool() }
            }

            // Replaces the default Help item, which otherwise looks for a help
            // book this app does not ship and opens an empty viewer.
            CommandGroup(replacing: .help) {
                Button("RollScrub Help") { openWindow(id: "help") }
                    .keyboardShortcut("?", modifiers: .command)
            }

            // Real menu commands rather than hidden zero-size buttons: these
            // are discoverable, and their shortcuts work wherever focus is.
            CommandMenu("Review") {
                Button("Mark for Trash") { session.markSelectionAndAdvance(.discard) }
                    .keyboardShortcut("d", modifiers: [])
                Button("Keep Both") { session.markSelectionAndAdvance(.keep) }
                    .keyboardShortcut("k", modifiers: [])
                Button("Clear Mark") { session.markSelection(.undecided) }
                    .keyboardShortcut("u", modifiers: [])

                Divider()

                Button("Next Pair") { session.selectNext(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("Previous Pair") { session.selectNext(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [])

                Divider()

                Button("Mark All Remaining for Trash") {
                    session.markAllPending(as: .discard)
                }
                Button("Clear All Marks") { session.markAllPending(as: .undecided) }
            }
        }

        // Utility windows: single-instance, not resizable into odd shapes, and
        // absent from the Window menu's document list.
        Window("About RollScrub", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window(license.isPro ? "Licence" : "Unlock Removal", id: "license") {
            LicenseView(model: license)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("RollScrub Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
