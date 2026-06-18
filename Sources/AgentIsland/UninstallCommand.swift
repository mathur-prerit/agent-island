import Foundation
import AgentIslandCLICore
import HookInstall

// `agentisland uninstall [--yes] [--dry-run]`. The PLAN (what to touch) is the pure
// `UninstallPlan.plan(InstallPaths)`; this executor performs each step. SAFETY: defaults to the real
// `$HOME`, but every step tolerates an already-absent target, hook reversal goes through the shared
// `SettingsFile.uninstall` (backup-aware, only removes our relay entries), and `--dry-run` performs
// NOTHING (just prints the plan). Confirmation is required unless `--yes`.
enum UninstallCommand {
    static func run(yes: Bool, dryRun: Bool, paths: InstallPaths = InstallPaths(home: HomeDir.path)) -> Bool {
        let actions = UninstallPlan.plan(paths)

        out("This will:")
        for a in actions { out("  - \(a.describe)") }

        if dryRun {
            out("\n(--dry-run: nothing was changed.)")
            return true
        }
        if !yes {
            out("\nProceed? [y/N] ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else { out("Aborted."); return false }
        }

        var ok = true
        for a in actions { ok = perform(a) && ok }
        out(ok ? "\nDone. agent-island removed." : "\nDone with some warnings (see above).")
        return ok
    }

    /// Perform one reversal step. Each tolerates an already-gone target (a partial install uninstalls
    /// cleanly) and never throws out of the loop — a single failure logs and continues so later steps
    /// still run.
    private static func perform(_ action: UninstallAction) -> Bool {
        let fm = FileManager.default
        switch action {
        case .reverseHooks(let settingsPath):
            // Reverse via the SHARED merge — removes only our relay entries, preserving the rest, and is
            // a no-op when settings.json doesn't exist. The command we pass must itself be recognized by
            // `SettingsMerge.isAgentIslandRelay` (contains "AgentIslandHookCLI" + ends in " relay") so the
            // signature match removes the hook however it was installed (app's quoted abs path OR the
            // hook CLI's argv0) — that's what makes this reverse both install styles.
            do {
                try SettingsFile.uninstall(settingsPath: settingsPath, command: "AgentIslandHookCLI relay")
                return true
            } catch {
                errOut("  warning: couldn't reverse hooks in \(settingsPath) (\(error))")
                return false
            }
        case .unregisterLoginItem:
            return LoginItem.unregister()
        case .removeBinary(let path), .removeApp(let path):
            return removePath(path, fm: fm)
        case .removeDirectory(let path):
            return removePath(path, fm: fm)
        }
    }

    /// Remove a path if present; an absent path is success (idempotent uninstall). A real removal
    /// failure (permissions) logs a warning and returns false but doesn't abort the rest.
    private static func removePath(_ path: String, fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: path) else { return true }
        do { try fm.removeItem(atPath: path); return true }
        catch {
            errOut("  warning: couldn't remove \(path) (\(error))")
            return false
        }
    }
}

private func out(_ s: String, terminator: String) { Swift.print(s, terminator: terminator) }
