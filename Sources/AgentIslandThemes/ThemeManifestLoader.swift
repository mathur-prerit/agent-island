import Foundation
import PersonaKit

// Strict, path-safe loader for a data theme's `theme.json`. A downloaded/bundled manifest is the
// security boundary (the asset paths it names are opened on disk), so loading rejects anything
// out-of-bounds: unknown keys (no smuggling an `exec`/`script` field), unknown state ids, the wrong
// schema version, an app that's too old, a disallowed asset type, or a path that escapes the theme
// folder (Zip-Slip). Path-safety + the image allowlist reuse `PersonaKit.PackValidator`; audio has
// its own allowlist here. Pure (no disk, no AppKit) so `AgentIslandSelfTest` covers it fully.

/// Why a `theme.json` was rejected. Wraps `PackRejection` for the shared path/asset checks and adds
/// the manifest-specific reasons.
public enum ThemeRejection: Error, Equatable, Sendable {
    case invalidJSON                       // not a JSON object at all
    case missingField(String)              // a required key is absent (e.g. "states")
    case wrongType(String)                 // a key is present but the wrong shape
    case unknownField(String)              // a key we don't recognize (strict schema)
    case unsupportedSchemaVersion(Int)     // schemaVersion != 1
    case idFolderMismatch(id: String, folder: String)  // manifest id must equal the folder name
    case unknownState(String)              // a states/tint key the core doesn't own
    case unknownVisualKind(String)         // visual.kind not in image|sprite|text|symbol
    case badColorRef(String)               // a colour ref that isn't hex/palette/system/clear
    case badSoundTrigger(String)           // sound.trigger not onEnter|loop
    case appTooOld(required: String)       // minAppVersion > the running app
    case asset(PackRejection)              // a path/type rejection from PackValidator (image or audio)

    /// Promote a `PackRejection` (path-safety / image allowlist) into a `ThemeRejection`.
    static func from(_ p: PackRejection) -> ThemeRejection { .asset(p) }
}

public enum ThemeManifestLoader {
    /// Audio types a theme may ship. WAV PCM is preferred (instant, decode-free `NSSound`); the rest
    /// are tolerated. Parallels `PackValidator.allowedAssetExtensions` (which is images-only).
    public static let allowedAudioExtensions: Set<String> = ["wav", "aiff", "caf", "m4a"]

    /// Top-level keys a manifest may carry (strict — anything else is rejected).
    static let allowedTopLevelKeys: Set<String> =
        ["schemaVersion", "id", "displayName", "minAppVersion", "showsPersonaGlyph",
         "palette", "tint", "states", "layout"]

    /// Sprite sizing ceilings (untrusted) — generous for real pixel art, far below any overflow/DoS
    /// threshold. A frame cell of 4096² covers any sensible sheet; 1024 frames at 240fps is absurdly
    /// long already, so anything past these is a malformed/hostile manifest.
    static let maxSpriteDimension = 4096
    static let maxFrameCount = 1024
    static let maxFPS = 240

    /// Decode + fully validate a manifest. `folderName` is the theme's directory name (the id must
    /// match it); `appVersion` is the running app's version (for `minAppVersion`). Returns the typed
    /// `ThemeManifest` only when every check passes.
    public static func load(data: Data, folderName: String,
                            appVersion: String) -> Result<ThemeManifest, ThemeRejection> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.invalidJSON)
        }

        // --- Strict top-level keys ---
        for key in root.keys where !allowedTopLevelKeys.contains(key) {
            return .failure(.unknownField(key))
        }

        // --- schemaVersion (required, must be 1) ---
        guard let schemaVersion = strictInt(root["schemaVersion"]) else {
            return .failure(root["schemaVersion"] == nil ? .missingField("schemaVersion")
                                                          : .wrongType("schemaVersion"))
        }
        guard schemaVersion == 1 else { return .failure(.unsupportedSchemaVersion(schemaVersion)) }

        // --- id (required, must equal the folder name) ---
        guard let id = root["id"] as? String else {
            return .failure(root["id"] == nil ? .missingField("id") : .wrongType("id"))
        }
        guard id == folderName else { return .failure(.idFolderMismatch(id: id, folder: folderName)) }

        // --- displayName (required) ---
        guard let displayName = root["displayName"] as? String else {
            return .failure(root["displayName"] == nil ? .missingField("displayName")
                                                        : .wrongType("displayName"))
        }

        // --- minAppVersion (optional; refuse to load on an older app) ---
        var minAppVersion: String?
        if let raw = root["minAppVersion"] {
            guard let v = raw as? String else { return .failure(.wrongType("minAppVersion")) }
            minAppVersion = v
            guard SemVer.isAtLeast(appVersion, v) else { return .failure(.appTooOld(required: v)) }
        }

        // --- showsPersonaGlyph (optional, default false) ---
        var showsPersonaGlyph = false
        if let raw = root["showsPersonaGlyph"] {
            guard let b = strictBool(raw) else { return .failure(.wrongType("showsPersonaGlyph")) }
            showsPersonaGlyph = b
        }

        // --- palette (optional): name → CONCRETE colour ref (no palette-name indirection / cycles) ---
        var palette: [String: String] = [:]
        if let raw = root["palette"] {
            guard let dict = raw as? [String: String] else { return .failure(.wrongType("palette")) }
            for (_, ref) in dict where !ColorRefSyntax.isValid(ref, palette: [:]) {
                return .failure(.badColorRef(ref))
            }
            palette = dict
        }

        // --- tint (optional): canonical state id → colour ref (may name a palette entry) ---
        var tint: [String: String] = [:]
        if let raw = root["tint"] {
            guard let dict = raw as? [String: String] else { return .failure(.wrongType("tint")) }
            for (state, ref) in dict {
                guard ThemeStateID.all.contains(state) else { return .failure(.unknownState(state)) }
                guard ColorRefSyntax.isValid(ref, palette: palette) else { return .failure(.badColorRef(ref)) }
            }
            tint = dict
        }

        // --- states (required) ---
        guard let statesRaw = root["states"] as? [String: Any] else {
            return .failure(root["states"] == nil ? .missingField("states") : .wrongType("states"))
        }
        var states: [String: StateSpec] = [:]
        for (state, specRaw) in statesRaw {
            guard ThemeStateID.all.contains(state) else { return .failure(.unknownState(state)) }
            guard let specDict = specRaw as? [String: Any] else { return .failure(.wrongType("states.\(state)")) }
            for key in specDict.keys where key != "visual" && key != "sound" {
                return .failure(.unknownField("states.\(state).\(key)"))
            }
            switch parseStateSpec(specDict, state: state, palette: palette) {
            case .failure(let r): return .failure(r)
            case .success(let spec): states[state] = spec
            }
        }

        // --- layout (optional) ---
        var layout: Layout?
        if let raw = root["layout"] {
            switch parseLayout(raw) {
            case .failure(let r): return .failure(r)
            case .success(let l): layout = l
            }
        }

        return .success(ThemeManifest(
            schemaVersion: schemaVersion, id: id, displayName: displayName,
            minAppVersion: minAppVersion, showsPersonaGlyph: showsPersonaGlyph,
            palette: palette, tint: tint, states: states, layout: layout))
    }

    // MARK: - State / visual / sound

    private static func parseStateSpec(_ dict: [String: Any], state: String,
                                       palette: [String: String]) -> Result<StateSpec, ThemeRejection> {
        guard let visualRaw = dict["visual"] as? [String: Any] else {
            return .failure(dict["visual"] == nil ? .missingField("states.\(state).visual")
                                                   : .wrongType("states.\(state).visual"))
        }
        let visualResult = parseVisual(visualRaw, state: state, palette: palette)
        guard case .success(let visual) = visualResult else {
            if case .failure(let r) = visualResult { return .failure(r) }
            return .failure(.wrongType("states.\(state).visual"))
        }

        var sound: SoundSpec?
        if let soundRaw = dict["sound"] {
            switch parseSound(soundRaw, state: state) {
            case .failure(let r): return .failure(r)
            case .success(let s): sound = s
            }
        }
        return .success(StateSpec(visual: visual, sound: sound))
    }

    /// Allowed keys per `visual.kind` (strict — an unknown key inside a visual is rejected).
    private static let visualKeys: [String: Set<String>] = [
        "image":  ["kind", "file"],
        "sprite": ["kind", "sheet", "frameWidth", "frameHeight", "frameCount", "fps"],
        "text":   ["kind", "string", "color"],
        "symbol": ["kind", "name", "tint"],
    ]

    private static func parseVisual(_ d: [String: Any], state: String,
                                    palette: [String: String]) -> Result<Visual, ThemeRejection> {
        guard let kind = d["kind"] as? String else {
            return .failure(d["kind"] == nil ? .missingField("states.\(state).visual.kind")
                                              : .wrongType("states.\(state).visual.kind"))
        }
        guard let allowed = visualKeys[kind] else { return .failure(.unknownVisualKind(kind)) }
        for key in d.keys where !allowed.contains(key) {
            return .failure(.unknownField("states.\(state).visual.\(key)"))
        }

        switch kind {
        case "image":
            guard let file = d["file"] as? String else {
                return .failure(field("states.\(state).visual.file", in: d))
            }
            if let r = PackValidator.validateAsset(file) { return .failure(.from(r)) }
            return .success(.image(file: file))

        case "sprite":
            guard let sheet = d["sheet"] as? String else {
                return .failure(field("states.\(state).visual.sheet", in: d))
            }
            if let r = PackValidator.validateAsset(sheet) { return .failure(.from(r)) }
            guard let fw = strictInt(d["frameWidth"]) else { return .failure(field("states.\(state).visual.frameWidth", in: d)) }
            guard let fh = strictInt(d["frameHeight"]) else { return .failure(field("states.\(state).visual.frameHeight", in: d)) }
            guard let fc = strictInt(d["frameCount"]) else { return .failure(field("states.\(state).visual.frameCount", in: d)) }
            guard let fps = strictInt(d["fps"]) else { return .failure(field("states.\(state).visual.fps", in: d)) }
            guard fw > 0, fh > 0, fc > 0, fps > 0 else {
                return .failure(.wrongType("states.\(state).visual (sprite dims must be > 0)"))
            }
            // Upper bounds: these untrusted values drive `i * frameWidth` (trapping `*`) and a slicing
            // loop in `ManifestScene`. Without a ceiling, a downloaded manifest with a near-`Int.max`
            // dimension would crash on overflow, and a huge `frameCount` would hang the slicer (DoS).
            guard fw <= maxSpriteDimension, fh <= maxSpriteDimension,
                  fc <= maxFrameCount, fps <= maxFPS else {
                return .failure(.wrongType("states.\(state).visual (sprite dims out of range)"))
            }
            return .success(.sprite(sheet: sheet, frameWidth: fw, frameHeight: fh, frameCount: fc, fps: fps))

        case "text":
            guard let string = d["string"] as? String else {
                return .failure(field("states.\(state).visual.string", in: d))
            }
            var color: String?
            if let raw = d["color"] {
                guard let c = raw as? String else { return .failure(.wrongType("states.\(state).visual.color")) }
                guard ColorRefSyntax.isValid(c, palette: palette) else { return .failure(.badColorRef(c)) }
                color = c
            }
            return .success(.text(string: string, color: color))

        case "symbol":
            guard let name = d["name"] as? String else {
                return .failure(field("states.\(state).visual.name", in: d))
            }
            var tint: String?
            if let raw = d["tint"] {
                guard let t = raw as? String else { return .failure(.wrongType("states.\(state).visual.tint")) }
                guard ColorRefSyntax.isValid(t, palette: palette) else { return .failure(.badColorRef(t)) }
                tint = t
            }
            return .success(.symbol(name: name, tint: tint))

        default:
            return .failure(.unknownVisualKind(kind))   // unreachable (visualKeys gate above)
        }
    }

    private static func parseSound(_ raw: Any, state: String) -> Result<SoundSpec, ThemeRejection> {
        guard let d = raw as? [String: Any] else { return .failure(.wrongType("states.\(state).sound")) }
        for key in d.keys where key != "file" && key != "trigger" && key != "volume" {
            return .failure(.unknownField("states.\(state).sound.\(key)"))
        }
        guard let file = d["file"] as? String else {
            return .failure(field("states.\(state).sound.file", in: d))
        }
        // Audio path safety reuses PackValidator's path check; the type allowlist is audio-specific.
        if let r = PackValidator.validateAssetPath(file) { return .failure(.from(r)) }
        let ext = (file as NSString).pathExtension.lowercased()
        guard allowedAudioExtensions.contains(ext) else { return .failure(.from(.disallowedAsset(file))) }

        var trigger = SoundSpec.Trigger.onEnter
        if let raw = d["trigger"] {
            guard let s = raw as? String, let t = SoundSpec.Trigger(rawValue: s) else {
                return .failure(.badSoundTrigger((d["trigger"] as? String) ?? "<non-string>"))
            }
            trigger = t
        }
        var volume = 1.0
        if let raw = d["volume"] {
            guard let v = raw as? Double ?? (raw as? Int).map(Double.init) else {
                return .failure(.wrongType("states.\(state).sound.volume"))
            }
            volume = min(1.0, max(0.0, v))   // clamp 0…1
        }
        return .success(SoundSpec(file: file, trigger: trigger, volume: volume))
    }

    private static func parseLayout(_ raw: Any) -> Result<Layout, ThemeRejection> {
        guard let d = raw as? [String: Any] else { return .failure(.wrongType("layout")) }
        for key in d.keys where key != "ownRow" && key != "size" {
            return .failure(.unknownField("layout.\(key)"))
        }
        var ownRow = false
        if let raw = d["ownRow"] {
            guard let b = strictBool(raw) else { return .failure(.wrongType("layout.ownRow")) }
            ownRow = b
        }
        var size: Layout.Size?
        if let sizeRaw = d["size"] {
            guard let s = sizeRaw as? [String: Any] else { return .failure(.wrongType("layout.size")) }
            for key in s.keys where key != "width" && key != "height" {
                return .failure(.unknownField("layout.size.\(key)"))
            }
            guard let w = number(s["width"]), let h = number(s["height"]) else {
                return .failure(.wrongType("layout.size (width/height required numbers)"))
            }
            size = Layout.Size(width: w, height: h)
        }
        return .success(Layout(ownRow: ownRow, size: size))
    }

    // MARK: - Tiny helpers

    /// Missing vs. wrong-type for a required field, given the surrounding dict. The last dotted
    /// segment of `path` is the dict key (NOT `NSString.lastPathComponent`, which splits on `/` and
    /// would treat the whole dotted path as one key — making a present-but-wrong-type field misreport
    /// as missing).
    private static func field(_ path: String, in d: [String: Any]) -> ThemeRejection {
        let key = path.split(separator: ".").last.map(String.init) ?? path
        return d[key] == nil ? .missingField(path) : .wrongType(path)
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    // JSONSerialization bridges JSON scalars to NSNumber, and an NSNumber backed by a JSON BOOL casts
    // cleanly to Int (`true`→1) while a JSON int 0/1 casts cleanly to Bool — so a naive `as? Int` /
    // `as? Bool` silently coerces the wrong JSON type into a "strict" field. These discriminate by the
    // CFBoolean type id: an Int field refuses a JSON bool, a Bool field refuses a JSON number. (`x is
    // Bool` can't be used — a genuine JSON `1` also reports `is Bool` on this toolchain.)

    /// An `Int` only when `any` is a JSON number (not a JSON bool); nil otherwise.
    private static func strictInt(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }

    /// A `Bool` only when `any` is a genuine JSON bool (not a JSON number); nil otherwise.
    private static func strictBool(_ any: Any?) -> Bool? {
        guard let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
}
