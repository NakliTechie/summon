// swift-tools-version: 5.9
// Summon — SPM workspace. Targets mirror handoff §1.
// AI is core (not a removable sidecar): SummonAI is always built.

import PackageDescription

// Embedded llama.cpp is WIP (feasibility gate landed; rung not yet). Opt in with
// SUMMON_LLAMA=1; off by default so releases aren't bloated by an unused framework.
let llamaEnabled = Context.environment["SUMMON_LLAMA"] == "1"

var products: [Product] = [
    .library(name: "SummonCore", targets: ["SummonCore"]),
    .library(name: "SummonUI", targets: ["SummonUI"]),
    .library(name: "SummonShim", targets: ["SummonShim"]),
    .executable(name: "summon-cli", targets: ["summon-cli"]),
    .executable(name: "summon-app", targets: ["summon-app"]),
]

var cliDeps: [Target.Dependency] = ["SummonCore", "SummonUI"]
var appDeps: [Target.Dependency] = ["SummonCore", "SummonUI"]
var cliSettings: [SwiftSetting] = []
var appSettings: [SwiftSetting] = []

cliDeps.append("SummonAI")
appDeps.append("SummonAI")
cliSettings.append(.define("SUMMON_AI"))
appSettings.append(.define("SUMMON_AI"))

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
        path: "Sources/SummonUI",
        linkerSettings: [
            .linkedFramework("ServiceManagement"),
            .linkedFramework("Carbon"),
            .linkedFramework("AppKit"),
        ]
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

// SummonAI is core — always built. Embedded llama.cpp (official prebuilt
// xcframework, pinned + Metal) is gated behind SUMMON_LLAMA so it's not shipped
// until the rung lands; our own rung will call its C API — no third-party wrapper.
products.append(.library(name: "SummonAI", targets: ["SummonAI"]))
var summonAIDeps: [Target.Dependency] = ["SummonCore"]
var summonAILinker: [LinkerSetting] = [.linkedFramework("FoundationModels")]
if llamaEnabled {
    targets.append(
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10068/llama-b10068-xcframework.zip",
            checksum: "5238397dd4ca305c9db537c3ae106948909ba2605e77d2d3463ac2d2ca08cc8a"
        )
    )
    summonAIDeps.append("llama")
    summonAILinker.append(.linkedLibrary("c++"))
}
targets.append(
    .target(
        name: "SummonAI",
        dependencies: summonAIDeps,
        path: "Sources/SummonAI",
        linkerSettings: summonAILinker
    )
)
    targets.append(
        .testTarget(
            name: "SummonAITests",
            dependencies: [
                "SummonAI",
                "SummonCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/SummonAITests"
        )
    )
    // Links both UI and AI to drive the real launcher through the real model
    // (gated on SUMMON_RUN_L1_LIVE; skipped otherwise).
    targets.append(
        .testTarget(
            name: "SummonLiveProbeTests",
            dependencies: ["SummonUI", "SummonAI", "SummonCore"],
            path: "Tests/SummonLiveProbeTests"
        )
    )

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
