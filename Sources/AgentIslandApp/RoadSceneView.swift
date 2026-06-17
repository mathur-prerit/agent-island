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

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }
    override var isFlipped: Bool { false }   // y-up: road at the bottom, signs rise above it

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true          // clip signs/labels sliding past the edges
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private let roadTopY: CGFloat = 10       // top of the road surface (vehicle wheels rest here)

    override func draw(_ dirtyRect: NSRect) {
        let w = Double(bounds.width)
        let layout = RoadJourney.layout(tokens: tokens, viewWidth: w)
        let stageColor = IslandIcons.color(for: layout.stage, airborne: layout.airborne)

        drawRoad()
        for sign in layout.signs { draw(sign: sign, stageColor: stageColor) }
        drawVehicle(layout: layout, color: stageColor)
    }

    // MARK: - Pieces

    private func drawRoad() {
        let band = NSRect(x: 0, y: 3, width: bounds.width, height: roadTopY - 3)
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(rect: band).fill()
        // Scrolling dashed centre line (motion cue). Frozen under Reduce Motion.
        let dashW: CGFloat = 9, gap: CGFloat = 9, period = dashW + gap
        let phase = IslandAnimations.reduceMotion ? 0 : CGFloat(frame_) * 1.6
        let offset = phase.truncatingRemainder(dividingBy: period)
        NSColor.labelColor.withAlphaComponent(0.28).setFill()
        var x = -offset
        let y = (3 + roadTopY) / 2 - 0.75
        while x < bounds.width {
            NSBezierPath(rect: NSRect(x: x, y: y, width: dashW, height: 1.5)).fill()
            x += period
        }
    }

    private func draw(sign: RoadJourney.Sign, stageColor: NSColor) {
        let x = CGFloat(sign.x)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
        ]
        if sign.isMajor {
            // A signboard "town" on a post.
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
            // A thin milestone post with the label above it.
            let post = NSBezierPath(rect: NSRect(x: x - 0.5, y: roadTopY, width: 1, height: 6))
            NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill(); post.fill()
            let label = NSAttributedString(string: sign.label,
                attributes: attrs.merging([.foregroundColor: NSColor.tertiaryLabelColor]) { $1 })
            let ls = label.size()
            label.draw(at: NSPoint(x: x - ls.width / 2, y: roadTopY + 6))
        }
    }

    private func drawVehicle(layout: RoadJourney.Layout, color: NSColor) {
        let base = IslandIcons.symbol(for: layout.stage)
        let img = tinted(base, color)
        let s = img.size
        let bob = IslandAnimations.reduceMotion ? 0 : CGFloat(sin(Double(frame_) * 0.35)) * 0.8
        let lift: CGFloat = layout.airborne ? 7 : 0     // the plane takes off past the last town
        let x = CGFloat(layout.vehicleX) - s.width / 2
        let y = roadTopY - 1 + bob + lift
        if !layout.airborne {
            // A soft ground shadow grounds the vehicle on the road.
            NSColor.black.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 1, y: roadTopY - 3, width: s.width - 2, height: 3)).fill()
        }
        img.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1)
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
        let samples: [(Int, String)] = [
            (0, "0 · bike"), (20_000, "20k · bike"), (52_000, "52k · car"),
            (130_000, "130k · train"), (210_000, "210k · ✈ takeoff"),
        ]
        let frames = [0, 7]                                   // two phases: dash + bob shift
        let sceneW: CGFloat = 150, sceneH: CGFloat = 26
        let labelW: CGFloat = 110, pad: CGFloat = 10, rowGap: CGFloat = 8
        let canvasW = labelW + (sceneW + pad) * CGFloat(frames.count) + pad
        let canvasH = pad + (sceneH + rowGap) * CGFloat(samples.count)

        let canvas = NSImage(size: NSSize(width: canvasW, height: canvasH))
        // Draw in the dark appearance so semantic colours (labelColor…) resolve light, as on the
        // real HUD island. Draw each scene's content directly (a translated CTM) rather than via
        // cacheDisplay, which yields an opaque white rep that hides the subtle road + dashes.
        let render = {
            canvas.lockFocus()
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()    // dark HUD-ish backdrop
            NSRect(x: 0, y: 0, width: canvasW, height: canvasH).fill()
            for (r, sample) in samples.enumerated() {
                let y = canvasH - pad - sceneH - CGFloat(r) * (sceneH + rowGap)
                NSAttributedString(string: sample.1, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: NSColor.white,
                ]).draw(at: NSPoint(x: pad, y: y + sceneH / 2 - 6))
                for (c, f) in frames.enumerated() {
                    let x = labelW + CGFloat(c) * (sceneW + pad)
                    let view = RoadSceneView(frame: NSRect(x: 0, y: 0, width: sceneW, height: sceneH))
                    view.tokens = sample.0
                    view.frame_ = f
                    NSGraphicsContext.current?.saveGraphicsState()
                    let t = NSAffineTransform(); t.translateX(by: x, yBy: y); t.concat()
                    view.draw(view.bounds)
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
            }
            canvas.unlockFocus()
        }
        if #available(macOS 11.0, *), let dark = NSAppearance(named: .darkAqua) {
            dark.performAsCurrentDrawingAppearance(render)
        } else {
            render()
        }

        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("road sample: failed to encode PNG\n".utf8)); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("road sample written to \(path)\n".utf8))
    }
}
