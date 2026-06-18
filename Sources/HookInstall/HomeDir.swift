import Foundation

// ONE source of truth for "where is HOME", shared by every binary that touches ~/.claude or
// ~/.agent-island: the management CLI (uninstall / start-on-boot / theme), the hook bridge
// (`agentisland-hook install|uninstall|relay`), and the app's event-driven setup. It lives in
// HookInstall — the dependency-free leaf all three already link — so they resolve home IDENTICALLY
// (previously the hook CLI + app used `("~/…" as NSString).expandingTildeInPath`, i.e. NSHomeDirectory(),
// which IGNORES a `$HOME` override, while the management CLI honored `$HOME` — so a sandboxed
// `HOME=$(mktemp -d)` run diverged between them).
//
// Prefers the `HOME` environment variable (validated by the pure `HomeValidation`), falling back to
// `NSHomeDirectory()`. In normal use `$HOME` IS the user's real home, so behavior is unchanged; the
// difference only shows under a deliberate `HOME` override (sandbox tests), where now ALL paths land in
// the same place. A degenerate `HOME="/"` or whitespace is rejected (it would yield nonsense roots like
// `//.agent-island` and let a destructive `uninstall` "succeed" against a place nothing was installed).
public enum HomeDir {
    public static var path: String {
        if let h = ProcessInfo.processInfo.environment["HOME"],
           let accepted = HomeValidation.accepted(h, dirExists: { dirExists($0) }) {
            return accepted
        }
        return NSHomeDirectory()
    }

    private static func dirExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
