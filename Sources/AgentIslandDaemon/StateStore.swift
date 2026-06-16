import Foundation

/// Thread-safe per-session state the daemon maintains from incoming hook events.
public final class StateStore {
    private var sessions: [String: SessionSnapshot] = [:]
    private let lock = NSLock()

    public init() {}

    /// Apply a parsed hook event for a session. Returns true if state changed.
    @discardableResult
    public func apply(eventType: String, sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        var snap = sessions[sessionID] ?? SessionSnapshot(sessionID: sessionID, state: "working")

        switch eventType {
        case EventRouter.subagentStart:
            snap.subActive += 1
        case EventRouter.subagentStop:
            snap.subActive = max(0, snap.subActive - 1)
            snap.subDone += 1
        default:
            guard let status = EventRouter.status(forEventType: eventType) else { return false }
            snap.state = status.stateToken
        }
        sessions[sessionID] = snap
        return true
    }

    public func snapshot() -> DaemonState {
        lock.lock(); defer { lock.unlock() }
        return DaemonState(sessions: sessions.values.sorted { $0.sessionID < $1.sessionID })
    }
}
