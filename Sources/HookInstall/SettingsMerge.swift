import Foundation

public enum SettingsMergeError: Error, Equatable {
    /// The existing settings file is not valid JSON. The caller MUST NOT overwrite the
    /// file in this case — abort and surface the error rather than clobbering user config.
    case invalidJSON
}

/// Pure, safe merge of agent-island's hook command into a Claude Code `settings.json`
/// (or `settings.local.json`) document. Operates on bytes in / bytes out so the caller
/// can do the rest safely (backup + atomic temp-then-rename).
public enum SettingsMerge {

    /// Merge our hook `command` into each event under the top-level `hooks` map,
    /// preserving every other key and any existing entries. Idempotent: an event that
    /// already references our command is left untouched (no duplicate). Returns the new
    /// JSON bytes, or `.invalidJSON` if `existing` won't parse (do not overwrite then).
    public static func install(existing: Data,
                               command: String,
                               events: [String]) -> Result<Data, SettingsMergeError> {
        var root: [String: Any]
        if existing.isEmpty {
            root = [:]
        } else if let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = obj
        } else {
            return .failure(.invalidJSON)
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for event in events {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            if !entries.contains(where: { references(entry: $0, command: command) }) {
                entries.append(["hooks": [["type": "command", "command": command]]])
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks

        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.invalidJSON)
        }
        return .success(data)
    }

    /// Remove only our command's entries (by exact command match), preserving everything
    /// else. Returns `.invalidJSON` if `existing` won't parse.
    public static func uninstall(existing: Data, command: String) -> Result<Data, SettingsMergeError> {
        guard !existing.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            return existing.isEmpty ? .success(existing) : .failure(.invalidJSON)
        }
        var root = obj
        if var hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard var entries = value as? [[String: Any]] else { continue }
                entries.removeAll { references(entry: $0, command: command) }
                hooks[event] = entries
            }
            root["hooks"] = hooks
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.invalidJSON)
        }
        return .success(data)
    }

    private static func references(entry: [String: Any], command: String) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String) == command }
    }
}
