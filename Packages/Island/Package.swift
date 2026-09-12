// swift-tools-version: 6.2

import PackageDescription

// Island is the floating panel that hangs off the notch: the shell's geometry,
// the faces, and the controller that applies call detection's actions to the
// recording session. It reads observable state from the packages below it and
// calls their methods; it owns no audio, no disk and no models.
let package = Package(
    name: "Island",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "Island", targets: ["Island"])
    ],
    dependencies: [
        .package(path: "../CallDetection"),
        .package(path: "../DesignSystem"),
        .package(path: "../EchoCore"),
        .package(path: "../Recording"),
    ],
    targets: [
        .target(
            name: "Island",
            dependencies: [
                .product(name: "CallDetection", package: "CallDetection"),
                .product(name: "DesignSystem", package: "DesignSystem"),
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "Recording", package: "Recording"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "IslandTests",
            dependencies: [
                "Island",
                .product(name: "CallDetection", package: "CallDetection"),
                .product(name: "DesignSystem", package: "DesignSystem"),
                .product(name: "Recording", package: "Recording"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
