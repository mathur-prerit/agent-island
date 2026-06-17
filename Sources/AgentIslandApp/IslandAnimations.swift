import AppKit
import QuartzCore

/// Core Animation builders for the island's **working** cue — the only state that animates.
/// Everything else (waiting / failed / finished / idle) is shown dimmed and static, so the one
/// thing that's actively running is the only thing that draws the eye.
///
/// WORKING = a fast hue-flowing conic ring + a counter-orbiting twinkle dot on the fixed 14x14
/// `cue`, plus a gentle anchor-independent glyph bob + opacity swell.
///
/// AppKit robustness rules baked in (the reason it actually renders):
///  - `NSTextField.textColor` is NOT CALayer-animatable, so nothing here animates text color.
///  - The glyph is an intrinsic-sized NSTextField; Auto Layout resets its backing-layer
///    anchorPoint to (0,0) on every layout pass, and the caller reassigns `glyph.stringValue`
///    each ~3s refresh (forcing a layout). So all continuous glyph motion is anchor-INDEPENDENT
///    (`transform.translation` + `opacity`); no transform.scale/rotation on the glyph.
///  - All ring/orbit geometry lives on the FIXED `cue` host (bounds never change, explicitly
///    anchored sublayers survive relayout). Nothing is sized to the variable row width.
///  - Looping animations use `repeatCount = .infinity` and are installed only on statusKey
///    CHANGE by the caller, so they are not reseated on every refresh.
///  - All motion is gated on Reduce Motion: when it's on, the static ring still installs (the
///    cue isn't blank) but nothing spins, flows, orbits, twinkles, or bobs.
enum IslandAnimations {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Bright six-stop loop (first == last) so a hue cross-fade between consecutive frames is
    /// seamless. Saturated enough to read as energetic at 14pt.
    private static let aurora: [NSColor] = [
        .systemTeal, .systemCyan, .systemBlue, .systemIndigo, .systemPurple, .systemTeal,
    ]

    private static let cueSize: CGFloat = 14

    /// `frames + 1` evenly distributed phase-rotations of `base` (wrapping). Feeding them to a
    /// keyframe animation makes a gradient's hues drift continuously — "flowing light"
    /// independent of any rotation. `base` must start and end on the same color to loop seamlessly.
    private static func phaseRamp(_ base: [NSColor], frames: Int) -> [[CGColor]] {
        let stops = base.count - 1            // distinct stops (last duplicates first)
        guard stops > 0 else { return [base.map(\.cgColor)] }
        var out: [[CGColor]] = []
        out.reserveCapacity(frames + 1)
        for f in 0...frames {
            let shift = Double(f) / Double(frames) * Double(stops)
            var frame: [CGColor] = []
            frame.reserveCapacity(base.count)
            for i in 0..<base.count {
                let pos = (Double(i) + shift).truncatingRemainder(dividingBy: Double(stops))
                let lo = Int(pos) % stops
                let hi = (lo + 1) % stops
                let t = CGFloat(pos - Double(Int(pos)))
                frame.append(lerp(base[lo], base[hi], t).cgColor)
            }
            out.append(frame)
        }
        return out
    }

    private static func lerp(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let ca = a.usingColorSpace(.sRGB) ?? a
        let cb = b.usingColorSpace(.sRGB) ?? b
        return NSColor(srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
                       green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
                       blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
                       alpha: ca.alphaComponent + (cb.alphaComponent - ca.alphaComponent) * t)
    }

    // MARK: Working — rotating, hue-flowing conic ring + counter-orbiting twinkle dot on the cue

    static func installWorkingRing(on host: NSView) {
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        if layer.sublayers?.contains(where: { $0.name == "aurora-ring" }) == true { return }

        let size = cueSize
        let lw: CGFloat = 2.6

        // Conic aurora ring, masked to a donut stroke.
        let ring = CAGradientLayer()
        ring.name = "aurora-ring"
        ring.type = .conic
        ring.frame = CGRect(x: 0, y: 0, width: size, height: size)
        ring.colors = aurora.map(\.cgColor)
        ring.startPoint = CGPoint(x: 0.5, y: 0.5)
        ring.endPoint = CGPoint(x: 0.5, y: 0.0)
        let donut = CAShapeLayer()
        donut.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: lw / 2, dy: lw / 2), transform: nil)
        donut.fillColor = NSColor.clear.cgColor
        donut.strokeColor = NSColor.black.cgColor
        donut.lineWidth = lw
        ring.mask = donut
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.position = CGPoint(x: size / 2, y: size / 2)
        layer.addSublayer(ring)

        // Counter-orbiting accent dot: a container pinned at the cue centre rotates the other
        // way; the dot sits at a fixed radius so it traces a circle just inside the ring.
        let orbit = CALayer()
        orbit.name = "aurora-orbit"
        orbit.frame = CGRect(x: 0, y: 0, width: size, height: size)
        orbit.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        orbit.position = CGPoint(x: size / 2, y: size / 2)
        let dotR: CGFloat = 1.9
        let radius = size / 2 - lw / 2          // ride the centre-line of the stroke
        let dot = CALayer()
        dot.name = "aurora-orbit-dot"
        dot.frame = CGRect(x: size / 2 - dotR, y: size / 2 - dotR + radius,
                           width: dotR * 2, height: dotR * 2)
        dot.cornerRadius = dotR
        dot.backgroundColor = NSColor.white.cgColor
        dot.shadowColor = NSColor.systemCyan.cgColor
        dot.shadowRadius = 2.2
        dot.shadowOpacity = 0.9
        dot.shadowOffset = .zero
        orbit.addSublayer(dot)
        layer.addSublayer(orbit)

        guard !reduceMotion else { return }

        // (1) Ring spin — fast, the primary motion.
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0.0
        spin.toValue = 2.0 * Double.pi
        spin.duration = 1.3
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")

        // (2) Hue flow — stops drift around the wheel at an unrelated period, so light keeps
        //     moving even where the ring is geometrically still.
        let flow = CAKeyframeAnimation(keyPath: "colors")
        flow.values = phaseRamp(aurora, frames: 24)
        flow.duration = 3.4
        flow.calculationMode = .linear
        flow.repeatCount = .infinity
        ring.add(flow, forKey: "hue-flow")

        // (3) Accent dot orbits the OTHER way, slower, so the cue never blurs into one streak.
        let orbitSpin = CABasicAnimation(keyPath: "transform.rotation.z")
        orbitSpin.fromValue = 0.0
        orbitSpin.toValue = -2.0 * Double.pi
        orbitSpin.duration = 2.8
        orbitSpin.repeatCount = .infinity
        orbit.add(orbitSpin, forKey: "orbit")

        // (4) The dot's glow twinkles so the orbit reads even at small size.
        let twinkle = CAKeyframeAnimation(keyPath: "shadowOpacity")
        twinkle.values = [0.4, 1.0, 0.4]
        twinkle.keyTimes = [0, 0.5, 1.0]
        twinkle.duration = 1.15
        twinkle.repeatCount = .infinity
        dot.add(twinkle, forKey: "twinkle")
    }

    static func removeWorkingRing(from host: NSView) {
        host.layer?.sublayers?
            .filter { $0.name == "aurora-ring" || $0.name == "aurora-orbit" }
            .forEach { $0.removeFromSuperlayer() }
    }

    /// Continuous, ANCHOR-INDEPENDENT glyph liveliness for the working state: a springy vertical
    /// bob on `transform.translation.y` (survives the per-refresh layout/anchor reset) paired
    /// with a faint opacity swell. No transform.scale — that would pivot off the reset anchor.
    static func startWorkingGlyph(on view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "work-bob")
        layer.removeAnimation(forKey: "work-swell")
        guard !reduceMotion else { return }

        let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bob.values = [0.0, 2.2, 0.0, -0.9, 0.0]
        bob.keyTimes = [0.0, 0.30, 0.62, 0.82, 1.0]
        bob.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        bob.duration = 1.55
        bob.repeatCount = .infinity
        layer.add(bob, forKey: "work-bob")

        let swell = CABasicAnimation(keyPath: "opacity")
        swell.fromValue = 0.85
        swell.toValue = 1.0
        swell.duration = 1.9      // unrelated period to the bob
        swell.autoreverses = true
        swell.repeatCount = .infinity
        swell.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(swell, forKey: "work-swell")
    }

    static func stopWorkingGlyph(on view: NSView) {
        view.layer?.removeAnimation(forKey: "work-bob")
        view.layer?.removeAnimation(forKey: "work-swell")
    }
}
