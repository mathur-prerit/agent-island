import AppKit
import AgentIslandCore

/// Builders for the road-trip theme's small icons. SF Symbols are template images (tinted by the
/// row's `contentTintColor`); the traffic light has no SF equivalent, so it's hand-drawn in colour.
enum IslandIcons {
    /// A tintable SF Symbol image at a given point size (template → takes `contentTintColor`).
    static func symbol(_ name: String, pointSize: CGFloat = 13, weight: NSFont.Weight = .semibold) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(cfg) ?? NSImage()
        img.isTemplate = true
        return img
    }

    static func symbol(for stage: RoadJourney.Stage, pointSize: CGFloat = 13) -> NSImage {
        switch stage {
        case .cycle: return symbol("bicycle", pointSize: pointSize)
        case .car:   return symbol("car.fill", pointSize: pointSize)
        case .train: return symbol("tram.fill", pointSize: pointSize)
        case .plane: return symbol("airplane", pointSize: pointSize)
        }
    }

    /// The stage tint, matching the original road-trip palette.
    static func color(for stage: RoadJourney.Stage, airborne: Bool) -> NSColor {
        if airborne { return .systemPink }
        switch stage {
        case .cycle: return .systemTeal
        case .car:   return .systemBlue
        case .train: return .systemIndigo
        case .plane: return .systemPink
        }
    }

    /// A small 3-lamp traffic light; `frame` cycles the lit lamp red → amber → green (mostly red).
    static func trafficLight(frame: Int) -> NSImage {
        let size = NSSize(width: 13, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        // Housing.
        let housing = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 0, width: 10, height: 18), xRadius: 3, yRadius: 3)
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        housing.fill()
        // Which lamp is lit (top=red, mid=amber, bottom=green). Dwell on red, flick through amber.
        let seq: [Int] = [0, 0, 0, 0, 1, 2, 2, 2, 1]   // index into [red, amber, green]
        let lit = IslandAnimations.reduceMotion ? 0 : seq[(frame / 5) % seq.count]
        let lamps: [(y: CGFloat, color: NSColor)] = [
            (11.5, .systemRed), (6.5, .systemYellow), (1.5, .systemGreen),
        ]
        for (i, lamp) in lamps.enumerated() {
            let dot = NSBezierPath(ovalIn: NSRect(x: 3.5, y: lamp.y, width: 6, height: 5))
            (i == lit ? lamp.color : lamp.color.withAlphaComponent(0.16)).setFill()
            dot.fill()
        }
        img.unlockFocus()
        img.isTemplate = false   // carries its own colours
        return img
    }
}

/// The scrolling road scene drawn for a running session in the road-trip theme: a vehicle pinned
/// near the left "drives" while milestone signs (one per 5K tokens, signboards at the upgrade
/// towns) scroll past. Token count fixes the world position (real progress); the shared ticker's
/// `frame` only animates the lane dashes + a tiny vehicle bob, and freezes under Reduce Motion.
final class RoadSceneView: NSView {
    var tokens: Int = 0 { didSet { if tokens != oldValue { needsDisplay = true } } }
    var frame_: Int = 0 { didSet { if frame_ != oldValue { needsDisplay = true } } }
    var mode: RoadMode = .driving { didSet { if mode != oldValue { needsDisplay = true } } }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }
    override var isFlipped: Bool { false }   // y-up: road at the bottom, signs rise above it

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true          // clip signs/labels sliding past the edges
        // Width is driven by the row's banner constraint; don't pin to the intrinsic 150.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private let roadTopY: CGFloat = 10       // top of the road surface (vehicle wheels rest here)

    override func draw(_ dirtyRect: NSRect) {
        let w = Double(bounds.width)
        let layout = RoadJourney.layout(tokens: tokens, viewWidth: w)
        let stageColor = IslandIcons.color(for: layout.stage, airborne: layout.airborne)
        let stopped: RoadMode.StopKind?
        if case let .stopped(kind) = mode { stopped = kind } else { stopped = nil }

        // The light stands just ahead of the (stopped) vehicle, so the two read as one "stopped at
        // the light" unit. Clamped to the view's right edge.
        let signalX: CGFloat? = (stopped != nil)
            ? min((CGFloat(layout.vehicleX) + 34).rounded(), CGFloat(w) - 7) : nil

        drawRoad(moving: stopped == nil)
        for sign in layout.signs {
            // When halted, drop the signs sitting on the vehicle or behind the signal so that
            // stopped unit stays legible (the world is frozen, so nothing blinks); distant signs
            // still give progress context. While driving, signs pass through normally.
            if stopped != nil {
                if abs(sign.x - layout.vehicleX) < 13 { continue }
                if let sx = signalX, abs(CGFloat(sign.x) - sx) < 16 { continue }
            }
            draw(sign: sign, stageColor: stageColor)
        }
        if let kind = stopped, let sx = signalX { drawSignal(x: sx, kind: kind) }
        drawVehicle(layout: layout, color: stageColor, stopped: stopped)
    }

    // MARK: - Pieces

    /// The road surface + scrolling centre line. When the vehicle is stopped (or Reduce Motion is
    /// on) the dashes freeze — a stationary road reads as "not going anywhere right now".
    private func drawRoad(moving: Bool) {
        let band = NSRect(x: 0, y: 3, width: bounds.width, height: roadTopY - 3)
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(rect: band).fill()
        let dashW: CGFloat = 9, gap: CGFloat = 9, period = dashW + gap
        let phase = (IslandAnimations.reduceMotion || !moving) ? 0 : CGFloat(frame_) * 1.6
        let offset = phase.truncatingRemainder(dividingBy: period)
        NSColor.labelColor.withAlphaComponent(0.28).setFill()
        var x = -offset
        let y = (3 + roadTopY) / 2 - 0.75
        while x < bounds.width {
            NSBezierPath(rect: NSRect(x: x, y: y, width: dashW, height: 1.5)).fill()
            x += period
        }
    }

    /// Deep "highway green" used for the roadside guide signs (white text, thin white border) —
    /// the same idiom as US interstate mile-markers / exit signs, so a sign reads as a sign.
    private static let highwayGreen = NSColor(srgbRed: 0.04, green: 0.40, blue: 0.24, alpha: 1)

    private func draw(sign: RoadJourney.Sign, stageColor: NSColor) {
        let x = CGFloat(sign.x)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
        ]
        if sign.isMajor {
            // A stage-coloured signboard "town" on a post — the vehicle-upgrade milestones.
            let post = NSBezierPath(rect: NSRect(x: x - 0.75, y: roadTopY, width: 1.5, height: 4))
            stageColor.withAlphaComponent(0.8).setFill(); post.fill()
            let label = NSAttributedString(string: sign.label,
                attributes: attrs.merging([.foregroundColor: NSColor.white]) { $1 })
            let ls = label.size()
            let board = NSRect(x: x - ls.width / 2 - 4, y: roadTopY + 4, width: ls.width + 8, height: 13)
            let bp = NSBezierPath(roundedRect: board, xRadius: 3, yRadius: 3)
            stageColor.withAlphaComponent(0.92).setFill(); bp.fill()
            label.draw(at: NSPoint(x: board.minX + 4, y: board.minY + 2.5))
        } else {
            // A small green highway guide sign mounted on a post — white token count, thin white
            // border. Smaller and green so it stays clearly subordinate to the upgrade-town boards.
            let post = NSBezierPath(rect: NSRect(x: x - 0.5, y: roadTopY, width: 1, height: 4))
            NSColor.labelColor.withAlphaComponent(0.40).setFill(); post.fill()
            let label = NSAttributedString(string: sign.label,
                attributes: attrs.merging([.foregroundColor: NSColor.white]) { $1 })
            let ls = label.size()
            let board = NSRect(x: (x - ls.width / 2 - 2.5).rounded(), y: roadTopY + 4,
                               width: (ls.width + 5).rounded(), height: 11)
            let bp = NSBezierPath(roundedRect: board, xRadius: 2, yRadius: 2)
            RoadSceneView.highwayGreen.withAlphaComponent(0.92).setFill(); bp.fill()
            bp.lineWidth = 0.75
            NSColor.white.withAlphaComponent(0.7).setStroke(); bp.stroke()
            label.draw(at: NSPoint(x: board.minX + 2.5, y: board.minY + 1.5))
        }
    }

    private func drawVehicle(layout: RoadJourney.Layout, color: NSColor, stopped: RoadMode.StopKind?) {
        let base = IslandIcons.symbol(for: layout.stage)
        let img = tinted(base, color)
        let s = img.size
        // Stopped → no idle bob, and a plane waits on the tarmac (no takeoff lift).
        let bob = (IslandAnimations.reduceMotion || stopped != nil) ? 0 : CGFloat(sin(Double(frame_) * 0.35)) * 0.8
        let lift: CGFloat = (layout.airborne && stopped == nil) ? 7 : 0
        let grounded = !layout.airborne || stopped != nil
        let x = CGFloat(layout.vehicleX) - s.width / 2
        let y = roadTopY - 1 + bob + lift
        if grounded {
            // A soft ground shadow grounds the vehicle on the road.
            NSColor.black.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 1, y: roadTopY - 3, width: s.width - 2, height: 3)).fill()
        }
        // A red brake glow at the rear (left) edge when blocked on a permission prompt — "stopped,
        // your move". The gentler turn-end pause skips it.
        if stopped == .permission {
            NSColor.systemRed.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 2, y: y + s.height * 0.28, width: 4, height: 4)).fill()
        }
        img.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// An in-scene traffic light standing on the roadside ahead of the (stopped) vehicle. The lamp
    /// cycles red→amber→green; `permission` dwells on red (blocking), `turnEnd` cycles gently
    /// (idling at a pitstop). Frozen on red/amber under Reduce Motion.
    private func drawSignal(x sx: CGFloat, kind: RoadMode.StopKind) {
        let poleTop = roadTopY + 19
        // Pole.
        NSColor.labelColor.withAlphaComponent(0.38).setFill()
        NSBezierPath(rect: NSRect(x: sx - 0.75, y: roadTopY, width: 1.5, height: poleTop - roadTopY)).fill()
        // Housing.
        let hw: CGFloat = 7, hh: CGFloat = 15.5
        let housing = NSRect(x: sx - hw / 2, y: poleTop - hh, width: hw, height: hh)
        NSColor.labelColor.withAlphaComponent(0.30).setFill()
        NSBezierPath(roundedRect: housing, xRadius: 2, yRadius: 2).fill()
        // Lamps: index 0 top = red, 1 amber, 2 green (bottom).
        let seq: [Int] = (kind == .permission) ? [0, 0, 0, 0, 0, 0, 1, 2] : [0, 0, 1, 2, 2, 1]
        let lit = IslandAnimations.reduceMotion ? (kind == .permission ? 0 : 1) : seq[(frame_ / 5) % seq.count]
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
        let d: CGFloat = 3.8
        for i in 0..<3 {
            let cy = housing.maxY - 3.6 - CGFloat(i) * 4.4
            if i == lit {
                // A soft halo so the live lamp glows against the dark HUD.
                colors[i].withAlphaComponent(0.28).setFill()
                NSBezierPath(ovalIn: NSRect(x: sx - d / 2 - 1.6, y: cy - d / 2 - 1.6, width: d + 3.2, height: d + 3.2)).fill()
            }
            (i == lit ? colors[i] : colors[i].withAlphaComponent(0.16)).setFill()
            NSBezierPath(ovalIn: NSRect(x: sx - d / 2, y: cy - d / 2, width: d, height: d)).fill()
        }
    }

    /// Fill a template image with `color` (keeps its alpha mask) — for drawing a tinted vehicle.
    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let img = image.copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

/// Dev-only: render a grid of road scenes (several token amounts × two frames) to a PNG so the
/// drawing can be eyeballed without a live running session. Gated behind `-renderRoadSample <path>`.
enum RoadSampleRenderer {
    static func render(to path: String) {
        let samples: [(Int, RoadMode, String)] = [
            (0, .driving, "0 · bike"),
            (52_000, .driving, "52k · car"),
            (130_000, .driving, "130k · train"),
            (38_000, .stopped(.permission), "38k · permission"),
            (88_000, .stopped(.turnEnd), "88k · pitstop"),
        ]
        let frames = [0, 25]                                  // two phases (dashes + signal cycle)
        let sceneW: CGFloat = 290, sceneH: CGFloat = 26       // the real on-island banner width
        let labelW: CGFloat = 120, pad: CGFloat = 12, rowGap: CGFloat = 12
        let canvasW = labelW + (sceneW + pad) * CGFloat(frames.count) + pad
        let canvasH = pad + (sceneH + rowGap) * CGFloat(samples.count)

        // Render into a 2× bitmap so the small details (signal lamps, signs, vehicle) stay crisp
        // when the PNG is opened/zoomed. `rep.size` = logical points; pixels are 2× → CTM scales up.
        let scale = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(canvasW) * scale, pixelsHigh: Int(canvasH) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            FileHandle.standardError.write(Data("road sample: failed to alloc bitmap\n".utf8)); return
        }
        rep.size = NSSize(width: canvasW, height: canvasH)

        // Draw in the dark appearance so semantic colours (labelColor…) resolve light, as on the
        // real HUD island. Draw each scene's content directly (a translated CTM) rather than via
        // cacheDisplay, which yields an opaque white rep that hides the subtle road + dashes.
        let render = {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()    // dark HUD-ish backdrop
            NSRect(x: 0, y: 0, width: canvasW, height: canvasH).fill()
            for (r, sample) in samples.enumerated() {
                let y = canvasH - pad - sceneH - CGFloat(r) * (sceneH + rowGap)
                NSAttributedString(string: sample.2, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: NSColor.white,
                ]).draw(at: NSPoint(x: pad, y: y + sceneH / 2 - 6))
                for (c, f) in frames.enumerated() {
                    let x = labelW + CGFloat(c) * (sceneW + pad)
                    let view = RoadSceneView(frame: NSRect(x: 0, y: 0, width: sceneW, height: sceneH))
                    view.tokens = sample.0
                    view.mode = sample.1
                    view.frame_ = f
                    NSGraphicsContext.current?.saveGraphicsState()
                    let t = NSAffineTransform(); t.translateX(by: x, yBy: y); t.concat()
                    view.draw(view.bounds)
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if #available(macOS 11.0, *), let dark = NSAppearance(named: .darkAqua) {
            dark.performAsCurrentDrawingAppearance(render)
        } else {
            render()
        }

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("road sample: failed to encode PNG\n".utf8)); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("road sample written to \(path)\n".utf8))
    }
}
