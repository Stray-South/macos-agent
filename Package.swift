// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "macos-agent-v0",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "MacAgentCore",
            targets: ["MacAgentCore"]
        ),
        .executable(
            name: "MacOSAgentSmoke",
            targets: ["MacOSAgentSmoke"]
        ),
        .executable(
            name: "MacOSAgentSmokeAction",
            targets: ["MacOSAgentSmokeAction"]
        ),
        .executable(
            name: "MacOSAgentV0",
            targets: ["MacOSAgentV0"]
        ),
        .executable(
            name: "MacAgentReplay",
            targets: ["MacAgentReplay"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MacAgentCore",
            dependencies: [],
            path: "Sources/MacAgentCore",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "MacOSAgentSmoke",
            dependencies: ["MacAgentCore"],
            path: "Sources/MacOSAgentSmoke",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .executableTarget(
            name: "MacOSAgentSmokeAction",
            dependencies: ["MacAgentCore"],
            path: "Sources/MacOSAgentSmokeAction",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .executableTarget(
            name: "MacOSAgentV0",
            dependencies: ["MacAgentCore"],
            path: "Sources/MacOSAgentV0",
            exclude: ["Resources"],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .executableTarget(
            name: "MacAgentReplay",
            dependencies: ["MacAgentCore"],
            path: "Sources/MacAgentReplay",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .testTarget(
            name: "MacAgentCoreTests",
            dependencies: ["MacAgentCore"],
            path: "Tests/MacAgentCoreTests",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .testTarget(
            name: "MacOSAgentV0Tests",
            dependencies: ["MacOSAgentV0", "MacAgentCore"],
            path: "Tests/MacOSAgentV0Tests",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
    ]
)
