/// The personas that ship with v1. The pool a session draws from (the user will later
/// curate it). Each keeps the core's frozen color semantics and varies only glyph + copy.
public enum BuiltInPersonas {
    public static let minimal = Persona(
        name: "Minimal",
        working: StateSkin(glyph: "◐", label: "working"),
        waiting: StateSkin(glyph: "●", label: "waiting for you"),
        waitingPermission: StateSkin(glyph: "●", label: "needs permission"),
        finished: StateSkin(glyph: "✓", label: "done"),
        failed: StateSkin(glyph: "✗", label: "failed"))

    public static let pirate = Persona(
        name: "Pirate",
        working: StateSkin(glyph: "⚓", label: "plunderin'"),
        waiting: StateSkin(glyph: "🏴‍☠️", label: "awaitin' yer orders"),
        waitingPermission: StateSkin(glyph: "🗝️", label: "needs yer say-so"),
        finished: StateSkin(glyph: "💰", label: "treasure secured"),
        failed: StateSkin(glyph: "💀", label: "ran aground"))

    public static let astronaut = Persona(
        name: "Astronaut",
        working: StateSkin(glyph: "🛰", label: "in orbit"),
        waiting: StateSkin(glyph: "🧑‍🚀", label: "awaiting mission control"),
        waitingPermission: StateSkin(glyph: "🛑", label: "needs clearance"),
        finished: StateSkin(glyph: "🌕", label: "touchdown"),
        failed: StateSkin(glyph: "☄️", label: "mission aborted"))

    public static let herald = Persona(
        name: "Herald",
        working: StateSkin(glyph: "📜", label: "the work proceeds"),
        waiting: StateSkin(glyph: "🔔", label: "the herald awaits thy word"),
        waitingPermission: StateSkin(glyph: "⚖️", label: "thy judgement is sought"),
        finished: StateSkin(glyph: "🏆", label: "the deed is done"),
        failed: StateSkin(glyph: "⚔️", label: "the quest hath failed"))

    /// The default rotation pool.
    public static let all: [Persona] = [minimal, pirate, astronaut, herald]
}
