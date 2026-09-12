// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DupSweep",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dupsweep", targets: ["dupsweep"]),
        .executable(name: "DupSweepApp", targets: ["DupSweepApp"]),
        .library(name: "DupSweepCore", targets: ["DupSweepCore"]),
    ],
    targets: [
        .target(name: "DupSweepCore"),
        .executableTarget(name: "dupsweep", dependencies: ["DupSweepCore"]),
        .executableTarget(
            name: "DupSweepApp",
            dependencies: ["DupSweepCore"],
            // SwiftPM does not autolink these, and SwiftUI's VideoPlayer aborts
            // at runtime if AVKit's AVPlayerView class cannot be resolved.
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("QuickLookThumbnailing"),
            ]),
        .testTarget(name: "DupSweepCoreTests", dependencies: ["DupSweepCore", "DupSweepApp"]),
    ]
)
