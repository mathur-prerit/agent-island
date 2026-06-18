import AppKit
import Foundation
import AgentIslandCore

// MARK: - Pixel Jumper theme (id "jumper")

/// A retro side-scrolling platformer (ALL art drawn procedurally here, ALL sounds synthesized — no
/// third-party assets). Token burn drives a little blocky runner that hops along a scrolling course,
/// collecting coins and leaping obstacle blocks, and UPGRADES through power tiers as tokens add up
/// (tier 0 → 1 → 2, growing + recolouring + sprouting a star). A thin token bar at the base fills
/// toward the next power-up. Waiting freezes the runner mid-course; failed shows a game-over mark;
/// finished a goal flag; idle a paused controller. Lifecycle cues are original 8-bit-style jingles.
struct PixelJumperTheme: IslandTheme {
    let id = "jumper"               // persisted in UserDefaults["islandTheme"] — keep stable
    let displayName = "Pixel Jumper"
    let showsPersonaGlyph = false

    func makeScene() -> ThemeScene { PixelJumperScene() }
    func icon() -> NSImage { IslandIcons.symbol("figure.run", pointSize: 12) }
    func tint(for row: IslandPanel.Row) -> NSColor { stateTint(row) }

    /// Original synthesized cues, bundled under `Themes/PixelJumper/`.
    func sound(for transition: SoundTransition) -> URL? {
        switch transition {
        case .startedWorking:            return Self.clip("started")
        case .enteredWaiting:            return Self.clip("waiting")
        case .enteredFinished(.success): return Self.clip("complete")
        case .enteredFinished(.failed):  return Self.clip("gameover")
        case .enteredFinished(.unknown): return nil
        }
    }

    private static func clip(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "PixelJumper")
            ?? Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Themes/PixelJumper")
            ?? Bundle.module.url(forResource: name, withExtension: "wav")
    }
}

// MARK: - Pixel Jumper scene

/// Shows the wide scrolling platformer banner while working/waiting (its own row), and a small
/// inline SF-Symbol for the static states — mirroring JourneyScene's banner-vs-inline split.
final class PixelJumperScene: ThemeScene {
    private let stage = PlatformerSceneView()
    private let icon = NSImageView()
    private var stageActive = false

    init() {
        stage.isHidden = true
        NSLayoutConstraint.activate([
            stage.widthAnchor.constraint(equalToConstant: 290),
            stage.heightAnchor.constraint(equalToConstant: 26),
        ])
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.isHidden = true
    }

    var view: NSView { stageActive ? stage : icon }
    var prefersOwnRow: Bool { stageActive }

    func apply(_ snapshot: RowSnapshot) {
        switch snapshot.state {
        case .working:
            stage.tokens = snapshot.tokens; stage.paused = false; stageActive = true
        case .waiting:
            stage.tokens = snapshot.tokens; stage.paused = true; stageActive = true
        case .failed:
            setIcon(IslandIcons.symbol("xmark.octagon.fill"), tint: .systemRed)
        case .finished:
            setIcon(IslandIcons.symbol("flag.checkered"), tint: .systemGreen)
        case .idle:
            setIcon(IslandIcons.symbol("gamecontroller"), tint: .secondaryLabelColor)
        }
        stage.isHidden = !stageActive
        icon.isHidden = stageActive
    }

    func tick(_ frame: Int) { stage.frame_ = frame }

    func animates(_ snapshot: RowSnapshot) -> Bool {
        switch snapshot.state {
        case .working, .waiting: return true
        case .idle, .failed, .finished: return false
        }
    }

    private func setIcon(_ image: NSImage, tint: NSColor?) {
        icon.image = image; icon.contentTintColor = tint; stageActive = false
    }
}

// MARK: - Platformer scene view (original procedural art)

/// The scrolling platformer banner. The runner hops in place near the left while the course (ground
/// dashes + coins + obstacle blocks) scrolls past; token count sets the power tier (and the base
/// token bar's fill), the shared ticker's `frame` animates the run/hop/scroll, frozen under Reduce
/// Motion or while `paused` (waiting). All shapes are drawn here — no bitmap assets.
final class PlatformerSceneView: NSView {
    var tokens: Int = 0 { didSet { if tokens != oldValue { needsDisplay = true } } }
    var frame_: Int = 0 { didSet { if frame_ != oldValue { needsDisplay = true } } }
    var paused: Bool = false { didSet { if paused != oldValue { needsDisplay = true } } }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private let groundY: CGFloat = 6        // top of the ground the runner stands on
    private let runnerX: CGFloat = 30       // runner pinned near the left
    private let spacing: CGFloat = 46       // distance between course markers (coins / obstacles)

    // Power tier from tokens — "upgrading with different power" as the burn grows.
    private func tier(_ t: Int) -> Int { t >= 150_000 ? 2 : (t >= 50_000 ? 1 : 0) }
    private func tierColor(_ tier: Int) -> NSColor {
        [NSColor.systemTeal, .systemBlue, .systemPurple][min(tier, 2)]
    }
    // Stable pseudo-random in [0,1) per marker index — varies the course without Math.random.
    private func rand(_ i: Int) -> CGFloat {
        let x = UInt32(truncatingIfNeeded: (i &+ 1) &* 2_654_435_761)
        return CGFloat(x % 1000) / 1000.0
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let moving = !paused && !IslandAnimations.reduceMotion
        let tierNow = tier(tokens)
        let accent = tierColor(tierNow)

        drawGround(w: w, moving: moving)

        // Course markers scroll right→left. Even indices = coins; ~1 in 3 = an obstacle block.
        let scroll = moving ? CGFloat(frame_) * 2.0 : 0
        var screenX = runnerX + 60 - scroll.truncatingRemainder(dividingBy: spacing)
        var idx = Int(scroll / spacing)
        while screenX < w + 12 {
            let isObstacle = (rand(idx) > 0.62)
            if isObstacle { drawObstacle(x: screenX, h: 5 + rand(idx) * 4) }
            else { drawCoin(x: screenX, bob: moving ? sin(Double(frame_) * 0.3 + Double(idx)) * 1.0 : 0) }
            screenX += spacing; idx += 1
        }

        drawRunner(accent: accent, tier: tierNow, moving: moving)
        drawTokenBar(w: w, tier: tierNow, accent: accent)
    }

    private func drawGround(w: CGFloat, moving: Bool) {
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 3, width: w, height: groundY - 3)).fill()
        // Scrolling tread dashes for a sense of running.
        let period: CGFloat = 14
        let off = moving ? (CGFloat(frame_) * 2.0).truncatingRemainder(dividingBy: period) : 0
        NSColor.labelColor.withAlphaComponent(0.26).setFill()
        var x = -off
        while x < w { NSBezierPath(rect: NSRect(x: x, y: 4, width: 7, height: 1.2)).fill(); x += period }
    }

    private func drawCoin(x: CGFloat, bob: Double) {
        let r: CGFloat = 2.6, y = groundY + 7 + CGFloat(bob)
        NSColor.systemYellow.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)); ring.lineWidth = 0.5; ring.stroke()
    }

    private func drawObstacle(x: CGFloat, h: CGFloat) {
        // A brick-ish block on the ground for the runner to clear.
        let rect = NSRect(x: x - 4, y: groundY, width: 8, height: h)
        NSColor.systemBrown.setFill(); NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        NSColor.labelColor.withAlphaComponent(0.30).setStroke()
        let b = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1); b.lineWidth = 0.5; b.stroke()
    }

    /// A small blocky runner: rounded body + head with eyes + alternating legs. Hops on a periodic
    /// parabola; grows + recolours + sprouts a star with the power tier.
    private func drawRunner(accent: NSColor, tier: Int, moving: Bool) {
        let scale = 1.0 + CGFloat(tier) * 0.12
        let bw = 11.0 * scale, bh = 9.0 * scale
        // Hop: a parabola every ~20 frames; flatten under Reduce Motion / paused.
        let cycle = 20, phase = frame_ % cycle
        let jump = (moving && phase < 12) ? sin(Double(phase) / 12.0 * .pi) * 9.0 : 0
        let x = runnerX, y = groundY + CGFloat(jump)

        accent.setFill()
        // Body.
        NSBezierPath(roundedRect: NSRect(x: x - bw/2, y: y, width: bw, height: bh), xRadius: 2, yRadius: 2).fill()
        // Head.
        let hw = bw * 0.9, hh = 6.5 * scale, hy = y + bh - 1
        NSBezierPath(roundedRect: NSRect(x: x - hw/2, y: hy, width: hw, height: hh), xRadius: 2, yRadius: 2).fill()
        // Eyes (knock out so they read on any tint).
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        for dx in [-hw*0.18, hw*0.22] {
            NSBezierPath(ovalIn: NSRect(x: x + dx - 1, y: hy + hh*0.45, width: 1.8, height: 1.8)).fill()
        }
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        // Legs — alternate while running, tuck while jumping.
        accent.setFill()
        let legUp = (moving && (frame_ / 3) % 2 == 0) && jump == 0
        let l1 = NSRect(x: x - bw*0.34, y: y - 2.4, width: 2.4, height: legUp ? 1.2 : 2.6)
        let l2 = NSRect(x: x + bw*0.12, y: y - 2.4, width: 2.4, height: legUp ? 2.6 : 1.2)
        NSBezierPath(rect: l1).fill(); NSBezierPath(rect: l2).fill()
        // Power star (tier 2).
        if tier >= 2 {
            NSColor.systemYellow.setFill()
            drawStar(center: NSPoint(x: x + hw*0.5 + 3, y: hy + hh + 2), r: 3)
        }
    }

    private func drawStar(center: NSPoint, r: CGFloat) {
        let p = NSBezierPath()
        for i in 0..<10 {
            let ang = .pi/2 + Double(i) * .pi/5
            let rad = (i % 2 == 0) ? r : r*0.45
            let pt = NSPoint(x: center.x + CGFloat(cos(ang))*rad, y: center.y + CGFloat(sin(ang))*rad)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close(); p.fill()
    }

    /// A thin token-progress bar along the very base, filling toward the next power tier.
    private func drawTokenBar(w: CGFloat, tier: Int, accent: NSColor) {
        let lower = [0, 50_000, 150_000][min(tier, 2)]
        let upper = [50_000, 150_000, 400_000][min(tier, 2)]
        let frac = max(0, min(1, CGFloat(tokens - lower) / CGFloat(max(1, upper - lower))))
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: 2)).fill()
        accent.withAlphaComponent(0.85).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: w * frac, height: 2)).fill()
    }
}
