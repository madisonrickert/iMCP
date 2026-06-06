// swift-tools-version: 5.9
//
// Standalone test package for the Bonjour advertisement self-heal decision logic.
// Symlinks App/Controllers/SelfHealDecision.swift so the iMCP app build and
// these tests share a single source of truth.
//
// Run from this directory: `swift test`

import PackageDescription

let package = Package(
    name: "SelfHealTests",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "SelfHealLogic",
            path: "Sources/SelfHealLogic"
        ),
        .testTarget(
            name: "SelfHealTests",
            dependencies: ["SelfHealLogic"],
            path: "Tests/SelfHealTests"
        ),
    ]
)
