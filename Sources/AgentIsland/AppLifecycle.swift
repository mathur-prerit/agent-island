import Foundation
import AgentIslandCLICore
import HookInstall   // HomeDir

// `agentisland restart` / `agentisland stop` — operate on the WHOLE install: the menu-bar GUI
// (`AgentIslandApp`) AND the background `agentislandd`. (`daemon …` touches only the daemon; these are
// the "everything" verbs.)
//   stop:    quit the GUI + kill the daemon (+ clear the stale socket/lock, via DaemonCommand).
//   restart: stop both, then relaunch the .app — which brings the menu-bar item back and respawns the
//            daemon per the app's mode (event-driven). One command to fully bounce agent-island.
enum AppLifecycle {

    static func stop() -> Bool {
        let wasRunning = stopApp()
        _ = DaemonCommand.run(.stop)   // kills agentislandd + clears the stale socket/lock
        out(wasRunning ? "Stopped agent-island (app + daemon)." : "agent-island app wasn't running; daemon checked.")
        return true
    }

    static func restart() -> Bool {
        let wasRunning = stopApp()
        _ = DaemonCommand.run(.stop)
        if wasRunning { Thread.sleep(forTimeInterval: 0.6) }   // let the OS release the menu-bar slot + socket
        guard startApp() else {
            errOut("agentisland: couldn't relaunch the app — is AgentIsland.app installed at \(appPath)? "
                   + "(Launching it also restarts the daemon.)")
            return false
        }
        out("Restarted agent-island (app + daemon).")
        return true
    }

    private static var appPath: String { InstallPaths(home: HomeDir.path).appPath }

    /// Quit the menu-bar GUI. Exact process-name match (`-x`) so it never hits this CLI or the daemon.
    /// Returns whether anything was running.
    @discardableResult
    private static func stopApp() -> Bool {
        let pids = capture("/usr/bin/pgrep", ["-x", "AgentIslandApp"])
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { Int($0) }
        guard !pids.isEmpty else { return false }
        _ = exec("/usr/bin/pkill", ["-x", "AgentIslandApp"])
        return true
    }

    /// Relaunch the installed .app (brings back the menu-bar item + respawns the daemon).
    private static func startApp() -> Bool {
        guard FileManager.default.fileExists(atPath: appPath) else { return false }
        return exec("/usr/bin/open", [appPath]) == 0
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
