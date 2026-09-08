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
        // `HubApi` — repo metadata, the snapshot pass for the small files, and
        // the models/<org>/<repo> layout this package downloads into. It is a
        // swift-transformers product, not a swift-huggingface one.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3"),
        // Pinned to the version the PoC measured this transport against.
        // swift-transformers asks for `from: "0.8.1"`, which floats past it.
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "ModelDelivery",
            dependencies: [
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ModelDeliveryTests",
            dependencies: [
                "ModelDelivery",
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "EchoCoreTestSupport", package: "EchoCore"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
