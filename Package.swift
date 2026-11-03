// swift-tools-version:6.2
import PackageDescription

// Approachable concurrency (SE-0461): nonisolated async functions run on the
// caller's actor; `@concurrent` marks the few functions that must run off it.
let approachableConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "RiftboundScanner",
    // The Swift-native Vision API (DetectRectanglesRequest, RecognizeTextRequest,
    // GenerateImageFeaturePrintRequest) needs macOS 15 / iOS 18.
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RiftboundRecognizer", targets: ["RiftboundRecognizer"]),
        .executable(name: "riftscan", targets: ["riftscan"]),
    ],
    targets: [
        .target(
            name: "RiftboundRecognizer",
            swiftSettings: approachableConcurrency + [
                // ADR-001: this is a non-UI compute module. It stays nonisolated by
                // default so it can be called from any actor; heavy work is exposed
                // through `@concurrent` functions instead of main-actor isolation.
                .defaultIsolation(nil),
            ]
        ),
        .executableTarget(
            name: "riftscan",
            dependencies: ["RiftboundRecognizer"],
            swiftSettings: approachableConcurrency + [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "RiftboundRecognizerTests",
            dependencies: ["RiftboundRecognizer"],
            swiftSettings: approachableConcurrency + [
                .defaultIsolation(nil),
            ]
        ),
    ]
)
