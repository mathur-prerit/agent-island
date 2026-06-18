import Foundation

/// The slice of an OpenCode `message.data` JSON blob that state derivation needs. OpenCode stores
/// sessions in SQLite (`~/.local/share/opencode/opencode.db`), one row per message, `data` a JSON
/// string. For an ASSISTANT message that JSON carries `role`, `time.{created,completed}`, a `tokens`
/// object, a `finish` string, and `path.cwd`. Verified read-only against a real db — see
/// `spike/FINDINGS.md`. Centralizing the parse here (one adapter, mirroring `TranscriptAdapter`)
/// keeps a format change to one blast-radius point and makes it self-testable without a live db.
public struct OpenCodeMessage: Equatable, Sendable {
    public let role: String                 // "user" | "assistant"
    public let createdMs: Int?              // time.created (ms since epoch)
    public let completedMs: Int?            // time.completed — present ⇒ the turn finished generating
    public let tokensTotal: Int?            // tokens.total — the session token figure source
    public let finish: String?              // e.g. "tool-calls" (mid-loop) vs a terminal stop reason
    public let cwd: String?                 // path.cwd

    public init(role: String, createdMs: Int? = nil, completedMs: Int? = nil,
                tokensTotal: Int? = nil, finish: String? = nil, cwd: String? = nil) {
        self.role = role
        self.createdMs = createdMs
        self.completedMs = completedMs
        self.tokensTotal = tokensTotal
        self.finish = finish
        self.cwd = cwd
    }

    public var isAssistant: Bool { role == "assistant" }

    /// Parse one `message.data` JSON string. Returns nil for blank/unparseable input or a blob with
    /// no `role` — the caller treats db text leniently (skip, never crash), exactly like
    /// `TranscriptAdapter.parseLine` treats transcript lines.
    public static func parse(_ data: String) -> OpenCodeMessage? {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let bytes = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let role = obj["role"] as? String
        else { return nil }

        let time = obj["time"] as? [String: Any]
        let created = intValue(time?["created"])
        let completed = intValue(time?["completed"])

        // tokens.total — JSON numbers may arrive as Int or Double; coerce either.
        let tokens = obj["tokens"] as? [String: Any]
        let total = intValue(tokens?["total"])

        let finish = obj["finish"] as? String
        let cwd = (obj["path"] as? [String: Any])?["cwd"] as? String

        return OpenCodeMessage(role: role, createdMs: created, completedMs: completed,
                               tokensTotal: total, finish: finish, cwd: cwd)
    }

    /// Coerce a JSON number (Int or Double) to Int; nil for anything else. SQLite/JSON round-trips
    /// large millisecond timestamps as Double, so a plain `as? Int` cast would silently drop them.
    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}
