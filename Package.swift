// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentIslandCore", targets: ["AgentIslandCore"]),
        // Framework-free test runner — runs under Command Line Tools (no full Xcode /
        // XCTest / swift-testing needed). `swift run AgentIslandSelfTest`.
        .executable(name: "AgentIslandSelfTest", targets: ["AgentIslandSelfTest"]),
    ],
    targets: [
        // Pure, headless logic. The AppKit app (NSPanel island, strips) lives under
        // App/ and requires full Xcode to build; it links this package.
        .target(name: "AgentIslandCore"),
        .executableTarget(name: "AgentIslandSelfTest", dependencies: ["AgentIslandCore"]),
    ]
)
