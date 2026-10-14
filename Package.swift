// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "rollcage-guard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "rollcage-guard", targets: ["rollcage-guard"]),
        .library(name: "RollcageGuardCore", targets: ["RollcageGuardCore"]),
    ],
    targets: [
        // The rules: secret files, environment dumps, destructive commands, network and git leak checks.
        .target(name: "RollcageGuardCore", path: "Sources/RollcageGuardCore"),
        // The CLI the agents' hooks run, plus install/uninstall/explain for people.
        .executableTarget(name: "rollcage-guard", dependencies: ["RollcageGuardCore"], path: "Sources/rollcage-guard"),
        .testTarget(name: "RollcageGuardCoreTests", dependencies: ["RollcageGuardCore"], path: "Tests/RollcageGuardCoreTests"),
    ]
)
