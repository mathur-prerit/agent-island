import Foundation

/// A transcript JSONL record, parsed only as far as state derivation needs.
public struct TranscriptRecord: Equatable, Sendable {
    public let type: String
    /// For assistant records: the ordered content-block kinds, e.g. ["thinking","text","tool_use"].
    public let assistantBlockKinds: [String]

    public init(type: String, assistantBlockKinds: [String] = []) {
        self.type = type
        self.assistantBlockKinds = assistantBlockKinds
    }
}

/// Parses Claude Code transcript records. Centralizing all parsing here (one adapter)
/// keeps a format change to a single blast-radius point. Record vocabulary verified
/// against real `~/.claude` transcripts — see `spike/FINDINGS.md`.
public enum TranscriptAdapter {
    /// Non-conversational record types. These MUST be skipped when finding the last
    /// meaningful record, because the transcript tail frequently ends on one of them.
    public static let metadataTypes: Set<String> = [
        "permission-mode", "mode", "last-prompt", "ai-title",
        "attachment", "file-history-snapshot", "system", "queue-operation",
    ]

    public static func isConversational(_ type: String) -> Bool {
        type == "user" || type == "assistant"
    }

    /// Parse one JSONL line. Returns nil for blank/unparseable lines or lines with no
    /// `type` — the caller treats untrusted input leniently (skip, never crash).
    public static func parseLine(_ line: String) -> TranscriptRecord? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        var blockKinds: [String] = []
        if type == "assistant",
           let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            blockKinds = content.compactMap { $0["type"] as? String }
        }
        return TranscriptRecord(type: type, assistantBlockKinds: blockKinds)
    }

    /// Parse whole transcript lines, dropping unparseable ones.
    public static func parse(lines: [String]) -> [TranscriptRecord] {
        lines.compactMap(parseLine)
    }

    /// The last conversational (user|assistant) record, skipping metadata records.
    public static func lastConversational(_ records: [TranscriptRecord]) -> TranscriptRecord? {
        records.reversed().first(where: { isConversational($0.type) })
    }

    /// The text of the first `user` record — for a sub-agent transcript this is the task it was
    /// dispatched with, making a good descriptive name. Handles both the plain-string content shape
    /// and the content-blocks array (returns the first text block). nil if none found.
    public static func firstUserText(lines: [String]) -> String? {
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "user",
                  let message = obj["message"] as? [String: Any]
            else { continue }
            if let s = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty { return s }
            if let blocks = message["content"] as? [[String: Any]] {
                for b in blocks where (b["type"] as? String) == "text" {
                    if let t = (b["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !t.isEmpty { return t }
                }
            }
        }
        return nil
    }
}
