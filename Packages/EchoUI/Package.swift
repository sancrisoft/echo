// swift-tools-version: 6.3

import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]

let engine = Target.Dependency.product(name: "EchoEngine", package: "EchoEngine")

let package = Package(
    name: "EchoUI",
    platforms: [.macOS("15.6")],
    products: [
        .library(
            name: "EchoUI",
            targets: [
                "EchoDesignSystem",
                "EchoWorkspace",
                "EchoDocument",
                "EchoLibrary",
                "EchoSearch",
                "EchoIsland",
                "EchoOnboarding",
            ]
        )
    ],
    dependencies: [
        .package(path: "../EchoEngine")
    ],
    targets: [
        .target(name: "EchoDesignSystem", swiftSettings: swift6),
        .target(name: "EchoWorkspace", dependencies: ["EchoDesignSystem", engine], swiftSettings: swift6),
        .target(name: "EchoDocument", dependencies: ["EchoDesignSystem", engine], swiftSettings: swift6),
        .target(name: "EchoLibrary", dependencies: ["EchoDesignSystem", engine], swiftSettings: swift6),
        .target(name: "EchoSearch", dependencies: ["EchoDesignSystem", engine], swiftSettings: swift6),
        .target(name: "EchoIsland", dependencies: ["EchoDesignSystem", engine], swiftSettings: swift6),
        .target(name: "EchoOnboarding", dependencies: ["EchoDesignSystem", engine], swiftSettings: swift6),
    ]
)
