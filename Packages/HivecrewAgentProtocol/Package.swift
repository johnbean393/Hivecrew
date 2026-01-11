// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HivecrewAgentProtocol",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "HivecrewAgentProtocol",
            targets: ["HivecrewAgentProtocol"]),
    ],
    targets: [
        .target(
            name: "HivecrewAgentProtocol"),
        .testTarget(
            name: "HivecrewAgentProtocolTests",
            dependencies: ["HivecrewAgentProtocol"]),
    ]
)
