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
        .package(path: "../ModelDelivery"),
        // Qwen3.5 4B through MLX: `MLXLLM` loads the container, `MLXLMCommon`
        // owns the generation loop and the tokenizer protocol. Pinned to the
        // version this engine's parameter mapping and ChatML were measured
        // against.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        // `MLX` itself, for `GPU.set(cacheLimit:)`. mlx-swift-lm asks for it as
        // `.upToNextMinor(from: "0.31.4")`, which floats; this file imports MLX
        // directly, so the edge is declared rather than inherited — a pin only
        // binds through a product a target actually consumes, which is what
        // ModelDelivery learned the hard way with swift-huggingface.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        // `Tokenizers` — the real tokenizer for the ChatML string this package
        // builds in code. mlx-swift-lm does NOT depend on swift-transformers,
        // so this is the only source of it. Exact 1.3.3 to agree with
        // ModelDelivery's pin: 1.3.4 exists, and two conflicting `exact`
        // requirements on one package fail to resolve at all.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3"),
    ],
    targets: [
        .target(
            name: "Summarization",
            dependencies: [
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "ModelDelivery", package: "ModelDelivery"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SummarizationTests",
            dependencies: [
                "Summarization",
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "EchoCoreTestSupport", package: "EchoCore"),
                .product(name: "ModelDelivery", package: "ModelDelivery"),
                // The acceptance suites reach the tokenizer seam's return value,
                // whose members come from this module.
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
