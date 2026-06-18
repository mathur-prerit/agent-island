import AppKit
import AgentIslandCore

/// Dev-only: render every state of ANY theme (code or data) to a labelled PNG strip, so a theme can
/// be eyeballed without a live session. Generic over `IslandTheme`/`ThemeScene` — works for the
/// bundled `critter` data theme today and any downloaded manifest theme later. Gated behind
/// `-renderTheme <id> <path>`. Mirrors `RoadSampleRenderer` (2× bitmap, dark appearance).
enum ThemeSampleRenderer {
    private static let states: [(ThemeStateKey, String)] = [
        (.idle, "idle"),
        (.working, "working"),
        (.waiting(.permission), "waitPerm"),
        (.waiting(.stoppedTurn), "waitTurn"),
        (.failed, "failed"),
        (.finished, "finished"),
    ]

    static func render(themeID: String, to path: String) {
        let theme = Themes.named(themeID)
        let frames = [0, 12]                                  // two phases (catch a sprite mid-cycle)
        let cell = NSSize(width: 44, height: 28)
        let labelW: CGFloat = 92, pad: CGFloat = 10, rowGap: CGFloat = 8
        let canvasW = labelW + (cell.width + pad) * CGFloat(frames.count) + pad
        let canvasH = pad + (cell.height + rowGap) * CGFloat(states.count)

        let scale = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(canvasW) * scale, pixelsHigh: Int(canvasH) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            FileHandle.standardError.write(Data("theme sample: failed to alloc bitmap\n".utf8)); return
        }
        rep.size = NSSize(width: canvasW, height: canvasH)   // set BEFORE the context so its CTM scales 2×
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            FileHandle.standardError.write(Data("theme sample: failed to make context\n".utf8)); return
        }

        let draw = {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: canvasW, height: canvasH).fill()
            for (r, state) in states.enumerated() {
                let y = canvasH - pad - cell.height - CGFloat(r) * (cell.height + rowGap)
                NSAttributedString(string: "\(theme.id):\(state.1)", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: NSColor.white,
                ]).draw(at: NSPoint(x: pad, y: y + cell.height / 2 - 6))
                for (c, f) in frames.enumerated() {
                    let x = labelW + CGFloat(c) * (cell.width + pad)
                    let img = capture(theme.makeScene(), state: state.0, frame: f, size: cell)
                    img.draw(in: NSRect(x: x, y: y, width: cell.width, height: cell.height))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if #available(macOS 11.0, *), let dark = NSAppearance(named: .darkAqua) {
            dark.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("theme sample: PNG encode failed\n".utf8)); return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("theme sample written: \(path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("theme sample: write failed: \(error)\n".utf8))
        }
    }

    /// Realize one scene at a given state + frame in a fixed-size host and capture it (subviews
    /// included) to an `NSImage` via `cacheDisplay`.
    private static func capture(_ scene: ThemeScene, state: ThemeStateKey, frame: Int, size: NSSize) -> NSImage {
        scene.apply(RowSnapshot(id: "sample", tokens: 80_000, state: state))
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        let v = scene.view
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        scene.tick(frame)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return NSImage(size: size) }
        host.cacheDisplay(in: host.bounds, to: rep)
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }
}
