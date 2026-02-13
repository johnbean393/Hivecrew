// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HivecrewRetrievalSystem",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HivecrewRetrievalProtocol", targets: ["HivecrewRetrievalProtocol"]),
        .library(name: "HivecrewRetrievalCore", targets: ["HivecrewRetrievalCore"]),
        .library(name: "HivecrewRetrievalClient", targets: ["HivecrewRetrievalClient"]),
        .executable(name: "hivecrew-retrieval-daemon", targets: ["HivecrewRetrievalDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(path: "../HivecrewShared"),
    ],
    targets: [
        .target(
            name: "HivecrewRetrievalProtocol",
            dependencies: []
        ),
        .target(
            name: "HivecrewRetrievalCore",
            dependencies: [
                "HivecrewRetrievalProtocol",
                "HivecrewShared",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(
            name: "HivecrewRetrievalClient",
            dependencies: [
                "HivecrewRetrievalProtocol",
            ]
        ),
        .executableTarget(
            name: "HivecrewRetrievalDaemon",
            dependencies: [
                "HivecrewRetrievalProtocol",
                "HivecrewRetrievalCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "HivecrewRetrievalCoreTests",
            dependencies: [
                "HivecrewRetrievalCore",
                "HivecrewRetrievalProtocol",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)

