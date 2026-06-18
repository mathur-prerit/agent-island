import Foundation

/// Which agent CLI a session came from. Drives the small per-row badge so a merged island can tell
/// a Claude Code session from an OpenCode one. `claude` is the default/verified provider; others are
/// additive and poll-only. (Codex is a documented SEAM — see `spike/FINDINGS.md` — not implemented.)
public enum SessionProviderKind: String, Equatable, Sendable {
    case claude
    case opencode

    /// A 1-glyph badge for the island/menu rows. Kept tiny + AppKit-free (just text); the App picks
    /// the color. Claude = the original anthropic mark stand-in; OpenCode = its terminal "oc".
    public var badge: String {
        switch self {
        case .claude:   return "C"
        case .opencode: return "OC"
        }
    }
}

/// A provider-agnostic snapshot of one discovered session, in the SHARED status vocabulary the app
/// renders. Every `SessionProvider` maps its own on-disk format into this; the App merges the lists
/// from all enabled providers and builds its rows from these (no provider-specific fields leak up).
///
/// This is intentionally the SUBSET the App needs to build a row in *polling* mode — the same facts
/// `polledSessions()` already computes for Claude (id/label/title/status/tokens/startedAt + the
/// sub-agent digests + step count). The Claude daemon path is unchanged and still richer; this type
/// is the common denominator across poll-only providers.
public struct ProviderSession: Equatable, Sendable {
    public let provider: SessionProviderKind
    public let fullID: String
    public let label: String              // project / dir name
    public let title: String?             // a descriptive conversation title, if the provider has one
    public let status: AgentStatus
    public let tokens: Int
    public let startedAt: Date?
    public let steps: Int
    public let subDigests: [SubagentDigest]
    /// Last-activity time the provider observed (transcript mtime / DB time_updated). The App sorts
    /// equal-priority rows by this (newest first), mirroring the existing Claude polling sort.
    public let lastActivity: Date?

    public init(provider: SessionProviderKind, fullID: String, label: String, title: String?,
                status: AgentStatus, tokens: Int, startedAt: Date?, steps: Int = 0,
                subDigests: [SubagentDigest] = [], lastActivity: Date? = nil) {
        self.provider = provider
        self.fullID = fullID
        self.label = label
        self.title = title
        self.status = status
        self.tokens = tokens
        self.startedAt = startedAt
        self.steps = steps
        self.subDigests = subDigests
        self.lastActivity = lastActivity
    }
}

/// A per-agent session source. Generalizes the three Claude-specific seams the app was built on —
/// discovery (the `~/.claude/projects` scan), record parsing (`TranscriptAdapter`) and state
/// derivation (`StateEngine`) — into one polling entry point that yields the shared `ProviderSession`
/// model. Each provider owns its own discovery + parse + state mapping.
///
/// Scope of the protocol: POLLING only. The Claude event-driven path (hooks → daemon → state.json)
/// stays Claude-specific and lives outside this protocol — `ClaudeCodeProvider` reproduces only the
/// `polledSessions()` behavior. Other providers (OpenCode) are poll-only, which is why one polling
/// method is the whole contract.
public protocol SessionProvider {
    var kind: SessionProviderKind { get }

    /// Discover + parse + derive state for every currently-relevant session, as of `now`. Must be
    /// total: an absent / unreadable / empty source yields `[]`, never a throw or crash (the App
    /// polls this on a timer and merges the result — one provider failing must not take down the
    /// island). `now` is injectable so recency/idle decisions are deterministically testable.
    func poll(now: Date) -> [ProviderSession]
}

public extension SessionProvider {
    func poll() -> [ProviderSession] { poll(now: Date()) }
}

/// The one ordering rule every merged session list uses: action-priority (`DisplayPriority.rank`)
/// ascending, then most-recent activity first. STABLE — items that tie on both keys keep their input
/// order, so when poll-only rows (e.g. OpenCode) are appended to an authoritative list (e.g. the
/// Claude daemon rows, which share a nil `lastActivity`), the authoritative rows preserve their
/// relative order byte-for-byte. Generic over the row type via two projections so both the App's
/// `Session` and `ProviderSession` can be merged through the identical rule (no drift between paths).
public enum SessionMergeOrder {
    public static func ordered<Row>(_ rows: [Row],
                                    status: (Row) -> AgentStatus,
                                    lastActivity: (Row) -> Date?) -> [Row] {
        rows.enumerated()
            .sorted { lhs, rhs in
                let ra = DisplayPriority.rank(status(lhs.element)), rb = DisplayPriority.rank(status(rhs.element))
                if ra != rb { return ra < rb }
                let la = lastActivity(lhs.element) ?? .distantPast, lb = lastActivity(rhs.element) ?? .distantPast
                if la != lb { return la > lb }
                return lhs.offset < rhs.offset   // stable: ties preserve input order
            }
            .map(\.element)
    }
}
