import AppKit
import QuartzCore

/// Core Animation builders for island state cues. Every motion is gated on Reduce Motion:
/// when it's on, colors still apply but loops/pops are skipped.
enum IslandAnimations {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static let aurora: [CGColor] = [
        NSColor.systemTeal.cgColor, NSColor.systemBlue.cgColor, NSColor.systemIndigo.cgColor,
        NSColor.systemPurple.cgColor, NSColor.systemPink.cgColor, NSColor.systemTeal.cgColor,
    ]
    private static let idleHues: [CGColor] = [
        NSColor.systemTeal.cgColor, NSColor.systemBlue.cgColor,
        NSColor.systemPurple.cgColor, NSColor.systemTeal.cgColor,
    ]

    // MARK: Working — rotating conic aurora ring on a fixed-size host (14x14)

    static func installWorkingRing(on host: NSView) {
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        if layer.sublayers?.contains(where: { $0.name == "aurora-ring" }) == true { return }
        let size: CGFloat = 14, lw: CGFloat = 2.4
        let ring = CAGradientLayer()
        ring.name = "aurora-ring"
        ring.type = .conic
        ring.frame = CGRect(x: 0, y: 0, width: size, height: size)
        ring.colors = aurora
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
        guard !reduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0.0
        spin.toValue = 2.0 * Double.pi
        spin.duration = 2.0
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
    }

    static func removeWorkingRing(from host: NSView) {
        host.layer?.sublayers?.filter { $0.name == "aurora-ring" }.forEach { $0.removeFromSuperlayer() }
    }

    // MARK: Waiting — breathing opacity pulse (faster + scale for the urgent permission case)

    static func startPulse(on view: NSView, urgent: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        guard !reduceMotion else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1.0
        opacity.toValue = urgent ? 0.25 : 0.5
        opacity.duration = urgent ? 0.5 : 0.85
        opacity.autoreverses = true
        opacity.repeatCount = .infinity
        layer.add(opacity, forKey: "pulse")
        guard urgent else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.12
        scale.duration = 0.5
        scale.autoreverses = true
        scale.repeatCount = .infinity
        layer.add(scale, forKey: "pulse-scale")
    }

    static func stopPulse(on view: NSView) {
        view.layer?.removeAnimation(forKey: "pulse")
        view.layer?.removeAnimation(forKey: "pulse-scale")
    }

    // MARK: Finished — one-shot pop (success) or shake (failed) + colored glow

    static func celebrate(_ view: NSView, success: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer, !reduceMotion else { return }
        let color = (success ? NSColor.systemGreen : NSColor.systemRed).cgColor
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let motion = CAKeyframeAnimation(keyPath: success ? "transform.scale" : "position.x")
        if success {
            motion.values = [1.0, 1.28, 1.0]
            motion.keyTimes = [0, 0.4, 1.0]
        } else {
            let x = layer.position.x
            motion.values = [x, x - 4, x + 4, x - 2, x]
            motion.keyTimes = [0, 0.2, 0.5, 0.8, 1.0]
        }
        motion.duration = 0.55
        layer.add(motion, forKey: "celebrate-motion")
        layer.shadowColor = color
        layer.shadowRadius = 8
        layer.shadowOffset = .zero
        layer.shadowOpacity = 0
        let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glow.values = [0.0, 0.9, 0.0]
        glow.duration = 0.7
        layer.add(glow, forKey: "celebrate-glow")
    }

    // MARK: Idle — slow color-cycling dot on a fixed-size host (10x10)

    static func installIdleDot(on host: NSView) {
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        if layer.sublayers?.contains(where: { $0.name == "idle-dot" }) == true { return }
        let size: CGFloat = 8
        let dot = CALayer()
        dot.name = "idle-dot"
        dot.frame = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = size / 2
        dot.backgroundColor = idleHues.first
        layer.addSublayer(dot)
        guard !reduceMotion else { return }
        let cycle = CAKeyframeAnimation(keyPath: "backgroundColor")
        cycle.values = idleHues
        cycle.duration = 6.0
        cycle.repeatCount = .infinity
        dot.add(cycle, forKey: "idle-cycle")
    }

    static func removeIdleDot(from host: NSView) {
        host.layer?.sublayers?.filter { $0.name == "idle-dot" }.forEach { $0.removeFromSuperlayer() }
    }
}
