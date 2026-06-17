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
    private var rowViews: [String: SessionRowView] = [:]
    private let header = NSTextField(labelWithString: "agent-island")

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
        if header.superview == nil {
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .tertiaryLabelColor
        }
        var ordered: [NSView] = [header]
        var seen = Set<String>()
        for row in rows {
            seen.insert(row.id)
            let view = rowViews[row.id] ?? {
                let v = SessionRowView()
                v.onToggle = { [weak self] in self?.resizeAndReposition() }
                rowViews[row.id] = v
                return v
            }()
            view.update(row)
            ordered.append(view)
        }
        // Collect stale ids first, then delete — don't mutate `rowViews` while iterating it.
        for id in rowViews.keys.filter({ !seen.contains($0) }) {
            rowViews[id]?.removeFromSuperview()
            rowViews.removeValue(forKey: id)
        }
        // Reorder the stack to match `ordered`, reusing existing arranged subviews.
        for v in stack.arrangedSubviews where !ordered.contains(v) { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, v) in ordered.enumerated() {
            if stack.arrangedSubviews.firstIndex(of: v) != i {
                stack.removeArrangedSubview(v)
                stack.insertArrangedSubview(v, at: i)
            }
        }
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

}

/// One reused-per-session row. Persists across refreshes so Core Animation loops aren't
/// reseated each tick, and so a state transition (e.g. -> finished) can fire a one-shot once.
final class SessionRowView: NSView {
    private let line = NSStackView()
    private let cue = NSView()            // fixed-size host for ring / idle dot (14x14)
    private let glyph = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let cell = NSStackView()
    private let subStack = NSStackView()
    private let disclosure = NSButton(title: "▸", target: nil, action: nil)
    private var expanded = false
    private var statusKey: String?       // "working" | "wait-stopped" | "wait-permission" | "finished" | "idle"

    var onToggle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 9
        line.translatesAutoresizingMaskIntoConstraints = false

        cue.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cue.widthAnchor.constraint(equalToConstant: 14),
            cue.heightAnchor.constraint(equalToConstant: 14),
        ])

        glyph.font = .systemFont(ofSize: 16)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        stateLabel.font = .systemFont(ofSize: 11, weight: .regular)

        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 1
        cell.addArrangedSubview(titleLabel)
        cell.addArrangedSubview(stateLabel)

        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.isBordered = false
        disclosure.font = .systemFont(ofSize: 9)
        disclosure.contentTintColor = .tertiaryLabelColor

        line.addArrangedSubview(disclosure)
        line.addArrangedSubview(cue)
        line.addArrangedSubview(glyph)
        line.addArrangedSubview(cell)

        subStack.orientation = .vertical
        subStack.alignment = .leading
        subStack.spacing = 2
        subStack.edgeInsets = NSEdgeInsets(top: 2, left: 28, bottom: 2, right: 0)
        subStack.isHidden = true

        let outer = NSStackView(views: [line, subStack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 4
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func toggle() {
        expanded.toggle()
        subStack.isHidden = !expanded
        disclosure.title = expanded ? "▾" : "▸"
        onToggle?()
    }

    func update(_ row: IslandPanel.Row) {
        titleLabel.stringValue = row.title
        titleLabel.textColor = row.dimmed ? .secondaryLabelColor : .labelColor
        stateLabel.stringValue = row.state
        stateLabel.textColor = row.dimmed ? .tertiaryLabelColor : row.color
        glyph.stringValue = row.glyph

        // Disclosure + sub-rows (rebuild contents each update; preserve expanded state).
        let hasSubs = !row.subRows.isEmpty
        disclosure.isHidden = !hasSubs
        subStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if hasSubs {
            for s in row.subRows {
                let sl = NSTextField(labelWithString: "\(s.glyph)  \(s.text)")
                sl.font = .systemFont(ofSize: 11)
                sl.textColor = .secondaryLabelColor
                subStack.addArrangedSubview(sl)
            }
            subStack.isHidden = !expanded
        } else {
            subStack.isHidden = true
        }
        applyAnimations(for: row)
    }

    private func applyAnimations(for row: IslandPanel.Row) {
        let key: String
        if row.id == "idle" { key = "idle" }
        else if row.spinning { key = "working" }
        else if row.waitReason == .permission { key = "wait-permission" }
        else if row.pulsing { key = "wait-stopped" }
        else if row.dimmed { key = "finished" }
        else { key = "neutral" }

        let became = (statusKey != key)
        let transitionedToFinished = became && key == "finished" && statusKey != nil

        if became {
            // Tear down the previous state's looping cues before installing the new ones.
            IslandAnimations.removeWorkingRing(from: cue)
            IslandAnimations.removeIdleDot(from: cue)
            IslandAnimations.stopPulse(on: glyph)

            switch key {
            case "working":
                glyph.isHidden = false
                IslandAnimations.installWorkingRing(on: cue)
            case "idle":
                glyph.isHidden = true
                IslandAnimations.installIdleDot(on: cue)
            case "wait-permission":
                glyph.isHidden = false
                IslandAnimations.startPulse(on: glyph, urgent: true)
            case "wait-stopped":
                glyph.isHidden = false
                IslandAnimations.startPulse(on: glyph, urgent: false)
            default:  // "finished", "neutral"
                glyph.isHidden = false
            }
            statusKey = key
        }

        if transitionedToFinished {
            IslandAnimations.celebrate(glyph, success: row.verdict != .failed)
        }
    }
}
