import AppKit
import Foundation
import QuartzCore
import AgentIslandCore
import PersonaKit
import AgentIslandDaemon
import AgentIslandThemes

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
    private let dismissedKey = "islandDismissedFinished"   // UserDefaults: persisted dismissedFinished ids

    // "Keep Mac awake": while ON and a session is working, hold an idle-system-sleep assertion so a
    // long agent run isn't suspended when you step away. (Won't keep the Mac awake with the lid
    // closed on battery — clamshell sleep is a separate mechanism.)
    private var sleepToken: NSObjectProtocol?
    private let keepAwakeKey = "islandKeepAwake"   // UserDefaults bool; default off

    // Click-to-focus: the owning terminal's window identity per session (keyed by fullID), captured
    // at SessionStart by the hook and carried in the daemon snapshot. Empty in polling mode.
    private struct WindowIdentity { let termProgram: String?; let itermSessionID: String?; let bundleID: String? }
    private var windowIdentities: [String: WindowIdentity] = [:]

    // Downloadable themes: the hosted catalog, fetched once lazily in the background (network) and
    // cached so the menu builds synchronously. nil = not fetched yet / fetch failed (offline → the
    // submenu just shows no download entries; never an error dialog). A download in flight blocks a
    // second start of the SAME id so a double-click can't race two installs.
    private var themeCatalog: ThemeCatalog?
    private var downloadingThemeIDs: Set<String> = []

    // "Update available": the result of the once-a-day GitHub Releases check (see UpdateCheck). Drives a
    // dismissible menu item + a subtle menu-bar cue. `.upToDate` until a successful fetch of a
    // strictly-newer, undismissed release; dismissing persists the version so it stays quiet until
    // something newer ships. Network-optional — offline/rate-limited just leaves this `.upToDate`.
    private var updateAvailable: UpdateAvailability = .upToDate

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
        var provider: SessionProviderKind = .claude   // which agent CLI — drives the row badge
        // Last-activity time, when the source has one (poll-only providers: transcript mtime / DB
        // time_updated). The daemon path doesn't track it (nil), so it only matters for ordering
        // poll-derived rows (e.g. OpenCode rows merged alongside the daemon-fresh Claude list).
        var lastActivity: Date? = nil
    }

    // The poll-only providers merged into the island alongside the Claude daemon/poll path. Claude is
    // the default + verified provider; OpenCode is additive (reads its SQLite db read-only). Both live
    // behind the `SessionProvider` protocol in AgentIslandCore.
    private let claudeProvider = ClaudeCodeProvider()
    private let openCodeProvider = OpenCodeProvider()

    func start() {
        statusItem.button?.title = "○"
        menu.autoenablesItems = false
        statusItem.menu = menu
        dismissedFinished = Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
        island.onDismiss = { [weak self] id in self?.dismissFinished(id) }
        island.onFocus = { [weak self] id in self?.focusWindow(id) }
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
        fetchThemeCatalog()
        checkForUpdate()
    }

    /// Kick off the throttled (≤ once/day) GitHub Releases check in the background; on a strictly-newer,
    /// undismissed release, store it and rebuild the menu so the indicator appears. Best-effort and
    /// silent on any failure — see UpdateCheck. Never blocks the main thread on the network.
    private func checkForUpdate() {
        UpdateCheck.checkIfDue { [weak self] availability in
            guard let self = self else { return }
            self.updateAvailable = availability
            self.refresh()
        }
    }

    /// Fetch the hosted theme catalog once in the background; cache it and rebuild the menu so the
    /// download entries appear. Best-effort — offline / a failed fetch simply leaves the submenu with
    /// no download entries (no dialog, no crash). Never blocks the main thread on the network.
    private func fetchThemeCatalog() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard case .success(let catalog) = ThemeDownloader.fetchCatalog() else { return }
            DispatchQueue.main.async {
                self?.themeCatalog = catalog
                self?.refresh()
            }
        }
    }

    private func refresh() {
        var sessions = activeSessions()
        // Hide finished rows the user dismissed. Keep the dismissed set pruned to ids that are still
        // present AND still finished, so a session that resumes work (or a brand-new one) reappears.
        let finishedIDs = Set(sessions.filter { isFinished($0.status) }.map { $0.fullID })
        dismissedFinished.formIntersection(finishedIDs)
        persistDismissed()   // prune-then-persist so the stored set never accumulates stale ids
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
        // "Update available" indicator: only present when the daily check found a strictly-newer,
        // undismissed release. A submenu carries the one-click action + a Dismiss that persists the
        // version so it stays quiet until something newer ships. Placed near the top so it's seen, but
        // it's absent (not greyed) when up to date — "don't nag".
        if let newVersion = updateAvailable.offeredVersion {
            let updateItem = NSMenuItem(title: "Update available — v\(newVersion)", action: nil, keyEquivalent: "")
            let updateMenu = NSMenu()
            let get = NSMenuItem(title: "Get update…", action: #selector(openUpdate), keyEquivalent: "")
            get.target = self; get.isEnabled = true
            updateMenu.addItem(get)
            let dismiss = NSMenuItem(title: "Dismiss this version", action: #selector(dismissUpdate), keyEquivalent: "")
            dismiss.target = self; dismiss.isEnabled = true; dismiss.representedObject = newVersion
            updateMenu.addItem(dismiss)
            updateItem.submenu = updateMenu
            menu.addItem(updateItem)
            menu.addItem(.separator())
        }
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
        let installedIDs = Set(Themes.all.map(\.id))
        for t in Themes.all {
            let ti = NSMenuItem(title: t.displayName, action: #selector(pickTheme(_:)), keyEquivalent: "")
            ti.target = self; ti.representedObject = t.id; ti.state = (t.id == currentTheme) ? .on : .off
            themeMenu.addItem(ti)
        }
        // Downloadable themes from the hosted catalog: only those NOT already installed. An entry the
        // running app is too old for is shown disabled (greyed); everything else triggers a download
        // on click. Offline / no catalog → this whole section is simply absent.
        let downloadable = (themeCatalog?.themes ?? []).filter { !installedIDs.contains($0.id) }
        if !downloadable.isEmpty {
            themeMenu.addItem(.separator())
            themeMenu.addItem(infoItem("Download more"))
            for entry in downloadable {
                let supported = SemVer.isAtLeast(AppInfo.version, entry.minAppVersion)
                let downloading = downloadingThemeIDs.contains(entry.id)
                let suffix = downloading ? " (downloading…)" : (supported ? "" : " (needs app \(entry.minAppVersion ?? "?"))")
                // displayName is untrusted catalog text → strip control/ANSI + clamp before it goes in a
                // menu title (reuses the agent-output sanitizer; 48 chars is generous for a theme label).
                let label = TaskLineSanitizer.sanitize(entry.displayName, maxLength: 48)
                let di = NSMenuItem(title: "\(label)\(suffix)",
                                    action: #selector(downloadTheme(_:)), keyEquivalent: "")
                di.target = self; di.representedObject = entry.id
                di.isEnabled = supported && !downloading   // grey out unsupported / in-flight entries
                themeMenu.addItem(di)
            }
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

        // Opt-in: prevent OS idle system-sleep while an agent is working (good battery citizen —
        // only asserts when ON and something is actually working; see updateSleepAssertion).
        let keepAwakeToggle = NSMenuItem(title: "Keep Mac awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
        keepAwakeToggle.target = self; keepAwakeToggle.isEnabled = true
        keepAwakeToggle.state = UserDefaults.standard.bool(forKey: keepAwakeKey) ? .on : .off
        menu.addItem(keepAwakeToggle)

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
        updateSleepAssertion(on: UserDefaults.standard.bool(forKey: keepAwakeKey), working: working)
        let glyph: String
        let glyphColor: NSColor
        // A subtle update cue rides only on the idle glyph (○⋯) — the urgent waiting/working states keep
        // their uncluttered count, so the update hint never competes with "an agent needs you". The menu
        // item is the real affordance; this is just a quiet "there's something in the menu".
        let updateCue = updateAvailable.offeredVersion != nil
        if waiting > 0 { glyph = "● \(waiting)"; glyphColor = .systemRed }
        else if working { glyph = "◐"; glyphColor = .systemTeal }
        else { glyph = updateCue ? "○⋯" : "○"; glyphColor = .secondaryLabelColor }
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

        // Tooltip surfaces WHICH session needs you: the highest-priority waiting session's title +
        // runtime (the glyph above stays a compact count). Quiet default when nothing's waiting.
        if let top = sessions.filter({ isWaiting($0.status) })
            .min(by: { DisplayPriority.rank($0.status) < DisplayPriority.rank($1.status) }) {
            let name = TaskLineSanitizer.sanitize(top.title ?? top.label, maxLength: 28)
            let elapsed = top.startedAt.map { TranscriptClock.elapsedLabel(from: $0, to: Date()) }
            statusItem.button?.toolTip = elapsed.map { "\(name) · \($0)" } ?? name
        } else if working {
            let n = sessions.filter { $0.status == .working }.count
            statusItem.button?.toolTip = (n == 1) ? "1 agent working" : "\(n) agents working"
        } else {
            statusItem.button?.toolTip = "agent-island"
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
                    // Project name in the expanded detail, with a small provider badge so a merged
                    // island distinguishes OpenCode rows from Claude ones (Claude stays unbadged).
                    let detail = "📂 \(providerBadge(s.provider))\(s.label)"
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
        return "\(providerBadge(s.provider))\(skin.glyph)  \(s.label)  —  \(skin.label)"
    }

    /// A small leading "[OC] " tag so a merged island can tell an OpenCode session from a Claude one.
    /// Claude is the default/unbadged provider (no clutter on the common case); only additive
    /// providers carry a badge.
    private func providerBadge(_ p: SessionProviderKind) -> String {
        p == .claude ? "" : "[\(p.badge)] "
    }

    private func persona(for s: Session) -> Persona {
        PersonaRuntime.persona(forSessionID: s.fullID, pool: pool) ?? BuiltInPersonas.minimal
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func quit() {
        if let token = sleepToken { ProcessInfo.processInfo.endActivity(token); sleepToken = nil }
        NSApplication.shared.terminate(nil)
    }
    @objc private func toggleIsland() { islandEnabled.toggle(); refresh() }

    // Remove a single finished session from view (its ✕), or all finished at once (menu).
    private func dismissFinished(_ id: String) { dismissedFinished.insert(id); persistDismissed(); refresh() }
    @objc private func clearFinished() {
        dismissedFinished.formUnion(activeSessions().filter { isFinished($0.status) }.map { $0.fullID })
        persistDismissed()
        refresh()
    }

    /// Persist the dismissed-finished set so removals survive relaunch (re-pruned each refresh()).
    private func persistDismissed() { UserDefaults.standard.set(Array(dismissedFinished), forKey: dismissedKey) }
    @objc private func resetIslandPosition() { island.resetPosition() }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "islandTheme")
        island.setTheme(id)
        refresh()
    }

    /// Download + install a catalog theme by id. Runs the whole validate-then-install pipeline off the
    /// main thread; on success re-discovers themes (`Themes.reload()`) so the new theme appears in the
    /// submenu and renders. On failure it logs and no-ops — a bad download must never crash the app or
    /// leave a partial install (the downloader guarantees the latter). Re-entrancy-guarded per id.
    @objc private func downloadTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = themeCatalog?.themes.first(where: { $0.id == id }),
              !downloadingThemeIDs.contains(id) else { return }
        downloadingThemeIDs.insert(id)
        refresh()   // reflect "(downloading…)" + disable the entry
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ThemeDownloader.install(entry)
            DispatchQueue.main.async {
                self?.downloadingThemeIDs.remove(id)
                switch result {
                case .success(let installedID):
                    Themes.reload()   // re-scan ~/.agent-island/themes → the new theme is now discoverable
                    FileHandle.standardError.write(Data("agent-island: installed theme '\(installedID)'\n".utf8))
                case .failure(let error):
                    FileHandle.standardError.write(Data("agent-island: theme download '\(id)' failed: \(error)\n".utf8))
                }
                self?.refresh()   // rebuild the menu either way (drop the spinner, show the new theme)
            }
        }
    }

    /// Act on the "update available" indicator. Prefers the installed `agentisland` management CLI: if
    /// it's resolvable (a sibling of the app executable — how `build-app.sh`/`install.sh` lay it out —
    /// or on a common PATH dir), open Terminal running `agentisland update` so the user sees (and
    /// confirms) the in-place, build-from-source update interactively. Falls back to opening the GitHub
    /// Releases page when the CLI isn't found (e.g. a bare `swift run` with no installed binary).
    @objc private func openUpdate() {
        if let cli = locateManagementCLI() {
            // Launch Terminal on a short script that runs the updater then pauses so the window stays up.
            let script = "clear; \"\(cli)\" update; echo; echo '(press return to close)'; read -r _"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // `open -a Terminal <file>` runs a shell script in a new Terminal window.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentisland-update.command")
            if (try? script.write(to: tmp, atomically: true, encoding: .utf8)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
                p.arguments = ["-a", "Terminal", tmp.path]
                if (try? p.run()) != nil { return }
            }
        }
        // Fallback: open the Releases page in the browser.
        if let url = URL(string: UpdateCheck.releasesPageURL) { NSWorkspace.shared.open(url) }
    }

    /// Resolve the installed `agentisland` management CLI: first as a sibling of the running app
    /// executable (the build/install layout), then in the common PATH dirs the installer uses. Returns
    /// nil when no executable is found (then `openUpdate` falls back to the Releases page).
    private func locateManagementCLI() -> String? {
        let fm = FileManager.default
        if let exe = Bundle.main.executablePath {
            let sibling = (exe as NSString).deletingLastPathComponent + "/agentisland"
            if fm.isExecutableFile(atPath: sibling) { return sibling }
        }
        for dir in ["/usr/local/bin", "/opt/homebrew/bin"] {
            let p = dir + "/agentisland"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Dismiss the offered update: persist the version so the badge stays quiet until a strictly-newer
    /// release ships (the pure `UpdateAvailability.decide` compares against this), then hide it now.
    @objc private func dismissUpdate(_ sender: NSMenuItem) {
        guard let version = sender.representedObject as? String else { return }
        UpdateCheck.dismiss(version: version)
        updateAvailable = .upToDate
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

    @objc private func toggleKeepAwake() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: keepAwakeKey), forKey: keepAwakeKey)
        refresh()
    }

    /// Hold an idle-system-sleep assertion only while the toggle is ON and a session is working;
    /// release it otherwise. Held strongly for its whole lifetime (dropping it lets the Mac sleep).
    private func updateSleepAssertion(on: Bool, working: Bool) {
        if on && working {
            if sleepToken == nil {
                sleepToken = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled],
                    reason: "agent-island: agent session running")
            }
        } else if let token = sleepToken {
            ProcessInfo.processInfo.endActivity(token)
            sleepToken = nil
        }
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
        case "enabled":
            // Self-heal the hook set: an app upgrade may add events (e.g. PostToolUse) that an
            // already-"enabled" install predates. Re-installing is idempotent and writes only when
            // something actually changed, so this is a no-op once the set is in sync.
            try? EventDrivenSetup.installHooks()
            EventDrivenSetup.ensureDaemonRunning()
            return
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

    private func activeSessions() -> [Session] {
        if let d = daemonSessions() {
            // The Claude daemon is authoritative for Claude rows, but it knows nothing about OpenCode
            // (poll-only, independent of the daemon). Without this merge, OpenCode rows vanish whenever
            // the daemon is up (the default after consent). Merge OpenCode's poll alongside — the
            // daemon rows are appended-to and re-sorted, never routed through the daemon or mutated.
            return Self.mergeOpenCode(intoDaemon: d, openCode: openCodeProvider.poll(now: Date()))
        }
        // Daemon down/stale → polling. Window identity doesn't go stale the way *state* does (a
        // terminal window doesn't move), so load it best-effort from state.json regardless of the
        // freshness gate — click-to-focus keeps working as long as the session was ever seen.
        loadWindowIdentitiesFromState()
        return polledSessions()
    }

    /// Merge OpenCode poll rows into the daemon-fresh Claude list. The daemon rows are kept exactly as
    /// produced (content byte-for-byte unchanged); OpenCode rows are mapped and appended, then the
    /// COMBINED list is re-sorted with the SAME comparator the poll path uses — `DisplayPriority.rank`
    /// ascending, then `lastActivity` descending. A trailing original-index tiebreaker keeps the sort
    /// stable, so daemon rows preserve their relative order within a priority rank (and among each
    /// other, since they share a nil `lastActivity`). OpenCode stays poll-only and independent of the
    /// daemon's authority — this only affects display order of the merged list.
    private static func mergeOpenCode(intoDaemon daemon: [Session], openCode: [ProviderSession]) -> [Session] {
        guard !openCode.isEmpty else { return daemon }   // nothing to merge → daemon untouched
        let combined = daemon + openCode.map(Self.session(from:))
        return SessionMergeOrder.ordered(combined, status: \.status, lastActivity: \.lastActivity)
    }

    /// Populate `windowIdentities` from state.json WITHOUT the daemon-freshness gate. A terminal
    /// window's identity is durable (it doesn't move), so even a stale state.json is a valid source;
    /// this keeps click-to-focus alive when the daemon is down and the app falls back to polling.
    /// Rebuilds the map fresh each call, bounding it to the sessions state.json currently knows.
    private func loadWindowIdentitiesFromState() {
        let statePath = ("~/.agent-island/state.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let state = try? JSONDecoder().decode(DaemonState.self, from: data) else {
            windowIdentities = [:]   // no readable state file → nothing to focus
            return
        }
        var map: [String: WindowIdentity] = [:]
        for snap in state.sessions
        where snap.termProgram != nil || snap.itermSessionID != nil || snap.termBundleID != nil {
            map[snap.sessionID] = WindowIdentity(termProgram: snap.termProgram,
                                                 itermSessionID: snap.itermSessionID,
                                                 bundleID: snap.termBundleID)
        }
        windowIdentities = map
    }

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
        // Capture each session's window identity (for click-to-focus); set at SessionStart by the
        // hook and persisted on the snapshot. Only daemon mode has it — polling clears the map.
        windowIdentities = [:]
        for snap in state.sessions
        where snap.termProgram != nil || snap.itermSessionID != nil || snap.termBundleID != nil {
            windowIdentities[snap.sessionID] = WindowIdentity(termProgram: snap.termProgram,
                                                              itermSessionID: snap.itermSessionID,
                                                              bundleID: snap.termBundleID)
        }
        return state.sessions.map { snap in
            let short = String(snap.sessionID.prefix(8))
            // The daemon tracks state only; everything transcript-derived (tokens, title, start
            // time, per-sub-agent detail) is computed app-side from the transcript, read once.
            let path = snap.cwd.map { transcriptPath(cwd: $0, sessionID: snap.sessionID) }
            let lines = path.map { readLines($0) } ?? []
            let digest = TranscriptDigest.scan(lines: lines)   // one pass: tokens/title/startedAt/steps
            var digests = path.map { subagentDigests(forTranscript: $0) } ?? []
            // If the sub-agent transcripts aren't on disk yet, fall back to the daemon's
            // running/done counts as nameless placeholders so the tally still shows.
            if digests.isEmpty, snap.subActive + snap.subDone > 0 {
                digests = Array(repeating: SubagentDigest(name: "sub-agent", status: .working, tokens: 0, durationSeconds: nil), count: snap.subActive)
                    + Array(repeating: SubagentDigest(name: "sub-agent", status: .finished(.success), tokens: 0, durationSeconds: nil), count: snap.subDone)
            }
            return Session(fullID: snap.sessionID, shortID: short, label: snap.label ?? short,
                           title: digest.title, status: AgentStatus(stateToken: snap.state),
                           subDigests: digests, steps: 0, tokens: digest.tokens, startedAt: digest.startedAt)
        }
    }

    /// Path to a session's transcript: ~/.claude/projects/<cwd with "/"→"-">/<sessionID>.jsonl.
    private func transcriptPath(cwd: String, sessionID: String) -> String {
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        return "\(projectsDir)/\(encoded)/\(sessionID).jsonl"
    }

    /// Per-sub-agent digests for a session, parsed from its `subagents/agent-*.jsonl` transcripts.
    /// Still used by the daemon path (the daemon tracks counts only; the App computes the per-sub
    /// detail from disk). The Claude polling path now gets these from `ClaudeCodeProvider`.
    private func subagentDigests(forTranscript sessionPath: String) -> [SubagentDigest] {
        let subDir = (sessionPath as NSString).deletingPathExtension + "/subagents"
        guard let walker = fm.enumerator(atPath: subDir) else { return [] }
        var out: [SubagentDigest] = []
        for case let rel as String in walker {
            let name = (rel as NSString).lastPathComponent
            guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { continue }
            let full = "\(subDir)/\(rel)"
            // mtime lets a busy sub-agent's mid-turn text-tail read as working, not waiting (which
            // Rollup would otherwise float up to the whole session).
            let mtime = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date
            out.append(SubagentDigest.fromTranscript(lines: readLines(full), lastActivity: mtime))
        }
        return out
    }

    private func readLines(_ path: String) -> [String] {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
    }

    /// Poll every enabled provider and merge into one list. Claude is polled via `ClaudeCodeProvider`
    /// (a verbatim extraction of the old inline `~/.claude/projects` scan — same discovery, parse,
    /// state derivation, idle downgrade, and sort, now living in AgentIslandCore behind the
    /// `SessionProvider` protocol). OpenCode is additive: its SQLite db read read-only, top-level
    /// non-archived sessions only. Each provider already sorts its own list by action-priority then
    /// recency; merging preserves that order across providers so the most-urgent rows still float up.
    private func polledSessions() -> [Session] {
        let now = Date()
        let merged = claudeProvider.poll(now: now) + openCodeProvider.poll(now: now)
        return merged
            .sorted(by: Self.providerSortsBefore)
            .map(Self.session(from:))
    }

    /// `ProviderSession → Session`, carrying `lastActivity` so a merged list (e.g. OpenCode rows
    /// alongside the daemon-fresh Claude rows) can be ordered by the same recency tiebreaker.
    private static func session(from p: ProviderSession) -> Session {
        Session(fullID: p.fullID, shortID: String(p.fullID.prefix(8)), label: p.label, title: p.title,
                status: p.status, subDigests: p.subDigests, steps: p.steps, tokens: p.tokens,
                startedAt: p.startedAt, provider: p.provider, lastActivity: p.lastActivity)
    }

    /// The merge comparator used everywhere: action-priority (`DisplayPriority.rank`) ascending, then
    /// most-recent `lastActivity` first. Shared by the poll merge and the daemon+OpenCode merge so the
    /// ordering rule never drifts between paths.
    private static func providerSortsBefore(_ a: ProviderSession, _ b: ProviderSession) -> Bool {
        let ra = DisplayPriority.rank(a.status), rb = DisplayPriority.rank(b.status)
        if ra != rb { return ra < rb }
        return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
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

    // MARK: - Click-to-focus (raise the owning terminal window)

    /// Raise the terminal window/tab that owns this session. Identity is captured at SessionStart
    /// (daemon mode only); polling-mode or unknown-host rows have no identity and no-op gracefully.
    private func focusWindow(_ id: String) {
        guard let ident = windowIdentities[id] else { return }
        if ident.termProgram == "iTerm.app", let guid = itermGUID(from: ident.itermSessionID) {
            focusITerm2(guid: guid)
        } else if let bundle = ident.bundleID,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Select + activate an iTerm2 session by its GUID via AppleScript. First use prompts for
    /// Automation (TCC) permission. Runs off the main thread; errors are swallowed (best-effort).
    private func focusITerm2(guid: String) {
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (id of s) is "\(guid)" then
                  select w
                  select t
                  select s
                  activate
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
        }
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

// Dev-only: `-renderTheme <id> <path>` renders every state of any theme (code or data) to a PNG.
if let i = CommandLine.arguments.firstIndex(of: "-renderTheme"),
   i + 2 < CommandLine.arguments.count {
    ThemeSampleRenderer.render(themeID: CommandLine.arguments[i + 1], to: CommandLine.arguments[i + 2])
    exit(0)
}

let controller = AppController()
controller.start()
app.run()
