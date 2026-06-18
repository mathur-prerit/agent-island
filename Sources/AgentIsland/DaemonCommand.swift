import Foundation
import AgentIslandCLICore
import HookInstall   // HomeDir

// `agentisland daemon [status|stop|restart]`. Manages the background `agentislandd` process — chiefly
// to kill a DANGLING daemon (the app quit/crashed but the daemon lingered, holding the socket + a stale
// state.json) and optionally respawn a fresh one. `status` is read-only (the default), so a bare
// invocation never kills anything.
enum DaemonCommand {
    static func run(_ action: DaemonAction) -> Bool {
        switch action {
        case .status:  return status()
        case .stop:    return stop()
        case .restart: return restart()
        }
    }

    /// PIDs of every running `agentislandd` (exact process-name match, so it never hits this CLI).
    private static func runningPIDs() -> [Int] {
        capture("/usr/bin/pgrep", ["-x", "agentislandd"])
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { Int($0) }
    }

    private static func status() -> Bool {
        let pids = runningPIDs()
        if pids.isEmpty { out("agentislandd: not running") }
        else { out("agentislandd: running (pid \(pids.map(String.init).joined(separator: ", ")))") }
        return true
    }

    private static func stop() -> Bool {
        let pids = runningPIDs()
        if pids.isEmpty {
            out("agentislandd: nothing to stop.")
        } else {
            _ = exec("/usr/bin/pkill", ["-x", "agentislandd"])
            out("Stopped \(pids.count) agentislandd process\(pids.count == 1 ? "" : "es").")
        }
        cleanStale()   // drop the stale socket + lock so a fresh daemon (or the app) rebinds cleanly
        return true
    }

    private static func restart() -> Bool {
        _ = stop()
        guard let bin = daemonBinary() else {
            errOut("agentisland: couldn't find agentislandd — is AgentIsland.app installed? (Launching the app also starts it.)")
            return false
        }
        // Spawn DETACHED (nohup … &) so the fresh daemon outlives this short-lived CLI invocation.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup \"\(bin)\" >/dev/null 2>&1 &"]
        do { try p.run(); p.waitUntilExit() }
        catch { errOut("agentisland: couldn't start agentislandd (\(error))"); return false }
        out("Restarted agentislandd.")
        return true
    }

    /// The daemon binary inside the installed .app (a sibling of the app executable).
    private static func daemonBinary() -> String? {
        let bin = InstallPaths(home: HomeDir.path).appPath + "/Contents/MacOS/agentislandd"
        return FileManager.default.isExecutableFile(atPath: bin) ? bin : nil
    }

    /// Remove the stale unix socket + lock from `~/.agent-island` (leaves themes/state otherwise).
    private static func cleanStale() {
        let dir = InstallPaths(home: HomeDir.path).agentIslandDir
        for f in ["agentisland.sock", "agentislandd.lock"] {
            try? FileManager.default.removeItem(atPath: "\(dir)/\(f)")
        }
    }

    @discardableResult
    private static func exec(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    private static func capture(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
