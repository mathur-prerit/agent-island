import AppKit
import Foundation
import AgentIslandCore
import PersonaKit

// agent-island v0 app: a menu-bar (accessory) item plus an always-on-top floating
// "island" panel. Both list your active Claude Code sessions and their derived state,
// polled from ~/.claude transcripts via the verified AgentIslandCore, and each session
// wears a persona (PersonaKit) locked to it for the session. Plain SwiftPM executable:
//
//   swift run AgentIslandApp          # or pick the AgentIslandApp scheme in Xcode and Run
//
// Color stays core-owned (legibility); personas vary only glyph + wording. The island
// appears (top-right) only while sessions are active; toggle it or quit from the menu.
// Polling is a v0 shortcut — the daemon + hooks will replace it with event-driven updates.

final class AppController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let island = IslandPanel()
    private var timer: Timer?
    private var islandEnabled = true

    private let fm = FileManager.default
    private let projectsDir = ("~/.claude/projects" as NSString).expandingTildeInPath
    private let activeWindow: TimeInterval = 600  // a session touched within 10 min is "active"
    private let pool = BuiltInPersonas.all

    private struct Session { let fullID: String; let shortID: String; let status: AgentStatus }

    func start() {
        statusItem.button?.title = "○"
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        let sessions = activeSessions()

        // Menu-bar dropdown
        menu.removeAllItems()
        if sessions.isEmpty {
            menu.addItem(infoItem("No active Claude Code sessions"))
        } else {
            menu.addItem(infoItem("Active sessions"))
            for s in sessions { menu.addItem(infoItem(rowText(for: s))) }
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Show floating island", action: #selector(toggleIsland), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = true
        toggle.state = islandEnabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit agent-island", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        // Menu-bar glyph reflects the most-urgent state (core glyphs, not persona-specific).
        let waiting = sessions.filter { isWaiting($0.status) }.count
        let working = sessions.contains { $0.status == .working }
        statusItem.button?.title = waiting > 0 ? "● \(waiting)" : (working ? "◐" : "○")

        // Floating island
        if islandEnabled && !sessions.isEmpty {
            let rows = sessions.map {
                IslandPanel.Row(glyph: persona(for: $0).skin(for: $0.status).glyph,
                                color: color($0.status),
                                text: rowText(for: $0, includeGlyph: false))
            }
            island.update(rows: rows)
            layoutIsland(rowCount: rows.count)
            island.orderFrontRegardless()
        } else {
            island.orderOut(nil)
        }
    }

    private func rowText(for s: Session, includeGlyph: Bool = true) -> String {
        let skin = persona(for: s).skin(for: s.status)
        let prefix = includeGlyph ? "\(skin.glyph)  " : ""
        return "\(prefix)\(s.shortID)  —  \(skin.label)"
    }

    private func persona(for s: Session) -> Persona {
        PersonaRuntime.persona(forSessionID: s.fullID, pool: pool) ?? BuiltInPersonas.minimal
    }

    private func layoutIsland(rowCount: Int) {
        let width: CGFloat = 340
        let height = CGFloat(12 + (rowCount + 1) * 20 + 12)  // header row + N session rows + insets
        var frame = NSRect(x: 0, y: 0, width: width, height: height)
        if let visible = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: visible.maxX - width - 16, y: visible.maxY - height - 16)
        }
        island.setFrame(frame, display: true)
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func toggleIsland() { islandEnabled.toggle(); refresh() }

    // MARK: - Derivation from real transcripts

    private func activeSessions() -> [Session] {
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
                let records = TranscriptAdapter.parse(lines: readLines(p))
                let sessionStatus = StateEngine.deriveStatus(records: records, openPermission: false)
                let rolled = Rollup.rollUp(session: sessionStatus, subAgents: subAgentStatuses(forSession: p))
                let fullID = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                found.append((Session(fullID: fullID, shortID: String(fullID.prefix(8)), status: rolled), mtime))
            }
        }
        return found.sorted { $0.mtime > $1.mtime }.map(\.session)
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

    private func isWaiting(_ s: AgentStatus) -> Bool {
        if case .waitingForInput = s { return true } else { return false }
    }

    private func color(_ s: AgentStatus) -> NSColor {
        switch s {
        case .working: return .systemYellow
        case .waitingForInput: return .systemRed
        case .finished(.failed): return .systemRed
        case .finished: return .systemGreen
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
let controller = AppController()
controller.start()
app.run()
