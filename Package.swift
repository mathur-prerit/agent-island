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
        // Tiny demo: runs the verified engine against your real ~/.claude transcripts.
        // `swift run AgentIslandDemo [path-to-session.jsonl]`.
        .executable(name: "AgentIslandDemo", targets: ["AgentIslandDemo"]),
    ],
    targets: [
        // Pure, headless logic. The AppKit app (NSPanel island, strips) lives under
        // App/ and requires full Xcode to build; it links these packages.
        .target(name: "AgentIslandCore"),
        .target(name: "PersonaKit"),
        .target(name: "HookInstall"),
        .target(name: "AgentIslandDaemon"),
        .executableTarget(
            name: "AgentIslandSelfTest",
            dependencies: ["AgentIslandCore", "PersonaKit", "HookInstall", "AgentIslandDaemon"]),
        .executableTarget(name: "AgentIslandDemo", dependencies: ["AgentIslandCore"]),
    ]
)
