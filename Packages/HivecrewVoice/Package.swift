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
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.6")
    ],
    targets: [
        .target(
            name: "HivecrewVoice",
            dependencies: [
                "FluidAudio"
            ]
        ),
        .testTarget(
            name: "HivecrewVoiceTests",
            dependencies: ["HivecrewVoice"]
        ),
    ]
)
