// swift-tools-version: 6.2

import PackageDescription

// EchoCore is the vocabulary every other package shares, and nothing more.
// Something enters this package only if at least three packages need it, it
// has no UI, and it is not a capability of its own (see
// docs/architecture/v2-architecture.md §2.1).
let package = Package(
    name: "EchoCore",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "EchoCore", targets: ["EchoCore"]),
        // Test-only helpers (fixtures root, acceptance gate, temp roots). A
        // separate product so app code cannot link it.
        .library(name: "EchoCoreTestSupport", targets: ["EchoCoreTestSupport"]),
    ],
    targets: [
        .target(
            name: "EchoCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "EchoCoreTestSupport",
            dependencies: ["EchoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EchoCoreTests",
            dependencies: ["EchoCore", "EchoCoreTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
