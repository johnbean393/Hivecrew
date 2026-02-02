// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HivecrewMCP",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "HivecrewMCP",
            targets: ["HivecrewMCP"]
        ),
    ],
    targets: [
        .target(
            name: "HivecrewMCP"
        ),
        .testTarget(
            name: "HivecrewMCPTests",
            dependencies: ["HivecrewMCP"]
        ),
    ]
)
