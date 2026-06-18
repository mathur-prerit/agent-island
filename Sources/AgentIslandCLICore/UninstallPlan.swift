import Foundation

// The PURE plan for `agentisland uninstall`: given the install paths, produce the ordered list of
// reversal actions WITHOUT performing any of them. The executable walks the plan (asking for
// confirmation, honoring `--dry-run`) and only then touches the filesystem / login item. Separating
// the plan from the doing means the self-test can assert EXACTLY what uninstall targets against a temp
// `home` — proving it would never reach outside the sandbox — with nothing real removed.

/// One reversal step. Carries enough for the executable to act and for a `--dry-run`/confirmation to
/// describe it to the user. Order matters: hooks first (so a half-finished uninstall still leaves the
/// system functional), then the login item, then the on-disk artifacts.
public enum UninstallAction: Equatable {
    case reverseHooks(settingsPath: String)        // SettingsFile.uninstall — remove the relay hooks
    case unregisterLoginItem                        // SMAppService.unregister the .app login item
    case removeBinary(path: String)                 // an `agentisland*` binary on PATH
    case removeDirectory(path: String)              // `~/.agent-island` (full wipe — only on --purge)
    case removeDataKeepingThemes(path: String)      // `~/.agent-island` EXCEPT `themes/` (the default)
    case removeApp(path: String)                    // the installed `.app`

    /// A one-line, user-facing description (used by `--dry-run` and the confirmation prompt).
    public var describe: String {
        switch self {
        case .reverseHooks(let p): return "Remove agent-island hooks from \(p)"
        case .unregisterLoginItem: return "Unregister the start-on-boot login item"
        case .removeBinary(let p): return "Remove binary \(p)"
        case .removeDirectory(let p): return "Remove directory \(p)"
        case .removeDataKeepingThemes(let p): return "Remove \(p) — KEEPING your custom themes in themes/"
        case .removeApp(let p): return "Remove app \(p)"
        }
    }
}

public enum UninstallPlan {
    /// Build the full ordered plan from the install paths. Pure: lists what WOULD happen; the executor
    /// performs each step (and tolerates already-absent targets). Hooks are reversed first, then the
    /// login item, then the binaries, the data dir, and finally the `.app`. By default the data step
    /// KEEPS `~/.agent-island/themes/` (your custom themes survive an uninstall/reinstall); `purge`
    /// wipes the whole data dir for a true clean slate.
    public static func plan(_ paths: InstallPaths, purge: Bool = false) -> [UninstallAction] {
        var actions: [UninstallAction] = [
            .reverseHooks(settingsPath: paths.settingsPath),
            .unregisterLoginItem,
        ]
        actions += paths.binaryPaths.map { .removeBinary(path: $0) }
        actions.append(purge ? .removeDirectory(path: paths.agentIslandDir)
                             : .removeDataKeepingThemes(path: paths.agentIslandDir))
        actions.append(.removeApp(path: paths.appPath))
        return actions
    }
}
