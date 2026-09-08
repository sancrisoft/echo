// swift-tools-version: 6.2

import PackageDescription

// ModelDelivery owns getting several GB of model onto the user's disk
// honestly: a byte-honest resumable transfer, byte-weighted progress and the
// codebase's one progress clamp, the stall watchdog and its retry, the
// snapshot download and its fail-safe completeness manifest, the persisted
// pause intent, retired-model cleanup and the free-disk floor.
//
// It knows nothing about which models exist: Transcription and Summarization
// own their model identities and drive this package with repo ids, globs and
// destinations. An engine package — no SwiftUI, no AppKit, no default
// isolation (ADR-002).
let package = Package(
    name: "ModelDelivery",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "ModelDelivery", targets: ["ModelDelivery"]),
    ],
    dependencies: [
        .package(path: "../EchoCore"),
    ],
    targets: [
        .target(
            name: "ModelDelivery",
            dependencies: [.product(name: "EchoCore", package: "EchoCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ModelDeliveryTests",
            dependencies: [
                "ModelDelivery",
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "EchoCoreTestSupport", package: "EchoCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
