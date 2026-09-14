// swift-tools-version: 6.2

import PackageDescription

// Workspace is the main window: the sidebar of meetings, the document, trash
// and the settings screen. It reads observable state from the engine packages
// and calls their methods; it never touches disk, audio or models itself.
//
// Settings › Updates is why it sees Updates and Recording: the section renders
// `UpdateChecker`'s answer, and Update Now is disabled while a session is live
// because updating quits Echo and mid-meeting that is a lost meeting.
let package = Package(
    name: "Workspace",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "Workspace", targets: ["Workspace"])
    ],
    dependencies: [
        .package(path: "../EchoCore"),
        .package(path: "../Meetings"),
        .package(path: "../Recording"),
        .package(path: "../Updates"),
        .package(path: "../DesignSystem"),
    ],
    targets: [
        .target(
            name: "Workspace",
            dependencies: [
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "Meetings", package: "Meetings"),
                .product(name: "Recording", package: "Recording"),
                .product(name: "Updates", package: "Updates"),
                .product(name: "DesignSystem", package: "DesignSystem"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "WorkspaceTests",
            dependencies: [
                "Workspace",
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "EchoCoreTestSupport", package: "EchoCore"),
                .product(name: "Meetings", package: "Meetings"),
                .product(name: "Updates", package: "Updates"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
