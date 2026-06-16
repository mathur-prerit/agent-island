import Foundation

/// Per-state sub-agent tallies for the collapsed "N run · M done" strip label.
public struct SubAgentCounts: Equatable, Sendable {
    public var working: Int
    public var finished: Int
    public init(working: Int = 0, finished: Int = 0) {
        self.working = working
        self.finished = finished
    }
}

/// Rolls a session's own status together with its sub-agents into one displayed status.
public enum Rollup {
    /// Precedence (R16): any developer-block in the hierarchy ⇒ WAITING-FOR-INPUT;
    /// else any working ⇒ WORKING; else FINISHED (FAILED if any failed).
    public static func rollUp(session: AgentStatus, subAgents: [AgentStatus]) -> AgentStatus {
        let all = [session] + subAgents

        for status in all {
            if case .waitingForInput(let reason) = status {
                return .waitingForInput(reason)
            }
        }
        if all.contains(.working) {
            return .working
        }
        let anyFailed = all.contains {
            if case .finished(.failed) = $0 { return true } else { return false }
        }
        return .finished(anyFailed ? .failed : .success)
    }

    /// Count sub-agents by displayed state (waiting counts as "working" for the tally —
    /// it is still an in-flight, not-done sub-agent).
    public static func counts(subAgents: [AgentStatus]) -> SubAgentCounts {
        var c = SubAgentCounts()
        for status in subAgents {
            switch status {
            case .working, .waitingForInput: c.working += 1
            case .finished: c.finished += 1
            }
        }
        return c
    }
}
