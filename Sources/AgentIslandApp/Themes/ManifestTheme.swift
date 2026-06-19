import AppKit
import AgentIslandCore
import AgentIslandThemes

// The generic interpreter that turns a validated `ThemeManifest` (data) into a live `IslandTheme`
// (a real, swappable theme) — no per-theme Swift. One `ManifestTheme` wraps one theme folder; its
// `ManifestScene` renders the four visual kinds (image / sprite / text / symbol) per row and animates
// sprites off the shared ticker. The manifest is already validated + path-safe (see
// `AgentIslandThemes.ThemeManifestLoader`), so this file only resolves paths/colours and draws.

/// A data theme: a validated manifest + the on-disk folder its asset paths resolve against.
struct ManifestTheme: IslandTheme {
    let manifest: ThemeManifest
    let baseURL: URL          // the theme folder; every asset path is relative to this

    var id: String { manifest.id }
    var displayName: String { manifest.displayName }
    var showsPersonaGlyph: Bool { manifest.showsPersonaGlyph }

    func makeScene() -> ThemeScene { ManifestScene(manifest: manifest, baseURL: baseURL) }

    /// Row background tint: the manifest's per-state colour ref, or `.clear` when unspecified.
    func tint(for row: IslandPanel.Row) -> NSColor {
        let key = ManifestStateMap.id(for: rowStateKey(row))
        guard let ref = manifest.tint[key] else { return .clear }
        return ColorResolver.resolve(ref, palette: manifest.palette) ?? .clear
    }

    /// A lifecycle jingle: map the edge-triggered transition to the entered state, and play that
    /// state's `onEnter` sound (loops are handled by the scene, not lifecycle transitions).
    func sound(for transition: SoundTransition) -> URL? {
        let stateID: String
        switch transition {
        case .startedWorking: stateID = ThemeStateID.working
        case .enteredWaiting(let reason):
            stateID = reason == .permission ? ThemeStateID.waitingPermission : ThemeStateID.waitingTurnEnd
        case .enteredFinished(let verdict):
            // Silent on an unknown verdict, matching DefaultSoundSet / JourneyTheme — only a
            // definitive success or failure plays a clip.
            guard verdict == .success || verdict == .failed else { return nil }
            stateID = verdict == .failed ? ThemeStateID.failed : ThemeStateID.finished
        }
        guard let sound = manifest.states[stateID]?.sound, sound.trigger == .onEnter else { return nil }
        return ThemeAsset.safeURL(base: baseURL, relative: sound.file)
    }

    /// The row's primitive fields → canonical `ThemeStateKey` (shared precedence, in Core).
    private func rowStateKey(_ row: IslandPanel.Row) -> ThemeStateKey {
        RowStateMapper.stateKey(isIdleRow: row.id == "idle", spinning: row.spinning,
                                waitReason: row.waitReason, verdict: row.verdict, dimmed: row.dimmed)
    }
}

/// Maps the Core `ThemeStateKey` onto the manifest's canonical state-id strings (and back is not
/// needed). The manifest splits "waiting" into permission vs. turn-end; the runtime carries that in
/// the `WaitReason` associated value.
enum ManifestStateMap {
    static func id(for key: ThemeStateKey) -> String {
        switch key {
        case .idle: return ThemeStateID.idle
        case .working: return ThemeStateID.working
        case .waiting(.permission): return ThemeStateID.waitingPermission
        case .waiting(.stoppedTurn): return ThemeStateID.waitingTurnEnd
        case .failed: return ThemeStateID.failed
        case .finished: return ThemeStateID.finished
        }
    }
}

// MARK: - Scene

/// Renders one row for a manifest theme. Holds a container with a stacked image view + label; each
/// `apply` shows whichever matches the current state's `visual.kind` and configures it. Sprites slice
/// their sheet once (cached) and step frames on `tick`; everything else is static.
final class ManifestScene: ThemeScene {
    private let manifest: ThemeManifest
    private let baseURL: URL
    private let container = NSView()
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var snapshot = RowSnapshot(id: "", tokens: 0, state: .idle)

    /// Cache: a sliced sprite sheet keyed by its relative path (load + slice once per theme/row).
    private var spriteCache: [String: [NSImage]] = [:]

    init(manifest: ThemeManifest, baseURL: URL) {
        self.manifest = manifest
        self.baseURL = baseURL
        container.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        container.addSubview(imageView)
        container.addSubview(label)

        // Size the indicator from the layout hint (sensible default for an inline glyph). The image
        // view fills the box; the label centers in it.
        let size = manifest.layout?.size
        let w = size.map { CGFloat($0.width) } ?? 28
        let h = size.map { CGFloat($0.height) } ?? 24
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: w),
            container.heightAnchor.constraint(equalToConstant: h),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    var view: NSView { container }
    var prefersOwnRow: Bool { manifest.layout?.ownRow ?? false }

    func apply(_ snapshot: RowSnapshot) {
        self.snapshot = snapshot
        render(frame: 0)
    }

    func tick(_ frame: Int) {
        // Only sprites move; re-rendering a static visual every tick is wasteful, so guard on it.
        guard case .sprite = currentVisual else { return }
        render(frame: frame)
    }

    func animates(_ snapshot: RowSnapshot) -> Bool {
        if case .sprite(_, _, _, let frameCount, _) = visual(for: snapshot.state, tokens: snapshot.tokens) {
            return frameCount > 1
        }
        return false
    }

    /// The visual for the CURRENT snapshot (nil when the manifest omits this state). Token-band aware:
    /// when the state declares `visualBands`, the live token count selects the band and its visual.
    private var currentVisual: Visual? { visual(for: snapshot.state, tokens: snapshot.tokens) }

    /// Resolve the visual for a state at a given token count: a per-band override when the state has
    /// `visualBands` and the current band supplies one, else the state's base `visual`. A theme with no
    /// `tokenBands` (or a state with no `visualBands`) always lands on the base visual — unchanged.
    private func visual(for state: ThemeStateKey, tokens: Int) -> Visual? {
        guard let spec = manifest.states[ManifestStateMap.id(for: state)] else { return nil }
        if !spec.visualBands.isEmpty,
           let band = TokenBands.bandName(for: tokens, bands: manifest.tokenBands),
           let banded = spec.visualBands[band] {
            return banded
        }
        return spec.visual
    }

    private func render(frame: Int) {
        guard let visual = currentVisual else {           // state not in this manifest → blank
            imageView.isHidden = true; label.isHidden = true; return
        }
        switch visual {
        case .image(let file):
            showImage(ThemeAsset.safeURL(base: baseURL, relative: file).flatMap { NSImage(contentsOf: $0) })
            imageView.contentTintColor = nil

        case .sprite(let sheet, let fw, let fh, let frameCount, let fps):
            let frames = slicedFrames(sheet: sheet, frameWidth: fw, frameHeight: fh, frameCount: frameCount)
            let idx = SpriteClock.frameIndex(tick: frame, fps: fps, frameCount: frames.count)
            showImage(frames.isEmpty ? nil : frames[idx])
            imageView.contentTintColor = nil

        case .text(let string, let color):
            label.stringValue = string
            label.textColor = color.flatMap { ColorResolver.resolve($0, palette: manifest.palette) } ?? .labelColor
            imageView.isHidden = true; label.isHidden = false

        case .symbol(let name, let tint):
            let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            showImage(img)
            imageView.contentTintColor = tint.flatMap { ColorResolver.resolve($0, palette: manifest.palette) }
        }
    }

    private func showImage(_ image: NSImage?) {
        imageView.image = image
        imageView.isHidden = false
        label.isHidden = true
    }

    /// Load a sprite sheet and slice it into `frameCount` horizontal cells, cached per sheet path.
    /// Pixel-precise via `CGImage.cropping` (origin top-left, matching a left-to-right strip). A
    /// missing/short sheet degrades gracefully to whatever frames could be cut (possibly none).
    private func slicedFrames(sheet: String, frameWidth: Int, frameHeight: Int, frameCount: Int) -> [NSImage] {
        if let cached = spriteCache[sheet] { return cached }
        var frames: [NSImage] = []
        if let url = ThemeAsset.safeURL(base: baseURL, relative: sheet),
           let image = NSImage(contentsOf: url),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // Frame dims are in PIXELS, measured against the sheet's pixel buffer (cg.width/height) —
            // a sheet must be exported 1×. The loader bounds frameWidth/Count, so this loop is finite;
            // `break` once a cell runs past the sheet edge (a short/mismatched sheet stops cleanly).
            for i in 0..<frameCount {
                let rect = CGRect(x: i * frameWidth, y: 0, width: frameWidth, height: frameHeight)
                guard rect.maxX <= CGFloat(cg.width), rect.maxY <= CGFloat(cg.height) else { break }
                guard let cell = cg.cropping(to: rect) else { continue }
                frames.append(NSImage(cgImage: cell, size: NSSize(width: frameWidth, height: frameHeight)))
            }
        }
        spriteCache[sheet] = frames
        return frames
    }
}

// MARK: - Asset path safety (disk-side)

/// Resolves a manifest's (already string-validated) relative asset path against the theme folder and
/// confirms it stays INSIDE that folder after symlink resolution. The loader's `PackValidator` check
/// is purely string-based and runs before any disk access (rejects `..`, absolute, NUL); this is the
/// disk-side other half: a downloaded theme is delivered as an extracted folder, so a single entry
/// could be a SYMLINK whose target escapes the folder. Returns nil (→ render nothing / no sound) for
/// an escaping or unreadable asset.
enum ThemeAsset {
    static func safeURL(base: URL, relative: String) -> URL? {
        // Resolve BOTH sides the same way so platform symlinks (/tmp→/private/tmp, /var→/private/var)
        // don't cause a spurious mismatch; compare by path components (prefix containment).
        let baseResolved = base.resolvingSymlinksInPath().standardizedFileURL
        let candidate = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        let baseComps = baseResolved.pathComponents
        let candComps = candidate.pathComponents
        guard candComps.count > baseComps.count,
              Array(candComps.prefix(baseComps.count)) == baseComps else { return nil }
        return candidate
    }
}

// MARK: - Colour resolution

/// Resolves a manifest colour-ref string to an `NSColor` (the App-side half of `ColorRefSyntax`,
/// which only validated the syntax). Forms: `clear` · `#RRGGBB` / `#RRGGBBAA` · `system:<name>` ·
/// a `palette` key (resolved one level — palette values are concrete, enforced by the loader).
enum ColorResolver {
    static func resolve(_ ref: String, palette: [String: String]) -> NSColor? {
        if ref == "clear" { return .clear }
        if ref.hasPrefix("#") { return hex(ref) }
        if ref.hasPrefix("system:") { return system(String(ref.dropFirst("system:".count))) }
        if let concrete = palette[ref] { return resolve(concrete, palette: [:]) }   // palette indirection (one level)
        return nil
    }

    private static func hex(_ ref: String) -> NSColor? {
        let body = ref.dropFirst()
        guard body.count == 6 || body.count == 8, let value = UInt64(body, radix: 16) else { return nil }
        let hasAlpha = body.count == 8
        let r, g, b, a: CGFloat
        if hasAlpha {
            r = CGFloat((value >> 24) & 0xFF) / 255; g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255;  a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255; g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255;         a = 1
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// The `NSColor.system*` and semantic label colours a manifest may name (`system:teal` etc.).
    private static func system(_ name: String) -> NSColor? {
        switch name {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "mint": return .systemMint
        case "teal": return .systemTeal
        case "cyan": return .systemCyan
        case "blue": return .systemBlue
        case "indigo": return .systemIndigo
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "brown": return .systemBrown
        case "gray", "grey": return .systemGray
        case "label": return .labelColor
        case "secondaryLabel": return .secondaryLabelColor
        case "tertiaryLabel": return .tertiaryLabelColor
        case "quaternaryLabel": return .quaternaryLabelColor
        default: return nil
        }
    }
}
