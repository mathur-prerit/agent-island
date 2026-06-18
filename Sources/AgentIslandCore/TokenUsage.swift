import Foundation

/// Sums token usage from a session transcript's assistant records.
public enum TokenUsage {
    /// The session's token figure: **peak request context + total generated output**.
    ///
    /// - The *context* of one assistant request is `input_tokens + cache_read_input_tokens +
    ///   cache_creation_input_tokens` — the whole request billed that turn. On a Claude Code
    ///   session most of it lives in the cache fields (`input_tokens` collapses to ~1-2 once the
    ///   context is cached), so the old "input+output, cache excluded" definition saw almost none
    ///   of it. We take the PEAK across records, not the last: a session can compact/clear and
    ///   shrink, and the tail is often a small summary record.
    /// - *Output* is summed ONCE PER assistant message. Claude Code writes one JSONL record per
    ///   streamed content block and every record of the same message repeats the identical usage,
    ///   so we dedup by `message.id` (records without an id each count once).
    ///
    /// This is immune to the two ways the naive `sum(input+output)` over-counted: cumulative-per-
    /// request input re-added on every turn, and one message's usage multiplied by its record
    /// fan-out. Tolerant of both the top-level `usage` shape and the nested `message.usage` shape.
    public static func freshTokens(lines: [String]) -> Int {
        var maxContext = 0
        var outputByMessage: [String: Int] = [:]
        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let message = obj["message"] as? [String: Any]
            let usage = (obj["usage"] as? [String: Any]) ?? (message?["usage"] as? [String: Any])
            guard let u = usage else { continue }
            let input = (u["input_tokens"] as? Int) ?? 0
            let cacheRead = (u["cache_read_input_tokens"] as? Int) ?? 0
            let cacheCreate = (u["cache_creation_input_tokens"] as? Int) ?? 0
            maxContext = max(maxContext, input + cacheRead + cacheCreate)
            // Dedup output by message id; id-less records each count once (synthetic per-line key).
            // `max` (not last-write) is robust to a message's streamed records arriving out of order
            // or carrying partial-then-final usage — under identical-usage dupes it's the same value.
            let key = (message?["id"] as? String) ?? "•line\(index)"
            outputByMessage[key] = max(outputByMessage[key] ?? 0, (u["output_tokens"] as? Int) ?? 0)
        }
        return maxContext + outputByMessage.values.reduce(0, +)
    }

    /// Compact label: `<1000 -> "N"`, `<10k -> "N.Nk"`, `<1M -> "Nk"`, else `"N.NM"`.
    public static func compact(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 {
            let k = Double(n) / 1_000
            return k < 10 ? String(format: "%.1fk", k) : "\(Int(k.rounded()))k"
        }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}
