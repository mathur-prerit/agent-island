import Foundation
import AgentIslandCLICore
import AgentIslandThemes

// `agentisland update`. Reuses the SHARED pure decision (`ReleaseFeed.parseLatestTag` +
// `UpdateAvailability.decide` + `SemVer`) — no version logic is duplicated. The only effect is the
// network GET of the releases feed and (on the user's confirmation) re-running the installer one-liner
// to update in place. Honest + thin: if it can't apply non-interactively, it prints the one-liner.
enum UpdateCommand {
    static func run() -> Bool {
        let installed = CLIConstants.version
        // Fetch the latest tag (https-only GET → the shared parser). A 404 means the repo has no
        // releases yet — definitively "nothing newer", so treat it (and any fetch failure) as up to
        // date with a soft note, matching the app's silent posture. nil latest → decide() = .upToDate.
        let latest: String?
        switch Net.get(CLIConstants.releasesLatestAPI) {
        case .success(let data):
            latest = ReleaseFeed.parseLatestTag(data)
        case .failure(.httpStatus(404)):
            latest = nil   // no releases published → nothing to update to
        case .failure(let e):
            errOut("agentisland: note — couldn't reach the release feed (\(e)); assuming up to date.")
            latest = nil
        }

        // Same decision the app's menu uses — no dismissed version on the CLI side (a CLI run is an
        // explicit check, so we always offer a strictly-newer release).
        switch UpdateAvailability.decide(installed: installed, latest: latest, dismissed: nil) {
        case .upToDate:
            out("agent-island \(installed) is up to date.")
            return true
        case .available(let newVersion):
            out("Update available: \(installed) → \(newVersion)")
            // Apply by re-running the from-source installer. It's interactive-safe (builds, copies,
            // re-wires hooks idempotently). We confirm first unless stdin isn't a TTY (then just print
            // the one-liner so a script never blocks).
            guard isatty(fileno(stdin)) != 0 else {
                out("To update, run:\n  \(CLIConstants.installOneLiner)")
                return true
            }
            out("Update now by re-running the installer? This rebuilds from source. [y/N] ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                out("Skipped. To update later:\n  \(CLIConstants.installOneLiner)")
                return true
            }
            return applyUpdate()
        }
    }

    /// Apply the update by piping the installer through `sh` (the same one-liner). We shell out to
    /// `curl … | sh` rather than re-implementing the install steps — one source of truth. Returns the
    /// installer's success.
    private static func applyUpdate() -> Bool {
        out("Running the installer…")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", CLIConstants.installOneLiner]
        do { try proc.run() } catch {
            errOut("agentisland: couldn't launch the installer — run it manually:\n  \(CLIConstants.installOneLiner)")
            return false
        }
        proc.waitUntilExit()
        if proc.terminationStatus == 0 {
            out("Updated.")
            return true
        } else {
            errOut("agentisland: the installer exited \(proc.terminationStatus)")
            return false
        }
    }
}

private func out(_ s: String, terminator: String) { Swift.print(s, terminator: terminator) }
