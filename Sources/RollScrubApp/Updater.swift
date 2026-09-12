import Sparkle
import SwiftUI

/// Wraps Sparkle's updater so SwiftUI can drive it.
///
/// Sparkle is started here rather than on demand: it needs to be running to
/// schedule its own background checks, and `canCheckForUpdates` is what keeps
/// the menu item from being clickable while a check is already in flight.
@MainActor
final class Updater: ObservableObject {

    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true is what schedules the periodic check. The first
        // one is deferred by Sparkle until the user has answered its permission
        // prompt, so this does not phone home behind their back on first launch.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
