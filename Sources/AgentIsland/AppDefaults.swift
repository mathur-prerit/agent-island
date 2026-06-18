import Foundation
import AgentIslandCLICore

// Read/write the APP's preferences domain (`com.mathur-prerit.agentisland`), NOT this CLI's own domain.
// The app reads `UserDefaults.standard` in its own bundle-id domain, so to change what it sees we must
// write THAT domain. `UserDefaults(suiteName:)` targets a named domain directly (it's the public
// wrapper over CFPreferences), so a value the CLI writes here is exactly what the next `defaults read
// com.mathur-prerit.agentisland <key>` — and the running app — observes.
enum AppDefaults {
    /// The app's defaults store, addressed by bundle id. Force-unwrapped is avoided: a nil suite (only
    /// if the id were the CLI's own bundle id, which it isn't) falls back to `.standard` so a write
    /// still goes somewhere visible rather than crashing.
    private static var store: UserDefaults {
        UserDefaults(suiteName: CLIConstants.appBundleID) ?? .standard
    }

    /// The current value for `key`, rendered as a string for display (bools as "true"/"false"). Nil
    /// when unset — `config` shows "(unset)".
    static func stringValue(forKey key: String) -> String? {
        let d = store
        guard d.object(forKey: key) != nil else { return nil }
        if let b = d.object(forKey: key) as? Bool, ConfigKeys.lookup(key)?.kind == .bool {
            return b ? "true" : "false"
        }
        return d.string(forKey: key) ?? "\(d.object(forKey: key) ?? "")"
    }

    /// Write a validated value into the app's domain. `synchronize()` flushes it to the plist promptly
    /// so a subsequent `defaults read` (or app relaunch) sees it without waiting for the periodic flush.
    static func write(_ value: NormalizedConfigValue, forKey key: String) {
        let d = store
        switch value {
        case .bool(let b): d.set(b, forKey: key)
        case .string(let s): d.set(s, forKey: key)
        }
        d.synchronize()
    }
}
