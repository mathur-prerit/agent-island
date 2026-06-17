import AppKit
import QuartzCore
import AgentIslandCore

/// The always-on-top "island": a borderless, non-activating floating panel anchored at the
/// screen edge that never steals keyboard focus and stays visible over fullscreen apps.
///
/// Collapsed by default to a single clickable summary line (e.g. "agent-island · ❗1 waiting ·
/// ◐2 running ▸"); clicking the header toggles a full, priority-ordered list inside a
/// height-capped scroll view, so it never eats the screen. Sessions sort needs-you → failed →
/// running → finished, and only the running rows animate — everything else is dimmed and still.
final class IslandPanel: NSPanel {
    private let container = NSVisualEffectView()
    private let outerStack = NSStackView()          // vertical: [headerButton, scrollView]
    private let headerButton = NSButton()
    private let scrollView = NSScrollView()
    private let rowsStack = NSStackView()            // the scroll view's document view
    private var rowViews: [String: SessionRowView] = [:]
    private var lastRows: [Row] = []
    private var expanded: Bool

    private var scrollWidth: NSLayoutConstraint!
    private var scrollHeight: NSLayoutConstraint!
    private let maxRowsHeight: CGFloat = 260         // cap; rows beyond this scroll
    private static let expandedKey = "islandExpanded"

    struct SubRow {
        let glyph: String; let color: NSColor; let text: String
        init(glyph: String, color: NSColor, text: String) {
            self.glyph = glyph; self.color = color; self.text = text
        }
    }

    struct Row {
        let id: String
        let glyph: String; let color: NSColor; let title: String; let state: String
        let spinning: Bool; let dimmed: Bool
        let waitReason: WaitReason?; let verdict: Verdict?; let subRows: [SubRow]
        init(id: String, glyph: String, color: NSColor, title: String, state: String,
             spinning: Bool = false, dimmed: Bool = false,
             waitReason: WaitReason? = nil, verdict: Verdict? = nil, subRows: [SubRow] = []) {
            self.id = id; self.glyph = glyph; self.color = color; self.title = title; self.state = state
            self.spinning = spinning; self.dimmed = dimmed
            self.waitReason = waitReason; self.verdict = verdict; self.subRows = subRows
        }
    }

    init() {
        expanded = UserDefaults.standard.bool(forKey: IslandPanel.expandedKey)  // default false = collapsed
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

        // Clickable header that toggles collapse/expand.
        headerButton.isBordered = false
        headerButton.bezelStyle = .inline
        headerButton.setButtonType(.momentaryChange)
        headerButton.alignment = .left
        headerButton.focusRingType = .none
        headerButton.target = self
        headerButton.action = #selector(toggleCollapsed)
        headerButton.translatesAutoresizingMaskIntoConstraints = false

        // Rows live in a vertical stack inside the scroll view (document view).
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = rowsStack
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            rowsStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        scrollWidth = scrollView.widthAnchor.constraint(equalToConstant: 260)
        scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([scrollWidth, scrollHeight])

        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 8
        outerStack.edgeInsets = NSEdgeInsets(top: 13, left: 16, bottom: 13, right: 18)
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.addArrangedSubview(headerButton)
        outerStack.addArrangedSubview(scrollView)
        container.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: container.topAnchor),
            outerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outerStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc private func toggleCollapsed() {
        expanded.toggle()
        UserDefaults.standard.set(expanded, forKey: IslandPanel.expandedKey)
        render()
    }

    func update(rows: [Row]) {
        lastRows = rows
        render()
    }

    private func render() {
        // Reconcile row views by session id into rowsStack, reusing instances so the running
        // row's Core Animation loop keeps running across refreshes and across collapse/expand.
        var ordered: [NSView] = []
        var seen = Set<String>()
        for row in lastRows {
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
        for id in rowViews.keys.filter({ !seen.contains($0) }) {
            rowViews[id]?.removeFromSuperview()
            rowViews.removeValue(forKey: id)
        }
        // Place each view at its target index. Only remove a CURRENTLY-arranged view — calling
        // removeArrangedSubview on a non-arranged view aborts the app on macOS 26+.
        for (i, v) in ordered.enumerated() {
            let current = rowsStack.arrangedSubviews.firstIndex(of: v)
            if current == i { continue }
            if current != nil { rowsStack.removeArrangedSubview(v) }
            rowsStack.insertArrangedSubview(v, at: min(i, rowsStack.arrangedSubviews.count))
        }

        headerButton.attributedTitle = headerTitle()
        scrollView.isHidden = !expanded
        resizeAndReposition()
    }

    private func headerTitle() -> NSAttributedString {
        let chevron = expanded ? "▾" : "▸"
        let text = expanded ? "agent-island  \(chevron)" : "\(collapsedSummary())  \(chevron)"
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// Compact one-line summary shown when collapsed, in priority order.
    private func collapsedSummary() -> String {
        if lastRows.isEmpty || (lastRows.count == 1 && lastRows[0].id == "idle") {
            return "agent-island · idle"
        }
        var waiting = 0, failed = 0, running = 0, finished = 0
        for r in lastRows {
            if r.spinning { running += 1 }
            else if r.waitReason != nil { waiting += 1 }
            else if r.verdict == .failed { failed += 1 }
            else { finished += 1 }
        }
        var parts: [String] = []
        if waiting > 0 { parts.append("❗\(waiting) waiting") }
        if failed > 0 { parts.append("✗\(failed) failed") }
        if running > 0 { parts.append("◐\(running) running") }
        if finished > 0 { parts.append("✓\(finished) done") }
        return parts.isEmpty ? "agent-island" : "agent-island · " + parts.joined(separator: " · ")
    }

    private func resizeAndReposition() {
        container.layoutSubtreeIfNeeded()
        // Width: fit the widest row (or the header), clamped to a sane band.
        let widest = max(headerButton.fittingSize.width, rowViews.values.map { $0.fittingSize.width }.max() ?? 0)
        scrollWidth.constant = min(max(240, widest), 460)
        // Height: cap the rows area so a long list scrolls instead of growing without bound.
        let rowsContentHeight = rowsStack.fittingSize.height
        scrollHeight.constant = expanded ? min(rowsContentHeight, maxRowsHeight) : 0
        container.layoutSubtreeIfNeeded()

        let fitting = outerStack.fittingSize
        let size = NSSize(width: max(220, fitting.width), height: max(36, fitting.height))
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
    private var statusKey: String?       // "working" | "static"

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
        // Only a running session animates; waiting / failed / finished / idle stay dimmed and
        // static (their importance is conveyed by sort position + dimming, not motion).
        let key = row.spinning ? "working" : "static"
        guard statusKey != key else { return }
        statusKey = key
        IslandAnimations.removeWorkingRing(from: cue)
        IslandAnimations.stopWorkingGlyph(on: glyph)
        if key == "working" {
            IslandAnimations.installWorkingRing(on: cue)   // hue-flowing spin + orbiting twinkle dot
            IslandAnimations.startWorkingGlyph(on: glyph)  // anchor-independent bob + opacity swell
        }
    }
}
