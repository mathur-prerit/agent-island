import Foundation

/// One-pass transcript digest: walks the JSONL lines once, parsing each line a single time, and
/// derives every transcript-level fact the UI needs (tokens, title, start time, step count).
///
/// This exists purely as a performance refactor — transcripts grow, and the call sites used to
/// re-read + re-JSON-parse the same lines 2–5× (once per fact). `scan` folds those independent
/// walks into one. It is BYTE-IDENTICAL to composing the individual functions:
///   - `TokenUsage.freshTokens(lines:)`
///   - `ConversationTitle.fromTranscript(lines:)`
///   - `TranscriptClock.startedAt(lines:)`
///   - the `TranscriptAdapter.parse(lines:)`-based `tool_use` count
/// The individual functions remain the canonical definitions (other call sites + tests use them);
/// `scan` only re-applies their LOGIC against a shared parse. The self-test asserts equality.
public enum TranscriptDigest {
    public struct Result: Equatable, Sendable {
        public let tokens: Int
        public let title: String?
        public let startedAt: Date?
        public let steps: Int

        public init(tokens: Int, title: String?, startedAt: Date?, steps: Int) {
            self.tokens = tokens
            self.title = title
            self.startedAt = startedAt
            self.steps = steps
        }
    }

    /// Single walk over `lines`, one `JSONSerialization` parse per line, all four rules applied to
    /// that one parsed object. Tolerant of unparseable lines exactly as the individual functions are.
    public static func scan(lines: [String]) -> Result {
        var maxContext = 0
        var outputByMessage: [String: Int] = [:]
        var title: String?
        var startedAt: Date?
        var steps = 0

        for (index, line) in lines.enumerated() {
            // SINGLE parse per line. Unparseable / non-object lines are skipped entirely — every
            // individual function below also bails on exactly this guard, so skipping here is safe.
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let message = obj["message"] as? [String: Any]

            // --- Rule 1: tokens (mirrors TokenUsage.freshTokens) ---
            // usage at top level OR nested under message.usage. The figure is the PEAK request
            // context (input + cache_read + cache_creation) plus output deduped by message.id —
            // see TokenUsage.freshTokens for why summing input+output per record over-counts.
            if let u = (obj["usage"] as? [String: Any]) ?? (message?["usage"] as? [String: Any]) {
                let input = (u["input_tokens"] as? Int) ?? 0
                let cacheRead = (u["cache_read_input_tokens"] as? Int) ?? 0
                let cacheCreate = (u["cache_creation_input_tokens"] as? Int) ?? 0
                maxContext = max(maxContext, input + cacheRead + cacheCreate)
                let key = (message?["id"] as? String) ?? "•line\(index)"
                outputByMessage[key] = max(outputByMessage[key] ?? 0, (u["output_tokens"] as? Int) ?? 0)
            }

            let type = obj["type"] as? String

            // --- Rule 2: title (mirrors ConversationTitle.fromTranscript) ---
            // ai-title records; read aiTitle; trim; LAST non-empty wins.
            if type == "ai-title", let raw = obj["aiTitle"] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { title = trimmed }
            }

            // --- Rule 3: startedAt (mirrors TranscriptClock.startedAt) ---
            // FIRST record carrying a parseable timestamp.
            if startedAt == nil,
               let ts = obj["timestamp"] as? String,
               let d = TranscriptClock.parse(ts) {
                startedAt = d
            }

            // --- Rule 4: steps (mirrors TranscriptAdapter.parseLine's assistantBlockKinds, then
            //     records.reduce { tool_use count }). assistantBlockKinds is populated ONLY when the
            //     record type is "assistant" AND message.content is an array of objects; each block's
            //     "type" is read, and tool_use blocks are counted. ---
            if type == "assistant",
               let content = message?["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "tool_use" {
                    steps += 1
                }
            }
        }

        let tokens = maxContext + outputByMessage.values.reduce(0, +)
        return Result(tokens: tokens, title: title, startedAt: startedAt, steps: steps)
    }
}
