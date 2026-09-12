import SwiftUI

/// Version strings come from the bundle when RollScrub runs as an installed
/// app, and are absent under `swift run` — where there is no Info.plist.
enum AppInfo {
    static let name = "RollScrub"
    static let website = URL(string: "https://rollscrub.app")!
    static let supportEmail = "support@rollscrub.app"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "© 2026 Ricardo Sanchez"
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 4) {
                Text(AppInfo.name).font(.title.weight(.semibold))
                Text("Version \(AppInfo.version) (\(AppInfo.build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Finds duplicate photos and videos across any folders or drives "
                 + "you choose, and shows you each pair side by side before anything moves.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The one claim worth repeating everywhere: matches are proven, not
            // guessed. It is what separates this from similarity-scoring tools.
            Label("Every match is compared byte for byte", systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)

            Divider().padding(.vertical, 2)

            HStack(spacing: 14) {
                Link("Website", destination: AppInfo.website)
                Link("Support", destination: URL(string: "mailto:\(AppInfo.supportEmail)")!)
            }
            .font(.callout)

            Text(AppInfo.copyright)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 380)
    }
}
