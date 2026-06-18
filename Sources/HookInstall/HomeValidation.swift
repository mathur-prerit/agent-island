import Foundation

// PURE validation for a candidate `$HOME` value. Pure (no process env, no real filesystem) so the
// self-test can cover the rules directly: the only effectful input — "does this path name an existing
// directory?" — is passed in as a closure, so tests inject a stub while the sibling `HomeDir` (same
// module) injects `FileManager`.
//
// Why: `HomeDir` previously accepted ANY non-empty `$HOME`, so `HOME="/"` or whitespace produced
// nonsense roots (`//.agent-island`, ` /.claude/settings.json`) and `uninstall` would "succeed" against
// a place nothing was ever installed. A valid home must be trimmed-nonempty, absolute, not the
// filesystem root itself, and an existing directory; otherwise the caller falls back to the real home.
public enum HomeValidation {
    /// `true` iff `candidate` is acceptable as `$HOME`: after trimming surrounding whitespace it is
    /// non-empty, absolute (`/`-prefixed), not exactly `/`, and `dirExists(trimmed)` is `true`.
    /// `dirExists` receives the trimmed path so a `HOME=" /tmp/x "` with stray spaces still resolves.
    public static func isAcceptable(_ candidate: String, dirExists: (String) -> Bool) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/"), trimmed != "/" else { return false }
        return dirExists(trimmed)
    }

    /// The accepted home (trimmed) when `candidate` passes, else `nil` (caller falls back). Trimming the
    /// returned value keeps the derived roots clean even if `$HOME` carried surrounding whitespace.
    public static func accepted(_ candidate: String, dirExists: (String) -> Bool) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        return isAcceptable(candidate, dirExists: dirExists) ? trimmed : nil
    }
}
