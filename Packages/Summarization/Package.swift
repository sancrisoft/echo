// swift-tools-version: 6.2

import PackageDescription

// Summarization owns turning a finished transcript into the Markdown a person
// reads: the text-generation seam, transcript chunking, language detection,
// the routing between the single-pass and map/merge/reduce paths, the prompts,
// the NDJSON fact protocol and its deterministic merge, the row caption, and
// the summary model's own download/load/unload lifecycle.
//
// Nothing here decides WHEN a summary runs or where it is stored: the
// scheduler and the finalization gate belong to Recording, and `summary.md` is
// written by `MeetingStore`. This package produces a `SummaryDocument` and
// nothing else.
//
// An engine package — no SwiftUI, no AppKit, no default isolation, isolation
// stated per type (ADR-002).
let package = Package(
    name: "Summarization",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "Summarization", targets: ["Summarization"]),
    ],
    dependencies: [
        .package(path: "../EchoCore"),
    ],
    targets: [
        .target(
            name: "Summarization",
            dependencies: [
                .product(name: "EchoCore", package: "EchoCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SummarizationTests",
            dependencies: [
                "Summarization",
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "EchoCoreTestSupport", package: "EchoCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
