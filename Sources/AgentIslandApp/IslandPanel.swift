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

    // User-dragged position, stored as the TOP-LEFT corner so the island keeps its top edge put as
    // it grows/shrinks. nil = default top-right snap. `isProgrammaticMove` lets us ignore the
    // windowDidMove fired by our own setFrame (only real user drags should persist a position).
    private var userTopLeft: NSPoint?
    private var isProgrammaticMove = false
    private static let positionKey = "islandTopLeft"

    /// Called when the user dismisses a finished row (via its ✕). Wired to the app's dismiss set.
    var onDismiss: ((String) -> Void)?

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
        let detail: String?   // expanded-only session line (e.g. "📂 project"); also makes the row expandable
        init(id: String, glyph: String, color: NSColor, title: String, state: String,
             spinning: Bool = false, dimmed: Bool = false,
             waitReason: WaitReason? = nil, verdict: Verdict? = nil, tokens: Int = 0,
             subRows: [SubRow] = [], detail: String? = nil) {
            self.id = id; self.glyph = glyph; self.color = color; self.title = title; self.state = state
            self.spinning = spinning; self.dimmed = dimmed
            self.waitReason = waitReason; self.verdict = verdict; self.tokens = tokens; self.subRows = subRows
            self.detail = detail
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
        // Draggable from any background area (the controls — header, disclosure, ✕ — handle their
        // own clicks, so this doesn't swallow them). Once the user drags it, `windowDidMove`
        // records the spot and `resizeAndReposition` stops re-snapping to the top-right.
        isMovableByWindowBackground = true
        if let saved = UserDefaults.standard.string(forKey: IslandPanel.positionKey) {
            userTopLeft = NSPointFromString(saved)
        }
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
        delegate = self
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
                v.onDismiss = { [weak self] id in self?.onDismiss?(id) }
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
        isProgrammaticMove = true
        setFrame(NSRect(origin: desiredOrigin(for: size), size: size), display: true)
        isProgrammaticMove = false
    }

    /// Bottom-left origin for a given size: pinned under the user's dragged top-left corner if they
    /// moved it, else the default top-right. Always clamped to a visible screen so it can't get lost.
    private func desiredOrigin(for size: NSSize) -> NSPoint {
        let screen = screenForUserTopLeft() ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let topLeft = userTopLeft ?? NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - 16)
        let x = min(max(topLeft.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        let y = min(max(topLeft.y - size.height, visible.minY), max(visible.minY, visible.maxY - size.height))
        return NSPoint(x: x, y: y)
    }

    private func screenForUserTopLeft() -> NSScreen? {
        guard let tl = userTopLeft else { return nil }
        return NSScreen.screens.first { $0.frame.contains(NSPoint(x: tl.x, y: tl.y - 1)) }
    }

    /// Forget the dragged position and snap back to the default top-right.
    func resetPosition() {
        userTopLeft = nil
        UserDefaults.standard.removeObject(forKey: IslandPanel.positionKey)
        resizeAndReposition()
    }
}

extension IslandPanel: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove else { return }   // ignore our own setFrame; record only user drags
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        userTopLeft = topLeft
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: IslandPanel.positionKey)
    }
}

/// One reused-per-session row. Persists across refreshes so the CLI cue keeps ticking and the
/// expand state survives. Carries a per-state background tint + a monospace status indicator.
final class SessionRowView: NSView {
    private let line = NSStackView()
    // The status cue renders as exactly one of these (the others hidden): a monospace label
    // (Minimal CLI cues), a tintable icon (SF Symbol / traffic light), or the scrolling road scene.
    private let cueText = NSTextField(labelWithString: "")
    private let cueImage = NSImageView()
    private let cueRoad = RoadSceneView()
    private let glyph = NSTextField(labelWithString: "")        // persona emoji
    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let cell = NSStackView()
    private let subStack = NSStackView()
    private let disclosure = FirstMouseButton(title: "▸", target: nil, action: nil)
    private let closeButton = FirstMouseButton(title: "✕", target: nil, action: nil)  // dismiss a finished row
    private var expanded = false
    private var currentRow: IslandPanel.Row?
    var theme: IslandTheme = JourneyTheme()

    var onToggle: (() -> Void)?
    var onDismiss: ((String) -> Void)?
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

        cueText.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        cueText.translatesAutoresizingMaskIntoConstraints = false
        cueText.setContentHuggingPriority(.required, for: .horizontal)   // size to content
        cueImage.translatesAutoresizingMaskIntoConstraints = false
        cueImage.imageScaling = .scaleProportionallyUpOrDown
        cueImage.setContentHuggingPriority(.required, for: .horizontal)
        cueImage.isHidden = true
        // The road scene is a wide banner shown on its own row above the title — give it room so the
        // vehicle, milestone signs and signal all read distinctly (it's cramped beside the text).
        cueRoad.isHidden = true
        NSLayoutConstraint.activate([
            cueRoad.widthAnchor.constraint(equalToConstant: 290),
            cueRoad.heightAnchor.constraint(equalToConstant: 26),
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

        closeButton.target = self
        closeButton.action = #selector(dismissSelf)
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 10)
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.isHidden = true                  // only finished rows are dismissable
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        // Small inline cues (CLI spinner/caret, idle/finished icons) sit beside the title; the wide
        // road banner (cueRoad) lives on its own row above, added to `outer` below. The ✕ trails the
        // cell so a finished row can be removed.
        line.addArrangedSubview(disclosure)
        line.addArrangedSubview(cueText)
        line.addArrangedSubview(cueImage)
        line.addArrangedSubview(glyph)
        line.addArrangedSubview(cell)
        line.addArrangedSubview(closeButton)

        subStack.orientation = .vertical
        subStack.alignment = .leading
        subStack.spacing = 2
        subStack.edgeInsets = NSEdgeInsets(top: 2, left: 28, bottom: 2, right: 0)
        subStack.isHidden = true

        let outer = NSStackView(views: [cueRoad, line, subStack])
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

    @objc private func dismissSelf() { if let id = currentRow?.id { onDismiss?(id) } }

    func update(_ row: IslandPanel.Row) {
        titleLabel.stringValue = row.title
        titleLabel.textColor = row.dimmed ? .secondaryLabelColor : .labelColor
        stateLabel.stringValue = row.state
        stateLabel.textColor = row.dimmed ? .tertiaryLabelColor : row.color
        glyph.stringValue = row.glyph
        glyph.isHidden = !theme.showsPersonaGlyph || row.glyph.isEmpty

        // Per-state background tint + the theme's status cue.
        currentRow = row
        closeButton.isHidden = (row.verdict == nil)   // only finished/failed rows can be dismissed
        layer?.backgroundColor = theme.tint(for: row).withAlphaComponent(0.13).cgColor
        renderIndicator(frame: 0)

        // Disclosure + expanded detail: a session line (project name) plus rich sub-agent rows.
        // The row is expandable whenever there's any detail — so even a solo running session with
        // no sub-agents still gets a disclosure triangle.
        let hasDetail = (row.detail != nil) || !row.subRows.isEmpty
        disclosure.isHidden = !hasDetail
        subStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if hasDetail {
            if let detail = row.detail {
                let dl = NSTextField(labelWithString: detail)
                dl.font = .systemFont(ofSize: 11, weight: .medium)
                dl.textColor = .secondaryLabelColor
                subStack.addArrangedSubview(dl)
            }
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
        switch theme.cue(for: row, frame: f) {
        case let .text(s, color):
            cueText.stringValue = s
            cueText.textColor = color
            show(cueText)
        case let .icon(image, tint):
            cueImage.image = image
            cueImage.contentTintColor = tint   // nil → the image draws with its own colours
            show(cueImage)
        case let .road(tokens, mode):
            cueRoad.tokens = tokens
            cueRoad.mode = mode
            cueRoad.frame_ = f
            show(cueRoad)
        }
    }

    /// Show exactly one of the three cue subviews; hide the rest (NSStackView drops hidden views).
    private func show(_ view: NSView) {
        for v in [cueText, cueImage, cueRoad] as [NSView] { v.isHidden = (v !== view) }
    }
}
