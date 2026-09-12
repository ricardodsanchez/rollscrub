import SwiftUI

@main
struct RollScrubApp: App {
    // Owned here so the menu bar can drive the same session the window shows.
    @StateObject private var session = ReviewSession()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("RollScrub Review", id: "review") {
            ContentView(session: session)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .appInfo) {
                Button("About RollScrub") { openWindow(id: "about") }
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

        Window("RollScrub Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
