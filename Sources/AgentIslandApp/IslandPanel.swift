import AppKit
import QuartzCore
import AgentIslandCore

/// The always-on-top "island": a borderless, non-activating floating panel anchored at
/// the screen edge that never steals keyboard focus and stays visible over fullscreen
/// apps. Renders each session as a two-line cell — bold title (project name) + a
/// state line in the persona's color — with a persona glyph, a pulse on waiting rows,
/// dimmed "tombstone" styling for finished, and click-to-expand sub-agents.
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
        let id: String
        let glyph: String; let color: NSColor; let title: String; let state: String
        let pulsing: Bool; let spinning: Bool; let dimmed: Bool
        let waitReason: WaitReason?; let verdict: Verdict?; let subRows: [SubRow]
        init(id: String, glyph: String, color: NSColor, title: String, state: String,
             pulsing: Bool = false, spinning: Bool = false, dimmed: Bool = false,
             waitReason: WaitReason? = nil, verdict: Verdict? = nil, subRows: [SubRow] = []) {
            self.id = id; self.glyph = glyph; self.color = color; self.title = title; self.state = state
            self.pulsing = pulsing; self.spinning = spinning; self.dimmed = dimmed
            self.waitReason = waitReason; self.verdict = verdict; self.subRows = subRows
        }
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
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
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 13, left: 16, bottom: 13, right: 18)
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
        let header = NSTextField(labelWithString: "agent-island")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(header)
        for row in rows { stack.addArrangedSubview(sessionView(row)) }
        resizeAndReposition()
    }

    private func resizeAndReposition() {
        container.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        let size = NSSize(width: max(260, fitting.width), height: max(40, fitting.height))
        var frame = NSRect(origin: .zero, size: size)
        if let visible = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
        }
        setFrame(frame, display: true)
    }

    private func sessionView(_ row: Row) -> NSView {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 4

        let line = NSStackView()
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 9

        if !row.subRows.isEmpty {
            let disclosure = NSButton(title: "▸", target: self, action: #selector(toggleDisclosure(_:)))
            disclosure.isBordered = false
            disclosure.font = .systemFont(ofSize: 9)
            disclosure.contentTintColor = .tertiaryLabelColor
            line.addArrangedSubview(disclosure)
        }

        if row.spinning {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                spinner.widthAnchor.constraint(equalToConstant: 13),
                spinner.heightAnchor.constraint(equalToConstant: 13),
            ])
            spinner.startAnimation(nil)
            line.addArrangedSubview(spinner)
        }

        let glyph = NSTextField(labelWithString: row.glyph)
        glyph.font = .systemFont(ofSize: 16)
        line.addArrangedSubview(glyph)

        let cell = NSStackView()
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 1
        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = row.dimmed ? .secondaryLabelColor : .labelColor
        let state = NSTextField(labelWithString: row.state)
        state.font = .systemFont(ofSize: 11, weight: .regular)
        state.textColor = row.dimmed ? .tertiaryLabelColor : row.color
        cell.addArrangedSubview(title)
        cell.addArrangedSubview(state)
        line.addArrangedSubview(cell)

        outer.addArrangedSubview(line)

        if !row.subRows.isEmpty {
            let sub = NSStackView()
            sub.orientation = .vertical
            sub.alignment = .leading
            sub.spacing = 2
            sub.edgeInsets = NSEdgeInsets(top: 2, left: 28, bottom: 2, right: 0)
            for s in row.subRows {
                let sl = NSTextField(labelWithString: "\(s.glyph)  \(s.text)")
                sl.font = .systemFont(ofSize: 11)
                sl.textColor = .secondaryLabelColor
                sub.addArrangedSubview(sl)
            }
            sub.isHidden = true
            outer.addArrangedSubview(sub)
            if let disclosure = line.arrangedSubviews.first as? NSButton {
                disclosures[ObjectIdentifier(disclosure)] = sub
            }
        }

        if row.pulsing { addPulse(to: glyph) }
        return outer
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
        pulse.toValue = 0.4
        pulse.duration = 0.85
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        view.layer?.add(pulse, forKey: "pulse")
    }
}
