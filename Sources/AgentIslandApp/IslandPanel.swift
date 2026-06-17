import AppKit
import AgentIslandCore

/// A button that fires on the FIRST click even when its window isn't key. Required for controls
/// in a non-activating status-bar panel: by default `NSButton.acceptsFirstMouse` is false, so a
/// click while the app/panel is inactive is swallowed just to (try to) activate, and the action
/// never fires — which reads as "clicking does nothing."
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The always-on-top "island": a borderless, non-activating floating panel anchored at the
/// screen edge that never steals keyboard focus and stays visible over fullscreen apps.
///
/// Collapsed by default to a single clickable summary line; clicking the header toggles a
/// priority-ordered list (waiting-for-you → failed → running → finished) inside a height-capped
/// scroll view. Each row carries a per-state background tint and a CLI-style status cue: a
/// braille spinner while running, a blinking caret while waiting, a static ✓/✗/· otherwise. A
/// single shared ticker drives the motion (and is off when nothing animates / Reduce Motion).
final class IslandPanel: NSPanel {
    private let container = NSVisualEffectView()
    private let outerStack = NSStackView()          // vertical: [headerButton, scrollView]
    private let headerButton = FirstMouseButton()
    private let scrollView = NSScrollView()
    private let rowsStack = NSStackView()            // the scroll view's document view
    private var rowViews: [String: SessionRowView] = [:]
    private var lastRows: [Row] = []
    private var expanded: Bool

    private var scrollWidth: NSLayoutConstraint!
    private var scrollHeight: NSLayoutConstraint!
    private let maxRowsHeight: CGFloat = 260         // cap; rows beyond this scroll
    private static let expandedKey = "islandExpanded"

    private var ticker: Timer?                       // shared cue animator
    private var frameCount = 0
    private var theme: IslandTheme = Themes.named(UserDefaults.standard.string(forKey: "islandTheme"))

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
        let waitReason: WaitReason?; let verdict: Verdict?; let tokens: Int; let subRows: [SubRow]
        init(id: String, glyph: String, color: NSColor, title: String, state: String,
             spinning: Bool = false, dimmed: Bool = false,
             waitReason: WaitReason? = nil, verdict: Verdict? = nil, tokens: Int = 0, subRows: [SubRow] = []) {
            self.id = id; self.glyph = glyph; self.color = color; self.title = title; self.state = state
            self.spinning = spinning; self.dimmed = dimmed
            self.waitReason = waitReason; self.verdict = verdict; self.tokens = tokens; self.subRows = subRows
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
        // NOT movable-by-window-background — it intercepts header clicks, and the island
        // re-snaps to the top-right on every refresh anyway.
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true

        headerButton.isBordered = false
        headerButton.bezelStyle = .inline
        headerButton.setButtonType(.momentaryChange)
        headerButton.alignment = .left
        headerButton.focusRingType = .none
        headerButton.target = self
        headerButton.action = #selector(toggleCollapsed)
        headerButton.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
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

    /// Switch the animation theme (from the menu); re-render all rows with it.
    func setTheme(_ id: String) {
        theme = Themes.named(id)
        rowViews.values.forEach { $0.theme = theme }
        render()
    }

    private func render() {
        var ordered: [NSView] = []
        var seen = Set<String>()
        for row in lastRows {
            seen.insert(row.id)
            let view = rowViews[row.id] ?? {
                let v = SessionRowView()
                v.theme = theme
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
        // Only remove a CURRENTLY-arranged view — removeArrangedSubview on a non-arranged view
        // aborts the app on macOS 26+.
        for (i, v) in ordered.enumerated() {
            let current = rowsStack.arrangedSubviews.firstIndex(of: v)
            if current == i { continue }
            if current != nil { rowsStack.removeArrangedSubview(v) }
            rowsStack.insertArrangedSubview(v, at: min(i, rowsStack.arrangedSubviews.count))
        }

        headerButton.attributedTitle = headerTitle()
        scrollView.isHidden = !expanded
        resizeAndReposition()
        updateTicker()
    }

    /// Run the shared CLI ticker only while the list is expanded and a row actually animates
    /// (working spinner / waiting caret), and never under Reduce Motion.
    private func updateTicker() {
        let needs = expanded && !IslandAnimations.reduceMotion && rowViews.values.contains { $0.isAnimating }
        if needs {
            guard ticker == nil else { return }
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.frameCount &+= 1
                for v in self.rowViews.values { v.tick(self.frameCount) }
            }
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        } else {
            ticker?.invalidate()
            ticker = nil
        }
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
        let widest = max(headerButton.fittingSize.width, rowViews.values.map { $0.fittingSize.width }.max() ?? 0)
        scrollWidth.constant = min(max(240, widest), 460)
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

/// One reused-per-session row. Persists across refreshes so the CLI cue keeps ticking and the
/// expand state survives. Carries a per-state background tint + a monospace status indicator.
final class SessionRowView: NSView {
    private let line = NSStackView()
    private let indicator = NSTextField(labelWithString: "")   // CLI cue: spinner / caret / ✓ / ✗ / ·
    private let glyph = NSTextField(labelWithString: "")        // persona emoji
    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let cell = NSStackView()
    private let subStack = NSStackView()
    private let disclosure = FirstMouseButton(title: "▸", target: nil, action: nil)
    private var expanded = false
    private var currentRow: IslandPanel.Row?
    var theme: IslandTheme = JourneyTheme()

    var onToggle: (() -> Void)?
    var isAnimating: Bool { currentRow.map { theme.animates($0) } ?? false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 8
        line.translatesAutoresizingMaskIntoConstraints = false

        indicator.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setContentHuggingPriority(.required, for: .horizontal)   // size to content (1 char .. wide road bar)

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
        line.addArrangedSubview(indicator)
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
        outer.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 10)   // padding inside the tint
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
        glyph.isHidden = !theme.showsPersonaGlyph || row.glyph.isEmpty

        // Per-state background tint + the theme's status cue.
        currentRow = row
        layer?.backgroundColor = theme.tint(for: row).withAlphaComponent(0.13).cgColor
        renderIndicator(frame: 0)

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
    }

    /// Advance the cue one tick (called by the panel's shared ticker).
    func tick(_ frame: Int) { renderIndicator(frame: frame) }

    private func renderIndicator(frame: Int) {
        guard let row = currentRow else { return }
        let f = IslandAnimations.reduceMotion ? 0 : frame   // Reduce Motion → freeze on frame 0
        let cue = theme.indicator(for: row, frame: f)
        indicator.stringValue = cue.text
        indicator.textColor = cue.color
    }
}
