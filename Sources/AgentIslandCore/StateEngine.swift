import Foundation

/// Derives a single session's status from its transcript records.
public enum StateEngine {
    /// A stopped (text-tail) turn whose transcript was touched within this window is treated as
    /// still WORKING, not waiting. Claude Code writes one record per content block, so a continuing
    /// turn's tail sits on an `assistant` text preamble for seconds before the next `tool_use` lands
    /// — without this, a busy agent flickers to "waiting" during that gap. Sized to cover the common
    /// mid-turn gap (≈p90) while still surfacing a genuine wait promptly.
    public static let workingRecencyWindow: TimeInterval = 12

    /// Derive status from transcript records plus whether a developer-blocking
    /// permission/elicitation is currently open.
    ///
    /// See `spike/FINDINGS.md`: a trailing assistant `tool_use` block means the agent
    /// is mid-turn (WORKING); a stopped assistant turn is implicitly WAITING-FOR-INPUT.
    /// FINISHED is a lifecycle outcome, set elsewhere — not derived here.
    ///
    /// `lastActivity` (the transcript's mtime, when the caller has it) disambiguates a text-tail:
    /// freshly touched ⇒ a mid-turn preamble ⇒ WORKING; quiet past `workingRecencyWindow` ⇒ the
    /// turn truly stopped ⇒ WAITING. Omitting it preserves the original (recency-blind) behavior.
    public static func deriveStatus(records: [TranscriptRecord],
                                    openPermission: Bool,
                                    lastActivity: Date? = nil,
                                    now: Date = Date()) -> AgentStatus {
        if openPermission { return .waitingForInput(.permission) }

        guard let last = TranscriptAdapter.lastConversational(records) else {
            // No conversation yet — treat as spinning up.
            return .working
        }

        switch last.type {
        case "user":
            // The user's record is latest: the agent is processing it.
            return .working
        case "assistant":
            // A trailing tool_use block ⇒ mid-turn ⇒ WORKING.
            if last.assistantBlockKinds.last == "tool_use" {
                return .working
            }
            // Assistant ended on text. If the transcript was just touched, this is a continuing
            // turn's text preamble before the next tool call ⇒ still WORKING.
            if let lastActivity = lastActivity,
               now.timeIntervalSince(lastActivity) < workingRecencyWindow {
                return .working
            }
            // Otherwise the turn has truly stopped ⇒ implicitly waiting for the developer.
            return .waitingForInput(.stoppedTurn)
        default:
            return .working
        }
    }
}
