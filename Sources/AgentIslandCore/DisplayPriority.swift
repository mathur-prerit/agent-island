import Foundation

/// Island ordering: the most action-demanding states float to the top.
public enum DisplayPriority {
    /// Lower rank = higher in the list.
    /// permission (blocked, needs you) < stopped-turn (awaiting prompt) < working < finished.
    public static func rank(_ status: AgentStatus) -> Int {
        switch status {
        case .waitingForInput(.permission):  return 0
        case .waitingForInput(.stoppedTurn): return 1
        case .working:                       return 2
        case .finished:                      return 3
        }
    }
}
