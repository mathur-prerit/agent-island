import Foundation

/// Outcome of a finished session.
public enum Verdict: Equatable, Sendable {
    case success
    case failed
    case unknown
}

/// Why a session is waiting on the developer.
public enum WaitReason: Equatable, Sendable {
    /// The agent ended its turn on text and is implicitly awaiting the user.
    case stoppedTurn
    /// An open PermissionRequest / Elicitation is blocking (may be sub-agent-caused).
    case permission
}

/// The three displayed states plus the wait/verdict detail.
///
/// Refined model (see `spike/FINDINGS.md`): Claude Code has no hook that separates
/// "finished" from "waiting" — a stopped turn is implicitly WAITING-FOR-INPUT.
/// `finished` is a lifecycle outcome (SessionEnd / quit / staleness), set by the daemon,
/// not derived from a mid-run transcript snapshot.
public enum AgentStatus: Equatable, Sendable {
    case working
    case waitingForInput(WaitReason)
    case finished(Verdict)
}
