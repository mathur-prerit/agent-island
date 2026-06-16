import Foundation
import AgentIslandCore
import AgentIslandDaemon

// agent-island daemon. Listens on a Unix socket for hook events relayed by
// `agentisland-hook`, maintains per-session state, and publishes it to
// ~/.agent-island/state.json for the app to read (event-driven, replacing polling).
// Run by a launchd LaunchAgent (or directly for testing): `swift run agentislandd`.

let socketPath = ("~/.agent-island/agentisland.sock" as NSString).expandingTildeInPath
let statePath = ("~/.agent-island/state.json" as NSString).expandingTildeInPath
let store = StateStore()
let server = UnixSocketServer(socketPath: socketPath)

func publishState() {
    guard let data = try? JSONEncoder().encode(store.snapshot()) else { return }
    try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
}

do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("agentislandd: failed to bind \(socketPath): \(error)\n".utf8))
    exit(1)
}
publishState()
print("agentislandd listening at \(socketPath); state -> \(statePath)")

server.acceptLoop { payload in
    guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
    // Claude Code hook payloads carry the event under `hook_event_name`; tolerate `type`.
    let eventType = (obj["hook_event_name"] as? String) ?? (obj["type"] as? String) ?? ""
    let sessionID = (obj["session_id"] as? String) ?? ""
    if store.apply(eventType: eventType, sessionID: sessionID) {
        publishState()
    }
}
