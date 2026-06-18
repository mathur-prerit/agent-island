import Foundation
import AgentIslandCLICore

// The effectful half of `config get`/`config set`: validate against the pure allowlist
// (`ConfigKeys`), then read/write the app's defaults domain via `AppDefaults`. The validation +
// normalisation decision is entirely in the pure layer; this just reports + persists.
enum ConfigCommands {
    /// `config get <key>`: print the app's stored value (or "(unset)"). An unknown key is an error so a
    /// typo doesn't silently print "(unset)" forever.
    static func get(_ key: String) -> Bool {
        guard ConfigKeys.lookup(key) != nil else {
            errOut("agentisland: unknown config key '\(key)' (run `agentisland config` to list keys)")
            return false
        }
        out(AppDefaults.stringValue(forKey: key) ?? "(unset)")
        return true
    }

    /// `config set <key> <value>`: validate against the allowlist + value kind, then write the typed
    /// value into the app's domain. Reports the precise rejection reason on failure (unknown key, bad
    /// bool, off-allowlist value) — never writes an unvalidated value.
    static func set(key: String, value: String) -> Bool {
        switch ConfigKeys.validate(key: key, rawValue: value) {
        case .failure(let e):
            errOut("agentisland: " + describe(e))
            return false
        case .success(let normalized):
            AppDefaults.write(normalized, forKey: key)
            out("Set \(key) = \(value) (in \(CLIConstants.appBundleID)). Restart agent-island to apply.")
            return true
        }
    }

    private static func describe(_ e: ConfigError) -> String {
        switch e {
        case .unknownKey(let k):
            return "unknown config key '\(k)' (run `agentisland config` to list keys)"
        case .invalidBool(let v):
            return "'\(v)' isn't a boolean — use true/false"
        case .notAllowed(let v, let allowed):
            return "'\(v)' isn't allowed — pick one of: \(allowed.joined(separator: ", "))"
        }
    }
}
