// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HivecrewAPI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HivecrewAPI", targets: ["HivecrewAPI"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(path: "../HivecrewShared")
    ],
    targets: [
        .target(
            name: "HivecrewAPI",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                "HivecrewShared"
            ],
            resources: [
                .copy("WebUI")
            ]
        )
    ]
)
