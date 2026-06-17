# State Animations, Waiting-State Clarity, Tokens & Daemon-Default — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent-island floating panel and menu-bar item vivid, Reduce-Motion-aware per-state animations; distinguish the two waiting states ("needs your action" vs "awaiting next prompt"); show per-session token usage; fix the `preritmathur` label bug; and make the event-driven daemon the default via a reversible first-launch setup.

**Architecture:** Pure, testable logic (token sums, label extraction, display priority) lives in `AgentIslandCore` and is covered by the framework-free self-test runner. The AppKit island switches from full teardown-per-refresh to **reconcile-by-id** (`SessionRowView` reused across refreshes) so Core Animation loops run uninterrupted and one-shot transitions fire exactly once. Animations are built in a focused `IslandAnimations` helper that gates on `accessibilityDisplayShouldReduceMotion`. The daemon becomes the default through `EventDrivenSetup`, which installs hooks (reusing the existing safe `SettingsFile`) and spawns `agentislandd`, with polling as the automatic fallback.

**Tech Stack:** Swift 6 / SwiftPM, AppKit + QuartzCore (Core Animation), `Foundation.JSONSerialization`, `NSWorkspace`, `Process`, `UserDefaults`. Tests: `swift run AgentIslandSelfTest` (no XCTest).

**Spec:** `docs/superpowers/specs/2026-06-17-state-animations-and-fixes-design.md`

**Conventions for every task below:**
- Build check: `swift build` (expect: `Build complete!`).
- Test check: `swift run AgentIslandSelfTest` (expect: `ALL PASS — N checks`, exit 0).
- Self-test checks are appended as top-level `check(<bool>, "<name>")` statements **immediately before** the `print("")` summary block at the end of `Sources/AgentIslandSelfTest/main.swift`.
- Commits are local only (do not push — not authorized per HANDOFF). Each commit trailer ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

> **Note on animation fidelity vs spec:** the spec's "shimmer sweeping the row / underline bar" is realized here as a **rotating conic aurora ring + lively colored text**, and idle "color drift" as a **color-cycling dot layer**. These operate on fixed-size elements and avoid fragile row-width layer-frame tracking in AppKit auto-layout. The result is still vivid; the full-width sweep can be revisited later if desired.

---

## Task 1: `TokenUsage.freshTokens` (Core, TDD)

**Files:**
- Create: `Sources/AgentIslandCore/TokenUsage.swift`
- Test: `Sources/AgentIslandSelfTest/main.swift`

- [ ] **Step 1: Write the failing test** (append before the `print("")` summary)

```swift
// --- Token usage ---
let usageLines = [
    #"{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":9999}}}"#,
    #"{"type":"user"}"#,
    "garbage{",
    #"{"type":"assistant","usage":{"input_tokens":10,"output_tokens":5}}"#,
]
check(TokenUsage.freshTokens(lines: usageLines) == 165, "freshTokens sums input+output across both usage shapes, ignoring cache")
check(TokenUsage.freshTokens(lines: []) == 0, "freshTokens empty -> 0")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift run AgentIslandSelfTest`
Expected: compile error — `cannot find 'TokenUsage' in scope`.

- [ ] **Step 3: Write the minimal implementation**

```swift
import Foundation

/// Sums token usage from a session transcript's assistant records.
public enum TokenUsage {
    /// "Fresh" tokens = `input_tokens + output_tokens` (cache create/read excluded).
    /// Tolerant of both the top-level `usage` shape and the nested `message.usage` shape.
    public static func freshTokens(lines: [String]) -> Int {
        var total = 0
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let usage = (obj["usage"] as? [String: Any])
                ?? ((obj["message"] as? [String: Any])?["usage"] as? [String: Any])
            guard let u = usage else { continue }
            let input = (u["input_tokens"] as? Int) ?? 0
            let output = (u["output_tokens"] as? Int) ?? 0
            total += input + output
        }
        return total
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift run AgentIslandSelfTest`
Expected: `ALL PASS — 84 checks` (82 + 2 new), exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentIslandCore/TokenUsage.swift Sources/AgentIslandSelfTest/main.swift
git commit -m "feat(core): TokenUsage.freshTokens — sum input+output per transcript"
```

---

## Task 2: `TokenUsage.compact` formatting (Core, TDD)

**Files:**
- Modify: `Sources/AgentIslandCore/TokenUsage.swift`
- Test: `Sources/AgentIslandSelfTest/main.swift`

- [ ] **Step 1: Write the failing test** (append before the summary)

```swift
check(TokenUsage.compact(999) == "999", "compact < 1000 is raw")
check(TokenUsage.compact(1500) == "1.5k", "compact thousands one-decimal")
check(TokenUsage.compact(146_000) == "146k", "compact tens-of-thousands integer k")
check(TokenUsage.compact(2_870_000) == "2.9M", "compact millions one-decimal")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift run AgentIslandSelfTest`
Expected: compile error — `type 'TokenUsage' has no member 'compact'`.

- [ ] **Step 3: Add the method to `TokenUsage`**

```swift
    /// Compact label: `<1000 -> "N"`, `<10k -> "N.Nk"`, `<1M -> "Nk"`, else `"N.NM"`.
    public static func compact(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 {
            let k = Double(n) / 1_000
            return k < 10 ? String(format: "%.1fk", k) : "\(Int(k.rounded()))k"
        }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift run AgentIslandSelfTest`
Expected: `ALL PASS — 88 checks`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentIslandCore/TokenUsage.swift Sources/AgentIslandSelfTest/main.swift
git commit -m "feat(core): TokenUsage.compact — human token labels (146k, 2.9M)"
```

---

## Task 3: `ProjectLabel.fromTranscript` — label bug fix (Core, TDD)

**Files:**
- Create: `Sources/AgentIslandCore/ProjectLabel.swift`
- Test: `Sources/AgentIslandSelfTest/main.swift`

- [ ] **Step 1: Write the failing test** (append before the summary)

```swift
// --- Project label (uses LAST cwd, not first — fixes the "preritmathur" bug) ---
let cwdLines = [
    #"{"type":"user","cwd":"/Users/preritmathur"}"#,
    #"{"type":"assistant"}"#,
    #"{"type":"user","cwd":"/Users/preritmathur/projects/prerit/agent-island"}"#,
]
check(ProjectLabel.fromTranscript(lines: cwdLines) == "agent-island", "label uses last cwd (project), not first (launch dir)")
check(ProjectLabel.fromTranscript(lines: [#"{"type":"user"}"#]) == nil, "label nil when no cwd present")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift run AgentIslandSelfTest`
Expected: compile error — `cannot find 'ProjectLabel' in scope`.

- [ ] **Step 3: Write the minimal implementation**

```swift
import Foundation

/// Derives a friendly session label from the transcript's working directory.
public enum ProjectLabel {
    /// `lastPathComponent` of the **last** `cwd` recorded — the real project dir even when
    /// Claude Code was launched elsewhere (e.g. the home dir) and `cd`'d in later.
    /// Returns nil if no usable `cwd` is present.
    public static func fromTranscript(lines: [String]) -> String? {
        var lastCwd: String?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty
            else { continue }
            lastCwd = cwd
        }
        guard let cwd = lastCwd else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift run AgentIslandSelfTest`
Expected: `ALL PASS — 90 checks`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentIslandCore/ProjectLabel.swift Sources/AgentIslandSelfTest/main.swift
git commit -m "fix(core): derive session label from last cwd, not launch dir"
```

---

## Task 4: `DisplayPriority.rank` — needs-you-first ordering (Core, TDD)

**Files:**
- Create: `Sources/AgentIslandCore/DisplayPriority.swift`
- Test: `Sources/AgentIslandSelfTest/main.swift`

- [ ] **Step 1: Write the failing test** (append before the summary)

```swift
// --- Display priority: states that need you float to the top ---
check(DisplayPriority.rank(.waitingForInput(.permission)) < DisplayPriority.rank(.waitingForInput(.stoppedTurn)), "permission outranks stopped-turn waiting")
check(DisplayPriority.rank(.waitingForInput(.stoppedTurn)) < DisplayPriority.rank(.working), "any waiting outranks working")
check(DisplayPriority.rank(.working) < DisplayPriority.rank(.finished(.success)), "working outranks finished")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift run AgentIslandSelfTest`
Expected: compile error — `cannot find 'DisplayPriority' in scope`.

- [ ] **Step 3: Write the minimal implementation**

```swift
import Foundation

/// Island ordering: the most action-demanding states float to the top.
public enum DisplayPriority {
    /// Lower rank = higher in the list.
    /// permission (blocked, needs you) < stopped-turn (awaiting prompt) < working < finished.
    public static func rank(_ status: AgentStatus) -> Int {
        switch status {
        case .waitingForInput(.permission):  return 0
        case .waitingForInput(.stoppedTurn): return 1
        case .working:                       return 2
        case .finished:                      return 3
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift run AgentIslandSelfTest`
Expected: `ALL PASS — 93 checks`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentIslandCore/DisplayPriority.swift Sources/AgentIslandSelfTest/main.swift
git commit -m "feat(core): DisplayPriority.rank — needs-you states sort first"
```

---

## Task 5: Wire `main.swift` to Core helpers — label fix + tokens + ordering

**Files:**
- Modify: `Sources/AgentIslandApp/main.swift`

- [ ] **Step 1: Add `tokens` to the `Session` struct** (`main.swift:25-28`)

Replace:
```swift
    private struct Session {
        let fullID: String; let shortID: String; let label: String
        let status: AgentStatus; let subStatuses: [AgentStatus]; let steps: Int
    }
```
with:
```swift
    private struct Session {
        let fullID: String; let shortID: String; let label: String
        let status: AgentStatus; let subStatuses: [AgentStatus]; let steps: Int
        let tokens: Int
    }
```

- [ ] **Step 2: Fix the label + compute tokens in `polledSessions`** (`main.swift:153-157`)

Replace:
```swift
                let steps = records.reduce(0) { $0 + $1.assistantBlockKinds.filter { $0 == "tool_use" }.count }
                let fullID = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                let label = projectName(fromLines: lines) ?? String(fullID.prefix(8))
                found.append((Session(fullID: fullID, shortID: String(fullID.prefix(8)),
                                      label: label, status: rolled, subStatuses: subs, steps: steps), mtime))
```
with:
```swift
                let steps = records.reduce(0) { $0 + $1.assistantBlockKinds.filter { $0 == "tool_use" }.count }
                let tokens = TokenUsage.freshTokens(lines: lines)
                let fullID = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                let label = ProjectLabel.fromTranscript(lines: lines) ?? String(fullID.prefix(8))
                found.append((Session(fullID: fullID, shortID: String(fullID.prefix(8)),
                                      label: label, status: rolled, subStatuses: subs, steps: steps,
                                      tokens: tokens), mtime))
```

- [ ] **Step 3: Order by priority, then recency** (`main.swift:160`)

Replace:
```swift
        return found.sorted { $0.mtime > $1.mtime }.map(\.session)
```
with:
```swift
        return found
            .sorted {
                let ra = DisplayPriority.rank($0.session.status), rb = DisplayPriority.rank($1.session.status)
                return ra != rb ? ra < rb : $0.mtime > $1.mtime
            }
            .map(\.session)
```

- [ ] **Step 4: Set `tokens: 0` on the daemon path** (`main.swift:130-131`)

Replace:
```swift
            return Session(fullID: snap.sessionID, shortID: short, label: short,
                           status: AgentStatus(stateToken: snap.state), subStatuses: subs, steps: 0)
```
with:
```swift
            return Session(fullID: snap.sessionID, shortID: short, label: short,
                           status: AgentStatus(stateToken: snap.state), subStatuses: subs, steps: 0,
                           tokens: 0)
```

- [ ] **Step 5: Delete the now-unused `projectName(fromLines:)`** (`main.swift:181-191`)

Remove the entire method:
```swift
    /// Friendly label from the transcript's cwd (the project folder), else a short id.
    private func projectName(fromLines lines: [String]) -> String? {
        for line in lines.prefix(80) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            let name = (cwd as NSString).lastPathComponent
            return name.isEmpty ? nil : name
        }
        return nil
    }
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: `Build complete!` (no unused-function or missing-arg errors).

- [ ] **Step 7: Manual verify**

Run: `swift run AgentIslandApp`. The previously-mislabeled row should now read the real project folder name (e.g. `agent-island`, not `preritmathur`). Rows that need you (waiting) appear above working rows. Quit with the menu-bar item.

- [ ] **Step 8: Commit**

```bash
git add Sources/AgentIslandApp/main.swift
git commit -m "fix(app): correct project label, compute fresh tokens, order needs-you first"
```

---

## Task 6: Row model + per-state display (id, waitReason, verdict, steps·tok, permission marker, colors)

**Files:**
- Modify: `Sources/AgentIslandApp/IslandPanel.swift` (Row struct + import)
- Modify: `Sources/AgentIslandApp/main.swift` (row construction, colors, state text)

- [ ] **Step 1: Import Core + extend `Row` in `IslandPanel.swift`**

At the top of `IslandPanel.swift`, after `import QuartzCore`, add:
```swift
import AgentIslandCore
```

Replace the `Row` struct (`IslandPanel.swift:21-29`) with:
```swift
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
```

- [ ] **Step 2: Differentiate colors by wait reason in `main.swift`** (`main.swift:196-203`)

Replace:
```swift
    private func color(_ s: AgentStatus) -> NSColor {
        switch s {
        case .working: return .systemYellow
        case .waitingForInput: return .systemRed
        case .finished(.failed): return .systemRed
        case .finished: return .systemGreen
        }
    }
```
with:
```swift
    private func color(_ s: AgentStatus) -> NSColor {
        switch s {
        case .working: return .systemTeal
        case .waitingForInput(.permission): return .systemOrange
        case .waitingForInput(.stoppedTurn): return .systemRed
        case .finished(.failed): return .systemRed
        case .finished: return .systemGreen
        }
    }
    private func waitReason(_ s: AgentStatus) -> WaitReason? {
        if case .waitingForInput(let r) = s { return r } else { return nil }
    }
    private func verdict(_ s: AgentStatus) -> Verdict? {
        if case .finished(let v) = s { return v } else { return nil }
    }
```

- [ ] **Step 3: Build the state text (steps · tok, permission marker) and pass new fields** (`main.swift:72-87`)

Replace the `if sessions.isEmpty { … } else { … }` row-building block with:
```swift
            if sessions.isEmpty {
                rows = [IslandPanel.Row(id: "idle", glyph: "·", color: .tertiaryLabelColor,
                                        title: "idle", state: "no active sessions (last 30 min)")]
            } else {
                rows = sessions.map { s -> IslandPanel.Row in
                    let skin = persona(for: s).skin(for: s.status)
                    let isWorking = (s.status == .working)
                    let reason = waitReason(s.status)
                    var parts: [String] = [skin.label]
                    if isWorking && s.steps > 0 { parts.append("\(s.steps) steps") }
                    if !isFinished(s.status) && s.tokens > 0 { parts.append("\(TokenUsage.compact(s.tokens)) tok") }
                    var stateText = parts.joined(separator: " · ")
                    if reason == .permission { stateText = "❗ " + stateText }
                    let subRows = s.subStatuses.map {
                        IslandPanel.SubRow(glyph: "↳", color: color($0), text: subDescribe($0))
                    }
                    return IslandPanel.Row(id: s.fullID, glyph: skin.glyph, color: color(s.status),
                                           title: s.label, state: stateText,
                                           pulsing: isWaiting(s.status), spinning: isWorking,
                                           dimmed: isFinished(s.status),
                                           waitReason: reason, verdict: verdict(s.status), subRows: subRows)
                }
            }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`

> Note: `IslandPanel.sessionView` still references the old `Row` initializer fields it uses (`glyph`, `color`, `title`, `state`, `pulsing`, `spinning`, `dimmed`, `subRows`) — all still present, so it compiles unchanged. `waitReason`/`verdict` are wired into the view in Task 9.

- [ ] **Step 5: Manual verify**

Run: `swift run AgentIslandApp`. Working rows show `… · N steps · 146k tok`; waiting rows show `… · 146k tok`. (Permission `❗` and finished rows are exercised in daemon mode, Tasks 11–12.)

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentIslandApp/IslandPanel.swift Sources/AgentIslandApp/main.swift
git commit -m "feat(app): row id + wait-reason/verdict, steps·tok line, per-reason colors"
```

---

## Task 7: `IslandAnimations` — animation builders + Reduce-Motion gate

**Files:**
- Create: `Sources/AgentIslandApp/IslandAnimations.swift`

- [ ] **Step 1: Write the full helper**

```swift
import AppKit
import QuartzCore

/// Core Animation builders for island state cues. Every motion is gated on Reduce Motion:
/// when it's on, colors still apply but loops/pops are skipped.
enum IslandAnimations {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static let aurora: [CGColor] = [
        NSColor.systemTeal.cgColor, NSColor.systemBlue.cgColor, NSColor.systemIndigo.cgColor,
        NSColor.systemPurple.cgColor, NSColor.systemPink.cgColor, NSColor.systemTeal.cgColor,
    ]
    private static let idleHues: [CGColor] = [
        NSColor.systemTeal.cgColor, NSColor.systemBlue.cgColor,
        NSColor.systemPurple.cgColor, NSColor.systemTeal.cgColor,
    ]

    // MARK: Working — rotating conic aurora ring on a fixed-size host (14x14)

    static func installWorkingRing(on host: NSView) {
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        if layer.sublayers?.contains(where: { $0.name == "aurora-ring" }) == true { return }
        let size: CGFloat = 14, lw: CGFloat = 2.4
        let ring = CAGradientLayer()
        ring.name = "aurora-ring"
        ring.type = .conic
        ring.frame = CGRect(x: 0, y: 0, width: size, height: size)
        ring.colors = aurora
        ring.startPoint = CGPoint(x: 0.5, y: 0.5)
        ring.endPoint = CGPoint(x: 0.5, y: 0.0)
        let donut = CAShapeLayer()
        donut.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: lw / 2, dy: lw / 2), transform: nil)
        donut.fillColor = NSColor.clear.cgColor
        donut.strokeColor = NSColor.black.cgColor
        donut.lineWidth = lw
        ring.mask = donut
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.position = CGPoint(x: size / 2, y: size / 2)
        layer.addSublayer(ring)
        guard !reduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0.0
        spin.toValue = 2.0 * Double.pi
        spin.duration = 2.0
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
    }

    static func removeWorkingRing(from host: NSView) {
        host.layer?.sublayers?.filter { $0.name == "aurora-ring" }.forEach { $0.removeFromSuperlayer() }
    }

    // MARK: Waiting — breathing opacity pulse (faster + scale for the urgent permission case)

    static func startPulse(on view: NSView, urgent: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        guard !reduceMotion else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1.0
        opacity.toValue = urgent ? 0.25 : 0.5
        opacity.duration = urgent ? 0.5 : 0.85
        opacity.autoreverses = true
        opacity.repeatCount = .infinity
        layer.add(opacity, forKey: "pulse")
        guard urgent else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.12
        scale.duration = 0.5
        scale.autoreverses = true
        scale.repeatCount = .infinity
        layer.add(scale, forKey: "pulse-scale")
    }

    static func stopPulse(on view: NSView) {
        view.layer?.removeAnimation(forKey: "pulse")
        view.layer?.removeAnimation(forKey: "pulse-scale")
    }

    // MARK: Finished — one-shot pop (success) or shake (failed) + colored glow

    static func celebrate(_ view: NSView, success: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer, !reduceMotion else { return }
        let color = (success ? NSColor.systemGreen : NSColor.systemRed).cgColor
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let motion = CAKeyframeAnimation(keyPath: success ? "transform.scale" : "position.x")
        if success {
            motion.values = [1.0, 1.28, 1.0]
            motion.keyTimes = [0, 0.4, 1.0]
        } else {
            let x = layer.position.x
            motion.values = [x, x - 4, x + 4, x - 2, x]
            motion.keyTimes = [0, 0.2, 0.5, 0.8, 1.0]
        }
        motion.duration = 0.55
        layer.add(motion, forKey: "celebrate-motion")
        layer.shadowColor = color
        layer.shadowRadius = 8
        layer.shadowOffset = .zero
        layer.shadowOpacity = 0
        let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glow.values = [0.0, 0.9, 0.0]
        glow.duration = 0.7
        layer.add(glow, forKey: "celebrate-glow")
    }

    // MARK: Idle — slow color-cycling dot on a fixed-size host (10x10)

    static func installIdleDot(on host: NSView) {
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        if layer.sublayers?.contains(where: { $0.name == "idle-dot" }) == true { return }
        let size: CGFloat = 8
        let dot = CALayer()
        dot.name = "idle-dot"
        dot.frame = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = size / 2
        dot.backgroundColor = idleHues.first
        layer.addSublayer(dot)
        guard !reduceMotion else { return }
        let cycle = CAKeyframeAnimation(keyPath: "backgroundColor")
        cycle.values = idleHues
        cycle.duration = 6.0
        cycle.repeatCount = .infinity
        dot.add(cycle, forKey: "idle-cycle")
    }

    static func removeIdleDot(from host: NSView) {
        host.layer?.sublayers?.filter { $0.name == "idle-dot" }.forEach { $0.removeFromSuperlayer() }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/AgentIslandApp/IslandAnimations.swift
git commit -m "feat(app): IslandAnimations — aurora ring, pulse, celebrate, idle dot (reduce-motion aware)"
```

---

## Task 8: Reconcile-by-id rendering — `SessionRowView` + reused rows

**Files:**
- Modify: `Sources/AgentIslandApp/IslandPanel.swift`

This task introduces `SessionRowView` and rewrites `update(rows:)` to reuse views by `id`. Animations are wired in Task 9; here the view renders text/colors/sub-rows correctly and persists across refreshes.

- [ ] **Step 1: Add the `SessionRowView` class** (append at the end of `IslandPanel.swift`, after the closing brace of `IslandPanel`)

```swift
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
    private var disclosure: NSButton?
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

        let disc = NSButton(title: "▸", target: self, action: #selector(toggle))
        disc.isBordered = false
        disc.font = .systemFont(ofSize: 9)
        disc.contentTintColor = .tertiaryLabelColor
        disclosure = disc

        line.addArrangedSubview(disc)
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
        disclosure?.title = expanded ? "▾" : "▸"
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
        disclosure?.isHidden = !hasSubs
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
        // Task 9 reconfigures animations from `row` + `statusKey` here.
        applyAnimations(for: row)
    }

    // Replaced with full body in Task 9.
    private func applyAnimations(for row: IslandPanel.Row) {}
}
```

- [ ] **Step 2: Replace `IslandPanel`'s view storage and `update(rows:)`**

In `IslandPanel`, replace the stored properties (`IslandPanel.swift:10-12`):
```swift
    private let container = NSVisualEffectView()
    private let stack = NSStackView()
    private var disclosures: [ObjectIdentifier: NSStackView] = [:]
```
with:
```swift
    private let container = NSVisualEffectView()
    private let stack = NSStackView()
    private var rowViews: [String: SessionRowView] = [:]
    private let header = NSTextField(labelWithString: "agent-island")
```

Replace `update(rows:)` (`IslandPanel.swift:70-79`) with:
```swift
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
        for (id, view) in rowViews where !seen.contains(id) {
            view.removeFromSuperview()
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
```

- [ ] **Step 3: Delete the now-dead `sessionView`, `toggleDisclosure`, and `addPulse`** (`IslandPanel.swift:92-184`)

Remove the methods `sessionView(_:)`, `@objc toggleDisclosure(_:)`, and `addPulse(to:)` in their entirety — their responsibilities now live in `SessionRowView` and `IslandAnimations`. (Keep `resizeAndReposition()`.)

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!` (resolve any leftover references to the deleted methods).

- [ ] **Step 5: Manual verify (reconciliation is the key thing)**

Run: `swift run AgentIslandApp`. Rows render with glyph/title/state; clicking `▸` expands sub-agents and the panel resizes; across the ~3s refresh the rows update **in place** without flicker, and an expanded row stays expanded.

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentIslandApp/IslandPanel.swift
git commit -m "refactor(app): reconcile island rows by session id (SessionRowView reuse)"
```

---

## Task 9: Wire per-state animations into `SessionRowView`

**Files:**
- Modify: `Sources/AgentIslandApp/IslandPanel.swift` (`SessionRowView.applyAnimations`)

- [ ] **Step 1: Replace the stub `applyAnimations(for:)`** with the full body

```swift
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
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Manual verify (polling-reachable states)**

Run: `swift run AgentIslandApp` while you have at least one active Claude Code session.
- A **working** session shows the rotating aurora ring (replacing the old gray spinner) next to a teal state line.
- A **stopped/waiting** session's glyph breathes gently.
- With **no** active sessions, the idle row shows a slow color-cycling dot.
- Turn on System Settings ▸ Accessibility ▸ Display ▸ **Reduce motion**, relaunch: colors remain, motion stops.

(The urgent **permission** pulse and the **finished** pop are reachable once the daemon is the default — Tasks 11–12.)

- [ ] **Step 4: Commit**

```bash
git add Sources/AgentIslandApp/IslandPanel.swift
git commit -m "feat(app): per-state island animations (working ring, urgent/stopped pulse, done pop, idle dot)"
```

---

## Task 10: Colorize + pulse the menu-bar glyph

**Files:**
- Modify: `Sources/AgentIslandApp/main.swift` (`refresh`, `main.swift:66-68`)

- [ ] **Step 1: Replace the plain-title menu-bar update**

Replace:
```swift
        let waiting = sessions.filter { isWaiting($0.status) }.count
        let working = sessions.contains { $0.status == .working }
        statusItem.button?.title = waiting > 0 ? "● \(waiting)" : (working ? "◐" : "○")
```
with:
```swift
        let waiting = sessions.filter { isWaiting($0.status) }.count
        let working = sessions.contains { $0.status == .working }
        let glyph: String
        let glyphColor: NSColor
        if waiting > 0 { glyph = "● \(waiting)"; glyphColor = .systemRed }
        else if working { glyph = "◐"; glyphColor = .systemTeal }
        else { glyph = "○"; glyphColor = .secondaryLabelColor }
        if let button = statusItem.button {
            button.attributedTitle = NSAttributedString(
                string: glyph,
                attributes: [.foregroundColor: glyphColor, .font: NSFont.systemFont(ofSize: 13)])
            button.wantsLayer = true
            if waiting > 0 && !IslandAnimations.reduceMotion {
                if button.layer?.animation(forKey: "menu-pulse") == nil {
                    let p = CABasicAnimation(keyPath: "opacity")
                    p.fromValue = 1.0; p.toValue = 0.45
                    p.duration = 0.8; p.autoreverses = true; p.repeatCount = .infinity
                    button.layer?.add(p, forKey: "menu-pulse")
                }
            } else {
                button.layer?.removeAnimation(forKey: "menu-pulse")
            }
        }
```

- [ ] **Step 2: Add the QuartzCore import** (top of `main.swift`, after `import Foundation`)

```swift
import QuartzCore
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Manual verify**

Run: `swift run AgentIslandApp`. The menu-bar glyph is teal while working, red and gently pulsing while a session waits, gray when idle.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentIslandApp/main.swift
git commit -m "feat(app): colorize menu-bar glyph by state + pulse when waiting"
```

---

## Task 11: Add `HookInstall` dependency + `EventDrivenSetup` (paths + ensure-daemon + hooks)

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AgentIslandApp/EventDrivenSetup.swift`

- [ ] **Step 1: Add `HookInstall` to the app target** (`Package.swift`, `AgentIslandApp` executableTarget)

Replace:
```swift
        .executableTarget(name: "AgentIslandApp", dependencies: ["AgentIslandCore", "PersonaKit", "AgentIslandDaemon"]),
```
with:
```swift
        .executableTarget(name: "AgentIslandApp", dependencies: ["AgentIslandCore", "PersonaKit", "AgentIslandDaemon", "HookInstall"]),
```

- [ ] **Step 2: Write `EventDrivenSetup.swift`**

```swift
import Foundation
import HookInstall

/// Makes event-driven mode (daemon + hooks) the default, reversibly. The relay command and
/// daemon spawn need absolute paths to the sibling executables; we resolve them from the
/// running app's executable directory (works for `swift run` and the bundled .app). If they
/// can't be found, every entry point no-ops so the app simply stays on polling.
enum EventDrivenSetup {
    static let events = ["UserPromptSubmit", "Stop", "SubagentStart", "SubagentStop",
                         "PermissionRequest", "SessionStart", "SessionEnd"]
    static let settingsPath = ("~/.claude/settings.json" as NSString).expandingTildeInPath
    static let statePath = ("~/.agent-island/state.json" as NSString).expandingTildeInPath

    private static func binDir() -> String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return (exe as NSString).deletingLastPathComponent
    }
    private static func sibling(_ name: String) -> String? {
        let p = binDir() + "/" + name
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
    static func hookBinary() -> String? { sibling("AgentIslandHookCLI") }
    static func daemonBinary() -> String? { sibling("agentislandd") }

    /// Hooks + daemon binaries both present → auto-setup is possible.
    static var available: Bool { hookBinary() != nil && daemonBinary() != nil }

    private static func relayCommand() -> String? {
        guard let hook = hookBinary() else { return nil }
        return "\"\(hook)\" relay"  // quoted: the path may contain spaces
    }

    static func installHooks() throws {
        guard let cmd = relayCommand() else { throw SettingsFile.FileError.writeFailed }
        try SettingsFile.install(settingsPath: settingsPath, command: cmd, events: events)
    }
    static func uninstallHooks() throws {
        guard let cmd = relayCommand() else { return }
        try SettingsFile.uninstall(settingsPath: settingsPath, command: cmd)
    }

    /// Spawn `agentislandd` if its state file isn't fresh (a fresh file ⇒ already running).
    /// A duplicate instance fails to bind the socket and exits, so this is safe to call often.
    static func ensureDaemonRunning() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: statePath),
           let m = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(m) < 30 { return }
        guard let bin = daemonBinary() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/AgentIslandApp/EventDrivenSetup.swift
git commit -m "feat(app): EventDrivenSetup — resolve sibling binaries, install hooks, ensure daemon"
```

---

## Task 12: First-launch consent + Enable/Disable menu items

**Files:**
- Modify: `Sources/AgentIslandApp/main.swift`

- [ ] **Step 1: Offer setup once on launch** — add a call at the end of `start()` (`main.swift:44`, after `timer = t`)

```swift
        maybeOfferEventDrivenSetup()
```

- [ ] **Step 2: Add the consent + control methods** (inside `AppController`, e.g. after `toggleIsland`)

```swift
    private let eventModeKey = "eventDrivenSetupDecision"  // "enabled" | "declined" | "error"

    private func maybeOfferEventDrivenSetup() {
        let defaults = UserDefaults.standard
        if let decision = defaults.string(forKey: eventModeKey) {
            if decision == "enabled" { EventDrivenSetup.ensureDaemonRunning() }
            return
        }
        guard EventDrivenSetup.available else { return }  // e.g. `swift run` without `swift build`
        let alert = NSAlert()
        alert.messageText = "Enable event-driven mode?"
        alert.informativeText = "agent-island can update instantly by adding small hooks to "
            + "~/.claude/settings.json (reversible) and running a tiny background daemon. "
            + "Otherwise it polls your transcripts every few seconds."
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try EventDrivenSetup.installHooks()
                EventDrivenSetup.ensureDaemonRunning()
                defaults.set("enabled", forKey: eventModeKey)
            } catch {
                defaults.set("error", forKey: eventModeKey)
            }
        } else {
            defaults.set("declined", forKey: eventModeKey)
        }
    }

    @objc private func toggleEventMode() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: eventModeKey) == "enabled" {
            try? EventDrivenSetup.uninstallHooks()
            defaults.set("declined", forKey: eventModeKey)
        } else {
            guard EventDrivenSetup.available else { return }
            do {
                try EventDrivenSetup.installHooks()
                EventDrivenSetup.ensureDaemonRunning()
                defaults.set("enabled", forKey: eventModeKey)
            } catch { defaults.set("error", forKey: eventModeKey) }
        }
        refresh()
    }
```

- [ ] **Step 3: Add the menu item** — in `refresh()`, after the "Show floating island" toggle is added (`main.swift:60`)

```swift
        let eventOn = UserDefaults.standard.string(forKey: eventModeKey) == "enabled"
        let eventToggle = NSMenuItem(title: "Event-driven mode", action: #selector(toggleEventMode), keyEquivalent: "")
        eventToggle.target = self
        eventToggle.isEnabled = EventDrivenSetup.available || eventOn
        eventToggle.state = eventOn ? .on : .off
        menu.addItem(eventToggle)
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Manual verify (the full experience)**

```bash
swift build                 # builds ALL products so the sibling binaries exist
swift run AgentIslandApp     # first launch → consent dialog
```
- Click **Enable**. Confirm `~/.claude/settings.json` gained the hooks (and a `.bak` was written), and `~/.agent-island/state.json` appears/updates.
- Trigger a permission prompt in a Claude Code session → its island row turns urgent (`❗`, orange, faster pulse) and sorts to the top.
- End a session → the row shows the green pop, then dims.
- Menu ▸ **Event-driven mode** toggles off → hooks removed from settings.json; app falls back to polling.

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentIslandApp/main.swift
git commit -m "feat(app): first-launch consent for event-driven mode + menu toggle"
```

---

## Task 13: Bundle the daemon + hook binaries in `build-app.sh`

**Files:**
- Modify: `Scripts/build-app.sh`

- [ ] **Step 1: Build all three products and copy the siblings into the bundle**

Replace:
```bash
echo "Building AgentIslandApp (release)…"
swift build -c release --product AgentIslandApp

APP="$ROOT/build/AgentIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/AgentIslandApp" "$APP/Contents/MacOS/AgentIsland"
```
with:
```bash
echo "Building AgentIslandApp + daemon + hook bridge (release)…"
swift build -c release --product AgentIslandApp
swift build -c release --product agentislandd
swift build -c release --product AgentIslandHookCLI

APP="$ROOT/build/AgentIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/AgentIslandApp" "$APP/Contents/MacOS/AgentIsland"
# Siblings next to the app executable so EventDrivenSetup can find them by name.
cp "$ROOT/.build/release/agentislandd" "$APP/Contents/MacOS/agentislandd"
cp "$ROOT/.build/release/AgentIslandHookCLI" "$APP/Contents/MacOS/AgentIslandHookCLI"
```

- [ ] **Step 2: Run the build script**

Run: `./Scripts/build-app.sh`
Expected: `Built: …/build/AgentIsland.app`; verify the siblings:
Run: `ls build/AgentIsland.app/Contents/MacOS`
Expected: `AgentIsland  AgentIslandHookCLI  agentislandd`

- [ ] **Step 3: Manual verify the bundle**

Run: `open build/AgentIsland.app` → first-launch consent appears; Enable → hooks install and daemon starts (same as Task 12 verify, but from the bundle).

- [ ] **Step 4: Commit**

```bash
git add Scripts/build-app.sh
git commit -m "build: bundle agentislandd + hook bridge into AgentIsland.app"
```

---

## Task 14: Docs — README updates + final test sweep

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the README** to reflect the shipped behavior

In the "After launching" section, replace the island bullet's state description so it reads:
```markdown
- The **floating island** sits at the top-right, one row per active session (touched in the last 30 min): persona glyph, project name, and state. **Working** rows show a rotating aurora ring with a live `N steps · T tok` line (steps = tool calls; tokens = this session's input+output). **Waiting** rows pulse — gently when awaiting your next prompt, urgently (❗, sorted to top) when blocked on a tool/permission approval. **Done** rows pop, then dim. All motion respects macOS **Reduce Motion**. Click a row's `▸` to expand its sub-agents.
```

In the "Event-driven mode" section, replace the opening so it reflects daemon-as-default:
```markdown
On first launch the app offers to **enable event-driven mode** — it installs the Claude Code hooks into `~/.claude/settings.json` (safe: backup + atomic write) and starts the `agentislandd` daemon for you. This unlocks the precise "needs your action" state and the done animation. Decline and it polls instead; toggle it anytime from the menu-bar item ▸ **Event-driven mode**. You can still set it up manually:
```

Update the status line near the top to drop "settings UI" as the only remaining item if appropriate, and mention the live token/animation work is in.

- [ ] **Step 2: Final full test sweep**

Run: `swift run AgentIslandSelfTest`
Expected: `ALL PASS — 93 checks`, exit 0.

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README — state animations, token line, daemon-as-default"
```

---

## Self-Review (completed during planning)

**Spec coverage:**
- Vivid animations (working ring, waiting pulse, done pop, idle dot, menu-bar) → Tasks 7, 9, 10. ✅
- Reconcile-by-id rendering → Task 8. ✅
- Two distinct waiting states + permission sorts to top → Tasks 4, 6, 9. ✅
- Token usage (fresh, compact, displayed) → Tasks 1, 2, 5, 6. ✅
- "Steps" clarified (= tool calls) → Tasks 6, 14 (docs). ✅
- Label bug (last cwd) → Tasks 3, 5. ✅
- Timer fix / state-derivation audit → no code change (verified in spec); covered by manual verify in Task 5/9 and existing self-tests. ✅
- Daemon as default (consent, install hooks, ensure daemon, reversible, path resolution, bundling) → Tasks 11, 12, 13. ✅
- Reduce Motion → Task 7 (gate), verified Task 9. ✅

**Placeholder scan:** No TBD/TODO; every code step has complete code; every command has expected output. ✅

**Type consistency:** `Row` initializer (Task 6) matches all call sites (Task 6 main.swift; consumed in Tasks 8–9). `IslandAnimations` method names (`installWorkingRing`/`removeWorkingRing`/`startPulse`/`stopPulse`/`celebrate`/`installIdleDot`/`removeIdleDot`) are defined in Task 7 and called identically in Task 9. `EventDrivenSetup` members (`available`, `installHooks`, `uninstallHooks`, `ensureDaemonRunning`, `hookBinary`, `daemonBinary`) defined in Task 11, used in Task 12. `eventModeKey` consistent across Task 12. ✅

**Test count:** 82 → 84 → 88 → 90 → 93 across Tasks 1–4; final sweep expects 93. ✅

## Risks / watch-points (from the spec)

- Sibling-binary resolution is the riskiest seam — if not found, every `EventDrivenSetup` path no-ops and the app stays on polling (never writes a broken hook command). Verify in both `swift run` (after `swift build`) and the bundled `.app`.
- `CAGradientLayer.type = .conic` requires macOS 12+; target is 13+ — fine.
- Menu-bar colored (non-template) text: verify legibility in both light and dark menu bars.
- Spawning a second daemon must be harmless (socket bind fails → exits). Confirm `agentislandd` exits cleanly on "address in use"; if not, add a guard before shipping login auto-start.
