// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SteeringOverlayPoC",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SteeringOverlay",
            path: "Sources/SteeringOverlay"
        )
    ]
)
