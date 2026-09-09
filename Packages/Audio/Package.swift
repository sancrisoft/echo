// swift-tools-version: 6.2

import PackageDescription

// Audio owns both capture channels and everything that defends them: the
// microphone through AVAudioEngine, the system output through Core Audio
// process taps (global or scoped to one app's process set), the canonical
// 16 kHz mono Float32 format they both downmix and resample to, the
// sample-rate guard that disbelieves the rate a device declares, echo
// cancellation, the device and route monitors, input-health classification
// and retention encoding to AAC.
//
// Microphone is You and system audio is Others: the two streams are kept
// apart for the whole pipeline and the channel is the speaker, never
// diarization. An engine package — no SwiftUI, no default isolation
// (ADR-002); AppKit appears in exactly two files, for process identity, and
// scripts/check_boundaries.sh allowlists them by path.
let package = Package(
    name: "Audio",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "Audio", targets: ["Audio"]),
    ],
    dependencies: [
        .package(path: "../EchoCore"),
    ],
    targets: [
        .target(
            name: "Audio",
            dependencies: [
                .product(name: "EchoCore", package: "EchoCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AudioTests",
            dependencies: [
                "Audio",
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "EchoCoreTestSupport", package: "EchoCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
