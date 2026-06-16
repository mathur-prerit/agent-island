import AgentIslandCore

/// Maps a Claude Code hook event to its effect on session state.
public enum EventRouter {
    public static let subagentStart = "SubagentStart"
    public static let subagentStop = "SubagentStop"

    /// The top-level session status implied by a hook event type, or nil for events that
    /// only affect sub-agent tracking. Mirrors the verified model: a `Stop` means the
    /// turn stopped (waiting for you), `PermissionRequest` is an explicit block, and
    /// `SessionEnd` is the only true terminal signal.
    public static func status(forEventType type: String) -> AgentStatus? {
        switch type {
        case "SessionStart", "UserPromptSubmit": return .working
        case "Stop": return .waitingForInput(.stoppedTurn)
        case "PermissionRequest": return .waitingForInput(.permission)
        case "SessionEnd": return .finished(.unknown)
        default: return nil
        }
    }
}
