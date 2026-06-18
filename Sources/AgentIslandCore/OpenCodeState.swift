import Foundation

/// Pure (no-db) state + token derivation for an OpenCode session, from its parsed messages plus the
/// row's `time_updated` recency. Kept separate from the thin SQLite read (`OpenCodeStore`) so the
/// crux logic is exhaustively self-testable from fixtures, never touching a live db.
///
/// OpenCode has no event/hook mechanism we can use, so state is inferred POLL-style — mirroring the
/// Claude polling path's recency approach (`StateEngine` + the App's idle downgrade):
///   - A turn still streaming (last assistant message has NO `completed` timestamp) ⇒ WORKING.
///   - A turn that finished generating but on a NON-terminal `finish` ("tool-calls") is mid-loop,
///     about to run a tool and continue ⇒ WORKING (the OpenCode analogue of Claude's trailing
///     `tool_use` block). Gated by recency: if it's been quiet past the idle window it's not really
///     looping anymore ⇒ idle/finished.
///   - A turn with a TERMINAL `finish` (anything other than the tool-loop value) + idle ⇒ the agent
///     stopped and is waiting on the developer; quiet past the idle window ⇒ finished/idle.
///   - A bare user message last (no assistant reply yet) ⇒ the agent is processing ⇒ WORKING.
public enum OpenCodeState {
    /// Recency window mirroring `StateEngine.workingRecencyWindow`: a turn whose row was updated this
    /// recently is treated as still live even if it momentarily looks stopped, smoothing the gap
    /// between a tool-call turn and the next message landing.
    public static let workingRecencyWindow: TimeInterval = 12
    /// A stopped/waiting session quiet longer than this reads as finished/idle, not "waiting on you"
    /// — the same downgrade the Claude polling path applies (`ClaudeCodeProvider.waitingIdleWindow`).
    public static let waitingIdleWindow: TimeInterval = 600

    /// The non-terminal `finish` value OpenCode writes mid tool-loop. Seen as `"tool-calls"` in real
    /// data; treated as "still working" exactly like a Claude trailing `tool_use` block.
    public static let toolLoopFinish = "tool-calls"

    /// Derive status from a session's messages (chronological) + the row's `time_updated`.
    /// `lastUpdated` plays the role the transcript mtime plays for Claude.
    public static func deriveStatus(messages: [OpenCodeMessage],
                                    lastUpdated: Date?,
                                    now: Date = Date()) -> AgentStatus {
        // Quiet past the idle window ⇒ the session is stale: no row should pin the island to
        // "working" forever (that defeats the keep-awake sleep assertion and leaves no way to dismiss
        // it). A missing `time_updated` is treated as stale (true), matching the discovery filter's
        // conservative handling. Computed up front so the "no messages" and "user-message-last"
        // branches downgrade the SAME way the assistant branches already do.
        let quietPastIdle = lastUpdated.map { now.timeIntervalSince($0) > waitingIdleWindow } ?? true

        // Walk back to the last conversational (user|assistant) message — same "skip to last
        // meaningful record" discipline the Claude adapter uses.
        guard let last = messages.last(where: { $0.role == "user" || $0.role == "assistant" }) else {
            // A session row with no usable messages yet — spinning up ⇒ working, UNLESS it's gone
            // quiet past the idle window (a stale empty session shouldn't pin "working" forever).
            return quietPastIdle ? .finished(.success) : .working
        }

        // A user message is latest ⇒ the agent is processing it ⇒ working, UNLESS quiet past idle
        // (a stale user-last turn the agent never picked up shouldn't pin "working" forever).
        if last.role == "user" { return quietPastIdle ? .finished(.success) : .working }

        // Assistant message latest.
        let recent = lastUpdated.map { now.timeIntervalSince($0) < workingRecencyWindow } ?? false

        // Still streaming (no completed timestamp) ⇒ working, unless it's gone cold past the idle
        // window (a crashed/abandoned partial turn shouldn't pin the island to "working" forever).
        if last.completedMs == nil {
            return quietPastIdle ? .finished(.success) : .working
        }

        // Completed generating. Mid tool-loop (non-terminal finish) ⇒ still working while recent;
        // once quiet past idle it's no longer looping ⇒ finished/idle.
        if last.finish == toolLoopFinish {
            if quietPastIdle { return .finished(.success) }
            return .working
        }

        // Terminal finish (or no finish recorded): the turn stopped. Recent ⇒ a brief mid-turn lull
        // still reads as working; quiet past idle ⇒ finished/idle; in between ⇒ waiting on developer.
        if recent { return .working }
        if quietPastIdle { return .finished(.success) }
        return .waitingForInput(.stoppedTurn)
    }

    /// The session token figure: the latest assistant message's `tokens.total`. OpenCode's `total`
    /// is already the full request context for that turn (input + cache + output + reasoning — see
    /// the real-data sample in `spike/FINDINGS.md`), so unlike Claude's per-record fan-out we don't
    /// sum: the last assistant turn's total is the current session size. 0 when none is recorded.
    public static func tokens(messages: [OpenCodeMessage]) -> Int {
        for m in messages.reversed() where m.isAssistant {
            if let t = m.tokensTotal { return t }
        }
        return 0
    }
}
