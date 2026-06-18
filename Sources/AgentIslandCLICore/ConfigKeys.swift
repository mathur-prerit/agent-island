import Foundation

// The PURE allowlist + validation for the `config` subcommand. The CLI reads/writes the APP's
// preference domain (`UserDefaults(suiteName: appBundleID)`), but WHICH keys are settable and how a
// value is validated is decided here, with no defaults store touched — so the self-test can assert the
// allowlist and the per-key validation without a real preferences write. The executable maps a
// validated value to a CFPreferences write.

/// What a config key stores. Drives both validation and how the executable writes it (bool vs string)
/// into the app's defaults so a `config set islandKeepAwake true` lands a real `Bool`, not the string
/// "true" the app would never read as a bool.
public enum ConfigValueKind: Equatable {
    case bool
    /// A free string, but only one of `allowed` if non-empty (an enum-like key).
    case string(allowed: [String])
}

/// One settable app preference: its key (the exact `UserDefaults` key the app reads), a human blurb for
/// `config` listing, and its value kind for validation. The CLI never invents keys — only these are
/// settable, mirroring exactly what `Sources/AgentIslandApp/main.swift` reads from `UserDefaults`.
public struct ConfigKey: Equatable {
    public let key: String
    public let summary: String
    public let kind: ConfigValueKind

    public init(key: String, summary: String, kind: ConfigValueKind) {
        self.key = key
        self.summary = summary
        self.kind = kind
    }
}

/// Why a `config set` value was rejected — pure, so the self-test asserts each branch.
public enum ConfigError: Error, Equatable {
    case unknownKey(String)              // not in the allowlist (no silent write of an unread key)
    case invalidBool(String)             // a bool key given something that isn't true/false/1/0/yes/no
    case notAllowed(value: String, allowed: [String])   // an enum-like key given an off-list value
}

/// A value validated + normalised for writing into the app's defaults. The executable matches on this
/// to choose a `Bool` vs `String` CFPreferences write — keeping the type decision in the pure layer.
public enum NormalizedConfigValue: Equatable {
    case bool(Bool)
    case string(String)
}

public enum ConfigKeys {
    /// The settable app preferences. Mirrors the keys `AgentIslandApp` reads from `UserDefaults`:
    /// `islandTheme` (the selected theme id — validated only as non-empty since installed ids are
    /// dynamic), `soundEnabled` / `soundCueSet`, `islandKeepAwake`, and the event-mode decision. Keys
    /// the app manages itself as opaque state (dismissed-finished set, last-update-check timestamp,
    /// dismissed-update version) are deliberately NOT exposed here — they aren't user knobs.
    public static let all: [ConfigKey] = [
        ConfigKey(key: "islandTheme",
                  summary: "Active animation theme id (e.g. journey, minimal, critter).",
                  kind: .string(allowed: [])),
        ConfigKey(key: "soundEnabled",
                  summary: "Play lifecycle sound cues (true/false).",
                  kind: .bool),
        ConfigKey(key: "soundCueSet",
                  summary: "Which cue set plays: theme | default.",
                  kind: .string(allowed: ["theme", "default"])),
        ConfigKey(key: "islandKeepAwake",
                  summary: "Keep the Mac awake while an agent is working (true/false).",
                  kind: .bool),
        ConfigKey(key: "eventDrivenSetupDecision",
                  summary: "Event-driven mode state: enabled | declined | error.",
                  kind: .string(allowed: ["enabled", "declined", "error"])),
    ]

    /// Look up a settable key, or nil if it isn't on the allowlist.
    public static func lookup(_ key: String) -> ConfigKey? {
        all.first { $0.key == key }
    }

    /// Validate + normalise a raw string value for `key`. Returns the typed value to write, or a typed
    /// error. Pure (no defaults store). The executable turns `.bool`/`.string` into the matching write.
    public static func validate(key: String, rawValue: String) -> Result<NormalizedConfigValue, ConfigError> {
        guard let known = lookup(key) else { return .failure(.unknownKey(key)) }
        switch known.kind {
        case .bool:
            guard let b = parseBool(rawValue) else { return .failure(.invalidBool(rawValue)) }
            return .success(.bool(b))
        case .string(let allowed):
            if !allowed.isEmpty, !allowed.contains(rawValue) {
                return .failure(.notAllowed(value: rawValue, allowed: allowed))
            }
            return .success(.string(rawValue))
        }
    }

    /// Lenient bool parse for `config set` — accepts the common shells of truthiness so a user needn't
    /// guess the exact spelling. Anything else is rejected (rather than silently coerced).
    public static func parseBool(_ s: String) -> Bool? {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return nil
        }
    }
}
