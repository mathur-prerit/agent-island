import Foundation
import Darwin
import AgentIslandCore
import PersonaKit
import HookInstall
import AgentIslandDaemon
import AgentIslandThemes

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
// Recency disambiguation: a text-tail (stopped turn) touched within the window is a mid-turn
// preamble before the next tool call -> WORKING; quiet past the window -> truly waiting.
let recencyBase = Date(timeIntervalSince1970: 1_700_000_000)
let textTail = recs([("user", []), ("assistant", ["thinking", "text"])])
check(StateEngine.deriveStatus(records: textTail, openPermission: false,
        lastActivity: recencyBase, now: recencyBase.addingTimeInterval(3)) == .working,
      "recent text-tail (within window) -> working (mid-turn, not waiting)")
check(StateEngine.deriveStatus(records: textTail, openPermission: false,
        lastActivity: recencyBase, now: recencyBase.addingTimeInterval(120)) == .waitingForInput(.stoppedTurn),
      "stale text-tail (past window) -> waiting")
check(StateEngine.deriveStatus(records: textTail, openPermission: false) == .waitingForInput(.stoppedTurn),
      "text-tail with no recency info -> waiting (original behavior preserved)")
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
// Self-heal on upgrade: re-installing with an extra event adds only the new hook (keeps the rest).
_ = try? SettingsFile.install(settingsPath: settingsTestPath, command: "/x/hook relay", events: ["Stop", "PostToolUse"])
check(parsedHookCount(settingsTestPath, event: "PostToolUse", command: "/x/hook relay") == 1
      && parsedHookCount(settingsTestPath, event: "Stop", command: "/x/hook relay") == 1,
      "install with a newly-added event self-heals (adds PostToolUse, keeps Stop once)")
// Semantic no-op: a fully-hooked but non-canonically-formatted file is left byte-untouched on
// re-install (so the self-healing launch re-install doesn't reformat a user's hand-edited file).
if let obj = try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: URL(fileURLWithPath: settingsTestPath))) ?? Data()),
   let compact = try? JSONSerialization.data(withJSONObject: obj) {   // compact = non-canonical formatting
    try? compact.write(to: URL(fileURLWithPath: settingsTestPath))
    _ = try? SettingsFile.install(settingsPath: settingsTestPath, command: "/x/hook relay", events: ["Stop", "PostToolUse"])
    let after = (try? Data(contentsOf: URL(fileURLWithPath: settingsTestPath))) ?? Data()
    check(after == compact, "re-install leaves a fully-hooked non-canonical file untouched (semantic no-op, no reformat)")
}
try? Data("not json".utf8).write(to: URL(fileURLWithPath: settingsTestPath))
var installAborted = false
do { try SettingsFile.install(settingsPath: settingsTestPath, command: "/x/hook relay", events: ["Stop"]) } catch { installAborted = true }
check(installAborted, "corrupt settings.json -> install throws (no clobber)")
check(((try? String(contentsOfFile: settingsTestPath, encoding: .utf8)) ?? "") == "not json", "corrupt file left untouched")
try? FileManager.default.removeItem(atPath: tmpDir)

// --- Daemon event routing + state store (event-driven path) ---
check(EventRouter.status(forEventType: "UserPromptSubmit") == .working, "UserPromptSubmit -> working")
check(EventRouter.status(forEventType: "Stop") == .waitingForInput(.stoppedTurn), "Stop -> waiting (stopped turn)")
check(EventRouter.status(forEventType: "PostToolUse") == .working, "PostToolUse -> working (re-arms a mid-loop Stop)")
check(EventRouter.status(forEventType: "PermissionRequest") == .waitingForInput(.permission), "PermissionRequest -> waiting (permission)")
check(EventRouter.status(forEventType: "SessionEnd") == .finished(.unknown), "SessionEnd -> finished")
check(EventRouter.status(forEventType: "SubagentStart") == nil, "SubagentStart -> sub-agent tracking, not session state")
let daemonStore = StateStore()
daemonStore.apply(eventType: "UserPromptSubmit", sessionID: "s1")
check(daemonStore.snapshot().sessions.first?.state == "working", "store: UserPromptSubmit -> working")
daemonStore.apply(eventType: "Stop", sessionID: "s1")
check(daemonStore.snapshot().sessions.first?.state == "waiting", "store: Stop -> waiting")
daemonStore.apply(eventType: "PostToolUse", sessionID: "s1")
check(daemonStore.snapshot().sessions.first?.state == "working", "store: PostToolUse re-arms working after a mid-loop Stop")
// A terminal session must NOT be revived by a straggler PostToolUse that raced past SessionEnd.
let endStore = StateStore()
endStore.apply(eventType: "SessionEnd", sessionID: "e1")
endStore.apply(eventType: "PostToolUse", sessionID: "e1")
check(endStore.snapshot().sessions.first?.state == "done", "store: PostToolUse does not revive a SessionEnd'd session")
daemonStore.apply(eventType: "Stop", sessionID: "s1")   // restore waiting for the sub-agent count checks below
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

// road-trip scrolling scene: pure layout math (vehicle stage, scrolling signs, towns, takeoff)
check(RoadJourney.stage(forTokens: 10_000) == .cycle, "road: <50k -> cycle stage")
check(RoadJourney.stage(forTokens: 75_000) == .car, "road: 50-100k -> car stage")
check(RoadJourney.stage(forTokens: 150_000) == .train, "road: 100-200k -> train stage")
check(RoadJourney.stage(forTokens: 250_000) == .plane, "road: >=200k -> plane stage")
let fresh = RoadJourney.layout(tokens: 0, viewWidth: 150)
check(fresh.vehicleX == 150 * 0.26, "road: vehicle pinned at anchorRatio of the width")
check(!fresh.airborne, "road: not airborne below 200k")
check(fresh.signs.allSatisfy { $0.tokens % RoadJourney.signEvery == 0 }, "road: every sign is a 5k multiple")
check(fresh.signs.allSatisfy { $0.label == "\($0.tokens / 1000)k" }, "road: sign labels are <n>k")
let first = fresh.signs.min { $0.tokens < $1.tokens }
check(first?.tokens == 5_000 && (first?.x ?? 0) > fresh.vehicleX, "road: at 0 tokens the first 5k sign is ahead of the vehicle")
check(fresh.signs.allSatisfy { !$0.isMajor }, "road: early 5k signs are minor posts, not towns")
let pastTown = RoadJourney.layout(tokens: 52_000, viewWidth: 150)
check(pastTown.stage == .car, "road: just past 50k drives the car")
check(pastTown.signs.contains { $0.tokens == 50_000 && $0.isMajor && $0.x < pastTown.vehicleX },
      "road: the passed 50k upgrade town is a signboard lingering behind the vehicle")
let flying = RoadJourney.layout(tokens: 220_000, viewWidth: 150)
check(flying.airborne && flying.stage == .plane, "road: past 200k the plane has taken off")
check(RoadJourney.layout(tokens: -5, viewWidth: 150).signs.first?.tokens == 5_000, "road: negative tokens clamp to the start")

// --- Sound transitions (edge-triggered) + throttle (drives the Road Runner lifecycle cues) ---
check(TransitionDetector.transition(from: nil, to: .working) == nil,
      "transition: first sighting is a silent baseline")
check(TransitionDetector.transition(from: .waitingForInput(.stoppedTurn), to: .working) == .startedWorking,
      "transition: waiting -> working fires startedWorking (game start)")
check(TransitionDetector.transition(from: .working, to: .working) == nil,
      "transition: working -> working is silent")
check(TransitionDetector.transition(from: .working, to: .waitingForInput(.stoppedTurn)) == .enteredWaiting(.stoppedTurn),
      "transition: working -> waiting(stopped) fires enteredWaiting (checkpoint / your turn)")
check(TransitionDetector.transition(from: .working, to: .waitingForInput(.permission)) == .enteredWaiting(.permission),
      "transition: working -> waiting(permission) fires enteredWaiting")
check(TransitionDetector.transition(from: .waitingForInput(.stoppedTurn), to: .waitingForInput(.permission)) == nil,
      "transition: already waiting does not re-fire")
check(TransitionDetector.transition(from: .working, to: .finished(.success)) == .enteredFinished(.success),
      "transition: -> finished(success) fires goal")
check(TransitionDetector.transition(from: .working, to: .finished(.failed)) == .enteredFinished(.failed),
      "transition: -> finished(failed) fires game over")
check(TransitionDetector.transition(from: .finished(.success), to: .finished(.success)) == nil,
      "transition: already finished does not re-fire")
// default (non-theme) cue set: pure transition -> clip-name mapping (App resolves names to WAVs)
check(DefaultSoundSet.clipName(for: .startedWorking) == "started",
      "default set: startedWorking -> started")
check(DefaultSoundSet.clipName(for: .enteredWaiting(.stoppedTurn)) == "waiting",
      "default set: enteredWaiting(stopped) -> waiting")
check(DefaultSoundSet.clipName(for: .enteredWaiting(.permission)) == "waiting",
      "default set: enteredWaiting(permission) -> waiting (same neutral cue)")
check(DefaultSoundSet.clipName(for: .enteredFinished(.success)) == "finished_ok",
      "default set: finished(success) -> finished_ok")
check(DefaultSoundSet.clipName(for: .enteredFinished(.failed)) == "finished_fail",
      "default set: finished(failed) -> finished_fail")
check(DefaultSoundSet.clipName(for: .enteredFinished(.unknown)) == nil,
      "default set: finished(unknown) -> nil (silent, matching the theme)")

let throttleBase = Date(timeIntervalSince1970: 1_700_000_000)
check(PlayThrottle.allows(now: throttleBase, last: .distantPast, cooldown: 1.0), "throttle: first play allowed")
check(!PlayThrottle.allows(now: throttleBase.addingTimeInterval(0.5), last: throttleBase, cooldown: 1.0), "throttle: within cooldown blocked")
check(PlayThrottle.allows(now: throttleBase.addingTimeInterval(1.0), last: throttleBase, cooldown: 1.0), "throttle: at cooldown boundary allowed")

// --- Token usage ---
let usageLines = [
    #"{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":9999}}}"#,
    #"{"type":"user"}"#,
    "garbage{",
    #"{"type":"assistant","usage":{"input_tokens":10,"output_tokens":5}}"#,
]
check(TokenUsage.freshTokens(lines: usageLines) == 10154,
      "freshTokens = peak context (max input+cache_read+cache_creation = 100+9999) + output deduped per message (50+5)")
check(TokenUsage.freshTokens(lines: []) == 0, "freshTokens empty -> 0")

// Token meter must (a) count one message's streamed-block records ONCE (dedup by message.id),
// (b) include the cache fields where the real context lives, and (c) take PEAK context — a later
// compaction/summary record with smaller context must not lower the figure.
let tokenMeterLines = [
    // message m1 streamed across 3 records — all carry the SAME usage; output must count once.
    #"{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":5,"output_tokens":200,"cache_read_input_tokens":40000,"cache_creation_input_tokens":1000}}}"#,
    #"{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":5,"output_tokens":200,"cache_read_input_tokens":40000,"cache_creation_input_tokens":1000}}}"#,
    #"{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":5,"output_tokens":200,"cache_read_input_tokens":40000,"cache_creation_input_tokens":1000}}}"#,
    // message m2 — a later, larger request: this is the peak context (60007).
    #"{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":7,"output_tokens":300,"cache_read_input_tokens":60000}}}"#,
    // trailing summary/compaction record with tiny context — must NOT lower the peak.
    #"{"type":"assistant","message":{"id":"m3","usage":{"input_tokens":1,"output_tokens":0}}}"#,
]
check(TokenUsage.freshTokens(lines: tokenMeterLines) == 60507,
      "token meter: peak context 60007 (m2) + deduped output 500 (m1 200 once + m2 300 + m3 0); streamed dupes counted once, compaction record doesn't shrink it")
check(TranscriptDigest.scan(lines: tokenMeterLines).tokens == TokenUsage.freshTokens(lines: tokenMeterLines),
      "scan.tokens mirrors freshTokens on the dedup/peak fixture")
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

// --- Conversation title (latest non-empty ai-title wins) ---
let titleLines = [
    #"{"type":"ai-title","aiTitle":"First guess"}"#,
    #"{"type":"assistant","message":{"content":[{"type":"text"}]}}"#,
    #"{"type":"ai-title","aiTitle":"Refined title"}"#,
    #"{"type":"ai-title","aiTitle":"   "}"#,
]
check(ConversationTitle.fromTranscript(lines: titleLines) == "Refined title", "title: latest non-empty ai-title wins")
check(ConversationTitle.fromTranscript(lines: [#"{"type":"user"}"#]) == nil, "title: nil when no ai-title record")

// --- Transcript clock: session start + durations from ISO-8601 timestamps ---
let tsLines = [
    #"{"type":"system"}"#,
    #"{"type":"user","timestamp":"2026-06-17T16:11:38.253Z"}"#,
    #"{"type":"assistant","timestamp":"2026-06-17T16:14:38.253Z"}"#,
]
check(TranscriptClock.startedAt(lines: tsLines) != nil, "clock: startedAt = first timestamped record")
let span = TranscriptClock.span(lines: tsLines)
check(span.first != nil && span.last.map { Int($0.timeIntervalSince(span.first!)) } == 180, "clock: span first..last = 180s")
check(TranscriptClock.startedAt(lines: [#"{"type":"system"}"#]) == nil, "clock: nil when no timestamps")
check(TranscriptClock.durationLabel(43) == "43s", "clock: <60s -> seconds")
check(TranscriptClock.durationLabel(720) == "12m", "clock: minutes")
check(TranscriptClock.durationLabel(7200) == "2h", "clock: hours")
check(TranscriptClock.durationLabel(60 * 60 * 24 * 3) == "3d", "clock: days")
let clockBase = TranscriptClock.parse("2026-06-17T16:11:38.253Z")!
check(TranscriptClock.elapsedLabel(from: clockBase, to: clockBase.addingTimeInterval(600)) == "10m", "clock: elapsedLabel from->to")
check(TranscriptClock.parse("2026-06-17T16:11:38Z") != nil, "clock: parses timestamp without fractional seconds")

// --- First user text (descriptive sub-agent name source) ---
check(TranscriptAdapter.firstUserText(lines: [
    #"{"type":"system"}"#,
    #"{"type":"user","message":{"content":"Survey the package"}}"#,
]) == "Survey the package", "firstUserText: plain string content")
check(TranscriptAdapter.firstUserText(lines: [
    #"{"type":"user","message":{"content":[{"type":"text","text":"Trace the daemon"}]}}"#,
]) == "Trace the daemon", "firstUserText: first text block")
check(TranscriptAdapter.firstUserText(lines: [#"{"type":"assistant"}"#]) == nil, "firstUserText: nil when no user record")

// --- Sub-agent digest: name + tokens + status + duration from one agent-*.jsonl ---
let subLines = [
    #"{"type":"user","timestamp":"2026-06-17T15:32:04Z","message":{"content":"Survey the Swift package at /path and list modules"}}"#,
    #"{"type":"assistant","timestamp":"2026-06-17T15:32:52Z","message":{"content":[{"type":"text"}],"usage":{"input_tokens":2000,"output_tokens":769}}}"#,
]
let dig = SubagentDigest.fromTranscript(lines: subLines)
check(dig.name.count == 38 && dig.name.hasPrefix("Survey the Swift package") && dig.name.hasSuffix("…"), "subagent digest: name = sanitized first prompt, truncated")
check(dig.tokens == 2769, "subagent digest: tokens = context (2000) + output (769)")
check(dig.status == .waitingForInput(.stoppedTurn), "subagent digest: status derived from records")
// A busy sub-agent (fresh transcript, mid-turn text-tail) must read as WORKING, not waiting — else
// Rollup floats it up and the whole session shows "waiting" while actively working (bug #11 path).
let busySub = SubagentDigest.fromTranscript(lines: subLines, lastActivity: Date())
check(busySub.status == .working, "subagent digest: fresh text-tail -> working (recency, doesn't roll session to waiting)")
check(dig.durationSeconds.map { Int($0) } == 48, "subagent digest: duration = last-first = 48s")

// --- Theme scene state mapping (RowStateMapper mirrors the old cue() precedence exactly) ---
check(RowStateMapper.stateKey(isIdleRow: true, spinning: true, waitReason: .permission, verdict: .failed, dimmed: true) == .idle,
      "stateKey: idle row wins over everything")
check(RowStateMapper.stateKey(isIdleRow: false, spinning: true, waitReason: .permission, verdict: .failed, dimmed: true) == .working,
      "stateKey: spinning -> working (outranks waiting/failed/finished)")
check(RowStateMapper.stateKey(isIdleRow: false, spinning: false, waitReason: .permission, verdict: .failed, dimmed: true) == .waiting(.permission),
      "stateKey: waiting(permission) outranks failed/finished")
check(RowStateMapper.stateKey(isIdleRow: false, spinning: false, waitReason: .stoppedTurn, verdict: nil, dimmed: false) == .waiting(.stoppedTurn),
      "stateKey: waiting(stoppedTurn)")
check(RowStateMapper.stateKey(isIdleRow: false, spinning: false, waitReason: nil, verdict: .failed, dimmed: true) == .failed,
      "stateKey: failed verdict outranks finished/dimmed")
check(RowStateMapper.stateKey(isIdleRow: false, spinning: false, waitReason: nil, verdict: .success, dimmed: true) == .finished,
      "stateKey: dimmed + success -> finished")
check(RowStateMapper.stateKey(isIdleRow: false, spinning: false, waitReason: nil, verdict: nil, dimmed: true) == .finished,
      "stateKey: dimmed (no verdict) -> finished")
check(RowStateMapper.stateKey(isIdleRow: false, spinning: false, waitReason: nil, verdict: nil, dimmed: false) == .idle,
      "stateKey: no signal -> idle fallback")
check(RowSnapshot(id: "a", tokens: 5, state: .working) == RowSnapshot(id: "a", tokens: 5, state: .working),
      "RowSnapshot is Equatable")

// --- Click-to-focus: iTerm2 GUID extraction + window-identity persistence ---
check(itermGUID(from: "w2t0p0:E6101BA4-C887-4433-9901-DD2126E04CC7") == "E6101BA4-C887-4433-9901-DD2126E04CC7",
      "itermGUID: extracts GUID after the colon")
check(itermGUID(from: "no-colon") == nil, "itermGUID: nil when no colon")
check(itermGUID(from: "trailing:") == nil, "itermGUID: nil on empty suffix")
check(itermGUID(from: nil) == nil, "itermGUID: nil input -> nil")
let focusStore = StateStore()
let focusT0 = Date(timeIntervalSince1970: 1_700_000_000)
focusStore.apply(eventType: "SessionStart", sessionID: "S1", cwd: "/x/proj",
                 termProgram: "iTerm.app", itermSessionID: "w0t0p0:GUID1", termBundleID: "com.googlecode.iterm2", at: focusT0)
let fSnap1 = focusStore.snapshot(now: focusT0).sessions.first { $0.sessionID == "S1" }
check(fSnap1?.itermSessionID == "w0t0p0:GUID1" && fSnap1?.termProgram == "iTerm.app",
      "store: SessionStart persists window identity")
focusStore.apply(eventType: "Stop", sessionID: "S1", at: focusT0.addingTimeInterval(1))
let fSnap2 = focusStore.snapshot(now: focusT0.addingTimeInterval(1)).sessions.first { $0.sessionID == "S1" }
check(fSnap2?.itermSessionID == "w0t0p0:GUID1", "store: identity-less event keeps prior identity")
let legacyJSON = #"{"sessions":[{"sessionID":"old","state":"working","subActive":0,"subDone":0}]}"#
let legacyDecoded = try? JSONDecoder().decode(DaemonState.self, from: Data(legacyJSON.utf8))
check(legacyDecoded?.sessions.first?.sessionID == "old" && legacyDecoded?.sessions.first?.itermSessionID == nil,
      "legacy state.json (no identity keys) decodes with identity nil")
// Click-to-focus loads identity from state.json regardless of freshness — verify an identity-bearing
// snapshot decodes intact (the durable source the app reads when the daemon is down and it polls).
let identityJSON = #"{"sessions":[{"sessionID":"s","state":"waiting","subActive":0,"subDone":0,"termProgram":"iTerm.app","itermSessionID":"w0t0p0:GUID","termBundleID":"com.googlecode.iterm2"}]}"#
let identitySnap = (try? JSONDecoder().decode(DaemonState.self, from: Data(identityJSON.utf8)))?.sessions.first
check(identitySnap?.termProgram == "iTerm.app" && identitySnap?.itermSessionID == "w0t0p0:GUID" && identitySnap?.termBundleID == "com.googlecode.iterm2",
      "state.json with window identity decodes intact (freshness-independent click-to-focus source)")

// --- TranscriptDigest: ONE-PASS scan must be byte-identical to the individual functions ---
let digestLines = [
    #"{"type":"user","timestamp":"2026-06-17T16:11:38.253Z","message":{"content":"hi"}}"#,
    #"{"type":"ai-title","aiTitle":"First"}"#,
    #"{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":9},"content":[{"type":"tool_use"},{"type":"text"}]}}"#,
    "garbage{",
    #"{"type":"ai-title","aiTitle":"Refined title"}"#,
    #"{"type":"assistant","usage":{"input_tokens":10,"output_tokens":5},"message":{"content":[{"type":"tool_use"}]}}"#,
    #"{"type":"ai-title","aiTitle":"   "}"#,
    #"{"type":"assistant","message":{"content":[{"type":"text"}]}}"#,
]
let scanned = TranscriptDigest.scan(lines: digestLines)
check(scanned.tokens == TokenUsage.freshTokens(lines: digestLines), "scan.tokens == freshTokens (byte-identical)")
check(scanned.title == ConversationTitle.fromTranscript(lines: digestLines), "scan.title == fromTranscript")
check(scanned.startedAt == TranscriptClock.startedAt(lines: digestLines), "scan.startedAt == startedAt")
let digestSteps = TranscriptAdapter.parse(lines: digestLines).reduce(0) { $0 + $1.assistantBlockKinds.filter { $0 == "tool_use" }.count }
check(scanned.steps == digestSteps, "scan.steps == TranscriptAdapter tool_use count")
check(scanned.tokens == 164, "scan: tokens 164 (peak context 100+9 + output 50+5; cache included, output deduped)")
check(scanned.title == "Refined title", "scan: last non-empty ai-title wins")
check(scanned.startedAt != nil, "scan: startedAt = first timestamp")
check(scanned.steps == 2, "scan: 2 tool_use steps")
check(TranscriptDigest.scan(lines: []) == TranscriptDigest.Result(tokens: 0, title: nil, startedAt: nil, steps: 0),
      "scan: empty -> zeros")
check(TranscriptDigest.scan(lines: usageLines).tokens == TokenUsage.freshTokens(lines: usageLines),
      "scan.tokens matches freshTokens on the usage fixture")
check(TranscriptDigest.scan(lines: titleLines).title == ConversationTitle.fromTranscript(lines: titleLines),
      "scan.title matches fromTranscript on the title fixture")
check(TranscriptDigest.scan(lines: tsLines).startedAt == TranscriptClock.startedAt(lines: tsLines),
      "scan.startedAt matches startedAt on the timestamp fixture")

// --- Data-theme manifest: pure helpers (sprite clock, semver, colour-ref syntax) ---
// Sprite frame index: 10 Hz ticker, 10 fps, 4 frames → one cell per tick, wrapping.
check(SpriteClock.frameIndex(tick: 0, fps: 10, frameCount: 4) == 0, "sprite clock: tick 0 -> frame 0")
check(SpriteClock.frameIndex(tick: 3, fps: 10, frameCount: 4) == 3, "sprite clock: tick 3 @10fps -> frame 3")
check(SpriteClock.frameIndex(tick: 4, fps: 10, frameCount: 4) == 0, "sprite clock: wraps at frameCount")
check(SpriteClock.frameIndex(tick: 5, fps: 20, frameCount: 4) == 2, "sprite clock: 20fps advances 2 cells/tick (10/(10) ) -> (5*20/10)%4=2")
check(SpriteClock.frameIndex(tick: 100, fps: 0, frameCount: 4) == 0, "sprite clock: fps 0 freezes on frame 0")
check(SpriteClock.frameIndex(tick: 5, fps: 10, frameCount: 0) == 0, "sprite clock: frameCount 0 -> 0 (no divide-by-zero)")
check(SemVer.isAtLeast("0.3.0", "0.3.0") && SemVer.isAtLeast("0.4.0", "0.3.0") && SemVer.isAtLeast("1.0", "0.9.9"),
      "semver: equal / newer / fewer-components-but-greater all satisfy")
check(!SemVer.isAtLeast("0.2.9", "0.3.0") && !SemVer.isAtLeast("0.3.0", "0.3.1"), "semver: older app fails the minimum")
check(SemVer.isAtLeast("0.1.0", nil) && SemVer.isAtLeast("0.1.0", ""), "semver: nil/blank minimum always satisfied")
check(ColorRefSyntax.isHex("#E52521") && ColorRefSyntax.isHex("#E52521FF"), "colour: 6- and 8-digit hex valid")
check(!ColorRefSyntax.isHex("#E525") && !ColorRefSyntax.isHex("#GGGGGG") && !ColorRefSyntax.isHex("E52521"),
      "colour: wrong-length / non-hex / missing-hash rejected")
check(ColorRefSyntax.isValid("clear", palette: [:]) && ColorRefSyntax.isValid("system:teal", palette: [:]),
      "colour: clear + system:<name> valid")
check(ColorRefSyntax.isValid("accent", palette: ["accent": "#E52521"]) && !ColorRefSyntax.isValid("accent", palette: [:]),
      "colour: palette name valid only when present in palette")

// --- Data-theme manifest: a full valid manifest decodes to the expected typed model ---
let validManifest = """
{
  "schemaVersion": 1,
  "id": "critter",
  "displayName": "Pixel Critter",
  "minAppVersion": "0.1.0",
  "showsPersonaGlyph": false,
  "palette": { "accent": "#5AC8FA" },
  "tint": { "working": "accent", "waitingPermission": "system:orange" },
  "states": {
    "working": {
      "visual": { "kind": "sprite", "sheet": "sprites/walk.png", "frameWidth": 24, "frameHeight": 24, "frameCount": 4, "fps": 8 },
      "sound": { "file": "sounds/blip.wav", "trigger": "onEnter", "volume": 0.6 }
    },
    "waitingPermission": { "visual": { "kind": "image", "file": "images/look.png" } },
    "waitingTurnEnd":   { "visual": { "kind": "text", "string": "zzz", "color": "system:secondaryLabel" } },
    "finished": { "visual": { "kind": "symbol", "name": "checkmark.circle.fill", "tint": "system:green" } },
    "failed":   { "visual": { "kind": "symbol", "name": "xmark.octagon.fill", "tint": "#FF3B30" } },
    "idle":     { "visual": { "kind": "text", "string": "·", "color": "clear" } }
  },
  "layout": { "ownRow": false, "size": { "width": 28, "height": 24 } }
}
"""
func loadTheme(_ s: String, folder: String = "critter", app: String = "0.3.0") -> Result<ThemeManifest, ThemeRejection> {
    ThemeManifestLoader.load(data: Data(s.utf8), folderName: folder, appVersion: app)
}
if case .success(let m) = loadTheme(validManifest) {
    check(m.id == "critter" && m.displayName == "Pixel Critter" && !m.showsPersonaGlyph, "manifest: scalar fields decode")
    check(m.palette["accent"] == "#5AC8FA" && m.tint["working"] == "accent", "manifest: palette + tint decode")
    check(m.states["working"]?.visual == .sprite(sheet: "sprites/walk.png", frameWidth: 24, frameHeight: 24, frameCount: 4, fps: 8),
          "manifest: sprite visual decodes with dims")
    check(m.states["working"]?.sound == SoundSpec(file: "sounds/blip.wav", trigger: .onEnter, volume: 0.6),
          "manifest: sound spec decodes")
    check(m.states["idle"]?.visual == .text(string: "·", color: "clear"), "manifest: text visual decodes")
    check(m.states["finished"]?.visual == .symbol(name: "checkmark.circle.fill", tint: "system:green"),
          "manifest: symbol visual decodes")
    check(m.layout == Layout(ownRow: false, size: Layout.Size(width: 28, height: 24)), "manifest: layout decodes")
} else {
    check(false, "manifest: a valid manifest must load")
}

// --- Data-theme manifest: every rejection path ---
func rejects(_ s: String, _ expected: ThemeRejection, _ name: String, folder: String = "critter", app: String = "0.3.0") {
    switch loadTheme(s, folder: folder, app: app) {
    case .failure(let r): check(r == expected, r == expected ? name : "\(name) [got \(r), expected \(expected)]")
    case .success: check(false, "\(name) (expected rejection, got success)")
    }
}
check({ if case .failure(.invalidJSON) = loadTheme("not json at all") { return true }; return false }(),
      "manifest: non-JSON -> invalidJSON")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{},"bogus":true}"#,
        .unknownField("bogus"), "manifest: unknown top-level key rejected (no smuggling)")
rejects(#"{"schemaVersion":2,"id":"critter","displayName":"x","states":{}}"#,
        .unsupportedSchemaVersion(2), "manifest: schemaVersion != 1 rejected")
rejects(#"{"id":"critter","displayName":"x","states":{}}"#,
        .missingField("schemaVersion"), "manifest: missing schemaVersion rejected")
rejects(#"{"schemaVersion":1,"id":"mario","displayName":"x","states":{}}"#,
        .idFolderMismatch(id: "mario", folder: "critter"), "manifest: id must equal folder name")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"bogus":{"visual":{"kind":"text","string":"·"}}}}"#,
        .unknownState("bogus"), "manifest: unknown state id rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","minAppVersion":"9.9.9","states":{}}"#,
        .appTooOld(required: "9.9.9"), "manifest: minAppVersion > app rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"working":{"visual":{"kind":"wormhole"}}}}"#,
        .unknownVisualKind("wormhole"), "manifest: unknown visual kind rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"idle":{"visual":{"kind":"text"}}}}"#,
        .missingField("states.idle.visual.string"), "manifest: missing required visual field rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"working":{"visual":{"kind":"image","file":"../escape.png"}}}}"#,
        .asset(.pathTraversal("../escape.png")), "manifest: Zip-Slip asset path rejected (PackValidator)")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"working":{"visual":{"kind":"image","file":"images/evil.svg"}}}}"#,
        .asset(.disallowedAsset("images/evil.svg")), "manifest: SVG image rejected (script-bearing)")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"working":{"visual":{"kind":"text","string":"x"},"sound":{"file":"s/x.mp3"}}}}"#,
        .asset(.disallowedAsset("s/x.mp3")), "manifest: non-allowlisted audio (mp3) rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"working":{"visual":{"kind":"text","string":"x"},"sound":{"file":"../x.wav"}}}}"#,
        .asset(.pathTraversal("../x.wav")), "manifest: Zip-Slip audio path rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"working":{"visual":{"kind":"text","string":"x"},"sound":{"file":"s/x.wav","trigger":"explode"}}}}"#,
        .badSoundTrigger("explode"), "manifest: bad sound trigger rejected")
rejects(##"{"schemaVersion":1,"id":"critter","displayName":"x","tint":{"working":"#GGG"},"states":{}}"##,
        .badColorRef("#GGG"), "manifest: bad colour ref rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"working":{"visual":{"kind":"sprite","sheet":"s/x.png","frameWidth":0,"frameHeight":24,"frameCount":4,"fps":8}}}}"#,
        .wrongType("states.working.visual (sprite dims must be > 0)"), "manifest: non-positive sprite dim rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"idle":{"visual":{"kind":"text","string":"·"},"bogus":1}}}"#,
        .unknownField("states.idle.bogus"), "manifest: unknown key inside a state rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"idle":{"visual":{"kind":"text","string":"·","bogus":1}}}}"#,
        .unknownField("states.idle.visual.bogus"), "manifest: unknown key inside a visual rejected")
// Volume clamps to 0…1 rather than rejecting.
if case .success(let m) = loadTheme(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"working":{"visual":{"kind":"text","string":"x"},"sound":{"file":"s/x.wav","volume":9}}}}"#) {
    check(m.states["working"]?.sound?.volume == 1.0, "manifest: out-of-range volume clamps to 1.0")
} else { check(false, "manifest: volume-clamp manifest must load") }

// Strict typing across the JSONSerialization Bool/Int NSNumber bridge (a JSON bool casts to Int=1 and
// a JSON int 0/1 casts to Bool with a naive `as?` — the loader must reject both for typed fields).
rejects(#"{"schemaVersion":true,"id":"critter","displayName":"x","states":{}}"#,
        .wrongType("schemaVersion"), "manifest: JSON bool rejected where Int (schemaVersion) required")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","showsPersonaGlyph":1,"states":{}}"#,
        .wrongType("showsPersonaGlyph"), "manifest: JSON int rejected where Bool (showsPersonaGlyph) required")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"working":{"visual":{"kind":"sprite","sheet":"s/x.png","frameWidth":true,"frameHeight":24,"frameCount":4,"fps":8}}}}"#,
        .wrongType("states.working.visual.frameWidth"), "manifest: JSON bool rejected where Int (sprite dim) required")
// Sprite dimensions are bounded (untrusted values flow into `i * frameWidth` / a slicing loop).
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"working":{"visual":{"kind":"sprite","sheet":"s/x.png","frameWidth":999999,"frameHeight":24,"frameCount":4,"fps":8}}}}"#,
        .wrongType("states.working.visual (sprite dims out of range)"), "manifest: oversized sprite dim rejected (overflow/DoS guard)")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"working":{"visual":{"kind":"sprite","sheet":"s/x.png","frameWidth":24,"frameHeight":24,"frameCount":999999,"fps":8}}}}"#,
        .wrongType("states.working.visual (sprite dims out of range)"), "manifest: oversized frameCount rejected (slicer DoS guard)")
// A system: colour must name one the resolver actually supports (no pass-then-silently-fallback).
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","tint":{"working":"system:turquoise"},"states":{}}"#,
        .badColorRef("system:turquoise"), "manifest: unknown system colour name rejected")
check(ColorRefSyntax.isValid("system:teal", palette: [:]) && ColorRefSyntax.isValid("system:secondaryLabel", palette: [:])
      && !ColorRefSyntax.isValid("system:bogus", palette: [:]),
      "colour: system name validated against the shared resolver allowlist")

print("")
if failures == 0 {
    print("ALL PASS — \(total) checks")
    exit(0)
} else {
    print("FAILURES: \(failures) of \(total)")
    exit(1)
}
