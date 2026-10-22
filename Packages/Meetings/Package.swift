// swift-tools-version: 6.2

import PackageDescription

// Meetings owns the library on disk and in memory: one folder per meeting under
// the data root, the meta/transcript/summary files and their tolerant schemas,
// trash, preserved recordings, storage measurement, and the observable façade
// the UI reads. It knows nothing about audio capture, transcription or
// summarization: it stores what it is given.
let package = Package(
    name: "Meetings",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "Meetings", targets: ["Meetings"]),
    ],
    dependencies: [
        .package(path: "../EchoCore"),
    ],
    targets: [
        .target(
            name: "Meetings",
            dependencies: [.product(name: "EchoCore", package: "EchoCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MeetingsTests",
            dependencies: [
                "Meetings",
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "EchoCoreTestSupport", package: "EchoCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
