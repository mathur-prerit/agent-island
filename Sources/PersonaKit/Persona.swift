import AgentIslandCore

/// One persona's presentation for a single state: a decorative glyph and the persona's
/// own wording. Color/position/motion stay core-owned and invariant across personas
/// (legibility) — a persona varies only glyph and copy.
public struct StateSkin: Sendable, Equatable {
    public let glyph: String
    public let label: String
    public init(glyph: String, label: String) {
        self.glyph = glyph
        self.label = label
    }
}

/// A randomized-but-legible character a session wears. Skins the three states' glyph +
/// wording; the core owns the color so "done" reads the same green in every persona.
public struct Persona: Sendable, Equatable {
    public let name: String
    public let working: StateSkin
    public let waiting: StateSkin
    public let waitingPermission: StateSkin
    public let finished: StateSkin
    public let failed: StateSkin

    public init(name: String, working: StateSkin, waiting: StateSkin,
                waitingPermission: StateSkin, finished: StateSkin, failed: StateSkin) {
        self.name = name
        self.working = working
        self.waiting = waiting
        self.waitingPermission = waitingPermission
        self.finished = finished
        self.failed = failed
    }

    public func skin(for status: AgentStatus) -> StateSkin {
        switch status {
        case .working: return working
        case .waitingForInput(.permission): return waitingPermission
        case .waitingForInput: return waiting
        case .finished(.failed): return failed
        case .finished: return finished
        }
    }
}
