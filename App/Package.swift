// swift-tools-version:6.2
// Reel: a minimal, free, open-source screen recorder for macOS.
// - ReelKit (library): capture, segments, composition, library storage. No UI.
// - Reel (executable): the menu bar app.
import PackageDescription

let mainActorByDefault: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

// ReelKit stays nonisolated by default, like a library: the caller decides where work runs.
let approachable: [SwiftSetting] = Array(mainActorByDefault.dropFirst())

let package = Package(
    name: "Reel",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Reel", targets: ["Reel"]),
        .library(name: "ReelKit", targets: ["ReelKit"]),
    ],
    targets: [
        .target(name: "ReelKit", path: "Sources/ReelKit", swiftSettings: approachable),
        .executableTarget(
            name: "Reel",
            dependencies: ["ReelKit"],
            path: "Sources/Reel",
            swiftSettings: mainActorByDefault,
            linkerSettings: [.linkedFramework("AVKit")]
        ),
        .testTarget(name: "ReelKitTests", dependencies: ["ReelKit"], path: "Tests/ReelKitTests"),
    ]
)
