import Foundation
import HookInstall

/// Makes event-driven mode (daemon + hooks) the default, reversibly. The relay command and
/// daemon spawn need absolute paths to the sibling executables; we resolve them from the
/// running app's executable directory (works for `swift run` and the bundled .app). If they
/// can't be found, every entry point no-ops so the app simply stays on polling.
enum EventDrivenSetup {
    static let events = ["UserPromptSubmit", "Stop", "PostToolUse", "SubagentStart", "SubagentStop",
                         "PermissionRequest", "SessionStart", "SessionEnd"]
    static let settingsPath = ("~/.claude/settings.json" as NSString).expandingTildeInPath
    static let statePath = ("~/.agent-island/state.json" as NSString).expandingTildeInPath

    private static func binDir() -> String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return (exe as NSString).deletingLastPathComponent
    }
    private static func sibling(_ name: String) -> String? {
        let p = binDir() + "/" + name
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
    static func hookBinary() -> String? { sibling("AgentIslandHookCLI") }
    static func daemonBinary() -> String? { sibling("agentislandd") }

    /// Hooks + daemon binaries both present → auto-setup is possible.
    static var available: Bool { hookBinary() != nil && daemonBinary() != nil }

    private static func relayCommand() -> String? {
        guard let hook = hookBinary() else { return nil }
        return "\"\(hook)\" relay"  // quoted: the path may contain spaces
    }

    static func installHooks() throws {
        guard let cmd = relayCommand() else { throw SettingsFile.FileError.writeFailed }
        try SettingsFile.install(settingsPath: settingsPath, command: cmd, events: events)
    }
    static func uninstallHooks() throws {
        guard let cmd = relayCommand() else { return }
        try SettingsFile.uninstall(settingsPath: settingsPath, command: cmd)
    }

    /// Spawn `agentislandd` if its state file isn't fresh (a fresh file ⇒ already running).
    /// The daemon holds a single-instance flock, so a redundant spawn (e.g. a startup race in
    /// this freshness check) exits immediately without disturbing the running one — safe to
    /// call often.
    static func ensureDaemonRunning() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: statePath),
           let m = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(m) < 30 { return }
        guard let bin = daemonBinary() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
