// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HivecrewVoice",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "HivecrewVoice",
            targets: ["HivecrewVoice"]
        ),
    ],
    targets: [
        .target(
            name: "HivecrewVoice"
        ),
        .testTarget(
            name: "HivecrewVoiceTests",
            dependencies: ["HivecrewVoice"]
        ),
    ]
)
