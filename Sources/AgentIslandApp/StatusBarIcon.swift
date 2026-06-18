import AppKit

// The menu-bar status item's glyph — a miniature of the app logo (the lighthouse on its island), so the
// menu bar and the app icon are one brand. The TOWER is drawn in the adaptive `labelColor` (reads on
// light AND dark bars, like a normal menu-bar template), and the LAMP + BEAM carry the state colour —
// mirroring the app icon's beacon: dim idle · teal working · red waiting · green finished. (The robot
// "agent" lives in the detailed app icon; at 18pt the lighthouse alone stays crisp.)
//
// Built with the point-based `NSImage(size:flipped:drawingHandler:)` initializer so the handler re-runs
// per backing scale factor (crisp on Retina). `isTemplate = false` because the lamp carries a real colour.
extension IslandIcons {
    static func lighthouse(lamp: NSColor, beam: Bool, showUpdateDot: Bool = false) -> NSImage {
        let structure = NSColor.labelColor
        let img = NSImage(size: NSSize(width: 19, height: 18), flipped: false) { rect in
            let W = rect.width, H = rect.height
            // Bias the tower slightly left when a beam shows so it has room without shifting the look.
            let cx = rect.minX + W * (beam ? 0.42 : 0.5)
            structure.setFill(); structure.setStroke()

            // Island base.
            NSBezierPath(roundedRect: NSRect(x: cx - W*0.28, y: rect.minY + H*0.08, width: W*0.56, height: H*0.07),
                         xRadius: H*0.035, yRadius: H*0.035).fill()
            // Tower (tapered).
            let tb = rect.minY + H*0.14, tt = rect.minY + H*0.64, bw = W*0.11, tw = W*0.075
            let tower = NSBezierPath()
            tower.move(to: NSPoint(x: cx-bw, y: tb)); tower.line(to: NSPoint(x: cx-tw, y: tt))
            tower.line(to: NSPoint(x: cx+tw, y: tt)); tower.line(to: NSPoint(x: cx+bw, y: tb)); tower.close()
            tower.fill()
            // Lantern room.
            NSBezierPath(roundedRect: NSRect(x: cx - W*0.10, y: tt, width: W*0.20, height: H*0.12),
                         xRadius: W*0.03, yRadius: W*0.03).fill()
            // Roof.
            let roof = NSBezierPath()
            roof.move(to: NSPoint(x: cx-W*0.12, y: tt+H*0.12)); roof.line(to: NSPoint(x: cx+W*0.12, y: tt+H*0.12))
            roof.line(to: NSPoint(x: cx, y: tt+H*0.27)); roof.close(); roof.fill()

            let lampC = NSPoint(x: cx, y: tt + H*0.06)
            // Beam (only when actively working/waiting) — a soft state-coloured cone up-right.
            if beam {
                let bp = NSBezierPath()
                bp.move(to: lampC)
                bp.line(to: NSPoint(x: rect.maxX, y: lampC.y + H*0.10))
                bp.line(to: NSPoint(x: rect.maxX, y: lampC.y + H*0.26))
                bp.close()
                lamp.withAlphaComponent(0.30).setFill(); bp.fill()
            }
            // Lamp — the state signal.
            let lr = W*0.055
            lamp.setFill()
            NSBezierPath(ovalIn: NSRect(x: lampC.x-lr, y: lampC.y-lr, width: lr*2, height: lr*2)).fill()
            // Quiet idle-only "update available" corner dot.
            if showUpdateDot {
                lamp.setFill()
                let r = W*0.09
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - r*2 - 0.5, y: rect.maxY - r*2 - 0.5, width: r*2, height: r*2)).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
