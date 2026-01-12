// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HivecrewGuestAgent",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(path: "../Packages/HivecrewAgentProtocol")
    ],
    targets: [
        .executableTarget(
            name: "HivecrewGuestAgent",
            dependencies: ["HivecrewAgentProtocol"],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
