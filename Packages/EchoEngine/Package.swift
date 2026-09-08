// swift-tools-version: 6.3

import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "EchoEngine",
    platforms: [.macOS("15.6")],
    products: [
        .library(
            name: "EchoEngine",
            targets: [
                "EchoCore",
                "CWebRTCAPM",
                "EchoAudio",
                "EchoModelDelivery",
                "EchoTranscription",
                "EchoSummarization",
                "EchoPersistence",
                "EchoCallDetection",
                "EchoRecording",
            ]
        )
    ],
    targets: [
        .target(name: "EchoCore", swiftSettings: swift6),
        .binaryTarget(name: "WebRTCAPM", path: "Vendor/WebRTCAPM.xcframework"),
        .target(
            name: "CWebRTCAPM",
            dependencies: ["WebRTCAPM"],
            sources: ["WebRTCAPMLinkProbe.cpp"],
            cxxSettings: [
                .define("WEBRTC_POSIX"),
                .headerSearchPath("vendor/include"),
                .headerSearchPath("vendor/include/webrtc-audio-processing-2"),
            ]
        ),
        .target(name: "EchoAudio", dependencies: ["EchoCore", "CWebRTCAPM"], swiftSettings: swift6),
        .target(name: "EchoModelDelivery", dependencies: ["EchoCore"], swiftSettings: swift6),
        .target(
            name: "EchoTranscription",
            dependencies: ["EchoCore", "EchoModelDelivery"],
            swiftSettings: swift6
        ),
        .target(
            name: "EchoSummarization",
            dependencies: ["EchoCore", "EchoModelDelivery"],
            swiftSettings: swift6
        ),
        .target(name: "EchoPersistence", dependencies: ["EchoCore"], swiftSettings: swift6),
        .target(name: "EchoCallDetection", dependencies: ["EchoCore"], swiftSettings: swift6),
        .target(
            name: "EchoRecording",
            dependencies: [
                "EchoAudio",
                "EchoTranscription",
                "EchoSummarization",
                "EchoPersistence",
                "EchoCallDetection",
            ],
            swiftSettings: swift6
        ),
        .testTarget(
            name: "EchoEngineTests",
            dependencies: [
                "EchoCore",
                "CWebRTCAPM",
                "EchoAudio",
                "EchoModelDelivery",
                "EchoTranscription",
                "EchoSummarization",
                "EchoPersistence",
                "EchoCallDetection",
                "EchoRecording",
            ],
            swiftSettings: swift6
        ),
    ],
    cxxLanguageStandard: .gnucxx20
)
