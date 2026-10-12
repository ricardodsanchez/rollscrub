import RollScrubCore
import SwiftUI

/// What the person was about to remove when they reached the gate. The unlock
/// window names their own numbers instead of describing the product in the
/// abstract: "14.2 GB to the Trash" is the reason to pay, and it is already
/// known.
struct UnlockContext: Equatable {
    let files: Int
    let bytes: Int64
}

@MainActor
final class LicenseModel: ObservableObject {
    @Published var key = ""
    /// Set by the Remove button just before it opens the window, cleared by
    /// the menu item, so a window opened from the menu never shows numbers
    /// left over from an earlier review.
    @Published var unlockContext: UnlockContext?
    @Published private(set) var isPro = License.isPro()
    /// Whether a real licence is stored, which is not the same question as
    /// `isPro`: a debug build can be unlocked with no licence at all, and a
    /// stored licence can fall outside the offline grace window.
    @Published private(set) var isActivated = License.isActivated
    @Published private(set) var isWorking = false
    @Published var error: String?

    /// Fixed for the life of the process — the environment does not change
    /// under a running app — and always false in a release build.
    let isDeveloperUnlocked = License.isDeveloperUnlocked

    func refreshFromStore() {
        isPro = License.isPro()
        isActivated = License.isActivated
    }

    func activate() async {
        // Return held down, or a double click, must not start a second
        // activation: each one takes a slot on Creem.
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            _ = try await License.activate(key: key, deviceName: Host.current().localizedName
                ?? "Mac")
            key = ""
            unlockContext = nil
            refreshFromStore()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deactivate() async {
        isWorking = true
        // A message left over from an earlier failed check would otherwise
        // reappear under the Buy layout once the licence is gone.
        error = nil
        defer { isWorking = false }
        await License.deactivate()
        refreshFromStore()
    }

    /// The unlock window's Check Again, for a saved licence past the offline
    /// grace window. Same call as the launch check, so it still does nothing
    /// unless a check is due and only an explicit refusal removes anything;
    /// the difference is that it shows it is working and says when it could
    /// not get an answer, instead of leaving a button that appears dead.
    func checkAgain() async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        await License.revalidate()
        refreshFromStore()
        if !isPro && isActivated {
            error = "Could not reach the licence server. Your licence is still saved "
                + "on this Mac; try again once you are online."
        }
    }

    /// When the last automatic check was sent, whatever it concluded.
    private var lastAutomaticCheck: Date?

    /// Run at launch, and from the window's hourly wake. Never blocks
    /// anything: a licence keeps working while the check is in flight, and a
    /// failed check changes nothing.
    ///
    /// `License.automaticCheckIsDue` decides, and an attempt is recorded only
    /// when a request is actually sent. With the server unreachable or
    /// misconfigured that holds an open window to one call a day, and a wake
    /// that arrives just before the licence is due costs nothing.
    func revalidateQuietly(now: Date = Date()) {
        guard License.automaticCheckIsDue(lastAttempt: lastAutomaticCheck, now: now) else {
            refreshFromStore()  // still notices the grace window running out
            return
        }
        lastAutomaticCheck = now
        Task {
            await License.revalidate()
            refreshFromStore()
        }
    }
}

struct LicenseView: View {
    @ObservedObject var model: LicenseModel
    @Environment(\.openURL) private var openURL

    /// A licence is stored but has gone past the offline grace window without
    /// reaching the server. This person has already paid: offering them a
    /// purchase first would be the wrong answer, so they get a re-check.
    private var needsRecheck: Bool { !model.isPro && model.isActivated }

    private var title: String {
        if model.isPro { return "RollScrub Pro" }
        if needsRecheck { return "Your licence needs a check" }
        guard let ctx = model.unlockContext else { return "Unlock removal" }
        let files = "\(ctx.files.formatted()) duplicate\(ctx.files == 1 ? "" : "s")"
        return "Move \(files) (\(ReportWriter.humanSize(ctx.bytes))) to the Trash"
    }

    private var subtitle: String {
        if model.isPro { return "Removal is unlocked on this Mac." }
        if needsRecheck {
            return "A licence is saved on this Mac, but it has not reached the licence "
                + "server for over 30 days. Connect to the internet and check again. "
                + "Nothing needs to be bought."
        }
        return "Scanning, reviewing and the reports are free forever. A one-time "
            + "\(License.displayPrice) licence unlocks moving duplicates to the "
            + "Trash, and the command-line tool's --move, on up to three Macs."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isPro {
                // Said plainly, because the alternative is a developer
                // demonstrating the app from a debug build and believing they
                // are looking at what a customer gets.
                if model.isDeveloperUnlocked {
                    Label("Developer unlock — debug build", systemImage: "hammer.fill")
                        .foregroundStyle(.orange)
                    Text(License.developerUnlockNotice)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Guarded on the licence itself rather than on `isPro`: with
                // only a developer unlock there is nothing to deactivate, and
                // the button would report success having done nothing.
                if model.isActivated {
                    Label("Licence active", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Deactivate on This Mac") {
                        Task { await model.deactivate() }
                    }
                    .disabled(model.isWorking)
                    Text("Deactivating frees the slot so you can use it on another Mac.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else if needsRecheck {
                // revalidate() does nothing unless a check is due, and only an
                // explicit server refusal can remove the licence, so this
                // button cannot cost anyone what they bought.
                Button("Check Again") { Task { await model.checkAgain() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isWorking)

                if model.isWorking { ProgressView().controlSize(.small) }

                if let error = model.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // No key field here on purpose. Activating over a stored
                // licence takes a new slot on Creem and the old one is never
                // given back (releasing it depends on a deactivate route not
                // yet exercised live), so pasting the key to "fix" this would
                // use up a customer's three Macs on one. A real refusal
                // removes the licence and this window switches to the key
                // layout by itself.
                Text("Still stuck? Email \(AppInfo.supportEmail) and include your licence key.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    openURL(License.purchaseURL(from: .app))
                } label: {
                    Text("Buy RollScrub Pro, \(License.displayPrice)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Divider()

                // Always visible, never folded away: a buyer comes back here
                // with a key from the receipt email, possibly after closing
                // the window or relaunching, and an activation error must
                // never end up hidden. Buy leads by being first and larger.
                Text("Already bought? Paste the key from your receipt email.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                keyEntry
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Licence key", text: $model.key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        // Return in the field must respect the same lock as
                        // the buttons, so an activation never overlaps a check.
                        guard !model.isWorking else { return }
                        Task { await model.activate() }
                    }
                Button("Activate") { Task { await model.activate() } }
                    .disabled(model.isWorking
                              || model.key.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.isWorking { ProgressView().controlSize(.small) }
            }

            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("A key works on up to three Macs at a time.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
