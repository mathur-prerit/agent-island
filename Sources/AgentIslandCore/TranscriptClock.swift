import Foundation

/// Time facts derived from a transcript's per-record `timestamp` fields (ISO-8601, e.g.
/// `2026-06-17T16:11:38.253Z`). Used for per-session running time and per-sub-agent durations.
public enum TranscriptClock {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// Parse an ISO-8601 timestamp, tolerating presence/absence of fractional seconds.
    public static func parse(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// When the session started = the first record carrying a parseable `timestamp`. nil if none.
    public static func startedAt(lines: [String]) -> Date? {
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ts = obj["timestamp"] as? String, let d = parse(ts)
            else { continue }
            return d
        }
        return nil
    }

    /// First and last parseable record timestamps — the span of recorded activity.
    public static func span(lines: [String]) -> (first: Date?, last: Date?) {
        var first: Date?, last: Date?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ts = obj["timestamp"] as? String, let d = parse(ts)
            else { continue }
            if first == nil { first = d }
            last = d
        }
        return (first, last)
    }

    /// Compact human label for a duration in seconds: `"43s"`, `"12m"`, `"2h"`, `"3d"`.
    public static func durationLabel(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(Int(s))s" }
        let m = Int(s / 60); if m < 60 { return "\(m)m" }
        let h = m / 60; if h < 24 { return "\(h)h" }
        return "\(h / 24)d"
    }

    /// Compact label for time elapsed from `start` to `now` (default: now).
    public static func elapsedLabel(from start: Date, to now: Date) -> String {
        durationLabel(now.timeIntervalSince(start))
    }
}
