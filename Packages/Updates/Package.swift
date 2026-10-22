// swift-tools-version: 6.2

import PackageDescription

// Updates owns everything between "a newer Echo exists" and "this Mac is
// running it": the arithmetic behind a `vX.Y.Z` tag, the one repository string
// every user-reachable URL derives from, the daily check against GitHub's
// releases API, and the updater that hands off to the same install script the
// README quotes.
//
// Echo ships as ad-hoc signed zips attached to GitHub releases, not through
// Sparkle, so there is no feed to subscribe to and no framework to host: a
// check is one unauthenticated GET, and an update is a detached bash process
// that waits for Echo to quit before touching the bundle.
//
// An engine package — no SwiftUI, no default isolation (ADR-002). AppKit
// appears in one file, for leaving the app rather than for drawing, and
// scripts/check_boundaries.sh allowlists it by path.
let package = Package(
    name: "Updates",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "Updates", targets: ["Updates"]),
    ],
    dependencies: [
        .package(path: "../EchoCore"),
    ],
    targets: [
        .target(
            name: "Updates",
            dependencies: [.product(name: "EchoCore", package: "EchoCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "UpdatesTests",
            dependencies: [
                "Updates",
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "EchoCoreTestSupport", package: "EchoCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
