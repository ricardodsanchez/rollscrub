import SwiftUI

/// Version strings come from the bundle when RollScrub runs as an installed
/// app, and are absent under `swift run` — where there is no Info.plist.
enum AppInfo {
    static let name = "RollScrub"
    static let website = URL(string: "https://rollscrub.com")!
    static let source = URL(string: "https://github.com/ricardodsanchez/rollscrub")!
    static let licence = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    static let supportEmail = "support@rollscrub.com"

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
            // The real icon from the bundle, not a stand-in symbol: an About
            // box showing something other than the app's own icon reads as a
            // different application.
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)

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
                Link("Source Code", destination: AppInfo.source)
                Link("Licence", destination: AppInfo.licence)
                Link("Support", destination: URL(string: "mailto:\(AppInfo.supportEmail)")!)
            }
            .font(.callout)

            // The notice the GPL asks an interactive program to show: who
            // holds the copyright, that there is no warranty, and where to
            // read the licence (the Licence link above; a copy also ships in
            // Contents/Resources).
            VStack(spacing: 2) {
                Text(AppInfo.copyright)
                Text("Free software under the GNU GPL v3. No warranty.")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 380)
    }
}
