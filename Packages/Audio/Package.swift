// swift-tools-version: 6.2

import PackageDescription

// Audio owns both capture channels and everything that defends them: the
// microphone through AVAudioEngine, the system output through Core Audio
// process taps (global or scoped to one app's process set), the canonical
// 16 kHz mono Float32 format they both downmix and resample to, the
// sample-rate guard that disbelieves the rate a device declares, echo
// cancellation, the device and route monitors, input-health classification
// and retention encoding to AAC.
//
// Microphone is You and system audio is Others: the two streams are kept
// apart for the whole pipeline and the channel is the speaker, never
// diarization. An engine package — no SwiftUI, no default isolation
// (ADR-002); AppKit appears in exactly two files, for process identity, and
// scripts/check_boundaries.sh allowlists them by path.
let package = Package(
    name: "Audio",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "Audio", targets: ["Audio"]),
    ],
    dependencies: [
        .package(path: "../EchoCore"),
    ],
    targets: [
        // The vendored WebRTC audio-processing module (AEC3), arm64 macOS,
        // static. Vendor/webrtc-apm/VERSION records the upstream tag, the
        // commit, how the archive was built and how to regenerate this
        // xcframework from it.
        .binaryTarget(name: "WebRTCAPM", path: "Vendor/WebRTCAPM.xcframework"),

        // The one seam between Swift and C++. SPM has no bridging headers, so
        // the ObjC++ implementation is its own target with a public header in
        // include/, and the Swift target imports it as a module. No WebRTC
        // type appears in that header.
        //
        // Both header roots the upstream pkg-config demands are on the search
        // path, taken from inside the xcframework so the repository carries
        // exactly one copy of the headers and one copy of the archive: the
        // public headers include each other as "api/…" and "rtc_base/…"
        // (relative to webrtc-audio-processing-2/) and abseil's as "absl/…"
        // (relative to its parent). The macos-arm64 slice is named directly
        // because Echo is Apple-Silicon-only; a second slice would need this
        // and the Package's platform list changed together.
        .target(
            name: "WebRTCAECBridge",
            dependencies: ["WebRTCAPM"],
            cxxSettings: [
                .headerSearchPath("../../Vendor/WebRTCAPM.xcframework/macos-arm64/Headers"),
                .headerSearchPath(
                    "../../Vendor/WebRTCAPM.xcframework/macos-arm64/Headers/webrtc-audio-processing-2"
                ),
                // The consumer cflag upstream's pkg-config specifies. The
                // implementation defines it too, so a build that reaches the
                // translation unit some other way still compiles.
                .define("WEBRTC_POSIX"),
            ]
        ),
        .target(
            name: "Audio",
            dependencies: [
                .product(name: "EchoCore", package: "EchoCore"),
                "WebRTCAECBridge",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AudioTests",
            dependencies: [
                "Audio",
                .product(name: "EchoCore", package: "EchoCore"),
                .product(name: "EchoCoreTestSupport", package: "EchoCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    cxxLanguageStandard: .gnucxx20
)
