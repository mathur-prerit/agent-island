// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentIslandCore", targets: ["AgentIslandCore"]),
        .library(name: "PersonaKit", targets: ["PersonaKit"]),
        // AppKit-free data-theme manifest model + strict loader/validator (data themes, schema v1).
        .library(name: "AgentIslandThemes", targets: ["AgentIslandThemes"]),
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
        // AppKit-free: depends on PersonaKit (PackValidator path/asset checks) → Core transitively.
        .target(name: "AgentIslandThemes", dependencies: ["PersonaKit"]),
        .target(name: "HookInstall"),
        .target(name: "AgentIslandDaemon", dependencies: ["AgentIslandCore"]),
        .executableTarget(
            name: "AgentIslandSelfTest",
            dependencies: ["AgentIslandCore", "PersonaKit", "HookInstall", "AgentIslandDaemon",
                           "AgentIslandThemes"]),
        .executableTarget(name: "AgentIslandDemo", dependencies: ["AgentIslandCore"]),
        .executableTarget(
            name: "AgentIslandApp",
            dependencies: ["AgentIslandCore", "PersonaKit", "AgentIslandDaemon", "HookInstall",
                           "AgentIslandThemes"],
            // Per-theme bundled resources (first use of Bundle.module). `.copy` keeps the folder
            // structure verbatim so relative lookups resolve. The theme-spec doc is source-tree
            // docs, not a runtime resource — exclude it so SwiftPM doesn't warn/bundle it.
            exclude: ["Themes/README.md"],
            resources: [.copy("Themes/RoadRunner"), .copy("Themes/Default"), .copy("Themes/critter")]),
        .executableTarget(name: "AgentIslandHookCLI", dependencies: ["HookInstall", "AgentIslandDaemon"]),
        .executableTarget(name: "agentislandd", dependencies: ["AgentIslandDaemon", "AgentIslandCore"]),
    ]
)
