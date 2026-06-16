import Foundation
import HookInstall
import AgentIslandDaemon

// agent-island hook bridge. Claude Code invokes `agentisland-hook relay` from each
// registered lifecycle hook; it reads the hook's JSON payload on stdin and fire-and-
// forgets it to the daemon's socket (never blocking the session). `install`/`uninstall`
// register/remove the hooks in ~/.claude/settings.json safely (backup + atomic write).
//
//   agentisland-hook install      # register hooks into ~/.claude/settings.json
//   agentisland-hook uninstall    # remove them
//   agentisland-hook relay        # (used by the hooks) stdin JSON -> daemon socket

let socketPath = ("~/.agent-island/agentisland.sock" as NSString).expandingTildeInPath
let settingsPath = ("~/.claude/settings.json" as NSString).expandingTildeInPath
let events = ["UserPromptSubmit", "Stop", "SubagentStart", "SubagentStop",
              "PermissionRequest", "SessionStart", "SessionEnd"]

func stderrPrint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let me = CommandLine.arguments.first ?? "agentisland-hook"
let relayCommand = "\(me) relay"
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "relay"

switch mode {
case "install":
    do {
        try SettingsFile.install(settingsPath: settingsPath, command: relayCommand, events: events)
        print("Installed agent-island hooks into \(settingsPath)")
        print("Backup of the previous file (if any): \(settingsPath).bak")
    } catch {
        stderrPrint("install failed: \(error) (your settings.json was left untouched)")
        exit(1)
    }

case "uninstall":
    do {
        try SettingsFile.uninstall(settingsPath: settingsPath, command: relayCommand)
        print("Removed agent-island hooks from \(settingsPath)")
    } catch {
        stderrPrint("uninstall failed: \(error)")
        exit(1)
    }

case "relay":
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    _ = UnixSocketClient.send(payload, toSocketPath: socketPath)  // fire-and-forget; never block

default:
    print("usage: agentisland-hook [install|uninstall|relay]")
}
