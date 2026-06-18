import AppKit
import Foundation

// The menu-bar status item's glyph — a miniature of the app logo (the lighthouse on its island), so the
// menu bar and the app icon are one brand. The TOWER is drawn in the adaptive `labelColor` (reads on
// light AND dark bars, like a normal menu-bar template); the LAMP + BEAM carry the state colour —
// dim idle · teal working · red waiting · green finished. The lighthouse sits on the LEFT with open
// "sky" to the right, where the BEAM sweeps when `beamPhase` is supplied (the app drives a frame timer
// while a session is working/waiting; idle/finished show clear sky). The robot "agent" lives in the
// detailed app icon; at this size the lighthouse alone stays crisp.
//
// Built with the point-based `NSImage(size:flipped:drawingHandler:)` initializer so the handler re-runs
// per backing scale factor (crisp on Retina). `isTemplate = false` because the lamp carries a real colour.
extension IslandIcons {
    /// `beamPhase` (0…1) animates the sweeping beam; `nil` draws a static beam (Reduce Motion / when the
    /// beam is off the parameter is ignored). `beam` gates whether any beam is drawn at all. `compact`
    /// renders a centered, narrow lighthouse with no beam — for inline use (e.g. the island panel header).
    static func lighthouse(lamp: NSColor, beam: Bool, beamPhase: CGFloat? = nil,
                           showUpdateDot: Bool = false, compact: Bool = false) -> NSImage {
        let structure = NSColor.labelColor
        let size = compact ? NSSize(width: 15, height: 18) : NSSize(width: 24, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let u = rect.height                 // size the lighthouse by HEIGHT so the wide canvas doesn't fatten it
            // Compact → centered (tight inline logo); full → left third with open sky on the right for the beam.
            let cx = compact ? rect.midX : rect.minX + u * 0.5
            let drawBeam = beam && !compact
            structure.setFill(); structure.setStroke()

            // Island base.
            NSBezierPath(roundedRect: NSRect(x: cx - u*0.30, y: rect.minY + u*0.06, width: u*0.60, height: u*0.07),
                         xRadius: u*0.035, yRadius: u*0.035).fill()
            // Tower (tapered).
            let tb = rect.minY + u*0.12, tt = rect.minY + u*0.62, bw = u*0.11, tw = u*0.075
            let tower = NSBezierPath()
            tower.move(to: NSPoint(x: cx-bw, y: tb)); tower.line(to: NSPoint(x: cx-tw, y: tt))
            tower.line(to: NSPoint(x: cx+tw, y: tt)); tower.line(to: NSPoint(x: cx+bw, y: tb)); tower.close(); tower.fill()
            // Lantern room + roof.
            NSBezierPath(roundedRect: NSRect(x: cx - u*0.10, y: tt, width: u*0.20, height: u*0.12),
                         xRadius: u*0.03, yRadius: u*0.03).fill()
            let roof = NSBezierPath()
            roof.move(to: NSPoint(x: cx-u*0.12, y: tt+u*0.12)); roof.line(to: NSPoint(x: cx+u*0.12, y: tt+u*0.12))
            roof.line(to: NSPoint(x: cx, y: tt+u*0.27)); roof.close(); roof.fill()

            let lampC = NSPoint(x: cx, y: tt + u*0.06)
            // Beam — sweeps across the right sky (low-right → near-vertical) when animated; static up-right otherwise.
            if drawBeam {
                let theta: CGFloat = (beamPhase.map { 0.78 + 0.68 * sin(2 * .pi * $0) }) ?? 0.62
                let len = u * 0.85, half: CGFloat = 0.28
                let p1 = NSPoint(x: lampC.x + len*cos(theta-half), y: lampC.y + len*sin(theta-half))
                let p2 = NSPoint(x: lampC.x + len*cos(theta+half), y: lampC.y + len*sin(theta+half))
                let b = NSBezierPath(); b.move(to: lampC); b.line(to: p1); b.line(to: p2); b.close()
                lamp.withAlphaComponent(0.32).setFill(); b.fill()
            }
            // Lamp — the state signal.
            let lr = u*0.055; lamp.setFill()
            NSBezierPath(ovalIn: NSRect(x: lampC.x-lr, y: lampC.y-lr, width: lr*2, height: lr*2)).fill()
            // Quiet idle-only "update available" corner dot.
            if showUpdateDot {
                lamp.setFill()
                let r = u*0.09
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - r*2 - 0.5, y: rect.maxY - r*2 - 0.5, width: r*2, height: r*2)).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
