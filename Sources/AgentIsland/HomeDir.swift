import Foundation
import AgentIslandCLICore

// One source of truth for "where is HOME" across the CLI's effectful commands. Prefers the `HOME`
// environment variable, falling back to `NSHomeDirectory()`. Using `$HOME` (rather than only
// `NSHomeDirectory()`, which reads the password database and ignores a `HOME` override) means a
// sandboxed `HOME=$(mktemp -d)` run — how the destructive paths are exercised in development WITHOUT
// touching the real `~/.claude` / `~/.agent-island` — actually lands inside the sandbox. In normal use
// `$HOME` is the user's real home, so behavior is unchanged.
//
// We accept `$HOME` only when it's a sane, existing directory (validated by the pure `HomeValidation`):
// a degenerate `HOME="/"` or whitespace would otherwise yield nonsense roots (`//.agent-island`) and
// make a destructive `uninstall` silently "succeed" against a place nothing was installed. An existing
// `HOME=$(mktemp -d)` passes, so the sandbox workflow is preserved.
enum HomeDir {
    static var path: String {
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
