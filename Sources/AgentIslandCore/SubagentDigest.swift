import Foundation

/// A glanceable summary of one sub-agent, derived from its `subagents/agent-*.jsonl` transcript:
/// a descriptive task name, derived status, token spend, and how long it ran. The `slug` field in
/// those transcripts is shared across a session's sub-agents (useless as a name), so the name comes
/// from the sub-agent's first user prompt — the task it was dispatched with.
public struct SubagentDigest: Equatable, Sendable {
    public let name: String
    public let status: AgentStatus
    public let tokens: Int
    public let durationSeconds: Double?   // last − first record timestamp; nil if untimed

    public init(name: String, status: AgentStatus, tokens: Int, durationSeconds: Double?) {
        self.name = name
        self.status = status
        self.tokens = tokens
        self.durationSeconds = durationSeconds
    }

    /// Parse one sub-agent transcript into a digest. `lastActivity` (the transcript's mtime, when the
    /// caller has it) lets a mid-turn text-tail read as WORKING rather than waiting — same recency
    /// disambiguation the top-level session status uses, so a busy sub-agent doesn't roll its parent
    /// up to "waiting" (see `Rollup`).
    public static func fromTranscript(lines: [String], lastActivity: Date? = nil) -> SubagentDigest {
        let records = TranscriptAdapter.parse(lines: lines)
        let status = StateEngine.deriveStatus(records: records, openPermission: false,
                                              lastActivity: lastActivity)
        let tokens = TokenUsage.freshTokens(lines: lines)
        let name = TranscriptAdapter.firstUserText(lines: lines)
            .map { TaskLineSanitizer.sanitize($0, maxLength: 38) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "sub-agent"
        let (first, last) = TranscriptClock.span(lines: lines)
        let duration = (first.flatMap { f in last.map { $0.timeIntervalSince(f) } })
        return SubagentDigest(name: name, status: status, tokens: tokens, durationSeconds: duration)
    }
}
