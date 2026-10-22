// swift-tools-version: 6.2

import PackageDescription

// Recording owns a meeting's lifecycle: the one observable a surface reads to
// know what is happening (`RecordingSession`), the wiring that turns two
// capture streams into retained audio and live levels, and the driver that
// turns a Stop into a transcript and then into notes.
//
// It is the only package that sees Audio, Transcription, Summarization,
// ModelDelivery and Meetings at once, which is why the pieces that need two of
// them live here: the `CaptureScope` → `CaptureScopeRecord` mapping, the
// finalization gate, the summary scheduler and the backfill policy.
//
// An engine package — no SwiftUI, no AppKit, and NO default isolation:
// `RecordingSession` states `@MainActor` on itself because it is the façade
// the UI reads, and everything else decides its own isolation (ADR-002).
let package = Package(
    name: "Recording",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "Recording", targets: ["Recording"]),
    ],
    dependencies: [
        .package(path: "../EchoCore"),
        .package(path: "../Audio"),
        .package(path: "../Transcription"),
        .package(path: "../Summarization"),
        .package(path: "../ModelDelivery"),
        .package(path: "../Meetings"),
    ],
    targets: [
        .target(
            name: "Recording",
            dependencies: [
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "Audio", package: "Audio"),
                .product(name: "Transcription", package: "Transcription"),
                .product(name: "Summarization", package: "Summarization"),
                .product(name: "ModelDelivery", package: "ModelDelivery"),
                .product(name: "Meetings", package: "Meetings"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RecordingTests",
            dependencies: [
                "Recording",
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "EchoCoreTestSupport", package: "EchoCore"),
                .product(name: "Audio", package: "Audio"),
                .product(name: "Transcription", package: "Transcription"),
                .product(name: "Summarization", package: "Summarization"),
                .product(name: "Meetings", package: "Meetings"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
