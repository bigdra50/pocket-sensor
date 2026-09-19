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
        .library(name: "PocketSensorServer", targets: ["PocketSensorServer"]),
        .library(name: "PocketSensorMedia", targets: ["PocketSensorMedia"]),
        .executable(name: "pocketsensor-sim", targets: ["pocketsensor-sim"]),
    ],
    targets: [
        .target(
            name: "PocketSensorCore",
            path: "Sources/PocketSensorCore"
        ),
        .target(
            name: "PocketSensorServer",
            dependencies: ["PocketSensorCore"],
            path: "Sources/PocketSensorServer"
        ),
        .target(
            name: "PocketSensorMedia",
            dependencies: ["PocketSensorCore"],
            path: "Sources/PocketSensorMedia"
        ),
        .executableTarget(
            name: "pocketsensor-sim",
            dependencies: ["PocketSensorCore", "PocketSensorServer", "PocketSensorMedia"],
            path: "Sources/pocketsensor-sim"
        ),
        .testTarget(
            name: "PocketSensorCoreTests",
            dependencies: ["PocketSensorCore"]
        ),
        .testTarget(
            name: "PocketSensorServerTests",
            dependencies: ["PocketSensorServer", "PocketSensorCore"]
        ),
        .testTarget(
            name: "PocketSensorMediaTests",
            dependencies: ["PocketSensorMedia", "PocketSensorCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
