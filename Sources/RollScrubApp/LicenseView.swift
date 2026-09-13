import RollScrubCore
import SwiftUI

@MainActor
final class LicenseModel: ObservableObject {
    @Published var key = ""
    @Published private(set) var isPro = License.isPro()
    @Published private(set) var isWorking = false
    @Published var error: String?

    func refreshFromStore() {
        isPro = License.isPro()
    }

    func activate() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            _ = try await License.activate(key: key, deviceName: Host.current().localizedName
                ?? "Mac")
            key = ""
            isPro = License.isPro()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deactivate() async {
        isWorking = true
        defer { isWorking = false }
        await License.deactivate()
        isPro = License.isPro()
    }

    /// Run at launch. Never blocks anything: a licence keeps working while the
    /// check is in flight, and a failed check changes nothing.
    func revalidateQuietly() {
        Task {
            await License.revalidate()
            isPro = License.isPro()
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
                Label("Licence active", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button("Deactivate on This Mac") {
                    Task { await model.deactivate() }
                }
                .disabled(model.isWorking)
                Text("Deactivating frees the slot so you can use it on another Mac.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
