// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "noajar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "lid-awake", targets: ["LidAwake"]),
        .executable(name: "LidAwakeMenuBar", targets: ["LidAwakeMenuBar"]),
        .executable(name: "NoAjarHelper", targets: ["NoAjarHelper"])
    ],
    targets: [
        .target(
            name: "LidAwakeCore"
        ),
        .executableTarget(
            name: "LidAwake",
            dependencies: ["LidAwakeCore"]
        ),
        .executableTarget(
            name: "LidAwakeMenuBar",
            dependencies: ["LidAwakeCore"]
        ),
        .executableTarget(
            name: "NoAjarHelper",
            dependencies: ["LidAwakeCore"]
        )
    ]
)
