// swift-tools-version: 5.9
// Summon — SPM workspace. Targets mirror handoff §1.
// SummonAI is compiled out for the removability gate via SUMMON_AI_ENABLED=0.

import PackageDescription

let summonAIEnabled = Context.environment["SUMMON_AI_ENABLED"] != "0"

var products: [Product] = [
    .library(name: "SummonCore", targets: ["SummonCore"]),
    .library(name: "SummonUI", targets: ["SummonUI"]),
    .library(name: "SummonShim", targets: ["SummonShim"]),
    .executable(name: "summon-cli", targets: ["summon-cli"]),
    .executable(name: "summon-app", targets: ["summon-app"]),
]

var cliDeps: [Target.Dependency] = ["SummonCore", "SummonUI", "SummonShim"]
var appDeps: [Target.Dependency] = ["SummonCore", "SummonUI", "SummonShim"]
var cliSettings: [SwiftSetting] = []
var appSettings: [SwiftSetting] = []

if summonAIEnabled {
    cliDeps.append("SummonAI")
    appDeps.append("SummonAI")
    cliSettings.append(.define("SUMMON_AI"))
    appSettings.append(.define("SUMMON_AI"))
}

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
        path: "Sources/SummonShim",
        resources: [
            .process("Resources"),
        ],
        linkerSettings: [
            .linkedFramework("JavaScriptCore"),
        ]
    ),
    .executableTarget(
        name: "summon-cli",
        dependencies: cliDeps,
        path: "Sources/summon-cli",
        swiftSettings: cliSettings,
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("Carbon"),
        ]
    ),
    .executableTarget(
        name: "summon-app",
        dependencies: appDeps,
        path: "Sources/summon-app",
        swiftSettings: appSettings,
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("Carbon"),
        ]
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
    .testTarget(
        name: "SummonShimTests",
        dependencies: ["SummonShim", "SummonCore"],
        path: "Tests/SummonShimTests",
        exclude: ["Fixtures"]
    ),
]

if summonAIEnabled {
    products.append(.library(name: "SummonAI", targets: ["SummonAI"]))
    targets.append(
        .target(
            name: "SummonAI",
            dependencies: ["SummonCore"],
            path: "Sources/SummonAI",
            linkerSettings: [
                .linkedFramework("FoundationModels"),
            ]
        )
    )
    targets.append(
        .testTarget(
            name: "SummonAITests",
            dependencies: ["SummonAI", "SummonCore"],
            path: "Tests/SummonAITests"
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
