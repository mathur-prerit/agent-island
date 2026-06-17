import Foundation

/// Derives the conversation's display title from the transcript's `ai-title` records.
///
/// Claude Code writes an `ai-title` record whenever it (re)summarizes the conversation; the file
/// accumulates several as the chat evolves, so the **last** one is the current title. Shape verified
/// against real `~/.claude` transcripts: `{"type":"ai-title","aiTitle":"…","sessionId":"…"}`.
public enum ConversationTitle {
    /// The most recent non-empty `ai-title`, or nil if the transcript has none yet.
    public static func fromTranscript(lines: [String]) -> String? {
        var title: String?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "ai-title",
                  let raw = obj["aiTitle"] as? String
            else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { title = trimmed }   // last one wins
        }
        return title
    }
}
