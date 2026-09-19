// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PocketSensorKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PocketSensorCore", targets: ["PocketSensorCore"]),
    ],
    targets: [
        .target(
            name: "PocketSensorCore",
            path: "Sources/PocketSensorCore"
        ),
        .testTarget(
            name: "PocketSensorCoreTests",
            dependencies: ["PocketSensorCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
