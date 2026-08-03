// swift-tools-version: 5.9
// Summon — SPM workspace. Targets mirror handoff §1.
// SummonAI is compiled out for the removability gate via SUMMON_AI_ENABLED.

import PackageDescription

let summonAIEnabled = Context.environment["SUMMON_AI_ENABLED"] != "0"

var products: [Product] = [
    .library(name: "SummonCore", targets: ["SummonCore"]),
    .library(name: "SummonUI", targets: ["SummonUI"]),
    .library(name: "SummonShim", targets: ["SummonShim"]),
    .executable(name: "summon-cli", targets: ["summon-cli"]),
]

var targets: [Target] = [
    .target(
        name: "SummonCore",
        dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
        ],
        path: "Sources/SummonCore"
    ),
    .target(
        name: "SummonUI",
        dependencies: ["SummonCore"],
        path: "Sources/SummonUI"
    ),
    .target(
        name: "SummonShim",
        dependencies: ["SummonCore"],
        path: "Sources/SummonShim"
    ),
    .executableTarget(
        name: "summon-cli",
        dependencies: ["SummonCore"],
        path: "Sources/summon-cli"
    ),
    .testTarget(
        name: "SummonCoreTests",
        dependencies: ["SummonCore"],
        path: "Tests/SummonCoreTests"
    ),
    .testTarget(
        name: "SummonUITests",
        dependencies: ["SummonUI", "SummonCore"],
        path: "Tests/SummonUITests"
    ),
]

if summonAIEnabled {
    products.append(.library(name: "SummonAI", targets: ["SummonAI"]))
    targets.append(
        .target(
            name: "SummonAI",
            dependencies: ["SummonCore"],
            path: "Sources/SummonAI"
        )
    )
}

let package = Package(
    name: "Summon",
    platforms: [
        .macOS(.v14),
    ],
    products: products,
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: targets
)
