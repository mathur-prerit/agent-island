import Foundation

/// The Claude Code session source, behind the `SessionProvider` protocol. This is a STRAIGHT
/// extraction of the App's existing `polledSessions()` (the `~/.claude/projects` scan) — same
/// discovery, same parse (`TranscriptAdapter`/`TranscriptDigest`), same state derivation
/// (`StateEngine` + `Rollup` + the >10-min idle downgrade), same sort. No behavior change: the App's
/// polling path now calls this instead of inlining the logic, and the self-test pins the per-session
/// mapping so any drift fails CI.
///
/// The Claude event-driven path (hooks → daemon → state.json) is unchanged and stays OUTSIDE this
/// provider (it's Claude-only and richer than the poll-only protocol). This provider reproduces the
/// poll path only — the fallback the App already uses when the daemon is down.
public struct ClaudeCodeProvider: SessionProvider {
    public let kind: SessionProviderKind = .claude

    /// A session touched within this window is "active" (the App's `activeWindow`). Kept here so the
    /// discovery filter matches the App verbatim.
    public static let activeWindow: TimeInterval = 1800
    /// A stopped/waiting session quiet longer than this reads as idle-done, not "waiting on you" —
    /// mirrors the daemon's idle downgrade so polling stops nagging on a long-abandoned wait.
    public static let waitingIdleWindow: TimeInterval = 600

    private let projectsDir: String
    private let fm = FileManager.default

    public init(projectsDir: String = (("~/.claude/projects") as NSString).expandingTildeInPath) {
        self.projectsDir = projectsDir
    }

    public func poll(now: Date) -> [ProviderSession] {
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }
        let cutoff = now.addingTimeInterval(-Self.activeWindow)
        var found: [ProviderSession] = []
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
                let fullID = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                let digests = subagentDigests(forTranscript: p)
                found.append(Self.session(lines: lines, fullID: fullID, mtime: mtime,
                                          subDigests: digests, now: now))
            }
        }
        return found.sorted {
            let ra = DisplayPriority.rank($0.status), rb = DisplayPriority.rank($1.status)
            if ra != rb { return ra < rb }
            return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    /// PURE per-transcript mapping — no FS. Byte-identical to the App's old inline polling rule, so
    /// it can be unit-tested from fixture lines: derive status from records + mtime recency, roll the
    /// sub-agents in, apply the >10-min waiting→idle downgrade, then digest for tokens/title/etc.
    public static func session(lines: [String], fullID: String, mtime: Date,
                               subDigests: [SubagentDigest], now: Date = Date()) -> ProviderSession {
        let records = TranscriptAdapter.parse(lines: lines)
        // mtime = last write to the transcript; lets deriveStatus tell a mid-turn text preamble
        // (still working) from a turn that truly stopped (waiting).
        let sessionStatus = StateEngine.deriveStatus(records: records, openPermission: false,
                                                     lastActivity: mtime, now: now)
        var rolled = Rollup.rollUp(session: sessionStatus, subAgents: subDigests.map(\.status))
        // A session stopped (waiting) but quiet past the idle window reads as idle, not "waiting on
        // you" — mirrors the daemon's idle downgrade.
        if case .waitingForInput = rolled, now.timeIntervalSince(mtime) > waitingIdleWindow {
            rolled = .finished(.success)
        }
        let digest = TranscriptDigest.scan(lines: lines)
        let label = ProjectLabel.fromTranscript(lines: lines) ?? String(fullID.prefix(8))
        return ProviderSession(provider: .claude, fullID: fullID, label: label, title: digest.title,
                               status: rolled, tokens: digest.tokens, startedAt: digest.startedAt,
                               steps: digest.steps, subDigests: subDigests, lastActivity: mtime)
    }

    /// Per-sub-agent digests for a session, from its `subagents/agent-*.jsonl` transcripts. Lifted
    /// verbatim from the App's `subagentDigests(forTranscript:)`.
    private func subagentDigests(forTranscript sessionPath: String) -> [SubagentDigest] {
        let subDir = (sessionPath as NSString).deletingPathExtension + "/subagents"
        guard let walker = fm.enumerator(atPath: subDir) else { return [] }
        var out: [SubagentDigest] = []
        for case let rel as String in walker {
            let name = (rel as NSString).lastPathComponent
            guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { continue }
            let full = "\(subDir)/\(rel)"
            let mtime = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date
            out.append(SubagentDigest.fromTranscript(lines: readLines(full), lastActivity: mtime))
        }
        return out
    }

    private func readLines(_ path: String) -> [String] {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
    }
}
