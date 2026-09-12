// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RollScrub",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "rollscrub", targets: ["rollscrub"]),
        .executable(name: "RollScrubApp", targets: ["RollScrubApp"]),
        .library(name: "RollScrubCore", targets: ["RollScrubCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "RollScrubCore"),
        .executableTarget(name: "rollscrub", dependencies: ["RollScrubCore"]),
        .executableTarget(
            name: "RollScrubApp",
            dependencies: [
                "RollScrubCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // SwiftPM does not autolink these, and SwiftUI's VideoPlayer aborts
            // at runtime if AVKit's AVPlayerView class cannot be resolved.
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("QuickLookThumbnailing"),
            ]),
        .testTarget(name: "RollScrubCoreTests", dependencies: ["RollScrubCore", "RollScrubApp"]),
    ]
)
