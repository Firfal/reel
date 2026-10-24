// swift-tools-version:6.0
// Reel: a minimal, free, open-source screen recorder for macOS.
import PackageDescription

let package = Package(
    name: "Reel",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Reel", targets: ["Reel"])],
    targets: [
        .executableTarget(
            name: "Reel",
            path: "Sources/Reel",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
