import AppKit
import Foundation
import AgentIslandCore

// agent-island v0 menu-bar app: a status-bar item whose dropdown lists your active
// Claude Code sessions and their derived state, polled from ~/.claude transcripts via
// the verified AgentIslandCore. Runs as a plain SwiftPM executable (a menu-bar accessory
// needs no .app bundle to appear):
//
//   swift run AgentIslandApp          # or pick the AgentIslandApp scheme in Xcode and Run
//
// Quit from the menu (or ⌘Q). Polling is a v0 shortcut — the daemon + hooks (built but
// not yet wired) will replace it for event-driven, lower-overhead updates.

final class AppController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?

    private let fm = FileManager.default
    private let projectsDir = ("~/.claude/projects" as NSString).expandingTildeInPath
    private let activeWindow: TimeInterval = 600  // a session touched within 10 min is "active"

    private struct Session { let id: String; let status: AgentStatus }

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
        menu.removeAllItems()

        if sessions.isEmpty {
            menu.addItem(infoItem("No active Claude Code sessions"))
        } else {
            menu.addItem(infoItem("Active sessions"))
            for s in sessions {
                menu.addItem(infoItem("\(glyph(s.status))  \(s.id)  —  \(describe(s.status))"))
            }
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit agent-island", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        let waiting = sessions.filter { isWaiting($0.status) }.count
        let working = sessions.contains { $0.status == .working }
        statusItem.button?.title = waiting > 0 ? "● \(waiting)" : (working ? "◐" : "○")
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

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
                let id = String(((p as NSString).lastPathComponent as NSString).deletingPathExtension.prefix(8))
                found.append((Session(id: id, status: rolled), mtime))
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

    private func glyph(_ s: AgentStatus) -> String {
        switch s {
        case .working: return "◐"
        case .waitingForInput: return "●"
        case .finished(.failed): return "✗"
        case .finished: return "✓"
        }
    }

    private func describe(_ s: AgentStatus) -> String {
        switch s {
        case .working: return "working"
        case .waitingForInput(.permission): return "waiting (permission)"
        case .waitingForInput: return "waiting for you"
        case .finished(.failed): return "done (failed)"
        case .finished: return "done"
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
let controller = AppController()
controller.start()
app.run()
