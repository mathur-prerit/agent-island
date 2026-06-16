import Foundation
import AgentIslandCore

// Runs the verified AgentIslandCore engine against a real Claude Code transcript and
// prints what it derives. No Xcode, no daemon — just the same logic the self-test
// covers, applied to your actual ~/.claude data.
//
//   swift run AgentIslandDemo                 # auto-picks your most recent session
//   swift run AgentIslandDemo <session.jsonl> # a specific transcript

let fm = FileManager.default
let projectsDir = ("~/.claude/projects" as NSString).expandingTildeInPath

func mostRecentSession() -> String? {
    guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return nil }
    var best: (path: String, mtime: Date)?
    for proj in projects {
        let projPath = "\(projectsDir)/\(proj)"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projPath, isDirectory: &isDir), isDir.boolValue,
              let entries = try? fm.contentsOfDirectory(atPath: projPath) else { continue }
        for entry in entries where entry.hasSuffix(".jsonl") {
            let p = "\(projPath)/\(entry)"
            let mtime = ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast
            if best == nil || mtime > best!.mtime { best = (p, mtime) }
        }
    }
    return best?.path
}

func readLines(_ path: String) -> [String] {
    (try? String(contentsOfFile: path, encoding: .utf8))?
        .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
}

func subAgentCount(forSession sessionPath: String) -> Int {
    let subDir = (sessionPath as NSString).deletingPathExtension + "/subagents"
    guard let walker = fm.enumerator(atPath: subDir) else { return 0 }
    var count = 0
    for case let rel as String in walker {
        let name = (rel as NSString).lastPathComponent
        if name.hasPrefix("agent-") && name.hasSuffix(".jsonl") { count += 1 }
    }
    return count
}

func label(_ status: AgentStatus) -> String {
    switch status {
    case .working: return "WORKING"
    case .waitingForInput(.stoppedTurn): return "WAITING-FOR-INPUT (agent stopped its turn)"
    case .waitingForInput(.permission): return "WAITING (permission prompt)"
    case .finished(let verdict): return "FINISHED (\(verdict))"
    }
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : (mostRecentSession() ?? "")
guard !path.isEmpty, fm.fileExists(atPath: path) else {
    print("No transcript found. Pass one: swift run AgentIslandDemo <session.jsonl>")
    exit(1)
}

let records = TranscriptAdapter.parse(lines: readLines(path))
let assistantCount = records.filter { $0.type == "assistant" }.count
let userCount = records.filter { $0.type == "user" }.count
let metadataCount = records.filter { !TranscriptAdapter.isConversational($0.type) }.count
let status = StateEngine.deriveStatus(records: records, openPermission: false)
let subs = subAgentCount(forSession: path)
let id = String(((path as NSString).lastPathComponent as NSString).deletingPathExtension.prefix(8))

print("agent-island demo — the verified engine on a real Claude Code transcript\n")
print("session: \(id)…   (\(records.count) records parsed)")
print("  \(assistantCount) assistant · \(userCount) user · \(metadataCount) metadata (skipped)")
if let last = TranscriptAdapter.lastConversational(records) {
    let blocks = last.assistantBlockKinds.isEmpty ? "" : "  content blocks \(last.assistantBlockKinds)"
    print("  last conversational record: \(last.type)\(blocks)")
}
print("  -> derived state: \(label(status))")
print("  sub-agents discovered: \(subs)")
print("""

(WORKING vs WAITING is derived from the transcript alone; true FINISHED needs the
 lifecycle layer — daemon + hooks — which isn't wired up yet. Same AgentIslandCore
 logic the 60 self-test checks cover, run against your real data.)
""")
