import Foundation

/// Decides when a WAITING read auto-closes, and when a silent session goes stale.
public enum AutoClose {
    /// Same-session events that close its WAITING read: `UserPromptSubmit` (the
    /// developer continued) and `SessionEnd` (the session ended).
    public static let closingEventTypes: Set<String> = ["UserPromptSubmit", "SessionEnd"]

    /// Whether an incoming event closes a given waiting session's read. Attribution is
    /// strictly by session id, so input to one session never closes another's WAITING.
    public static func closesWaiting(eventSessionId: String,
                                     eventType: String,
                                     waitingSessionId: String) -> Bool {
        eventSessionId == waitingSessionId && closingEventTypes.contains(eventType)
    }

    /// Staleness backstop: ungraceful exits (closed tab/window, kill) emit no event, and
    /// `/command` / `--resume` re-engagements don't fire `UserPromptSubmit`. A session
    /// whose last event is older than the timeout expires and its strip clears.
    public static func isStale(lastEventElapsed: TimeInterval, timeout: TimeInterval) -> Bool {
        lastEventElapsed >= timeout
    }
}
