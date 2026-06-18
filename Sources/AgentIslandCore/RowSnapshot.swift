import Foundation

// AppKit-free description of a row's status, plus the precedence mapper that turns the App-side
// `Row`'s primitive fields into a single `ThemeStateKey`. Lives in Core so it's self-testable
// (`AgentIslandSelfTest`) and so themes/scenes can speak one canonical state vocabulary instead
// of re-deriving precedence each.

/// The canonical state a theme scene renders. Mirrors the old per-theme `cue()` precedence as one
/// closed key: which visual a row shows is a function of this and (for the road) the token count.
public enum ThemeStateKey: Equatable, Sendable {
    case idle                  // the placeholder "idle" row (no live sessions)
    case working               // spinning — the agent is doing work
    case waiting(WaitReason)   // halted on the developer (.stoppedTurn / .permission)
    case failed                // finished with a failed verdict
    case finished              // done-ok (dimmed) — the checkered-flag / ✓ state
}

/// The minimal, AppKit-free snapshot a scene needs to render a row: its identity, token count
/// (drives the road's world position) and resolved state key.
public struct RowSnapshot: Equatable, Sendable {
    public let id: String
    public let tokens: Int
    public let state: ThemeStateKey
    public init(id: String, tokens: Int, state: ThemeStateKey) {
        self.id = id
        self.tokens = tokens
        self.state = state
    }
}

/// Resolves the row's primitive fields to a single `ThemeStateKey`, in the EXACT precedence the
/// old `cue()` used. Inputs are primitives (the `Row` type is App-side) so this stays in Core.
public enum RowStateMapper {
    /// Precedence (highest first), preserved verbatim from the original theme `cue()`:
    /// idle row → working (spinning) → waiting → failed verdict → finished (dimmed) → idle.
    public static func stateKey(isIdleRow: Bool, spinning: Bool, waitReason: WaitReason?,
                                verdict: Verdict?, dimmed: Bool) -> ThemeStateKey {
        if isIdleRow { return .idle }
        if spinning { return .working }
        if let w = waitReason { return .waiting(w) }
        if verdict == .failed { return .failed }
        if dimmed { return .finished }
        return .idle
    }
}
