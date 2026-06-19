import Foundation

// AppKit-free model of a data theme's `theme.json` manifest (schemaVersion 1), plus the pure helpers
// the renderer needs (sprite frame-index math, semver compare, colour-ref syntax). Lives in its own
// target — NOT the App — so `AgentIslandSelfTest` (which links Core/PersonaKit, not AppKit) can cover
// decode + validation. The frozen schema is documented in `Sources/AgentIslandApp/Themes/README.md`.
//
// A data theme is DATA, never code: a sandboxed SwiftPM app can't load downloaded Swift, so a single
// generic interpreter (`ManifestTheme`/`ManifestScene`, App-side) renders any validated manifest. The
// manifest is the security boundary for downloaded themes, so loading is strict and path-safe
// (see `ThemeManifestLoader` + `PersonaKit.PackValidator`).

/// The validated, typed form of a `theme.json`. Built by `ThemeManifestLoader` only after every
/// structural + safety check passes, so holding one means "this manifest is well-formed and safe".
public struct ThemeManifest: Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String                       // equals the folder name; the persisted theme id
    public let displayName: String
    public let minAppVersion: String?           // refuse to load on an older app, if set
    public let showsPersonaGlyph: Bool
    public let palette: [String: String]        // named colour → colour-ref string (e.g. "accent" → "#E52521")
    public let tint: [String: String]           // canonical state id → colour-ref string (row background)
    public let states: [String: StateSpec]      // canonical state id → what to render (+ optional sound)
    public let layout: Layout?
    public let tokenBands: [TokenBand]           // optional usage tiers (empty = no banding); ascending

    public init(schemaVersion: Int, id: String, displayName: String, minAppVersion: String?,
                showsPersonaGlyph: Bool, palette: [String: String], tint: [String: String],
                states: [String: StateSpec], layout: Layout?, tokenBands: [TokenBand] = []) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.minAppVersion = minAppVersion
        self.showsPersonaGlyph = showsPersonaGlyph
        self.palette = palette
        self.tint = tint
        self.states = states
        self.layout = layout
        self.tokenBands = tokenBands
    }
}

/// A token-usage tier. The theme declares an ordered list (ascending `upTo`); the engine derives the
/// CURRENT band from the live token count and swaps in that band's visual where a state supplies one.
/// `upTo` is an exclusive upper bound in tokens; the final band omits `upTo` (a catch-all for "and up").
public struct TokenBand: Equatable, Sendable {
    public let name: String
    public let upTo: Int?      // exclusive upper bound; nil = catch-all (only valid on the last band)
    public init(name: String, upTo: Int?) { self.name = name; self.upTo = upTo }
}

/// What one canonical state renders, plus an optional lifecycle sound. `visual` is the base/default;
/// `visualBands` optionally overrides it per token band (band name → visual). The engine renders
/// `visualBands[currentBand]` when present, else falls back to `visual`.
public struct StateSpec: Equatable, Sendable {
    public let visual: Visual
    public let sound: SoundSpec?
    public let visualBands: [String: Visual]
    public init(visual: Visual, sound: SoundSpec?, visualBands: [String: Visual] = [:]) {
        self.visual = visual; self.sound = sound; self.visualBands = visualBands
    }
}

/// The four visual kinds a state may render. Exactly one kind per state (the loader enforces it).
public enum Visual: Equatable, Sendable {
    /// A static image (`images/foo.png`).
    case image(file: String)
    /// A horizontal sprite sheet sliced into `frameCount` cells of `frameWidth × frameHeight`,
    /// animated at `fps`. The only animating kind.
    case sprite(sheet: String, frameWidth: Int, frameHeight: Int, frameCount: Int, fps: Int)
    /// A monospace string in an optional colour ref.
    case text(string: String, color: String?)
    /// An SF Symbol by name, in an optional tint colour ref.
    case symbol(name: String, tint: String?)
}

/// A lifecycle sound clip for a state.
public struct SoundSpec: Equatable, Sendable {
    public enum Trigger: String, Sendable { case onEnter, loop }
    public let file: String
    public let trigger: Trigger
    public let volume: Double        // clamped 0…1 by the loader
    public init(file: String, trigger: Trigger, volume: Double) {
        self.file = file; self.trigger = trigger; self.volume = volume
    }
}

/// Optional placement/size hints for the indicator.
public struct Layout: Equatable, Sendable {
    public let ownRow: Bool          // wide banner row vs. inline beside the title
    public let size: Size?
    public init(ownRow: Bool, size: Size?) { self.ownRow = ownRow; self.size = size }
    public struct Size: Equatable, Sendable {
        public let width: Double; public let height: Double
        public init(width: Double, height: Double) { self.width = width; self.height = height }
    }
}

// MARK: - Canonical vocabulary (mirrors AgentIslandCore's ThemeStateKey + WaitReason)

/// The canonical state ids a manifest may key. A theme MAY NOT invent new ones — these mirror the
/// host's row state machine exactly. Kept as strings here (not the Core enum) so this target stays
/// dependency-light; the App maps these strings onto `ThemeStateKey` in `ManifestTheme`.
public enum ThemeStateID {
    public static let idle = "idle"
    public static let working = "working"
    public static let waitingPermission = "waitingPermission"
    public static let waitingTurnEnd = "waitingTurnEnd"
    public static let failed = "failed"
    public static let finished = "finished"
    /// All six, for strict key validation.
    public static let all: Set<String> = [idle, working, waitingPermission, waitingTurnEnd, failed, finished]
}

// MARK: - Pure helpers (sprite clock, semver, colour-ref syntax)

/// Maps the host's shared animation ticker onto a sprite's own frame. The ticker fires at a fixed
/// `tickHz` (10 Hz today) and hands each scene a monotonically-increasing `tick`; a sprite wants to
/// advance at its own `fps`. Pure + testable so the slicing math never drifts.
public enum SpriteClock {
    /// The sprite frame index to show at `tick`, given the sheet's `fps` and `frameCount`.
    /// `tickHz` is the host ticker's rate. Clamps degenerate inputs to a stable frame 0.
    public static func frameIndex(tick: Int, fps: Int, frameCount: Int, tickHz: Int = 10) -> Int {
        guard frameCount > 0 else { return 0 }
        guard fps > 0, tickHz > 0 else { return 0 }   // no animation → freeze on the first cell
        let advanced = (tick * fps) / tickHz           // how many sprite-frames have elapsed
        let m = advanced % frameCount
        return m >= 0 ? m : m + frameCount             // tolerate a negative tick defensively
    }
}

/// Maps a live token count onto a theme's declared `tokenBands`. Pure + testable so the band the
/// engine renders never drifts from what validation accepted. Bands are ascending by `upTo`
/// (exclusive); the first band whose bound the count is BELOW wins; the final catch-all band
/// (`upTo == nil`) covers everything above. A count past every finite bound clamps to the last band.
public enum TokenBands {
    /// The band name for `tokens`, or nil when no bands are declared. Negative tokens clamp to the
    /// first band (an unknown/early count reads as the lowest tier).
    public static func bandName(for tokens: Int, bands: [TokenBand]) -> String? {
        guard let first = bands.first else { return nil }
        if tokens < 0 { return first.name }
        for band in bands {
            guard let upTo = band.upTo else { return band.name }   // catch-all
            if tokens < upTo { return band.name }
        }
        return bands.last?.name   // beyond every finite bound → clamp to the highest tier
    }
}

/// Dotted-numeric version compare for `minAppVersion`. Lenient on shape: pads missing components with
/// 0, ignores non-numeric trailers. Pure + testable.
public enum SemVer {
    /// True iff `version` ≥ `minimum` (component-wise). A nil/blank `minimum` is always satisfied.
    public static func isAtLeast(_ version: String, _ minimum: String?) -> Bool {
        guard let minimum = minimum, !minimum.isEmpty else { return true }
        let a = components(version), b = components(minimum)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true   // equal
    }

    /// True iff `version` is STRICTLY greater than `other` (component-wise). The "update available =
    /// latest > installed" half that `isAtLeast` can't express (`isAtLeast` is true on equal). A
    /// nil/blank `other` makes any non-empty `version` "newer" (an unknown baseline can always be
    /// improved on); a nil/blank `version` is never newer.
    public static func isNewer(_ version: String, than other: String?) -> Bool {
        let a = components(version)
        guard !a.isEmpty else { return false }   // a blank/component-less version is never "newer"
        guard let other = other, !other.isEmpty else { return true }   // any version beats an unknown baseline
        let b = components(other)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false   // equal → not strictly newer
    }

    private static func components(_ s: String) -> [Int] {
        s.split(separator: ".").map { part in
            // take the leading integer run ("3rc1" → 3, "" → 0)
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }
}

/// The `system:<name>` colour names a manifest may use — the single source of truth shared by the
/// (AppKit-free) syntax validator here and the App-side `ColorResolver`, so a name that PASSES
/// validation always resolves to a real `NSColor` (no silent fallback at render time). Keep this in
/// lockstep with `ColorResolver.system(_:)`.
public enum ThemeColorNames {
    public static let system: Set<String> = [
        "red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple",
        "pink", "brown", "gray", "grey",
        "label", "secondaryLabel", "tertiaryLabel", "quaternaryLabel",
    ]
}

/// Syntactic validation of a colour reference. The actual `NSColor` resolution is App-side
/// (`ManifestTheme`), but the loader rejects a syntactically-invalid ref up front. Valid forms:
/// `clear` · `#RRGGBB` / `#RRGGBBAA` · `system:<name>` (name must be in `ThemeColorNames.system`) ·
/// a key present in the manifest `palette`.
public enum ColorRefSyntax {
    public static func isValid(_ ref: String, palette: [String: String]) -> Bool {
        if ref == "clear" { return true }
        if ref.hasPrefix("#") { return isHex(ref) }
        // A system colour must name one the resolver actually supports — otherwise it would pass the
        // "strict" loader and then silently render with a fallback colour.
        if ref.hasPrefix("system:") { return ThemeColorNames.system.contains(String(ref.dropFirst("system:".count))) }
        return palette[ref] != nil    // otherwise it must name a palette entry
    }

    /// `#` followed by exactly 6 or 8 hex digits.
    public static func isHex(_ ref: String) -> Bool {
        guard ref.hasPrefix("#") else { return false }
        let body = ref.dropFirst()
        guard body.count == 6 || body.count == 8 else { return false }
        return body.allSatisfy { $0.isHexDigit }
    }
}
