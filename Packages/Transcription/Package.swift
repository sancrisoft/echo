// swift-tools-version: 6.2

import PackageDescription

// Transcription owns speech-to-text: the Parakeet model's identity and
// readiness, the post-stop batch pass over retained audio, and the layer that
// turns the model's raw token rows into a transcript a person can read —
// segment shaping, cross-channel echo dedup and chunking.
//
// Speaker is the channel it captured, never diarization: microphone is You,
// system audio is Others. An engine package — no SwiftUI, no AppKit, no
// default isolation (ADR-002).
let package = Package(
    name: "Transcription",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "Transcription", targets: ["Transcription"]),
    ],
    dependencies: [
        .package(path: "../EchoCore"),
        .package(path: "../ModelDelivery"),
        // Parakeet TDT 0.6B v3 through its Core ML port: the model files, the
        // batch decode and its own transport. Pinned to the version this
        // pass's segment shaping and decoder settings were measured against.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.5"),
    ],
    targets: [
        .target(
            name: "Transcription",
            dependencies: [
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "ModelDelivery", package: "ModelDelivery"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TranscriptionTests",
            dependencies: [
                "Transcription",
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "EchoCoreTestSupport", package: "EchoCore"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
