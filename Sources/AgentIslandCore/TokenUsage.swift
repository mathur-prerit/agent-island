import Foundation

/// Sums token usage from a session transcript's assistant records.
public enum TokenUsage {
    /// "Fresh" tokens = `input_tokens + output_tokens` (cache create/read excluded).
    /// Tolerant of both the top-level `usage` shape and the nested `message.usage` shape.
    public static func freshTokens(lines: [String]) -> Int {
        var total = 0
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let usage = (obj["usage"] as? [String: Any])
                ?? ((obj["message"] as? [String: Any])?["usage"] as? [String: Any])
            guard let u = usage else { continue }
            let input = (u["input_tokens"] as? Int) ?? 0
            let output = (u["output_tokens"] as? Int) ?? 0
            total += input + output
        }
        return total
    }
}
