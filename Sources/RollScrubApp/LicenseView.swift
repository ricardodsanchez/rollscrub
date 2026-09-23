import RollScrubCore
import SwiftUI

@MainActor
final class LicenseModel: ObservableObject {
    @Published var key = ""
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
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            _ = try await License.activate(key: key, deviceName: Host.current().localizedName
                ?? "Mac")
            key = ""
            refreshFromStore()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deactivate() async {
        isWorking = true
        defer { isWorking = false }
        await License.deactivate()
        refreshFromStore()
    }

    /// Run at launch. Never blocks anything: a licence keeps working while the
    /// check is in flight, and a failed check changes nothing.
    func revalidateQuietly() {
        Task {
            await License.revalidate()
            refreshFromStore()
        }
    }
}

struct LicenseView: View {
    @ObservedObject var model: LicenseModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.isPro ? "RollScrub Pro" : "Unlock removal")
                    .font(.title2.weight(.semibold))
                Text(model.isPro
                     ? "Removal is unlocked on this Mac."
                     : "Scanning, reviewing and the reports are free forever. A licence "
                       + "unlocks moving duplicates to the Trash, and the command-line "
                       + "tool's --move.")
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
            } else {
                TextField("Licence key", text: $model.key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { Task { await model.activate() } }

                if let error = model.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button("Activate") { Task { await model.activate() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking
                                  || model.key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Link("Buy a licence", destination: License.purchaseURL)
                }

                Text("Your key is in the email from your purchase. It works on up to "
                     + "three Macs at a time.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        .frame(width: 460)
    }
}
