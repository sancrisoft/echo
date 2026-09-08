// swift-tools-version: 6.2

import PackageDescription

// DesignSystem is the one palette, the one type scale, and the primitives every
// surface repeats. It has no dependencies and no product knowledge: it does not
// know what a meeting is.
let package = Package(
    name: "DesignSystem",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"])
    ],
    targets: [
        .target(
            name: "DesignSystem",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
