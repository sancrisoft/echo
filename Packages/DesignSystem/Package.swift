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
            // Onest and DM Mono travel with the package that names them, not
            // with the app: any host of this package — the gallery, a preview,
            // these tests — gets the design's typefaces or a traced failure,
            // never a silent fallback nobody can fix from here.
            resources: [.copy("Resources/Fonts")],
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
