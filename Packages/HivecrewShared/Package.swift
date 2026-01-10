// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HivecrewShared",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "HivecrewShared",
            targets: ["HivecrewShared"]
        ),
    ],
    targets: [
        .target(
            name: "HivecrewShared"
        ),
    ]
)
