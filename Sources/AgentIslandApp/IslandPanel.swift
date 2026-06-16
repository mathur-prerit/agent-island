import AppKit
import QuartzCore

/// The always-on-top "island": a borderless, non-activating floating panel anchored at
/// the screen edge that never steals keyboard focus and stays visible over fullscreen
/// apps (the verified incantation). Renders per-session rows with a colored state dot +
/// persona glyph, a pulse on waiting rows, click-to-expand sub-agents, and a dimmed
/// "tombstone" style for finished sessions. Self-sizes to its content.
final class IslandPanel: NSPanel {
    private let container = NSVisualEffectView()
    private let stack = NSStackView()
    private var disclosures: [ObjectIdentifier: NSStackView] = [:]

    struct SubRow {
        let glyph: String; let color: NSColor; let text: String
        init(glyph: String, color: NSColor, text: String) {
            self.glyph = glyph; self.color = color; self.text = text
        }
    }

    struct Row {
        let glyph: String; let color: NSColor; let text: String
        let pulsing: Bool; let dimmed: Bool; let subRows: [SubRow]
        init(glyph: String, color: NSColor, text: String,
             pulsing: Bool = false, dimmed: Bool = false, subRows: [SubRow] = []) {
            self.glyph = glyph; self.color = color; self.text = text
            self.pulsing = pulsing; self.dimmed = dimmed; self.subRows = subRows
        }
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 80),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func update(rows: [Row]) {
        disclosures.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(headerLabel("◍ agent-island"))
        for row in rows { stack.addArrangedSubview(sessionView(row)) }
        resizeAndReposition()
    }

    private func resizeAndReposition() {
        container.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        let size = NSSize(width: max(300, fitting.width), height: max(40, fitting.height))
        var frame = NSRect(origin: .zero, size: size)
        if let visible = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
        }
        setFrame(frame, display: true)
    }

    private func sessionView(_ row: Row) -> NSView {
        let vertical = NSStackView()
        vertical.orientation = .vertical
        vertical.alignment = .leading
        vertical.spacing = 3

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        if !row.subRows.isEmpty {
            let disclosure = NSButton(title: "▸", target: self, action: #selector(toggleDisclosure(_:)))
            disclosure.isBordered = false
            disclosure.font = .systemFont(ofSize: 11)
            header.addArrangedSubview(disclosure)
        }
        header.addArrangedSubview(dot(row.color))
        header.addArrangedSubview(label("\(row.glyph)  \(row.text)",
                                        color: row.dimmed ? .secondaryLabelColor : row.color))
        vertical.addArrangedSubview(header)

        if !row.subRows.isEmpty {
            let sub = NSStackView()
            sub.orientation = .vertical
            sub.alignment = .leading
            sub.spacing = 2
            sub.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 2, right: 0)
            for s in row.subRows {
                sub.addArrangedSubview(label("\(s.glyph)  \(s.text)", color: s.color, size: 11))
            }
            sub.isHidden = true
            vertical.addArrangedSubview(sub)
            if let disclosure = header.arrangedSubviews.first as? NSButton {
                disclosures[ObjectIdentifier(disclosure)] = sub
            }
        }

        if row.pulsing { addPulse(to: header) }
        return vertical
    }

    @objc private func toggleDisclosure(_ sender: NSButton) {
        guard let sub = disclosures[ObjectIdentifier(sender)] else { return }
        sub.isHidden.toggle()
        sender.title = sub.isHidden ? "▸" : "▾"
        resizeAndReposition()
    }

    private func addPulse(to view: NSView) {
        view.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        view.layer?.add(pulse, forKey: "pulse")
    }

    private func dot(_ color: NSColor) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = color.cgColor
        v.layer?.cornerRadius = 4
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 8),
            v.heightAnchor.constraint(equalToConstant: 8),
        ])
        return v
    }

    private func headerLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func label(_ s: String, color: NSColor, size: CGFloat = 12) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        l.textColor = color
        return l
    }
}
