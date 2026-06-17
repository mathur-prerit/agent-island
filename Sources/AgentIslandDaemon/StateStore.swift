import Foundation

/// Thread-safe per-session state the daemon maintains from incoming hook events.
public final class StateStore {
    private var sessions: [String: SessionSnapshot] = [:]
    private var lastSeen: [String: Date] = [:]
    private let lock = NSLock()

    /// Sessions idle (no events) longer than this are pruned from the snapshot, matching the
    /// app's polling active-window — so closed/done sessions age off instead of accumulating.
    public static let pruneAfter: TimeInterval = 1800  // 30 min
    /// A session that stopped its turn (waiting) but has been quiet this long reads as idle, not
    /// "waiting on you" — report it as done so only *recently* stopped sessions say "waiting".
    public static let idleWaitingAfter: TimeInterval = 600  // 10 min

    public init() {}

    /// Apply a parsed hook event for a session. `cwd` (from the hook payload) sets the project
    /// label; `at` is the event time (injectable for tests). Returns true if anything changed.
    @discardableResult
    public func apply(eventType: String, sessionID: String, cwd: String? = nil, at: Date = Date()) -> Bool {
        guard !sessionID.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        var snap = sessions[sessionID] ?? SessionSnapshot(sessionID: sessionID, state: "working")
        var changed = false

        if let cwd = cwd, !cwd.isEmpty {
            let name = (cwd as NSString).lastPathComponent
            if !name.isEmpty, snap.label != name { snap.label = name; changed = true }
        }

        switch eventType {
        case EventRouter.subagentStart:
            snap.subActive += 1; changed = true
        case EventRouter.subagentStop:
            snap.subActive = max(0, snap.subActive - 1); snap.subDone += 1; changed = true
        default:
            if let status = EventRouter.status(forEventType: eventType) {
                snap.state = status.stateToken; changed = true
            }
        }

        guard changed else { return false }
        sessions[sessionID] = snap
        lastSeen[sessionID] = at
        return true
    }

    /// The current state, with sessions idle longer than `pruneAfter` removed. `now` is
    /// injectable for tests; the daemon's heartbeat calls this so pruning happens even with
    /// no new events.
    public func snapshot(now: Date = Date()) -> DaemonState {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-StateStore.pruneAfter)
        for (id, seen) in lastSeen where seen < cutoff {
            sessions.removeValue(forKey: id)
            lastSeen.removeValue(forKey: id)
        }
        let idleCutoff = now.addingTimeInterval(-StateStore.idleWaitingAfter)
        let out = sessions.values.map { snap -> SessionSnapshot in
            // A waiting session that's been quiet past the idle threshold reads as done/idle.
            guard snap.state == "waiting" || snap.state == "waiting-permission",
                  let seen = lastSeen[snap.sessionID], seen < idleCutoff else { return snap }
            var s = snap; s.state = "done"; return s
        }
        return DaemonState(sessions: out.sorted { $0.sessionID < $1.sessionID })
    }
}
