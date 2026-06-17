import Foundation
import Darwin
import AgentIslandCore
import PersonaKit
import HookInstall
import AgentIslandDaemon

// Framework-free self-test. Runs under Command Line Tools (no Xcode/XCTest/Testing).
// `swift run AgentIslandSelfTest` — exits non-zero on any failure (usable in CI).

var failures = 0
var total = 0
func check(_ cond: Bool, _ name: String) {
    total += 1
    if cond { print("ok   - \(name)") } else { print("FAIL - \(name)"); failures += 1 }
}
func recs(_ items: [(String, [String])]) -> [TranscriptRecord] {
    items.map { TranscriptRecord(type: $0.0, assistantBlockKinds: $0.1) }
}

// --- State derivation (verified against real ~/.claude transcripts, see spike/FINDINGS.md) ---
check(StateEngine.deriveStatus(records: recs([("user", []), ("assistant", ["thinking", "text"]), ("last-prompt", []), ("ai-title", []), ("permission-mode", [])]), openPermission: false) == .waitingForInput(.stoppedTurn), "metadata tail skipped -> stopped/waiting")
check(StateEngine.deriveStatus(records: recs([("user", []), ("assistant", ["thinking", "text", "tool_use"])]), openPermission: false) == .working, "trailing tool_use -> working")
check(StateEngine.deriveStatus(records: recs([("assistant", ["thinking", "text"])]), openPermission: false) == .waitingForInput(.stoppedTurn), "stopped assistant text -> waiting")
check(StateEngine.deriveStatus(records: recs([("assistant", ["text"]), ("user", [])]), openPermission: false) == .working, "user last -> working")
check(StateEngine.deriveStatus(records: recs([("assistant", ["text", "tool_use"])]), openPermission: true) == .waitingForInput(.permission), "open permission -> waiting(permission)")
check(StateEngine.deriveStatus(records: [], openPermission: false) == .working, "empty transcript -> working")

// --- Parsing ---
check(TranscriptAdapter.parseLine("not json") == nil, "garbage line -> nil")
check(TranscriptAdapter.parseLine("") == nil, "empty line -> nil")
let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text"},{"type":"tool_use"}]}}"#
let rec = TranscriptAdapter.parseLine(line)
check(rec?.type == "assistant" && rec?.assistantBlockKinds == ["text", "tool_use"], "assistant content blocks parsed")
let stream = TranscriptAdapter.parse(lines: [#"{"type":"user"}"#, "garbage{", #"{"type":"ai-title"}"#, #"{"type":"assistant","message":{"content":[{"type":"text"}]}}"#])
check(stream.map(\.type) == ["user", "ai-title", "assistant"], "stream skips unparseable lines")
check(TranscriptAdapter.lastConversational(stream)?.type == "assistant", "last conversational record found")

// --- Rollup (R16 precedence) ---
check(Rollup.rollUp(session: .working, subAgents: [.working, .working, .working, .finished(.success)]) == .working, "AE6: working wins over a finished sub-agent")
let c = Rollup.counts(subAgents: [.working, .working, .working, .finished(.success)])
check(c.working == 3 && c.finished == 1, "AE6: counts = 3 run / 1 done")
check(Rollup.rollUp(session: .finished(.success), subAgents: [.finished(.success), .finished(.success), .finished(.failed)]) == .finished(.failed), "AE10: any failed -> FAILED verdict")
check(Rollup.rollUp(session: .waitingForInput(.permission), subAgents: [.working, .finished(.success)]) == .waitingForInput(.permission), "AE9: developer-block wins")
check(Rollup.rollUp(session: .finished(.success), subAgents: [.finished(.success), .finished(.success)]) == .finished(.success), "all success -> SUCCESS")

// --- Sanitizer (R14: untrusted agent output) ---
check(TaskLineSanitizer.sanitize("\u{1B}[31mrunning\u{1B}[0m tests\u{07}\n") == "running tests", "strip ANSI + control chars")
let trunc = TaskLineSanitizer.sanitize(String(repeating: "a", count: 100), maxLength: 40)
check(trunc.count == 40 && trunc.hasSuffix("…"), "truncate to 40 + ellipsis")
check(TaskLineSanitizer.sanitize("editing    auth\t\tflow") == "editing auth flow", "collapse whitespace incl. tabs")
check(TaskLineSanitizer.sanitize("running tests") == "running tests", "short string passes through")

// --- Escalation ladder (U9, quiet by default) ---
check(EscalationLadder.tier(effectiveElapsed: 0) == .silentPulse, "escalation t=0 -> silent pulse")
check(EscalationLadder.tier(effectiveElapsed: 30) == .bounce, "escalation t=30 -> bounce")
check(EscalationLadder.tier(effectiveElapsed: 60) == .brightness, "escalation t=60 -> brightness")
check(EscalationLadder.tier(effectiveElapsed: 999) == .brightness, "AE2: muted default caps at brightness (no sound)")
var loud = EscalationConfig(); loud.hapticEnabled = true; loud.soundEnabled = true
check(EscalationLadder.tier(effectiveElapsed: 90, config: loud) == .haptic, "haptic enabled, t=90 -> haptic")
check(EscalationLadder.tier(effectiveElapsed: 120, config: loud) == .sound, "sound enabled, t=120 -> sound")
check(WaitingClock.effectiveElapsed(rawElapsed: 100, snoozedTotal: 70) == 30, "AE11: snooze subtracts, escalation resumes mid-ladder")

// --- Auto-close (U10) ---
check(AutoClose.closesWaiting(eventSessionId: "s1", eventType: "UserPromptSubmit", waitingSessionId: "s1"), "AE4: input to the waiting session closes it")
check(!AutoClose.closesWaiting(eventSessionId: "s2", eventType: "UserPromptSubmit", waitingSessionId: "s1"), "input to another session does NOT close s1")
check(AutoClose.closesWaiting(eventSessionId: "s1", eventType: "SessionEnd", waitingSessionId: "s1"), "SessionEnd closes the session")
check(!AutoClose.closesWaiting(eventSessionId: "s1", eventType: "Stop", waitingSessionId: "s1"), "Stop does not close WAITING")
check(AutoClose.isStale(lastEventElapsed: 600, timeout: 300), "ungraceful-quit staleness expires the strip")
check(!AutoClose.isStale(lastEventElapsed: 100, timeout: 300), "recent session is not stale")

// --- PersonaKit pack validation (U11, security acceptance criteria) ---
check(PackValidator.validateAssetPath("icons/done.png") == nil, "valid relative asset path ok")
check(PackValidator.validateAssetPath("../escape.png") == .pathTraversal("../escape.png"), "Zip-Slip: ../ path rejected")
check(PackValidator.validateAssetPath("/etc/passwd") == .pathTraversal("/etc/passwd"), "absolute asset path rejected")
check(PackValidator.validateAsset("evil.svg") == .disallowedAsset("evil.svg"), "SVG disallowed by allowlist")
check(PackValidator.validateAsset("done.png") == nil, "png asset allowed")
check(PackValidator.checkLimits(archiveBytes: 1_000, uncompressedBytes: 2_000_000, fileCount: 5, largestFileBytes: 1_000) == .compressionBomb, "zip bomb (ratio) rejected")
check(PackValidator.checkLimits(archiveBytes: 20 * 1024 * 1024, uncompressedBytes: 30 * 1024 * 1024, fileCount: 5, largestFileBytes: 1_000) == .archiveTooLarge, "oversized archive rejected")
check(PackValidator.checkLimits(archiveBytes: 1_000, uncompressedBytes: 2_000, fileCount: 5, largestFileBytes: 500) == nil, "pack within limits ok")
check(PackValidator.validateManifestKeys(["name", "version", "slots", "exec"]) == .unknownSchemaField("exec"), "unknown manifest field (e.g. exec) rejected")
check(PackValidator.validateManifestKeys(["name", "version", "slots", "copy"]) == nil, "known manifest fields ok")
check(PackValidator.validateSlotKeys(["working", "finished", "totallyNewState"]) == .unknownState("totallyNewState"), "pack cannot introduce a new state slot")
check(PackValidator.validateSlotKeys(["working", "waitingForInput", "finished"]) == nil, "canonical slots ok")

// --- Hook installer safe-merge (U4) ---
func ourEntryCount(_ data: Data, event: String, command: String) -> Int {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hooks = root["hooks"] as? [String: Any],
          let entries = hooks[event] as? [[String: Any]] else { return -1 }
    return entries.filter { e in
        (e["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String) == command } ?? false
    }.count
}
func installed(_ existing: Data, _ cmd: String, _ events: [String]) -> Data? {
    if case .success(let d) = SettingsMerge.install(existing: existing, command: cmd, events: events) { return d }
    return nil
}
func abortsOnInvalid() -> Bool {
    if case .failure(.invalidJSON) = SettingsMerge.install(existing: Data("not json".utf8), command: "x", events: ["Stop"]) { return true }
    return false
}
let cmd = "/usr/local/bin/agentisland hook"
check(abortsOnInvalid(), "U4: malformed settings.json -> abort, do not overwrite")
let d1 = installed(Data(), cmd, ["Stop", "UserPromptSubmit"])
check(d1 != nil && ourEntryCount(d1!, event: "Stop", command: cmd) == 1, "U4: hook added for Stop")
let d2 = d1.flatMap { installed($0, cmd, ["Stop", "UserPromptSubmit"]) }
check(d2 != nil && ourEntryCount(d2!, event: "Stop", command: cmd) == 1, "U4: re-install is idempotent (no duplicate)")
let existingSettings = Data(#"{"otherKey":42,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/other/tool"}]}]}}"#.utf8)
let d3 = installed(existingSettings, cmd, ["Stop"])
let root3 = d3.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
check((root3?["otherKey"] as? Int) == 42, "U4: unknown top-level keys preserved")
check(d3 != nil && ourEntryCount(d3!, event: "Stop", command: cmd) == 1, "U4: our entry added alongside existing")
let stopEntries = ((root3?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]) ?? []
let hasOther = stopEntries.contains { ($0["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String) == "/other/tool" } ?? false }
check(hasOther, "U4: existing third-party hook preserved")

// U4b: app (quoted abs path) and CLI (unquoted argv0) relay hooks interoperate — no strand, no dup.
let appCmd = "\"/Applications/AgentIsland.app/Contents/MacOS/AgentIslandHookCLI\" relay"
let cliCmd = "/Users/me/.build/debug/AgentIslandHookCLI relay"
check(SettingsMerge.isAgentIslandRelay(appCmd) && SettingsMerge.isAgentIslandRelay(cliCmd), "U4b: both relay forms recognised by signature")
let appHooked = installed(Data(), appCmd, ["Stop"])!
let bothHooked = installed(appHooked, cliCmd, ["Stop"])!   // CLI install dedupes against the app's hook
check(ourEntryCount(bothHooked, event: "Stop", command: appCmd) == 1, "U4b: app+CLI relay forms dedupe to a single entry")
if case .success(let cleaned) = SettingsMerge.uninstall(existing: appHooked, command: cliCmd) {
    check(ourEntryCount(cleaned, event: "Stop", command: appCmd) == 0, "U4b: CLI-form uninstall removes the app-installed hook (no strand)")
} else { check(false, "U4b: cross-form uninstall succeeded") }

// --- Daemon IPC (U3) ---
check(FrameCodec.isAcceptableLength(0), "frame length 0 acceptable")
check(FrameCodec.isAcceptableLength(FrameCodec.maxMessageBytes), "frame length at 64KB cap acceptable")
check(!FrameCodec.isAcceptableLength(FrameCodec.maxMessageBytes + 1), "frame over 64KB cap rejected")
check(!FrameCodec.isAcceptableLength(-1), "negative frame length rejected")
let enc = FrameCodec.encode(Data("hello".utf8))
check(enc.count == 4 + 5, "encoded frame = 4-byte prefix + payload")
check(FrameCodec.decodeLength(Array(enc.prefix(4))) == 5, "length prefix decodes to payload size")
let payload = Data(#"{"type":"Stop","session_id":"s1"}"#.utf8)
check(SocketRoundTrip.loopback(payload) == payload, "U3: framed message round-trips over a real AF_UNIX socketpair")
let myUID = UInt32(getuid())
check(PeerCred.isAuthorized(peerEUID: myUID, daemonEUID: myUID), "same-uid peer authorized")
check(!PeerCred.isAuthorized(peerEUID: myUID &+ 1, daemonEUID: myUID), "different-uid peer rejected")

// --- Personas (U12) ---
check(BuiltInPersonas.all.count >= 3, "ships >=3 built-in personas")
let personaA = PersonaRuntime.persona(forSessionID: "session-abc", pool: BuiltInPersonas.all)
let personaB = PersonaRuntime.persona(forSessionID: "session-abc", pool: BuiltInPersonas.all)
check(personaA != nil && personaA == personaB, "persona is stable per session id (session-locked, no storage)")
check(PersonaRuntime.persona(forSessionID: "x", pool: []) == nil, "empty pool -> nil persona")
let personaStates: [AgentStatus] = [.working, .waitingForInput(.stoppedTurn), .waitingForInput(.permission), .finished(.success), .finished(.failed)]
var allSkinned = true
for persona in BuiltInPersonas.all {
    for st in personaStates {
        let sk = persona.skin(for: st)
        if sk.glyph.isEmpty || sk.label.isEmpty { allSkinned = false }
    }
}
check(allSkinned, "every persona has a glyph + label for all states")
let personasChosen = Set((0..<50).map { PersonaRuntime.persona(forSessionID: "s\($0)", pool: BuiltInPersonas.all)?.name ?? "" })
check(personasChosen.count >= 2, "different sessions get different personas")

// --- Hook installer file I/O (SettingsFile) ---
let tmpDir = NSTemporaryDirectory() + "ai-settings-\(getpid())"
try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
let settingsTestPath = tmpDir + "/settings.json"
try? Data(#"{"otherKey":7}"#.utf8).write(to: URL(fileURLWithPath: settingsTestPath))
let installedOK = (try? SettingsFile.install(settingsPath: settingsTestPath, command: "/x/hook relay", events: ["Stop"])) != nil
check(installedOK, "SettingsFile.install succeeds on a real file")
func parsedHookCount(_ path: String, event: String, command: String) -> Int {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hooks = root["hooks"] as? [String: Any],
          let entries = hooks[event] as? [[String: Any]] else { return -1 }
    return entries.filter { ($0["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String) == command } ?? false }.count
}
func parsedOtherKey(_ path: String) -> Int? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return root["otherKey"] as? Int
}
check(parsedOtherKey(settingsTestPath) == 7 && parsedHookCount(settingsTestPath, event: "Stop", command: "/x/hook relay") == 1,
      "install preserves other keys + adds our hook")
check(FileManager.default.fileExists(atPath: settingsTestPath + ".bak"), "install writes a .bak backup")
_ = try? SettingsFile.install(settingsPath: settingsTestPath, command: "/x/hook relay", events: ["Stop"])
check(parsedHookCount(settingsTestPath, event: "Stop", command: "/x/hook relay") == 1, "re-install is idempotent (command appears once)")
let bakAfterReinstall = (try? String(contentsOfFile: settingsTestPath + ".bak", encoding: .utf8)) ?? ""
check(bakAfterReinstall.contains("otherKey") && !bakAfterReinstall.contains("hooks"), "re-install preserves the pristine .bak (original config, no hooks)")
try? Data("not json".utf8).write(to: URL(fileURLWithPath: settingsTestPath))
var installAborted = false
do { try SettingsFile.install(settingsPath: settingsTestPath, command: "/x/hook relay", events: ["Stop"]) } catch { installAborted = true }
check(installAborted, "corrupt settings.json -> install throws (no clobber)")
check(((try? String(contentsOfFile: settingsTestPath, encoding: .utf8)) ?? "") == "not json", "corrupt file left untouched")
try? FileManager.default.removeItem(atPath: tmpDir)

// --- Daemon event routing + state store (event-driven path) ---
check(EventRouter.status(forEventType: "UserPromptSubmit") == .working, "UserPromptSubmit -> working")
check(EventRouter.status(forEventType: "Stop") == .waitingForInput(.stoppedTurn), "Stop -> waiting (stopped turn)")
check(EventRouter.status(forEventType: "PermissionRequest") == .waitingForInput(.permission), "PermissionRequest -> waiting (permission)")
check(EventRouter.status(forEventType: "SessionEnd") == .finished(.unknown), "SessionEnd -> finished")
check(EventRouter.status(forEventType: "SubagentStart") == nil, "SubagentStart -> sub-agent tracking, not session state")
let daemonStore = StateStore()
daemonStore.apply(eventType: "UserPromptSubmit", sessionID: "s1")
check(daemonStore.snapshot().sessions.first?.state == "working", "store: UserPromptSubmit -> working")
daemonStore.apply(eventType: "Stop", sessionID: "s1")
check(daemonStore.snapshot().sessions.first?.state == "waiting", "store: Stop -> waiting")
daemonStore.apply(eventType: "SubagentStart", sessionID: "s1")
daemonStore.apply(eventType: "SubagentStart", sessionID: "s1")
daemonStore.apply(eventType: "SubagentStop", sessionID: "s1")
let daemonSnap = daemonStore.snapshot().sessions.first
check(daemonSnap?.subActive == 1 && daemonSnap?.subDone == 1, "store: sub-agent counts (2 start, 1 stop -> 1 active, 1 done)")
check(!daemonStore.apply(eventType: "Stop", sessionID: ""), "store ignores empty session id")
let daemonState = DaemonState(sessions: [SessionSnapshot(sessionID: "s1", state: "waiting", subActive: 1, subDone: 1)])
let daemonEncoded = (try? JSONEncoder().encode(daemonState)) ?? Data()
let daemonDecoded = try? JSONDecoder().decode(DaemonState.self, from: daemonEncoded)
check(daemonDecoded == daemonState, "DaemonState JSON round-trips")
check(AgentStatus.working.stateToken == "working" && AgentStatus(stateToken: "waiting") == .waitingForInput(.stoppedTurn), "AgentStatus <-> token mapping")

// daemon: project-name label from cwd + idle pruning (injectable clock)
let labelStore = StateStore()
let t0 = Date(timeIntervalSince1970: 1_700_000_000)
_ = labelStore.apply(eventType: "SessionStart", sessionID: "p1",
                     cwd: "/Users/me/projects/fibr/fpt/fpt-be-external-data-service", at: t0)
check(labelStore.snapshot(now: t0).sessions.first?.label == "fpt-be-external-data-service", "daemon derives project-name label from cwd")
check(labelStore.snapshot(now: t0.addingTimeInterval(60)).sessions.count == 1, "daemon keeps a session within the 30m window")
check(labelStore.snapshot(now: t0.addingTimeInterval(1801)).sessions.isEmpty, "daemon prunes a session idle >30m")
let idleStore = StateStore()
let tw = Date(timeIntervalSince1970: 1_700_000_000)
_ = idleStore.apply(eventType: "Stop", sessionID: "w1", at: tw)   // Stop -> waiting
check(idleStore.snapshot(now: tw.addingTimeInterval(60)).sessions.first?.state == "waiting", "recently-stopped session still reads waiting")
check(idleStore.snapshot(now: tw.addingTimeInterval(601)).sessions.first?.state == "done", "stopped & quiet >10m downgrades waiting -> done (idle)")

// journey theme: vehicle upgrades by token band
check(JourneyMilestones.vehicle(forTokens: 10_000) == "🚲", "journey: <50k -> cycle")
check(JourneyMilestones.vehicle(forTokens: 75_000) == "🚗", "journey: 50-100k -> car")
check(JourneyMilestones.vehicle(forTokens: 150_000) == "🚆", "journey: 100-200k -> train")
check(JourneyMilestones.vehicle(forTokens: 250_000) == "✈️", "journey: >=200k -> plane (danger)")

// --- Token usage ---
let usageLines = [
    #"{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":9999}}}"#,
    #"{"type":"user"}"#,
    "garbage{",
    #"{"type":"assistant","usage":{"input_tokens":10,"output_tokens":5}}"#,
]
check(TokenUsage.freshTokens(lines: usageLines) == 165, "freshTokens sums input+output across both usage shapes, ignoring cache")
check(TokenUsage.freshTokens(lines: []) == 0, "freshTokens empty -> 0")
check(TokenUsage.compact(999) == "999", "compact < 1000 is raw")
check(TokenUsage.compact(1500) == "1.5k", "compact thousands one-decimal")
check(TokenUsage.compact(146_000) == "146k", "compact tens-of-thousands integer k")
check(TokenUsage.compact(2_870_000) == "2.9M", "compact millions one-decimal")

// --- Project label (uses LAST cwd, not first — fixes the "preritmathur" bug) ---
let cwdLines = [
    #"{"type":"user","cwd":"/Users/preritmathur"}"#,
    #"{"type":"assistant"}"#,
    #"{"type":"user","cwd":"/Users/preritmathur/projects/prerit/agent-island"}"#,
]
check(ProjectLabel.fromTranscript(lines: cwdLines) == "agent-island", "label uses last cwd (project), not first (launch dir)")
check(ProjectLabel.fromTranscript(lines: [#"{"type":"user"}"#]) == nil, "label nil when no cwd present")

// --- Display priority: states that need you float to the top ---
check(DisplayPriority.rank(.waitingForInput(.permission)) < DisplayPriority.rank(.waitingForInput(.stoppedTurn)), "permission outranks stopped-turn waiting")
check(DisplayPriority.rank(.waitingForInput(.stoppedTurn)) < DisplayPriority.rank(.finished(.failed)), "waiting-for-you outranks failed")
check(DisplayPriority.rank(.finished(.failed)) < DisplayPriority.rank(.working), "failed outranks running")
check(DisplayPriority.rank(.working) < DisplayPriority.rank(.finished(.success)), "running outranks finished-success")

print("")
if failures == 0 {
    print("ALL PASS — \(total) checks")
    exit(0)
} else {
    print("FAILURES: \(failures) of \(total)")
    exit(1)
}
