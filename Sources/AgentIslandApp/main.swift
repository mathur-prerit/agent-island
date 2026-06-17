import AppKit
import Foundation
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

    private let fm = FileManager.default
    private let projectsDir = ("~/.claude/projects" as NSString).expandingTildeInPath
    private let activeWindow: TimeInterval = 1800  // a session touched within 30 min is "active"
    private let pool = BuiltInPersonas.all

    private struct Session {
        let fullID: String; let shortID: String; let label: String
        let status: AgentStatus; let subStatuses: [AgentStatus]; let steps: Int
        let tokens: Int
    }

    func start() {
        statusItem.button?.title = "○"
        menu.autoenablesItems = false
        statusItem.menu = menu
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
    }

    private func refresh() {
        let sessions = activeSessions()

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
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit agent-island", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; quit.isEnabled = true
        menu.addItem(quit)

        let waiting = sessions.filter { isWaiting($0.status) }.count
        let working = sessions.contains { $0.status == .working }
        statusItem.button?.title = waiting > 0 ? "● \(waiting)" : (working ? "◐" : "○")

        if islandEnabled {
            let rows: [IslandPanel.Row]
            if sessions.isEmpty {
                rows = [IslandPanel.Row(glyph: "·", color: .tertiaryLabelColor,
                                        title: "idle", state: "no active sessions (last 30 min)")]
            } else {
                rows = sessions.map { s -> IslandPanel.Row in
                    let skin = persona(for: s).skin(for: s.status)
                    let working = (s.status == .working)
                    let stateText = (working && s.steps > 0) ? "\(skin.label) · \(s.steps) steps" : skin.label
                    let subRows = s.subStatuses.map {
                        IslandPanel.SubRow(glyph: "↳", color: color($0), text: subDescribe($0))
                    }
                    return IslandPanel.Row(glyph: skin.glyph, color: color(s.status),
                                           title: s.label, state: stateText,
                                           pulsing: isWaiting(s.status), spinning: working,
                                           dimmed: isFinished(s.status), subRows: subRows)
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

    // MARK: - Sessions (daemon state if running, else poll transcripts)

    private func activeSessions() -> [Session] { daemonSessions() ?? polledSessions() }

    private func daemonSessions() -> [Session]? {
        let statePath = ("~/.agent-island/state.json" as NSString).expandingTildeInPath
        guard let attrs = try? fm.attributesOfItem(atPath: statePath),
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) < 30,
              let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let state = try? JSONDecoder().decode(DaemonState.self, from: data),
              !state.sessions.isEmpty else { return nil }
        return state.sessions.map { snap in
            var subs: [AgentStatus] = Array(repeating: .working, count: snap.subActive)
            subs += Array(repeating: .finished(.success), count: snap.subDone)
            let short = String(snap.sessionID.prefix(8))
            return Session(fullID: snap.sessionID, shortID: short, label: short,
                           status: AgentStatus(stateToken: snap.state), subStatuses: subs, steps: 0,
                           tokens: 0)
        }
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
                let subs = subAgentStatuses(forSession: p)
                let rolled = Rollup.rollUp(session: sessionStatus, subAgents: subs)
                let steps = records.reduce(0) { $0 + $1.assistantBlockKinds.filter { $0 == "tool_use" }.count }
                let tokens = TokenUsage.freshTokens(lines: lines)
                let fullID = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                let label = ProjectLabel.fromTranscript(lines: lines) ?? String(fullID.prefix(8))
                found.append((Session(fullID: fullID, shortID: String(fullID.prefix(8)),
                                      label: label, status: rolled, subStatuses: subs, steps: steps,
                                      tokens: tokens), mtime))
            }
        }
        return found
            .sorted {
                let ra = DisplayPriority.rank($0.session.status), rb = DisplayPriority.rank($1.session.status)
                return ra != rb ? ra < rb : $0.mtime > $1.mtime
            }
            .map(\.session)
    }

    private func subAgentStatuses(forSession sessionPath: String) -> [AgentStatus] {
        let subDir = (sessionPath as NSString).deletingPathExtension + "/subagents"
        guard let walker = fm.enumerator(atPath: subDir) else { return [] }
        var out: [AgentStatus] = []
        for case let rel as String in walker {
            let name = (rel as NSString).lastPathComponent
            guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { continue }
            out.append(StateEngine.deriveStatus(records: TranscriptAdapter.parse(lines: readLines("\(subDir)/\(rel)")),
                                                 openPermission: false))
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
        case .working: return .systemYellow
        case .waitingForInput: return .systemRed
        case .finished(.failed): return .systemRed
        case .finished: return .systemGreen
        }
    }

    private func subDescribe(_ s: AgentStatus) -> String {
        switch s {
        case .working: return "sub-agent · working"
        case .waitingForInput: return "sub-agent · waiting"
        case .finished(.failed): return "sub-agent · failed"
        case .finished: return "sub-agent · done"
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
let controller = AppController()
controller.start()
app.run()
