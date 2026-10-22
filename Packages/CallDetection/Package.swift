// swift-tools-version: 6.2

import PackageDescription

// CallDetection owns the answer to "is the user in a call right now?": the
// curated catalog of meeting apps, every browser the system says is installed,
// the per-app filter the settings screen writes, and the pure machine that
// turns catalogued microphone capture into the island's faces and the two
// recording requests it may ask for.
//
// It decides nothing about capture and nothing about the library: its output
// is a face to show and a `CaptureScope` to record, and the surface above it
// is what acts on them. An engine package — no SwiftUI, no default isolation
// (ADR-002); AppKit appears in two files, for process identity, and
// scripts/check_boundaries.sh allowlists them by path.
let package = Package(
    name: "CallDetection",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "CallDetection", targets: ["CallDetection"]),
    ],
    dependencies: [
        .package(path: "../EchoCore"),
        .package(path: "../Audio"),
    ],
    targets: [
        .target(
            name: "CallDetection",
            dependencies: [
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "Audio", package: "Audio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CallDetectionTests",
            dependencies: [
                "CallDetection",
                .product(name: "Audio", package: "Audio"),
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "EchoCoreTestSupport", package: "EchoCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
