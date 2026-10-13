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
    @Published private(set) var standing = License.standing()
    @Published private(set) var isWorking = false
    @Published var error: String?
    /// Why a licence that used to be here is gone. Set when the server
    /// refuses one, so the window that then offers Buy says what happened
    /// instead of leaving a paid customer to guess.
    @Published private(set) var notice: String?

    var isPro: Bool { standing.unlocksRemoval }
    /// Whether a real licence is stored, which is not the same question as
    /// `isPro`: a debug build can be unlocked with no licence at all, and a
    /// stored licence can fall outside the offline grace window.
    var isActivated: Bool { standing.hasLicence }

    /// Fixed for the life of the process — the environment does not change
    /// under a running app — and always false in a release build.
    let isDeveloperUnlocked = License.isDeveloperUnlocked

    /// One keychain read. A read that fails mid-session does not undo what an
    /// earlier one found; see `License.settled`.
    ///
    /// A message belongs to the layout it was written for. When the standing
    /// changes underneath it, say a background check revokes a licence whose
    /// failed Deactivate is still on screen, it would otherwise carry over
    /// and contradict what the window now says.
    func refreshFromStore() {
        let fresh = License.settled(License.standing(), after: standing)
        if fresh != standing { error = nil }
        standing = fresh
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
            notice = nil
            refreshFromStore()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deactivate() async {
        guard !isWorking else { return }
        isWorking = true
        // A message left over from an earlier failed check would otherwise
        // reappear under the Buy layout once the licence is gone.
        error = nil
        defer { isWorking = false }
        let outcome = await License.deactivate()
        refreshFromStore()
        error = outcome.explanation
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
        let outcome = await License.revalidate()
        refreshFromStore()
        note(outcome)
        if !isPro && isActivated {
            // Still locked. Say which of the two failures it was; anything
            // else here means no request was sent at all.
            error = outcome.explanation
                ?? "Your licence could not be checked just now. Try again in a moment."
        }
    }

    /// Reads the keychain again, for the layout shown when it would not answer.
    func readAgain() {
        error = nil
        standing = License.standing()
        if standing == .unreadable {
            error = "macOS still would not let RollScrub read its saved licence."
        }
    }

    private func note(_ outcome: License.RecheckOutcome) {
        if case .revoked = outcome { notice = outcome.explanation }
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
            let outcome = await License.revalidate()
            refreshFromStore()
            note(outcome)
        }
    }
}

struct LicenseView: View {
    @ObservedObject var model: LicenseModel
    @Environment(\.openURL) private var openURL
    @FocusState private var focus: Field?

    private enum Field { case buy, key }

    /// A licence is stored but has gone past the offline grace window without
    /// reaching the server. This person has already paid: offering them a
    /// purchase first would be the wrong answer, so they get a re-check.
    private var needsRecheck: Bool { !model.isPro && model.isActivated }

    /// The keychain would not say whether a licence is stored. Not the Buy
    /// layout: this may well be a customer, and the key field there would
    /// spend a second activation slot on a Mac that already holds one.
    private var cannotReadLicence: Bool { model.standing == .unreadable }

    private var title: String {
        if model.isPro { return "RollScrub Pro" }
        if needsRecheck { return "Your licence needs a check" }
        if cannotReadLicence { return "Could not read your licence" }
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
        if cannotReadLicence {
            return "macOS did not let RollScrub read its saved licence from the "
                + "keychain, so it cannot tell whether this Mac has one. If macOS "
                + "asks for permission, choose Always Allow. Nothing needs to be bought."
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
                    if let error = model.error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            } else if cannotReadLicence {
                Button("Try Again") { model.readAgain() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                if let error = model.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Still stuck? Email \(AppInfo.supportEmail) and include your licence key.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let notice = model.notice {
                    Text(notice)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Focus starts here, not in the key field below: someone who
                // has not bought yet should be able to press Return and reach
                // checkout, not be told off for an empty key. A plain button
                // takes keyboard focus only when Keyboard Navigation is on in
                // System Settings, so it is made focusable outright and given
                // the keys a focused button answers to.
                Button(action: buy) {
                    Text("Buy RollScrub Pro, \(License.displayPrice)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .focusable()
                .focused($focus, equals: .buy)
                // Key down only: a held key repeats, and each repeat would
                // open another checkout tab and count another click.
                .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                    buy()
                    return .handled
                }

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
        .defaultFocus($focus, .buy)
    }

    private func buy() {
        openURL(License.purchaseURL(from: .app))
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Licence key", text: $model.key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($focus, equals: .key)
                    .onSubmit {
                        // Return in the field must respect the same lock as
                        // the buttons, so an activation never overlaps a check.
                        // An empty field does nothing, as the disabled
                        // Activate button beside it does.
                        guard !model.isWorking,
                              !model.key.trimmingCharacters(in: .whitespaces).isEmpty
                        else { return }
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
