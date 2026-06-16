// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentIslandCore", targets: ["AgentIslandCore"]),
        .library(name: "PersonaKit", targets: ["PersonaKit"]),
        .library(name: "HookInstall", targets: ["HookInstall"]),
        .library(name: "AgentIslandDaemon", targets: ["AgentIslandDaemon"]),
        // Framework-free test runner — runs under Command Line Tools (no full Xcode /
        // XCTest / swift-testing needed). `swift run AgentIslandSelfTest`.
        .executable(name: "AgentIslandSelfTest", targets: ["AgentIslandSelfTest"]),
        // Runs the verified engine against your real ~/.claude transcripts (console).
        .executable(name: "AgentIslandDemo", targets: ["AgentIslandDemo"]),
        // The visible widget: a menu-bar (accessory) app. Runs as a plain executable —
        // `swift run AgentIslandApp`, or select the AgentIslandApp scheme in Xcode.
        .executable(name: "AgentIslandApp", targets: ["AgentIslandApp"]),
    ],
    targets: [
        .target(name: "AgentIslandCore"),
        .target(name: "PersonaKit"),
        .target(name: "HookInstall"),
        .target(name: "AgentIslandDaemon"),
        .executableTarget(
            name: "AgentIslandSelfTest",
            dependencies: ["AgentIslandCore", "PersonaKit", "HookInstall", "AgentIslandDaemon"]),
        .executableTarget(name: "AgentIslandDemo", dependencies: ["AgentIslandCore"]),
        .executableTarget(name: "AgentIslandApp", dependencies: ["AgentIslandCore"]),
    ]
)
