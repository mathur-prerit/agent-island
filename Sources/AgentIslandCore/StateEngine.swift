import Foundation

/// Derives a single session's status from its transcript records.
public enum StateEngine {
    /// Derive status from transcript records plus whether a developer-blocking
    /// permission/elicitation is currently open.
    ///
    /// See `spike/FINDINGS.md`: a trailing assistant `tool_use` block means the agent
    /// is mid-turn (WORKING); a stopped assistant turn is implicitly WAITING-FOR-INPUT.
    /// FINISHED is a lifecycle outcome, set elsewhere — not derived here.
    public static func deriveStatus(records: [TranscriptRecord],
                                    openPermission: Bool) -> AgentStatus {
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
            // Assistant ended on text ⇒ implicitly waiting for the developer.
            return .waitingForInput(.stoppedTurn)
        default:
            return .working
        }
    }
}
