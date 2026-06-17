import AppKit
import QuartzCore

/// Core Animation builders for island state cues — the FINAL "layered-kinetic" motion language.
///
/// Design intent: noticeably livelier than a single spin/pulse, but still a peripheral,
/// quiet-by-default widget. Every state has 2+ continuous, unrelated-period motions so the
/// island always feels alive without strobing. WORKING is the headline (a fast hue-flowing
/// conic ring + a counter-orbiting twinkle dot on the cue, plus a gentle glyph bob).
///
/// Every motion is gated on Reduce Motion: when it's on, static colors/shapes still install
/// (the cue is never blank) but no loops, bobs, orbits, or pops run.
///
/// AppKit robustness rules baked into this file (the reason it actually renders):
///  - `NSTextField.textColor` is NOT CALayer-animatable, so NOTHING here animates text color.
///  - The glyph is an intrinsic-sized NSTextField. Auto Layout RESETS its backing-layer
///    anchorPoint to (0,0) on every layout pass, and the caller assigns `glyph.stringValue`
///    on every ~3s refresh (forcing a layout pass) BEFORE re-installing animations. Therefore
///    a persistent `transform.scale`/`transform.rotation` on the glyph would pivot off the
///    bottom-left corner and visibly jump each refresh. So all CONTINUOUS glyph motion here is
///    strictly anchor-INDEPENDENT: `transform.translation` (bob/drift) and `opacity` only.
///    The only glyph transform.scale is the ONE-SHOT success pop in `celebrate`, which
///    re-centres the anchor immediately before firing and is over (0.6s) long before the next
///    refresh — so the layout-driven anchor reset can never corrupt it mid-flight.
///  - All ring / orbit / idle / alert / shockwave geometry lives on the FIXED 14x14 `cue`
///    host, whose bounds never change and whose explicitly-anchored sublayers survive relayout.
///    Nothing is ever sized to the variable row WIDTH, so SessionRowView needs no layout()
///    override.
///  - Looping animations use `repeatCount = .infinity` and are installed only on statusKey
///    CHANGE by the caller, so they are not reseated on every refresh.
enum IslandAnimations {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Palettes

    /// Bright six-stop loop (first == last) so a hue cross-fade between consecutive frames
    /// is seamless. Saturated enough to read as energetic at 14pt.
    private static let aurora: [NSColor] = [
        .systemTeal, .systemCyan, .systemBlue, .systemIndigo, .systemPurple, .systemTeal,
    ]
    private static let idleHues: [NSColor] = [
        .systemTeal, .systemBlue, .systemIndigo, .systemPurple, .systemTeal,
    ]

    private static let cueSize: CGFloat = 14

    // MARK: Helpers

    /// Produce `frames + 1` evenly distributed phase-rotations of `base` (wrapping). Each entry
    /// is a full `colors` array; feeding them to a keyframe animation makes the gradient's hues
    /// drift continuously around the layer — "flowing light" independent of any rotation.
    /// `base` must start and end on the same color so the loop is seamless.
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

    /// Re-centre a layer's anchor to its middle WITHOUT visually shifting it (compensates
    /// position). Used ONLY for the one-shot success pop on the glyph — never for a persistent
    /// glyph loop, because Auto Layout resets the anchor on the next layout pass.
    private static func centerAnchor(_ layer: CALayer) {
        let b = layer.bounds
        let old = layer.anchorPoint
        let new = CGPoint(x: 0.5, y: 0.5)
        guard old != new else { return }
        if b.width > 0, b.height > 0 {
            layer.position = CGPoint(x: layer.position.x + (new.x - old.x) * b.width,
                                     y: layer.position.y + (new.y - old.y) * b.height)
        }
        layer.anchorPoint = new
    }

    // MARK: ───────────────────────── Working ─────────────────────────
    // Cue (fixed 14x14, all robust sublayers): fast conic ring that BOTH spins and flows its
    // hues, plus a counter-orbiting accent dot that twinkles. Glyph: anchor-independent bob +
    // opacity swell. Four simultaneous unrelated-period motions; nothing strobes.

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

        // (2) Hue flow — the stops drift around the wheel at an unrelated period, so light
        //     keeps moving even where the ring is geometrically still. Adds shimmer/depth.
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

    /// Continuous, ANCHOR-INDEPENDENT glyph liveliness for the working state: a springy
    /// vertical bob on `transform.translation.y` (survives the per-refresh layout/anchor reset)
    /// paired with a faint opacity swell. No transform.scale here — that would pivot wrong.
    static func startWorkingGlyph(on view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "work-bob")
        layer.removeAnimation(forKey: "work-swell")
        guard !reduceMotion else { return }

        let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
        // Up, settle, tiny overshoot, settle — a gentle living bob (positive = up; view is
        // not flipped). Anchor-independent: a relayout can only ever snap to the rest pose.
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

    // MARK: ───────────────────────── Waiting ─────────────────────────
    // Glyph motion is anchor-INDEPENDENT (opacity + translation). Urgent permission ALSO
    // installs an amber alert ring on the CUE (a robust sublayer) instead of a broken glyph
    // scale, so "needs you now" reads strongly without the anchor-jump hazard.

    static func startPulse(on view: NSView, urgent: Bool, cue: NSView? = nil) {
        view.wantsLayer = true
        guard let layer = view.layer else {
            if urgent, let cue { installAlertRing(on: cue) }
            return
        }

        if urgent, let cue { installAlertRing(on: cue) }
        guard !reduceMotion else { return }

        // Opacity breathe — present in both cases; faster/deeper when urgent.
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1.0
        opacity.toValue = urgent ? 0.3 : 0.5
        opacity.duration = urgent ? 0.5 : 0.85
        opacity.autoreverses = true
        opacity.repeatCount = .infinity
        opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(opacity, forKey: "pulse")

        // A gentle vertical drift so waiting is livelier than a bare fade. Anchor-independent,
        // so it survives the per-refresh layout reset. Urgent drifts faster + a touch more.
        let drift = CABasicAnimation(keyPath: "transform.translation.y")
        drift.fromValue = urgent ? 1.6 : 1.1
        drift.toValue = urgent ? -1.6 : -1.1
        drift.duration = urgent ? 0.7 : 1.6   // offset period from the opacity breathe
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(drift, forKey: "pulse-drift")
    }

    static func stopPulse(on view: NSView, cue: NSView? = nil) {
        view.layer?.removeAnimation(forKey: "pulse")
        view.layer?.removeAnimation(forKey: "pulse-drift")
        if let cue { removeAlertRing(from: cue) }
    }

    /// Amber ring on the cue that expands and fades on a loop — the urgent permission tell.
    /// Lives on the fixed cue, explicitly anchored at its centre, so it is robust.
    private static func installAlertRing(on host: NSView) {
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        if layer.sublayers?.contains(where: { $0.name == "alert-ring" }) == true { return }

        let size = cueSize
        let ring = CAShapeLayer()
        ring.name = "alert-ring"
        ring.frame = CGRect(x: 0, y: 0, width: size, height: size)
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.position = CGPoint(x: size / 2, y: size / 2)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor.systemOrange.cgColor
        ring.lineWidth = 2.0
        layer.addSublayer(ring)

        guard !reduceMotion else { return }

        let expand = CABasicAnimation(keyPath: "transform.scale")
        expand.fromValue = 0.62
        expand.toValue = 1.0
        expand.duration = 0.75
        expand.autoreverses = true
        expand.repeatCount = .infinity
        expand.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(expand, forKey: "alert-expand")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.3
        fade.duration = 0.75
        fade.autoreverses = true
        fade.repeatCount = .infinity
        ring.add(fade, forKey: "alert-fade")
    }

    private static func removeAlertRing(from host: NSView) {
        host.layer?.sublayers?.filter { $0.name == "alert-ring" }.forEach { $0.removeFromSuperlayer() }
    }

    // MARK: ──────────────────────── Finished ────────────────────────
    // One-shot. Success: a centred scale pop (one-shot, so the anchor reset can't corrupt it)
    // + green glow + a green shockwave bursting out of the cue. Failed: anchor-independent
    // position.x shake + red glow + red shockwave.

    static func celebrate(_ view: NSView, success: Bool, cue: NSView? = nil) {
        view.wantsLayer = true
        guard let layer = view.layer, !reduceMotion else { return }
        let color = (success ? NSColor.systemGreen : NSColor.systemRed).cgColor

        if success {
            centerAnchor(layer)   // one-shot only; finished within 0.6s, before the next refresh
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [1.0, 1.32, 0.95, 1.0]
            pop.keyTimes = [0, 0.4, 0.72, 1.0]
            pop.duration = 0.6
            pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(pop, forKey: "celebrate-motion")
        } else {
            // Anchor-independent shake — no centring needed.
            let x = layer.position.x
            let shake = CAKeyframeAnimation(keyPath: "position.x")
            shake.values = [x, x - 5, x + 5, x - 3, x + 3, x]
            shake.keyTimes = [0, 0.16, 0.36, 0.58, 0.8, 1.0]
            shake.duration = 0.55
            layer.add(shake, forKey: "celebrate-motion")
        }

        // Coloured glow on the glyph.
        layer.shadowColor = color
        layer.shadowRadius = 8
        layer.shadowOffset = .zero
        layer.shadowOpacity = 0
        let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glow.values = [0.0, 0.9, 0.0]
        glow.keyTimes = [0, 0.4, 1.0]
        glow.duration = 0.7
        layer.add(glow, forKey: "celebrate-glow")

        // One-shot shockwave ring bursting out of the cue, in the verdict colour.
        guard let cue else { return }
        cue.wantsLayer = true
        guard let cl = cue.layer else { return }
        let size = cueSize
        let wave = CAShapeLayer()
        wave.name = "celebrate-wave"
        wave.frame = CGRect(x: 0, y: 0, width: size, height: size)
        wave.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        wave.position = CGPoint(x: size / 2, y: size / 2)
        wave.path = CGPath(ellipseIn: wave.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        wave.fillColor = NSColor.clear.cgColor
        wave.strokeColor = color
        wave.lineWidth = 2.2
        cl.addSublayer(wave)

        let burst = CABasicAnimation(keyPath: "transform.scale")
        burst.fromValue = 0.3
        burst.toValue = 1.5
        burst.duration = 0.55
        burst.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wave.add(burst, forKey: "wave-burst")

        let waveFade = CABasicAnimation(keyPath: "opacity")
        waveFade.fromValue = 0.9
        waveFade.toValue = 0.0
        waveFade.duration = 0.55
        wave.add(waveFade, forKey: "wave-fade")

        // Self-remove the one-shot wave after it plays. [weak wave] = no retain cycle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak wave] in
            wave?.removeFromSuperlayer()
        }
    }

    // MARK: ─────────────────────────── Idle ──────────────────────────
    // Cue (fixed): a flowing-light gradient orb (hue flow + lighting drift + sublayer
    // scale-breathe) plus a soft expanding "sonar" halo. Three+ quiet motions at different
    // periods — clearly alive, but unhurried and recessive.

    static func installIdleDot(on host: NSView) {
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        if layer.sublayers?.contains(where: { $0.name == "idle-dot" }) == true { return }

        let center = CGPoint(x: cueSize / 2, y: cueSize / 2)

        // Halo ring behind the orb — a soft sonar bloom.
        let halo = CALayer()
        halo.name = "idle-halo"
        let haloSize: CGFloat = 9
        halo.bounds = CGRect(x: 0, y: 0, width: haloSize, height: haloSize)
        halo.cornerRadius = haloSize / 2
        halo.borderWidth = 1.0
        halo.borderColor = idleHues.first?.cgColor
        halo.backgroundColor = NSColor.clear.cgColor
        halo.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        halo.position = center
        layer.addSublayer(halo)

        // The flowing-light gradient orb.
        let size: CGFloat = 10
        let dot = CAGradientLayer()
        dot.name = "idle-dot"
        dot.type = .axial
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = size / 2
        dot.masksToBounds = true
        dot.startPoint = CGPoint(x: 0, y: 0)
        dot.endPoint = CGPoint(x: 1, y: 1)
        dot.colors = phaseRamp(idleHues, frames: 1).first   // seed with a real 5-stop frame
        dot.locations = [0.0, 0.30, 0.55, 0.80, 1.0]
        dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        dot.position = center
        layer.addSublayer(dot)

        guard !reduceMotion else { return }

        // (1) Hue flow — colours drift slowly through the palette: flowing light at rest.
        let flow = CAKeyframeAnimation(keyPath: "colors")
        flow.values = phaseRamp(idleHues, frames: 16)
        flow.duration = 6.0
        flow.calculationMode = .linear
        flow.repeatCount = .infinity
        dot.add(flow, forKey: "idle-flow")

        // (2) Lighting drift — the bright/dark seam slides, so the orb looks lit from a slowly
        //     moving angle. Subtle, at an unrelated period.
        let drift = CAKeyframeAnimation(keyPath: "locations")
        drift.values = [
            [0.0, 0.30, 0.55, 0.80, 1.0],
            [0.0, 0.20, 0.50, 0.85, 1.0],
            [0.0, 0.30, 0.55, 0.80, 1.0],
        ].map { $0.map(NSNumber.init) }
        drift.duration = 7.0
        drift.repeatCount = .infinity
        dot.add(drift, forKey: "idle-drift")

        // (3) Gentle scale-breathe (on the sublayer, explicitly anchored — robust).
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 0.84
        breathe.toValue = 1.0
        breathe.duration = 2.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(breathe, forKey: "idle-breathe")

        // (4) Halo sonar bloom — expand + fade group, in family with the orb's hue.
        let haloScale = CABasicAnimation(keyPath: "transform.scale")
        haloScale.fromValue = 0.7
        haloScale.toValue = 1.55
        let haloFade = CABasicAnimation(keyPath: "opacity")
        haloFade.fromValue = 0.55
        haloFade.toValue = 0.0
        let haloGroup = CAAnimationGroup()
        haloGroup.animations = [haloScale, haloFade]
        haloGroup.duration = 3.0
        haloGroup.repeatCount = .infinity
        haloGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        halo.add(haloGroup, forKey: "idle-halo-pulse")

        let haloCycle = CAKeyframeAnimation(keyPath: "borderColor")
        haloCycle.values = idleHues.map(\.cgColor)
        haloCycle.duration = 6.0
        haloCycle.calculationMode = .linear
        haloCycle.repeatCount = .infinity
        halo.add(haloCycle, forKey: "idle-halo-cycle")
    }

    static func removeIdleDot(from host: NSView) {
        host.layer?.sublayers?
            .filter { $0.name == "idle-dot" || $0.name == "idle-halo" }
            .forEach { $0.removeFromSuperlayer() }
    }
}
