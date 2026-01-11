// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HivecrewLLM",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "HivecrewLLM",
            targets: ["HivecrewLLM"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.4.0")
    ],
    targets: [
        .target(
            name: "HivecrewLLM",
            dependencies: ["OpenAI"]
        ),
        .testTarget(
            name: "HivecrewLLMTests",
            dependencies: ["HivecrewLLM"]
        ),
    ]
)
