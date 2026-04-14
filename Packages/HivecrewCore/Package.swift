// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "HivecrewCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(
            name: "HivecrewCore",
            targets: ["HivecrewCore"]
        ),
    ],
    dependencies: [
        .package(path: "../HivecrewAPI"),
        .package(path: "../HivecrewLLM"),
        .package(path: "../HivecrewShared"),
    ],
    targets: [
        .target(
            name: "HivecrewCore",
            dependencies: [
                .product(name: "HivecrewAPIModels", package: "HivecrewAPI"),
                "HivecrewLLM",
                "HivecrewShared",
            ]
        ),
        .testTarget(
            name: "HivecrewCoreTests",
            dependencies: ["HivecrewCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
