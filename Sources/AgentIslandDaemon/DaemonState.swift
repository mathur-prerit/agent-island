import Foundation
import AgentIslandCore

/// A serializable per-session snapshot the daemon writes to `state.json`.
public struct SessionSnapshot: Codable, Equatable {
    public var sessionID: String
    public var state: String     // working | waiting | waiting-permission | done | failed
    public var subActive: Int
    public var subDone: Int
    public var label: String?    // project name (lastPathComponent of the session's cwd), if known
    public var cwd: String?      // full working dir — lets the app find the transcript to sum tokens
    public init(sessionID: String, state: String, subActive: Int = 0, subDone: Int = 0,
                label: String? = nil, cwd: String? = nil) {
        self.sessionID = sessionID
        self.state = state
        self.subActive = subActive
        self.subDone = subDone
        self.label = label
        self.cwd = cwd
    }
}

/// The full state document the daemon publishes and the app reads.
public struct DaemonState: Codable, Equatable {
    public var sessions: [SessionSnapshot]
    public init(sessions: [SessionSnapshot] = []) { self.sessions = sessions }
}

/// Stable string tokens bridging AgentStatus across the daemon↔app file boundary.
public extension AgentStatus {
    var stateToken: String {
        switch self {
        case .working: return "working"
        case .waitingForInput(.permission): return "waiting-permission"
        case .waitingForInput: return "waiting"
        case .finished(.failed): return "failed"
        case .finished: return "done"
        }
    }

    init(stateToken: String) {
        switch stateToken {
        case "working": self = .working
        case "waiting-permission": self = .waitingForInput(.permission)
        case "waiting": self = .waitingForInput(.stoppedTurn)
        case "failed": self = .finished(.failed)
        case "done": self = .finished(.success)
        default: self = .working
        }
    }
}
