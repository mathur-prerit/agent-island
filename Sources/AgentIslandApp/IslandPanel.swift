import AppKit

/// The always-on-top "island": a borderless, non-activating floating panel anchored at
/// the screen edge that never steals keyboard focus and stays visible over fullscreen
/// apps. Uses the verified AppKit incantation (see spike/FINDINGS.md / the plan):
/// `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded` + the canJoinAllSpaces /
/// fullScreenAuxiliary / stationary collection behaviors, shown via orderFrontRegardless.
final class IslandPanel: NSPanel {
    private let stack = NSStackView()

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

        let container = NSVisualEffectView()
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

    // A status display rarely needs focus; allow key only if a control needs it, and
    // never become main (both-true on a non-activating panel can crash — see findings).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    struct Row { let glyph: String; let color: NSColor; let text: String }

    func update(rows: [Row]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(label("◍ agent-island", color: .secondaryLabelColor, bold: true))
        for row in rows {
            stack.addArrangedSubview(label("\(row.glyph)  \(row.text)", color: row.color, bold: false))
        }
        layoutIfNeeded()
    }

    private func label(_ string: String, color: NSColor, bold: Bool) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = bold
            ? .systemFont(ofSize: 12, weight: .semibold)
            : .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = color
        return field
    }
}
