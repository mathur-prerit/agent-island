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
let events = ["UserPromptSubmit", "Stop", "PostToolUse", "SubagentStart", "SubagentStop",
              "PermissionRequest", "SessionStart", "SessionEnd"]

func stderrPrint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// Click-to-focus enrichment: the hook process inherits the terminal's window-identity env vars
// (the CONFIRMED spike). We inject them into the payload (under an `island_` prefix to avoid
// colliding with Claude's own keys) so the daemon can persist them per session and the app can
// later raise the owning terminal tab on click. Injected on every relay (env is always present),
// keeping the relay fire-and-forget. If parsing fails we forward the ORIGINAL bytes untouched —
// never break the relay over enrichment.
func enrich(payload: Data) -> Data {
    guard var obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
        return payload   // not a JSON object → forward verbatim
    }
    let env = ProcessInfo.processInfo.environment
    func nonEmpty(_ key: String) -> String? {
        guard let v = env[key], !v.isEmpty else { return nil }
        return v
    }
    if let termProgram = nonEmpty("TERM_PROGRAM") { obj["island_term_program"] = termProgram }
    // Prefer iTerm2's own session id; fall back to the generic TERM_SESSION_ID (same GUID under iTerm2).
    if let itermSession = nonEmpty("ITERM_SESSION_ID") ?? nonEmpty("TERM_SESSION_ID") {
        obj["island_iterm_session_id"] = itermSession
    }
    if let bundleID = nonEmpty("__CFBundleIdentifier") { obj["island_term_bundle_id"] = bundleID }
    // Re-serialize; if that somehow fails, fall back to the original bytes.
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? payload
}

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
    let enriched = enrich(payload: payload)  // inject window-identity for click-to-focus
    _ = UnixSocketClient.send(enriched, toSocketPath: socketPath)  // fire-and-forget; never block

default:
    print("usage: agentisland-hook [install|uninstall|relay]")
}
