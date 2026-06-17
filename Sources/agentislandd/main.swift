import Foundation
import Darwin
import AgentIslandCore
import AgentIslandDaemon

// agent-island daemon. Listens on a Unix socket for hook events relayed by
// `agentisland-hook`, maintains per-session state, and publishes it to
// ~/.agent-island/state.json for the app to read (event-driven, replacing polling).
// Run by a launchd LaunchAgent (or directly for testing): `swift run agentislandd`.

let socketPath = ("~/.agent-island/agentisland.sock" as NSString).expandingTildeInPath
let statePath = ("~/.agent-island/state.json" as NSString).expandingTildeInPath

// Single-instance guard. UnixSocketServer.start() unconditionally unlinks + rebinds the
// socket, so without this a second daemon would silently bind over the first (orphaning its
// listener and racing state.json). Hold an exclusive, non-blocking advisory lock for our whole
// lifetime; if another agentislandd already holds it, exit quietly and let it keep serving.
let lockPath = ("~/.agent-island/agentislandd.lock" as NSString).expandingTildeInPath
try? FileManager.default.createDirectory(
    atPath: (lockPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    exit(0)  // another instance is running (or we can't lock) — don't start a duplicate
}
// lockFD is intentionally held (never closed) for the process lifetime; the OS releases the
// flock automatically when this process exits.

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

// Heartbeat: republish on a timer so state.json stays fresh (the app treats a file older than
// 30s as "daemon down" and falls back to polling) and idle sessions get pruned even when no new
// events arrive. acceptLoop blocks the main thread, so run this on a background queue.
DispatchQueue.global(qos: .utility).async {
    while true {
        Thread.sleep(forTimeInterval: 10)
        publishState()
    }
}

server.acceptLoop { payload in
    guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
    // Claude Code hook payloads carry the event under `hook_event_name`; tolerate `type`.
    let eventType = (obj["hook_event_name"] as? String) ?? (obj["type"] as? String) ?? ""
    let sessionID = (obj["session_id"] as? String) ?? ""
    let cwd = obj["cwd"] as? String   // project dir → label
    if store.apply(eventType: eventType, sessionID: sessionID, cwd: cwd) {
        publishState()
    }
}
