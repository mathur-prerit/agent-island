import AppKit

// The menu-bar status item's "agent" glyph — a small robot head, the brand mark for agent-island.
// Lives alongside `IslandIcons.trafficLight` (RoadSceneView.swift) and follows the same idiom: a
// fixed-size, per-state-coloured, non-template NSImage. Built with the point-based
// `NSImage(size:flipped:drawingHandler:)` initializer so the handler re-runs per backing scale factor
// (crisp on Retina with no manual point→pixel maths — the lockFocus path bakes a single rep).
extension IslandIcons {
    /// The menu-bar robot head, filled in the state `color` (the app's existing palette: gray idle ·
    /// teal working · red waiting · green finished). The eyes are knocked out (`destinationOut`) so they
    /// read as eyes against ANY menu-bar background, light or dark. `showUpdateDot` draws a quiet corner
    /// dot — the idle-only "update available" cue (callers gate it to the idle state so it never competes
    /// with an urgent waiting/working state).
    static func robotHead(color: NSColor, showUpdateDot: Bool = false) -> NSImage {
        // ~18×16pt: wide enough for the head + ears, tall enough for the antenna, inside the menu bar's
        // ~22pt height so it isn't clipped.
        let img = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { rect in
            let W = rect.width, H = rect.height
            color.setFill()
            // Head (rounded square).
            let hw = W * 0.74, hh = H * 0.58
            let hx = rect.midX - hw / 2, hy = rect.minY + H * 0.10
            NSBezierPath(roundedRect: NSRect(x: hx, y: hy, width: hw, height: hh),
                         xRadius: hw * 0.30, yRadius: hw * 0.30).fill()
            // Ears.
            for ex in [hx - W * 0.06, hx + hw - W * 0.04] {
                NSBezierPath(roundedRect: NSRect(x: ex, y: hy + hh * 0.34, width: W * 0.10, height: hh * 0.32),
                             xRadius: W * 0.04, yRadius: W * 0.04).fill()
            }
            // Antenna + ball.
            let ax = rect.midX, atop = hy + hh + H * 0.16
            let antenna = NSBezierPath()
            antenna.lineWidth = W * 0.07
            antenna.move(to: NSPoint(x: ax, y: hy + hh)); antenna.line(to: NSPoint(x: ax, y: atop))
            color.setStroke(); antenna.stroke()
            let ballR = W * 0.085
            NSBezierPath(ovalIn: NSRect(x: ax - ballR, y: atop - ballR * 0.6, width: ballR * 2, height: ballR * 2)).fill()
            // Eyes — knocked out so the menu-bar background shows through (legible on light AND dark).
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            for ex in [-hw * 0.19, hw * 0.19] {
                let r = W * 0.085
                NSBezierPath(ovalIn: NSRect(x: rect.midX + ex - r, y: hy + hh * 0.42 - r, width: r * 2, height: r * 2)).fill()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            // Quiet "update available" corner dot (idle-only; gated by the caller).
            if showUpdateDot {
                color.setFill()
                let r = W * 0.10
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - r * 2 - 0.5, y: rect.maxY - r * 2 - 0.5,
                                            width: r * 2, height: r * 2)).fill()
            }
            return true
        }
        img.isTemplate = false   // carries its own colours (mirrors IslandIcons.trafficLight)
        return img
    }
}
