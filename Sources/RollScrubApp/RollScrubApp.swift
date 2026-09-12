import SwiftUI

@main
struct RollScrubApp: App {
    // Owned here so the menu bar can drive the same session the window shows.
    @StateObject private var session = ReviewSession()

    var body: some Scene {
        Window("RollScrub Review", id: "review") {
            ContentView(session: session)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}

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
    }
}
