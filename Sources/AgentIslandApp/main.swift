import AppKit
import Foundation
import QuartzCore
import AgentIslandCore
import PersonaKit
import AgentIslandDaemon

// agent-island v0 app: a menu-bar (accessory) item plus an always-on-top floating
// "island" panel. Both list active Claude Code sessions and their derived state, polled
// from ~/.claude transcripts via the verified AgentIslandCore (or read from the daemon's
// state.json when it's running). Each session wears a persona (PersonaKit). Plain
// SwiftPM executable: `swift run AgentIslandApp`.

final class AppController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let island = IslandPanel()
    private var timer: Timer?
    private var islandEnabled = true
    private var dismissedFinished: Set<String> = []   // finished sessions the user removed from view
    private var lastStatus: [String: AgentStatus] = [:]   // prev status per session, for sound-cue transitions

    private let fm = FileManager.default
    private let projectsDir = ("~/.claude/projects" as NSString).expandingTildeInPath
    private let activeWindow: TimeInterval = 1800  // a session touched within 30 min is "active"
    private let pool = BuiltInPersonas.all

    private struct Session {
        let fullID: String; let shortID: String; let label: String
        let title: String?                       // conversation ai-title, if any
        let status: AgentStatus; let subDigests: [SubagentDigest]; let steps: Int
        let tokens: Int
        let startedAt: Date?                      // first transcript record time → running time
    }

    func start() {
        statusItem.button?.title = "○"
        menu.autoenablesItems = false
        statusItem.menu = menu
        island.onDismiss = { [weak self] id in self?.dismissFinished(id) }
        refresh()
        // Create the timer UNSCHEDULED and register it only in .common mode.
        // `Timer.scheduledTimer` already registers the timer in .default mode; adding
        // that same instance to .common a second time double-registers one timer —
        // a pattern Apple warns against, and it can leave the timer not firing at all
        // (the initial refresh draws, then the island never updates again). .common
        // covers default + event-tracking + modal, so the island keeps refreshing even
        // while the menu-bar menu is open.
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        maybeOfferEventDrivenSetup()
    }

    private func refresh() {
        var sessions = activeSessions()
        // Hide finished rows the user dismissed. Keep the dismissed set pruned to ids that are still
        // present AND still finished, so a session that resumes work (or a brand-new one) reappears.
        let finishedIDs = Set(sessions.filter { isFinished($0.status) }.map { $0.fullID })
        dismissedFinished.formIntersection(finishedIDs)
        sessions = sessions.filter { !dismissedFinished.contains($0.fullID) }

        detectTransitions(in: sessions)

        menu.removeAllItems()
        if sessions.isEmpty {
            menu.addItem(infoItem("No active sessions (last 30 min)"))
        } else {
            menu.addItem(infoItem("Active sessions"))
            for s in sessions { menu.addItem(infoItem(rowText(for: s))) }
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Show floating island", action: #selector(toggleIsland), keyEquivalent: "")
        toggle.target = self; toggle.isEnabled = true; toggle.state = islandEnabled ? .on : .off
        menu.addItem(toggle)
        let eventOn = UserDefaults.standard.string(forKey: eventModeKey) == "enabled"
        let eventToggle = NSMenuItem(title: "Event-driven mode", action: #selector(toggleEventMode), keyEquivalent: "")
        eventToggle.target = self
        eventToggle.isEnabled = EventDrivenSetup.available || eventOn
        eventToggle.state = eventOn ? .on : .off
        menu.addItem(eventToggle)

        let themeItem = NSMenuItem(title: "Animation theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        let currentTheme = UserDefaults.standard.string(forKey: "islandTheme") ?? Themes.all[0].id
        for t in Themes.all {
            let ti = NSMenuItem(title: t.displayName, action: #selector(pickTheme(_:)), keyEquivalent: "")
            ti.target = self; ti.representedObject = t.id; ti.state = (t.id == currentTheme) ? .on : .off
            themeMenu.addItem(ti)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // Quiet by default: themes opt into lifecycle sound cues (today only Road Runner's arcade set);
        // the neutral default set fills in for silent themes (or replaces the theme set entirely).
        let soundToggle = NSMenuItem(title: "Sound cues", action: #selector(toggleSound), keyEquivalent: "")
        soundToggle.target = self; soundToggle.isEnabled = true
        soundToggle.state = SoundManager.shared.isEnabled ? .on : .off
        menu.addItem(soundToggle)

        let soundSetItem = NSMenuItem(title: "Sound set", action: nil, keyEquivalent: "")
        let soundSetMenu = NSMenu()
        let activeSet = currentSoundSet
        for (id, label) in [("theme", "Theme set"), ("default", "Default set")] {
            let si = NSMenuItem(title: label, action: #selector(pickSoundSet(_:)), keyEquivalent: "")
            si.target = self; si.representedObject = id; si.state = (id == activeSet) ? .on : .off
            si.isEnabled = true   // always pickable; the choice just takes effect once cues are on
            soundSetMenu.addItem(si)
        }
        soundSetItem.submenu = soundSetMenu
        menu.addItem(soundSetItem)

        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear finished sessions", action: #selector(clearFinished), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = sessions.contains { isFinished($0.status) }
        menu.addItem(clear)
        let reset = NSMenuItem(title: "Reset island position", action: #selector(resetIslandPosition), keyEquivalent: "")
        reset.target = self; reset.isEnabled = true
        menu.addItem(reset)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit agent-island", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; quit.isEnabled = true
        menu.addItem(quit)

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

        if islandEnabled {
            let rows: [IslandPanel.Row]
            if sessions.isEmpty {
                rows = [IslandPanel.Row(id: "idle", glyph: "·", color: .tertiaryLabelColor,
                                        title: "idle", state: "no active sessions (last 30 min)")]
            } else {
                let now = Date()
                rows = sessions.map { s -> IslandPanel.Row in
                    let skin = persona(for: s).skin(for: s.status)
                    let isWorking = (s.status == .working)
                    let reason = waitReason(s.status)
                    var parts: [String] = [skin.label]
                    if isWorking && s.steps > 0 { parts.append("\(s.steps) steps") }
                    if !isFinished(s.status) && s.tokens > 0 { parts.append("\(TokenUsage.compact(s.tokens)) tok") }
                    if !isFinished(s.status), let start = s.startedAt {
                        parts.append(TranscriptClock.elapsedLabel(from: start, to: now))   // running time
                    }
                    var stateText = parts.joined(separator: " · ")
                    if reason == .permission { stateText = "❗ " + stateText }
                    // Title = the conversation's ai-title when known (more descriptive than the
                    // project name); the project name moves into the expanded detail line.
                    let title = s.title.map { TaskLineSanitizer.sanitize($0, maxLength: 36) } ?? s.label
                    let detail = "📂 \(s.label)"   // project name (the title line now shows the ai-title)
                    let subRows = s.subDigests.map { d -> IslandPanel.SubRow in
                        var bits = [d.name]
                        if d.tokens > 0 { bits.append("\(TokenUsage.compact(d.tokens)) tok") }
                        if let dur = d.durationSeconds { bits.append(TranscriptClock.durationLabel(dur)) }
                        return IslandPanel.SubRow(glyph: "↳", color: color(d.status), text: bits.joined(separator: " · "))
                    }
                    return IslandPanel.Row(id: s.fullID, glyph: skin.glyph, color: color(s.status),
                                           title: title, state: stateText,
                                           spinning: isWorking,
                                           dimmed: !isWorking,  // only the running row stays bright
                                           waitReason: reason, verdict: verdict(s.status),
                                           tokens: s.tokens, subRows: subRows, detail: detail)
                }
            }
            island.update(rows: rows)
            island.orderFrontRegardless()
        } else {
            island.orderOut(nil)
        }
    }

    private func rowText(for s: Session) -> String {
        let skin = persona(for: s).skin(for: s.status)
        return "\(skin.glyph)  \(s.label)  —  \(skin.label)"
    }

    private func persona(for s: Session) -> Persona {
        PersonaRuntime.persona(forSessionID: s.fullID, pool: pool) ?? BuiltInPersonas.minimal
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func toggleIsland() { islandEnabled.toggle(); refresh() }

    // Remove a single finished session from view (its ✕), or all finished at once (menu).
    private func dismissFinished(_ id: String) { dismissedFinished.insert(id); refresh() }
    @objc private func clearFinished() {
        dismissedFinished.formUnion(activeSessions().filter { isFinished($0.status) }.map { $0.fullID })
        refresh()
    }
    @objc private func resetIslandPosition() { island.resetPosition() }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "islandTheme")
        island.setTheme(id)
        refresh()
    }

    @objc private func toggleSound() {
        let next = !SoundManager.shared.isEnabled
        SoundManager.shared.isEnabled = next
        UserDefaults.standard.set(next, forKey: SoundManager.enabledKey)
        refresh()
    }

    @objc private func pickSoundSet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: AppController.soundSetKey)
        refresh()
    }

    // MARK: - Sound cues (theme-owned lifecycle jingles)

    /// The theme the user has selected — the source of any transition sounds.
    private var currentTheme: IslandTheme { Themes.named(UserDefaults.standard.string(forKey: "islandTheme")) }

    static let soundSetKey = "soundCueSet"   // UserDefaults; "theme" (default) | "default"

    /// Which cue set plays: the selected theme's jingles ("theme", filling silence with the neutral
    /// set) or always the neutral default set ("default"). Absent → "theme".
    private var currentSoundSet: String { UserDefaults.standard.string(forKey: AppController.soundSetKey) ?? "theme" }

    /// Diff each visible session's status+tokens against the previous refresh and play the current
    /// theme's clip for any sound-worthy transition. Prunes ids no longer present so a resumed
    /// session re-arms (and its first re-sighting is a silent baseline). Dismissed sessions are
    /// already filtered out before this runs, so they stay quiet.
    private func detectTransitions(in sessions: [Session]) {
        let present = Set(sessions.map(\.fullID))
        let theme = currentTheme
        let useDefaultSet = (currentSoundSet == "default")
        for s in sessions {
            if let transition = TransitionDetector.transition(from: lastStatus[s.fullID], to: s.status) {
                // "default" set always plays the neutral cues; "theme" set prefers the theme's own
                // jingle and falls back to the neutral cue so silent themes (Minimal) still cue.
                let url = useDefaultSet
                    ? DefaultSounds.url(for: transition)
                    : (theme.sound(for: transition) ?? DefaultSounds.url(for: transition))
                SoundManager.shared.play(url)
            }
            lastStatus[s.fullID] = s.status
        }
        lastStatus = lastStatus.filter { present.contains($0.key) }
    }

    // MARK: - Event-driven mode (daemon + hooks) — reversible, first-launch consent

    private let eventModeKey = "eventDrivenSetupDecision"  // "enabled" | "declined" | "error"

    private func maybeOfferEventDrivenSetup() {
        let defaults = UserDefaults.standard
        // "enabled" and "declined" are final decisions. A prior "error" (or no decision yet)
        // re-offers, so a transient install failure (e.g. a momentarily-malformed
        // settings.json the user later repairs) doesn't permanently suppress the prompt.
        switch defaults.string(forKey: eventModeKey) {
        case "enabled": EventDrivenSetup.ensureDaemonRunning(); return
        case "declined": return
        default: break  // nil or "error" → offer
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

    // MARK: - Sessions (daemon state if running, else poll transcripts)

    private func activeSessions() -> [Session] { daemonSessions() ?? polledSessions() }

    private func daemonSessions() -> [Session]? {
        let statePath = ("~/.agent-island/state.json" as NSString).expandingTildeInPath
        // A FRESH state.json (daemon heartbeats every 10s) is authoritative — trust it even when
        // it lists no sessions (the daemon genuinely knows nothing is active), so we don't fall
        // back to polling and resurface closed sessions as "open". nil only means "daemon down"
        // (file stale/absent/unreadable), which legitimately falls through to polling.
        guard let attrs = try? fm.attributesOfItem(atPath: statePath),
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) < 30,
              let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let state = try? JSONDecoder().decode(DaemonState.self, from: data) else { return nil }
        return state.sessions.map { snap in
            let short = String(snap.sessionID.prefix(8))
            // The daemon tracks state only; everything transcript-derived (tokens, title, start
            // time, per-sub-agent detail) is computed app-side from the transcript, read once.
            let path = snap.cwd.map { transcriptPath(cwd: $0, sessionID: snap.sessionID) }
            let lines = path.map { readLines($0) } ?? []
            let tokens = TokenUsage.freshTokens(lines: lines)
            let title = ConversationTitle.fromTranscript(lines: lines)
            let startedAt = TranscriptClock.startedAt(lines: lines)
            var digests = path.map { subagentDigests(forTranscript: $0) } ?? []
            // If the sub-agent transcripts aren't on disk yet, fall back to the daemon's
            // running/done counts as nameless placeholders so the tally still shows.
            if digests.isEmpty, snap.subActive + snap.subDone > 0 {
                digests = Array(repeating: SubagentDigest(name: "sub-agent", status: .working, tokens: 0, durationSeconds: nil), count: snap.subActive)
                    + Array(repeating: SubagentDigest(name: "sub-agent", status: .finished(.success), tokens: 0, durationSeconds: nil), count: snap.subDone)
            }
            return Session(fullID: snap.sessionID, shortID: short, label: snap.label ?? short,
                           title: title, status: AgentStatus(stateToken: snap.state),
                           subDigests: digests, steps: 0, tokens: tokens, startedAt: startedAt)
        }
    }

    /// Path to a session's transcript: ~/.claude/projects/<cwd with "/"→"-">/<sessionID>.jsonl.
    private func transcriptPath(cwd: String, sessionID: String) -> String {
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        return "\(projectsDir)/\(encoded)/\(sessionID).jsonl"
    }

    private func polledSessions() -> [Session] {
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }
        let cutoff = Date().addingTimeInterval(-activeWindow)
        var found: [(session: Session, mtime: Date)] = []
        for proj in projects {
            let projPath = "\(projectsDir)/\(proj)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projPath, isDirectory: &isDir), isDir.boolValue,
                  let entries = try? fm.contentsOfDirectory(atPath: projPath) else { continue }
            for entry in entries where entry.hasSuffix(".jsonl") {
                let p = "\(projPath)/\(entry)"
                let mtime = ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast
                guard mtime >= cutoff else { continue }
                let lines = readLines(p)
                let records = TranscriptAdapter.parse(lines: lines)
                let sessionStatus = StateEngine.deriveStatus(records: records, openPermission: false)
                let digests = subagentDigests(forTranscript: p)
                var rolled = Rollup.rollUp(session: sessionStatus, subAgents: digests.map(\.status))
                // A session stopped (waiting) but quiet >10 min reads as idle, not "waiting on
                // you" — mirrors the daemon's idle downgrade. (Polling still can't tell a truly
                // closed session from a long wait, but at least it stops nagging.)
                if case .waitingForInput = rolled, Date().timeIntervalSince(mtime) > 600 {
                    rolled = .finished(.success)
                }
                let steps = records.reduce(0) { $0 + $1.assistantBlockKinds.filter { $0 == "tool_use" }.count }
                let tokens = TokenUsage.freshTokens(lines: lines)
                let title = ConversationTitle.fromTranscript(lines: lines)
                let startedAt = TranscriptClock.startedAt(lines: lines)
                let fullID = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                let label = ProjectLabel.fromTranscript(lines: lines) ?? String(fullID.prefix(8))
                found.append((Session(fullID: fullID, shortID: String(fullID.prefix(8)),
                                      label: label, title: title, status: rolled, subDigests: digests,
                                      steps: steps, tokens: tokens, startedAt: startedAt), mtime))
            }
        }
        return found
            .sorted {
                let ra = DisplayPriority.rank($0.session.status), rb = DisplayPriority.rank($1.session.status)
                return ra != rb ? ra < rb : $0.mtime > $1.mtime
            }
            .map(\.session)
    }

    /// Per-sub-agent digests for a session, parsed from its `subagents/agent-*.jsonl` transcripts.
    /// Used in both daemon and polling modes (the daemon only tracks counts).
    private func subagentDigests(forTranscript sessionPath: String) -> [SubagentDigest] {
        let subDir = (sessionPath as NSString).deletingPathExtension + "/subagents"
        guard let walker = fm.enumerator(atPath: subDir) else { return [] }
        var out: [SubagentDigest] = []
        for case let rel as String in walker {
            let name = (rel as NSString).lastPathComponent
            guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { continue }
            out.append(SubagentDigest.fromTranscript(lines: readLines("\(subDir)/\(rel)")))
        }
        return out
    }

    private func readLines(_ path: String) -> [String] {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
    }

    private func isWaiting(_ s: AgentStatus) -> Bool { if case .waitingForInput = s { return true } else { return false } }
    private func isFinished(_ s: AgentStatus) -> Bool { if case .finished = s { return true } else { return false } }

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

}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon

// Dev-only: `-renderRoadSample <path>` renders the road-trip scene grid to a PNG and exits.
if let i = CommandLine.arguments.firstIndex(of: "-renderRoadSample"),
   i + 1 < CommandLine.arguments.count {
    RoadSampleRenderer.render(to: CommandLine.arguments[i + 1])
    exit(0)
}

let controller = AppController()
controller.start()
app.run()
