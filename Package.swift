// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "noajar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "noajar", targets: ["LidAwake"]),
        .executable(name: "LidAwakeMenuBar", targets: ["LidAwakeMenuBar"]),
        .executable(name: "noajar-hotspot", targets: ["NoAjarHotspotHelper"]),
        .executable(name: "NoAjarHelper", targets: ["NoAjarHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.1")
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
            dependencies: [
                "LidAwakeCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "NoAjarHotspotHelper"
        ),
        .executableTarget(
            name: "NoAjarHelper",
            dependencies: ["LidAwakeCore"]
        ),
        .testTarget(
            name: "LidAwakeCoreTests",
            dependencies: ["LidAwakeCore"]
        )
    ]
)
