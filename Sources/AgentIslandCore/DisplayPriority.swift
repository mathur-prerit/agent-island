import Foundation

/// Island ordering: the most action-demanding states float to the top.
public enum DisplayPriority {
    /// Lower rank = higher in the list. Surfaces what needs you, then what went wrong, then
    /// live work, then the boring done-success rows:
    /// waiting-for-you (permission, then stopped-turn) < failed < running < finished-success.
    public static func rank(_ status: AgentStatus) -> Int {
        switch status {
        case .waitingForInput(.permission):  return 0
        case .waitingForInput(.stoppedTurn): return 1
        case .finished(.failed):             return 2
        case .working:                       return 3
        case .finished:                      return 4   // .success / .unknown
        }
    }
}
