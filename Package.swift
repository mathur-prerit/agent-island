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
        // The visible widget: menu-bar item + floating island. Plain SwiftPM executable.
        .executable(name: "AgentIslandApp", targets: ["AgentIslandApp"]),
        // The hook bridge Claude Code invokes: install/uninstall hooks + relay events.
        .executable(name: "AgentIslandHookCLI", targets: ["AgentIslandHookCLI"]),
        // The background daemon: receives hook events over a Unix socket, maintains
        // session state, and writes ~/.agent-island/state.json for the app to read.
        .executable(name: "agentislandd", targets: ["agentislandd"]),
    ],
    targets: [
        .target(name: "AgentIslandCore"),
        .target(name: "PersonaKit", dependencies: ["AgentIslandCore"]),
        .target(name: "HookInstall"),
        .target(name: "AgentIslandDaemon", dependencies: ["AgentIslandCore"]),
        .executableTarget(
            name: "AgentIslandSelfTest",
            dependencies: ["AgentIslandCore", "PersonaKit", "HookInstall", "AgentIslandDaemon"]),
        .executableTarget(name: "AgentIslandDemo", dependencies: ["AgentIslandCore"]),
        .executableTarget(name: "AgentIslandApp", dependencies: ["AgentIslandCore", "PersonaKit", "AgentIslandDaemon"]),
        .executableTarget(name: "AgentIslandHookCLI", dependencies: ["HookInstall", "AgentIslandDaemon"]),
        .executableTarget(name: "agentislandd", dependencies: ["AgentIslandDaemon", "AgentIslandCore"]),
    ]
)
