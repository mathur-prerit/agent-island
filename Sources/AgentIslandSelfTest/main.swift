import Foundation
import Darwin
import SQLite3
import AgentIslandCore
import PersonaKit
import HookInstall
import AgentIslandDaemon
import AgentIslandThemes
import AgentIslandCLICore

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

// U4c: the `curl|sh` installer wires the hook under the binary name `agentisland-hook`, so its
// argv[0]-derived command is `agentisland-hook relay` (bare or absolute) — a DIFFERENT token than the
// app's `AgentIslandHookCLI`. The signature matcher must recognise BOTH naming styles, or `uninstall`
// (which reverses via the `AgentIslandHookCLI relay` form) strands the installer-wired hook pointing at
// a deleted binary, erroring on every Claude Code lifecycle event. (These assertions FAIL before the
// matcher fix and PASS after.)
let hookBareCmd = "agentisland-hook relay"
let hookAbsCmd  = "/usr/local/bin/agentisland-hook relay"
check(SettingsMerge.isAgentIslandRelay(hookBareCmd) && SettingsMerge.isAgentIslandRelay(hookAbsCmd),
      "U4c: installer-style `agentisland-hook relay` (bare + abs) recognised as our relay")
check(SettingsMerge.isAgentIslandRelay(appCmd),
      "U4c: app-style `\"<abs>/AgentIslandHookCLI\" relay` STILL recognised after the matcher widening")
// Foreign hooks (and a bare `relay` with no agent-island token) must NOT be mistaken for ours.
check(!SettingsMerge.isAgentIslandRelay("/usr/bin/say done")
      && !SettingsMerge.isAgentIslandRelay("/opt/some/other-tool relay")
      && !SettingsMerge.isAgentIslandRelay("relay"),
      "U4c: a foreign command (even one ending in ' relay') is NOT treated as our relay")
// uninstall (reversing with the CLI/app `AgentIslandHookCLI relay` form, as `agentisland uninstall`
// does) removes EVERY agent-island relay strand across both naming styles, while preserving a foreign
// hook and unrelated keys.
let reversalCmd = "AgentIslandHookCLI relay"   // the form SettingsFile.uninstall is invoked with
let mixedSettings = Data("""
{
  "topKey": 99,
  "hooks": {
    "Stop": [
      {"hooks":[{"type":"command","command":"agentisland-hook relay"}]},
      {"hooks":[{"type":"command","command":"/usr/local/bin/agentisland-hook relay"}]},
      {"hooks":[{"type":"command","command":"\\"/Applications/AgentIsland.app/Contents/MacOS/AgentIslandHookCLI\\" relay"}]},
      {"hooks":[{"type":"command","command":"/usr/bin/say boop"}]}
    ]
  }
}
""".utf8)
if case .success(let cleaned) = SettingsMerge.uninstall(existing: mixedSettings, command: reversalCmd) {
    let root = (try? JSONSerialization.jsonObject(with: cleaned) as? [String: Any]) ?? [:]
    let stop = ((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]) ?? []
    func cmds(_ entries: [[String: Any]]) -> [String] {
        entries.flatMap { ($0["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? [] }
    }
    let remaining = cmds(stop)
    check(!remaining.contains("agentisland-hook relay"), "U4c: uninstall removes the bare `agentisland-hook relay` strand")
    check(!remaining.contains("/usr/local/bin/agentisland-hook relay"), "U4c: uninstall removes the abs `/usr/local/bin/agentisland-hook relay` strand")
    check(!remaining.contains(where: { $0.contains("AgentIslandHookCLI") }), "U4c: uninstall still removes the app-style `\"<abs>/AgentIslandHookCLI\" relay`")
    check(remaining == ["/usr/bin/say boop"], "U4c: uninstall PRESERVES the foreign `/usr/bin/say` hook (only ours removed)")
    check((root["topKey"] as? Int) == 99, "U4c: uninstall preserves unrelated top-level keys")
} else { check(false, "U4c: mixed-style uninstall succeeded") }

// U4d: composed round-trip — install the hook exactly as the `curl|sh` installer does (binary named
// `agentisland-hook`, so command = `agentisland-hook relay`) via the real SettingsFile on a temp file,
// then run the uninstall reversal (`AgentIslandHookCLI relay`, as `agentisland uninstall` does) and
// assert the file is hook-free afterward. (FAILS before the matcher fix — the strand survives.)
do {
    let rtDir = NSTemporaryDirectory() + "ai-hook-roundtrip-\(getpid())-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: rtDir, withIntermediateDirectories: true)
    let rtPath = rtDir + "/settings.json"
    try? Data(#"{"keep":1}"#.utf8).write(to: URL(fileURLWithPath: rtPath))
    let rtEvents = ["Stop", "UserPromptSubmit", "SessionEnd"]
    _ = try? SettingsFile.install(settingsPath: rtPath, command: "agentisland-hook relay", events: rtEvents)
    // sanity: the installer-named hook really landed
    let afterInstall = (try? Data(contentsOf: URL(fileURLWithPath: rtPath))) ?? Data()
    let installRoot = (try? JSONSerialization.jsonObject(with: afterInstall) as? [String: Any]) ?? [:]
    let installHooks = (installRoot["hooks"] as? [String: Any]) ?? [:]
    let landed = rtEvents.allSatisfy { ev in
        (((installHooks[ev] as? [[String: Any]]) ?? []).flatMap {
            ($0["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
        }).contains("agentisland-hook relay")
    }
    check(landed, "U4d: round-trip — installer-style `agentisland-hook relay` wires into every event")
    // now reverse via the app/CLI canonical form, as `agentisland uninstall` does
    _ = try? SettingsFile.uninstall(settingsPath: rtPath, command: "AgentIslandHookCLI relay")
    let afterUninstall = (try? Data(contentsOf: URL(fileURLWithPath: rtPath))) ?? Data()
    let upRoot = (try? JSONSerialization.jsonObject(with: afterUninstall) as? [String: Any]) ?? [:]
    let upHooks = (upRoot["hooks"] as? [String: Any]) ?? [:]
    // Detect a surviving strand by the LITERAL installed command text (not via isAgentIslandRelay) so
    // this assertion is independent of the matcher under test — under the buggy matcher the strand
    // would survive AND go undetected by isAgentIslandRelay, so this must catch the raw string.
    let anyRelayLeft = upHooks.values.contains { value in
        (((value as? [[String: Any]]) ?? []).flatMap {
            ($0["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
        }).contains { $0.contains("relay") }
    }
    check(!anyRelayLeft, "U4d: round-trip — after the reversal NO agent-island relay hook strands (settings is hook-free)")
    check((upRoot["keep"] as? Int) == 1, "U4d: round-trip — unrelated keys survive the install/uninstall cycle")
    try? FileManager.default.removeItem(atPath: rtDir)
}

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

// --- "Update available" indicator: strict-newer compare, tag parse, decision (all network-free) ---
// SemVer.isNewer is the strict ">" the "update available = latest > installed" decision needs.
check(SemVer.isNewer("0.4.0", than: "0.3.0") && !SemVer.isNewer("0.3.0", than: "0.4.0"),
      "semver newer: 0.4.0 > 0.3.0, not the reverse")
check(!SemVer.isNewer("0.3.0", than: "0.3.0"), "semver newer: equal is NOT strictly newer")
check(SemVer.isNewer("1.0", than: "0.9.9") && !SemVer.isNewer("0.9.9", than: "1.0"),
      "semver newer: multi-segment 1.0 > 0.9.9 (pads missing component with 0)")
check(SemVer.isNewer("0.4.0", than: nil) && SemVer.isNewer("0.4.0", than: ""),
      "semver newer: any version beats a nil/blank baseline")
check(!SemVer.isNewer("nightly", than: "0.3.0") && !SemVer.isNewer("0.3.0", than: "0.3.0"),
      "semver newer: a non-numeric tag (→0.0.0) is never newer; handled without crashing")

// Tag parse: a leading v/V is stripped; a bare version passes through; junk is handled (not a crash).
check(ReleaseFeed.normalizeTag("v0.4.0") == "0.4.0" && ReleaseFeed.normalizeTag("0.4.0") == "0.4.0",
      "tag parse: 'v0.4.0' and '0.4.0' both normalise to '0.4.0'")
check(ReleaseFeed.normalizeTag("V1.2.3") == "1.2.3" && ReleaseFeed.normalizeTag("  v0.5.0  ") == "0.5.0",
      "tag parse: leading V + surrounding whitespace trimmed")
check(ReleaseFeed.normalizeTag("") == nil && ReleaseFeed.normalizeTag("   ") == nil,
      "tag parse: empty / whitespace-only tag → nil")
check(ReleaseFeed.normalizeTag("nightly") == "nightly", "tag parse: a junk tag survives (compares as 0.0.0 downstream)")
check(ReleaseFeed.parseLatestTag(Data(#"{"tag_name":"v0.4.0","name":"Release"}"#.utf8)) == "0.4.0",
      "tag parse: GitHub releases/latest JSON → 'v0.4.0' → '0.4.0'")
check(ReleaseFeed.parseLatestTag(Data(#"{"tag_name":""}"#.utf8)) == nil, "tag parse: empty tag_name → nil")
check(ReleaseFeed.parseLatestTag(Data(#"{"no_tag":"x"}"#.utf8)) == nil, "tag parse: missing tag_name → nil")
check(ReleaseFeed.parseLatestTag(Data("not json".utf8)) == nil, "tag parse: non-JSON → nil (no crash)")
check(ReleaseFeed.parseLatestTag(Data("[]".utf8)) == nil, "tag parse: JSON that isn't an object → nil")

// Update decision: available when latest>installed; quiet when equal/older/offline; respects dismissal.
check(UpdateAvailability.decide(installed: "0.3.0", latest: "0.4.0", dismissed: nil) == .available(version: "0.4.0"),
      "update decide: newer latest → .available")
check(UpdateAvailability.decide(installed: "0.3.0", latest: "0.3.0", dismissed: nil) == .upToDate,
      "update decide: equal latest → .upToDate")
check(UpdateAvailability.decide(installed: "0.4.0", latest: "0.3.0", dismissed: nil) == .upToDate,
      "update decide: older latest → .upToDate")
check(UpdateAvailability.decide(installed: "0.3.0", latest: nil, dismissed: nil) == .upToDate,
      "update decide: nil latest (offline / parse miss) → .upToDate")
check(UpdateAvailability.decide(installed: "0.3.0", latest: "0.4.0", dismissed: "0.4.0") == .upToDate,
      "update decide: dismissed == latest → suppressed (don't nag)")
check(UpdateAvailability.decide(installed: "0.3.0", latest: "0.5.0", dismissed: "0.4.0") == .available(version: "0.5.0"),
      "update decide: a release strictly newer than the dismissed one reappears")
check(UpdateAvailability.decide(installed: "0.3.0", latest: "0.4.0", dismissed: nil).offeredVersion == "0.4.0"
      && UpdateAvailability.decide(installed: "0.3.0", latest: "0.3.0", dismissed: nil).offeredVersion == nil,
      "update decide: offeredVersion mirrors .available / .upToDate")

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

// --- Token bands: pure selection + manifest decode/validation (config-based usage tiers) ---
let demoBands: [TokenBand] = [
    TokenBand(name: "rookie", upTo: 50_000),
    TokenBand(name: "super",  upTo: 100_000),
    TokenBand(name: "fire",   upTo: 200_000),
    TokenBand(name: "star",   upTo: nil),
]
check(TokenBands.bandName(for: 0, bands: demoBands) == "rookie", "token bands: 0 -> rookie")
check(TokenBands.bandName(for: 49_999, bands: demoBands) == "rookie", "token bands: just below first bound -> rookie")
check(TokenBands.bandName(for: 50_000, bands: demoBands) == "super", "token bands: at the bound crosses up (upTo exclusive)")
check(TokenBands.bandName(for: 150_000, bands: demoBands) == "fire", "token bands: mid-range -> fire")
check(TokenBands.bandName(for: 5_000_000, bands: demoBands) == "star", "token bands: beyond all finite bounds -> catch-all star")
check(TokenBands.bandName(for: -100, bands: demoBands) == "rookie", "token bands: negative clamps to the first band")
check(TokenBands.bandName(for: 10, bands: []) == nil, "token bands: no bands declared -> nil")
check(TokenBands.bandName(for: 999_999, bands: [TokenBand(name: "a", upTo: 10), TokenBand(name: "b", upTo: 20)]) == "b",
      "token bands: count past every finite bound clamps to the last band")

let bandedManifest = """
{
  "schemaVersion": 1, "id": "critter", "displayName": "x",
  "tokenBands": [ {"name":"rookie","upTo":50000}, {"name":"super","upTo":100000}, {"name":"star"} ],
  "states": {
    "working": {
      "visual": { "kind": "sprite", "sheet": "sprites/small.png", "frameWidth": 24, "frameHeight": 24, "frameCount": 4, "fps": 8 },
      "visualBands": {
        "super": { "kind": "sprite", "sheet": "sprites/super.png", "frameWidth": 24, "frameHeight": 24, "frameCount": 4, "fps": 8 },
        "star":  { "kind": "image", "file": "images/star.png" }
      }
    }
  }
}
"""
if case .success(let m) = loadTheme(bandedManifest) {
    check(m.tokenBands.map(\.name) == ["rookie", "super", "star"] && m.tokenBands[2].upTo == nil,
          "token bands: declared bands decode in order, last is the catch-all")
    check(m.states["working"]?.visual == .sprite(sheet: "sprites/small.png", frameWidth: 24, frameHeight: 24, frameCount: 4, fps: 8),
          "token bands: base visual still decodes alongside visualBands")
    check(m.states["working"]?.visualBands["super"] == .sprite(sheet: "sprites/super.png", frameWidth: 24, frameHeight: 24, frameCount: 4, fps: 8)
          && m.states["working"]?.visualBands["star"] == .image(file: "images/star.png"),
          "token bands: per-band visual overrides decode")
} else {
    check(false, "token bands: a valid banded manifest must load")
}
// A theme with no tokenBands keeps an empty band list (backward compatible — the existing validManifest above).
if case .success(let m) = loadTheme(validManifest) {
    check(m.tokenBands.isEmpty && (m.states["working"]?.visualBands.isEmpty ?? false),
          "token bands: a manifest without bands decodes to empty (backward compatible)")
}
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","tokenBands":[],"states":{}}"#,
        .badTokenBands("must list at least one band"), "token bands: empty list rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","tokenBands":[{"name":"a","upTo":100},{"name":"b","upTo":50}],"states":{}}"#,
        .badTokenBands("band 'b' upTo must be greater than the previous band"), "token bands: non-ascending upTo rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","tokenBands":[{"name":"a","upTo":100},{"name":"a"}],"states":{}}"#,
        .badTokenBands("duplicate band name 'a'"), "token bands: duplicate band name rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","tokenBands":[{"name":"a"},{"name":"b","upTo":100}],"states":{}}"#,
        .badTokenBands("only the last band may omit upTo (band 'a')"), "token bands: non-last catch-all rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","tokenBands":[{"name":"a","upTo":50},{"name":"b"}],"states":{"working":{"visual":{"kind":"text","string":"x"},"visualBands":{"ghost":{"kind":"text","string":"y"}}}}}"#,
        .unknownBand("ghost"), "token bands: visualBands key not in tokenBands rejected")
rejects(#"{"schemaVersion":1,"id":"critter","displayName":"x","states":{"working":{"visual":{"kind":"text","string":"x"},"visualBands":{"super":{"kind":"text","string":"y"}}}}}"#,
        .unknownBand("super"), "token bands: visualBands with no tokenBands declared rejected")

// --- Theme catalog: strict decode of the hosted download index ---
let validCatalog = """
{
  "themes": [
    { "id": "critter", "displayName": "Pixel Critter", "version": "1.0.0",
      "url": "https://example.com/critter.zip",
      "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "sizeBytes": 4096, "minAppVersion": "0.1.0" },
    { "id": "neon", "displayName": "Neon", "version": "2.1.0",
      "url": "https://example.com/neon.zip",
      "sha256": "abc123", "sizeBytes": 8192, "minAppVersion": null }
  ]
}
"""
if case .success(let cat) = ThemeCatalog.decode(Data(validCatalog.utf8)) {
    check(cat.themes.count == 2, "catalog: decodes both entries")
    check(cat.themes[0].id == "critter" && cat.themes[0].displayName == "Pixel Critter"
          && cat.themes[0].sizeBytes == 4096 && cat.themes[0].minAppVersion == "0.1.0",
          "catalog: entry scalar fields decode")
    check(cat.themes[1].minAppVersion == nil, "catalog: null minAppVersion decodes to nil")
} else {
    check(false, "catalog: a valid index must decode")
}
// Strict keys: an unknown field anywhere in the index rejects the whole catalog (no smuggling, same
// posture as the manifest loader's strict top-level keys).
check({ if case .failure(.malformedIndex) = ThemeCatalog.decode(Data(#"{"themes":[{"id":"x","displayName":"X","version":"1","url":"u","sha256":"h","sizeBytes":1,"exec":"rm -rf"}]}"#.utf8)) { return true }; return false }(),
      "catalog: unknown per-entry key (e.g. exec) rejected (strict, no smuggling)")
check({ if case .failure(.malformedIndex) = ThemeCatalog.decode(Data(#"{"bogus":[]}"#.utf8)) { return true }; return false }(),
      "catalog: missing 'themes' key rejected")
check({ if case .failure(.malformedIndex) = ThemeCatalog.decode(Data("not json".utf8)) { return true }; return false }(),
      "catalog: non-JSON index rejected")
check({ if case .failure(.malformedIndex) = ThemeCatalog.decode(Data("[]".utf8)) { return true }; return false }(),
      "catalog: bare array (wrong shape) rejected — index is an object")

// --- Theme catalog: integrity verify (size + sha256), the pre-extraction download gate ---
// Compute a real digest of a fixture blob so the MATCH case is genuine without any network.
let blob = Data("agent-island theme payload".utf8)
let digest = ThemeCatalogEntry.sha256Hex(blob)
check(digest.count == 64 && digest == digest.lowercased(), "catalog: sha256Hex is 64-char lowercase hex")
func entryFor(_ data: Data, sha: String) -> ThemeCatalogEntry {
    ThemeCatalogEntry(id: "t", displayName: "T", version: "1", url: "u", sha256: sha,
                      sizeBytes: data.count, minAppVersion: nil)
}
check(entryFor(blob, sha: digest).verify(blob) == nil, "catalog: matching size + sha256 verifies (nil)")
// Upper-case sha in the index still matches (case-insensitive compare).
check(entryFor(blob, sha: digest.uppercased()).verify(blob) == nil, "catalog: upper-case sha in index still matches")
// Size mismatch: declared size != actual blob length.
let sizeBadEntry = ThemeCatalogEntry(id: "t", displayName: "T", version: "1", url: "u",
                                     sha256: digest, sizeBytes: blob.count + 1, minAppVersion: nil)
check(sizeBadEntry.verify(blob) == .sizeMismatch(expected: blob.count + 1, actual: blob.count),
      "catalog: size mismatch rejected before sha check")
// Hash mismatch: right size, wrong (tampered) bytes — the digest differs.
let tampered = Data("agent-island theme payloads".utf8)   // one extra byte changes the digest
check(entryFor(tampered, sha: digest).verify(tampered) != nil, "catalog: tampered bytes fail sha (non-nil)")
if case .hashMismatch(let expected, let actual)? = entryFor(tampered, sha: digest).verify(tampered) {
    check(expected == digest && actual != digest && actual == ThemeCatalogEntry.sha256Hex(tampered),
          "catalog: hash mismatch reports expected vs. actual digest")
} else { check(false, "catalog: tampered bytes must report .hashMismatch") }
// Size is checked first (cheap) — a wrong-size blob never reaches the sha compare.
check(entryFor(blob, sha: "deadbeef").verify(Data()).map { if case .sizeMismatch = $0 { return true }; return false } == true,
      "catalog: empty blob fails on size, not sha")

// --- Theme catalog: entry id is a safe single path segment (HIGH-3 escape guard) ---
// The id becomes the install folder name (`~/.agent-island/themes/<id>/`); a `..`/`a/b`/empty id would
// escape that root (a later removeItem could delete the themes dir), so it's gated before any download.
check(ThemeCatalogEntry.isSafeID("critter") && ThemeCatalogEntry.isSafeID("neon-2"),
      "id-safe: a plain folder name is a safe id")
check(!ThemeCatalogEntry.isSafeID(".."), "id-safe: '..' rejected (would escape install root)")
check(!ThemeCatalogEntry.isSafeID("."), "id-safe: '.' rejected")
check(!ThemeCatalogEntry.isSafeID(""), "id-safe: empty id rejected")
check(!ThemeCatalogEntry.isSafeID("a/b"), "id-safe: 'a/b' (separator) rejected")
check(!ThemeCatalogEntry.isSafeID("../evil"), "id-safe: '../evil' rejected")
check(!ThemeCatalogEntry.isSafeID("a\\b"), "id-safe: backslash rejected")
check(!ThemeCatalogEntry.isSafeID("a\u{0}b"), "id-safe: NUL rejected")
check(ThemeCatalogEntry.isSafeID("a..b"), "id-safe: '..' as a substring of a single segment is fine")

// --- ZipInspector: defensive central-directory parsing on CRAFTED hostile bytes (HIGH-1) ---
// A from-scratch zip builder that emits ONLY a central directory + EOCD (the inspector reads no local
// headers / file data), so a crafted entry's name, sizes, and unix mode are set verbatim — no real
// archive, no disk, no network. external-attrs high 16 bits carry the unix st_mode (symlink detection).
func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
func le32(_ v: UInt64) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}
func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) } }
struct CraftEntry { var name: String; var uncompressed: UInt64; var compressed: UInt64; var mode: UInt16 }
// Build a central-directory header for one entry. `zip64` packs the sizes into the extra field and puts
// the 0xFFFFFFFF sentinel in the 32-bit size slots (exercises the zip64 path).
func centralHeader(_ e: CraftEntry, zip64: Bool) -> [UInt8] {
    let nameBytes = Array(e.name.utf8)
    var extra: [UInt8] = []
    var compField = le32(e.compressed)
    var uncompField = le32(e.uncompressed)
    if zip64 {
        compField = le32(0xFFFFFFFF); uncompField = le32(0xFFFFFFFF)
        // zip64 extra: id 0x0001, data length 16, then uncompressed (8) + compressed (8) in that order.
        extra = le16(0x0001) + le16(16) + le64(e.uncompressed) + le64(e.compressed)
    }
    var h: [UInt8] = []
    h += le32(0x02014b50)            // central file header signature
    h += le16(20)                    // version made by
    h += le16(20)                    // version needed
    h += le16(0)                     // flags
    h += le16(0)                     // compression method (stored)
    h += le16(0) + le16(0)           // mod time + date
    h += le32(0)                     // crc32
    h += compField                   // compressed size (or sentinel)
    h += uncompField                 // uncompressed size (or sentinel)
    h += le16(nameBytes.count)       // file name length
    h += le16(extra.count)           // extra field length
    h += le16(0)                     // file comment length
    h += le16(0)                     // disk number start
    h += le16(0)                     // internal attrs
    h += le32(UInt64(e.mode) << 16)  // external attrs: unix mode in the high 16 bits
    h += le32(0)                     // local header offset
    h += nameBytes
    h += extra
    return h
}
// Assemble a whole archive: an optional leading "local data" filler (so the CD offset isn't 0), the
// central directory, then the EOCD pointing at it.
func craftZip(_ entries: [CraftEntry], zip64: Bool = false,
              leadingBytes: Int = 8, comment: [UInt8] = []) -> Data {
    let lead = [UInt8](repeating: 0, count: leadingBytes)
    var cd: [UInt8] = []
    for e in entries { cd += centralHeader(e, zip64: zip64) }
    let cdOffset = lead.count
    var eocd: [UInt8] = []
    eocd += le32(0x06054b50)               // EOCD signature
    eocd += le16(0) + le16(0)              // disk numbers
    eocd += le16(entries.count)            // cd records on this disk
    eocd += le16(entries.count)            // total cd records
    eocd += le32(UInt64(cd.count))         // cd size
    eocd += le32(UInt64(cdOffset))         // cd offset
    eocd += le16(comment.count)            // comment length
    eocd += comment
    return Data(lead + cd + eocd)
}
// A regular-file unix mode (S_IFREG | 0644) and a symlink mode (S_IFLNK | 0777).
let regMode: UInt16 = 0o100644
let lnkMode: UInt16 = 0o120777

// Valid central directory parses: two benign files, sizes + names + (no) symlink read back correctly.
let validZip = craftZip([
    CraftEntry(name: "theme.json", uncompressed: 200, compressed: 120, mode: regMode),
    CraftEntry(name: "images/x.png", uncompressed: 4096, compressed: 2048, mode: regMode),
])
switch ZipInspector.inspect(validZip) {
case .success(let entries):
    check(entries.count == 2 && entries[0].name == "theme.json" && entries[0].uncompressedSize == 200
          && entries[1].name == "images/x.png" && entries[1].compressedSize == 2048
          && !entries[0].isSymlink,
          "zipinspect: valid central directory parses (names, sizes, not-symlink)")
case .failure(let e):
    check(false, "zipinspect: valid central directory must parse [got \(e)]")
}
// checkArchive on the valid zip with sane sizes passes (within all PackLimits).
check(ZipInspector.checkArchive(validZip, archiveBytes: validZip.count) == nil,
      "zipinspect: a benign small archive passes all limits")

// A `../` name is rejected as an unsafe (zip-slip) name, pre-extraction.
let traversalZip = craftZip([CraftEntry(name: "../escape.png", uncompressed: 10, compressed: 10, mode: regMode)])
check(ZipInspector.checkArchive(traversalZip, archiveBytes: traversalZip.count) == .unsafeName("../escape.png"),
      "zipinspect: a '../' entry name rejected (zip-slip)")
// An absolute name is rejected as unsafe.
let absoluteZip = craftZip([CraftEntry(name: "/etc/passwd", uncompressed: 10, compressed: 10, mode: regMode)])
check(ZipInspector.checkArchive(absoluteZip, archiveBytes: absoluteZip.count) == .unsafeName("/etc/passwd"),
      "zipinspect: an absolute entry name rejected")
// A symlink-mode entry is rejected as a symlink (S_IFLNK in the external-attrs unix mode).
let symlinkZip = craftZip([CraftEntry(name: "link", uncompressed: 8, compressed: 8, mode: lnkMode)])
check(ZipInspector.checkArchive(symlinkZip, archiveBytes: symlinkZip.count) == .symlink("link"),
      "zipinspect: a symlink-mode entry rejected (S_IFLNK)")
// A single file over the 5 MB per-file limit is rejected as .fileTooLarge.
let bigFileZip = craftZip([CraftEntry(name: "big.bin", uncompressed: 6 * 1024 * 1024, compressed: 1000, mode: regMode)])
check(ZipInspector.checkArchive(bigFileZip, archiveBytes: bigFileZip.count) == .limit(.fileTooLarge),
      "zipinspect: a single declared file over the 5 MB per-file cap rejected (.fileTooLarge)")
// 12 files each under the per-file cap but summing past the 50 MB TOTAL cap → .uncompressedTooLarge.
let bombTotal = craftZip((0..<12).map { CraftEntry(name: "f\($0).bin", uncompressed: 4_500_000, compressed: 1000, mode: regMode) })
check(ZipInspector.checkArchive(bombTotal, archiveBytes: 200_000) == .limit(.uncompressedTooLarge),
      "zipinspect: declared TOTAL uncompressed over the 50 MB cap rejected (each file under per-file cap)")
// A small archive that claims a ~100x+ inflate within the per-file/total caps still trips the RATIO.
let ratioZip = craftZip([CraftEntry(name: "a.bin", uncompressed: 4 * 1024 * 1024, compressed: 10, mode: regMode)])
check(ZipInspector.checkArchive(ratioZip, archiveBytes: 1000) == .limit(.compressionBomb),
      "zipinspect: compression ratio over limit rejected (declared, pre-extraction)")
// Truncated/garbage bytes never crash — they return a typed error (no EOCD found).
check({ if case .failure(.notAZip) = ZipInspector.inspect(Data("not a zip at all, just text".utf8)) { return true }; return false }(),
      "zipinspect: garbage bytes rejected without crash (.notAZip)")
check({ if case .failure(.notAZip) = ZipInspector.inspect(Data()) { return true }; return false }(),
      "zipinspect: empty input rejected without crash")
// A truncated central directory (EOCD claims a CD that runs past the bytes) is malformed, not a crash.
var truncated = [UInt8](craftZip([CraftEntry(name: "x", uncompressed: 1, compressed: 1, mode: regMode)]))
truncated.removeLast(30)   // lop off the EOCD + tail
check({ if case .failure = ZipInspector.inspect(Data(truncated)) { return true }; return false }(),
      "zipinspect: truncated archive rejected without crash")
// A trailing zip comment is handled (EOCD found by scanning back past the comment).
let commentedZip = craftZip([CraftEntry(name: "theme.json", uncompressed: 50, compressed: 50, mode: regMode)],
                            comment: Array("a friendly zip comment".utf8))
check({ if case .success(let es) = ZipInspector.inspect(commentedZip), es.count == 1 { return true }; return false }(),
      "zipinspect: a trailing zip comment is handled (EOCD located past it)")
// zip64: sizes live in the extra field (32-bit slots are the 0xFFFFFFFF sentinel) — read them back.
let zip64Zip = craftZip([CraftEntry(name: "huge.bin", uncompressed: 0xFFFF_FFFF + 100, compressed: 0xFFFF_FFFF + 1, mode: regMode)],
                        zip64: true)
switch ZipInspector.inspect(zip64Zip) {
case .success(let es):
    check(es.count == 1 && es[0].uncompressedSize == Int(0xFFFF_FFFF + 100),
          "zipinspect: zip64 sizes resolved from the extra field")
case .failure(let e):
    check(false, "zipinspect: zip64 archive must parse [got \(e)]")
}
// An EOCD claiming the MAX 16-bit entry count (65535) but with NO backing central directory must be
// rejected as malformed on the first header parse — it must NOT loop 65535 times or crash. (The
// .tooManyEntries ceiling guards the zip64 path where the count can exceed 100k; a 16-bit EOCD caps at
// 65535, below the ceiling, so this exercises the bounded-loop / forward-progress guard instead.)
var dosEOCD: [UInt8] = []
dosEOCD += le32(0x06054b50) + le16(0) + le16(0) + le16(0xFFFF) + le16(0xFFFF) + le32(0) + le32(0) + le16(0)
check({ if case .failure(.malformed) = ZipInspector.inspect(Data(dosEOCD)) { return true }; return false }(),
      "zipinspect: EOCD claiming 65535 entries with no backing CD -> .malformed (bounded, no crash/spin)")

// --- ThemeInstaller: OFFLINE install pipeline driven from a LOCAL fixture zip (no network) ---
// Build a REAL zip with /usr/bin/ditto at test time (the same engine the installer extracts with), run
// the install-from-local-zip path, and assert it lands a valid theme dir. THIS is the regression proof
// that the feature actually works end-to-end (HIGH-2) — not just compiles.
var fixtureWorkDirs: [URL] = []   // collected so the test cleans every fixture scratch dir at the end
func makeFixtureZip(themeID: String, manifestJSON: String, extraFiles: [(String, Data)] = [],
                    symlink: (name: String, target: String)? = nil) -> URL? {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("ai-fixture-\(UUID().uuidString)", isDirectory: true)
    fixtureWorkDirs.append(work)
    let src = work.appendingPathComponent(themeID, isDirectory: true)   // wrap in one folder (the common case)
    try? fm.createDirectory(at: src.appendingPathComponent("images"), withIntermediateDirectories: true)
    try? Data(manifestJSON.utf8).write(to: src.appendingPathComponent("theme.json"))
    for (rel, data) in extraFiles { try? data.write(to: src.appendingPathComponent(rel)) }
    if let link = symlink {
        try? fm.createSymbolicLink(atPath: src.appendingPathComponent(link.name).path, withDestinationPath: link.target)
    }
    let zipURL = work.appendingPathComponent("\(themeID).zip")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    proc.arguments = ["-c", "-k", "--sequesterRsrc", src.path, zipURL.path]   // -c create, -k PKZip
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }
    proc.waitUntilExit()
    return proc.terminationStatus == 0 ? zipURL : nil
}
func fixtureEntry(id: String, zipURL: URL) -> ThemeCatalogEntry {
    let data = (try? Data(contentsOf: zipURL)) ?? Data()
    return ThemeCatalogEntry(id: id, displayName: "Fixture \(id)", version: "1.0.0",
                             url: "https://example.com/\(id).zip",
                             sha256: ThemeCatalogEntry.sha256Hex(data), sizeBytes: data.count, minAppVersion: nil)
}
// A minimal VALID manifest (id must equal the install folder name).
func fixtureManifest(id: String) -> String {
    """
    {"schemaVersion":1,"id":"\(id)","displayName":"Fixture","states":{"idle":{"visual":{"kind":"image","file":"images/x.png"}}}}
    """
}
let installFM = FileManager.default
// A throwaway install root + scratch dir (NOT the user's real ~/.agent-island).
let benignRoot = installFM.temporaryDirectory.appendingPathComponent("ai-install-root-\(UUID().uuidString)", isDirectory: true)
let benignScratch = installFM.temporaryDirectory.appendingPathComponent("ai-scratch-\(UUID().uuidString)", isDirectory: true)
try? installFM.createDirectory(at: benignScratch, withIntermediateDirectories: true)
fixtureWorkDirs.append(benignRoot); fixtureWorkDirs.append(benignScratch)   // cleaned at the end (exit() skips defer)

if let zipURL = makeFixtureZip(themeID: "fixtheme", manifestJSON: fixtureManifest(id: "fixtheme"),
                               extraFiles: [("images/x.png", Data([0x89, 0x50, 0x4E, 0x47]))]) {
    let entry = fixtureEntry(id: "fixtheme", zipURL: zipURL)
    let result = ThemeInstaller.installFromLocalZip(zipURL, entry: entry, appVersion: "0.3.0",
                                                    installRoot: benignRoot, scratch: benignScratch)
    switch result {
    case .success(let id):
        let landed = benignRoot.appendingPathComponent("fixtheme").appendingPathComponent("theme.json")
        check(id == "fixtheme" && installFM.fileExists(atPath: landed.path),
              "installer: a benign theme installs end-to-end (HIGH-2 regression — feature actually works)")
    case .failure(let e):
        check(false, "installer: benign theme must install [got \(e)]")
    }
} else {
    check(false, "installer: ditto fixture zip must build (test environment needs /usr/bin/ditto)")
}

// Benign install with a TAMPERED catalog entry (wrong sha) is rejected at the integrity gate.
if let zipURL2 = makeFixtureZip(themeID: "tamper", manifestJSON: fixtureManifest(id: "tamper")) {
    var bad = fixtureEntry(id: "tamper", zipURL: zipURL2)
    bad = ThemeCatalogEntry(id: "tamper", displayName: bad.displayName, version: bad.version, url: bad.url,
                            sha256: String(repeating: "0", count: 64), sizeBytes: bad.sizeBytes, minAppVersion: nil)
    let scratch2 = installFM.temporaryDirectory.appendingPathComponent("ai-scratch-\(UUID().uuidString)", isDirectory: true)
    try? installFM.createDirectory(at: scratch2, withIntermediateDirectories: true)
    fixtureWorkDirs.append(scratch2)
    let r = ThemeInstaller.installFromLocalZip(zipURL2, entry: bad, appVersion: "0.3.0",
                                               installRoot: benignRoot, scratch: scratch2)
    check({ if case .failure(.integrity) = r { return true }; return false }(),
          "installer: a sha mismatch is rejected at the integrity gate (before extraction)")
}

// id-escape rejected before ANY filesystem mutation: an id of `..` / `a/b` / empty never moves a file.
let escScratch = installFM.temporaryDirectory.appendingPathComponent("ai-scratch-\(UUID().uuidString)", isDirectory: true)
try? installFM.createDirectory(at: escScratch, withIntermediateDirectories: true)
fixtureWorkDirs.append(escScratch)
let dummyZip = escScratch.appendingPathComponent("dummy.zip")
try? Data([0x00]).write(to: dummyZip)   // never read — id gate fails first
for badID in ["..", "a/b", ""] {
    let e = ThemeCatalogEntry(id: badID, displayName: "x", version: "1", url: "https://e/x.zip",
                              sha256: "x", sizeBytes: 1, minAppVersion: nil)
    let r = ThemeInstaller.installFromLocalZip(dummyZip, entry: e, appVersion: "0.3.0",
                                               installRoot: benignRoot, scratch: escScratch)
    check({ if case .failure(.unsafeID) = r { return true }; return false }(),
          "installer: id '\(badID)' rejected before any filesystem mutation")
}
// isDirectChild guards the move target: a direct child passes, a `..` escape does not.
check(ThemeInstaller.isDirectChild(benignRoot.appendingPathComponent("ok"), of: benignRoot),
      "installer: a direct child of the install root is allowed as a move target")
check(!ThemeInstaller.isDirectChild(benignRoot.appendingPathComponent("a/b"), of: benignRoot),
      "installer: a nested path is NOT a direct child (move refused)")

// A theme zip containing a SYMLINK is rejected (pre-extraction by the inspector if mode-marked, AND
// post-extraction by the lstat walk — here ditto writes a real symlink, exercising the post path).
if let symZip = makeFixtureZip(themeID: "evil", manifestJSON: fixtureManifest(id: "evil"),
                               extraFiles: [("images/x.png", Data([0x89]))],
                               symlink: (name: "link", target: "/etc/passwd")) {
    let e = fixtureEntry(id: "evil", zipURL: symZip)
    let scratch3 = installFM.temporaryDirectory.appendingPathComponent("ai-scratch-\(UUID().uuidString)", isDirectory: true)
    try? installFM.createDirectory(at: scratch3, withIntermediateDirectories: true)
    fixtureWorkDirs.append(scratch3)
    let r = ThemeInstaller.installFromLocalZip(symZip, entry: e, appVersion: "0.3.0",
                                               installRoot: benignRoot, scratch: scratch3)
    check({ if case .failure(.symlinkInArchive) = r { return true }
            if case .failure(.zip(.symlink)) = r { return true }   // pre-extraction reject is also acceptable
            return false }(),
          "installer: a theme zip containing a symlink is rejected (symlink defense, both layers)")
}

// --- Theme URL scheme: only https accepted (MED-4), no network needed. (The App's ThemeDownloader
// gates both the index URL and entry.url through this same pure check before any fetch.) ---
check(ThemeCatalogEntry.isHTTPSURL("https://example.com/x.zip"), "url-scheme: https URL accepted")
check(ThemeCatalogEntry.isHTTPSURL("HTTPS://EXAMPLE.com/x.zip"), "url-scheme: scheme compare is case-insensitive")
check(!ThemeCatalogEntry.isHTTPSURL("http://example.com/x.zip"), "url-scheme: http (plaintext) rejected")
check(!ThemeCatalogEntry.isHTTPSURL("file:///etc/passwd"), "url-scheme: file:// rejected")
check(!ThemeCatalogEntry.isHTTPSURL("ftp://example.com/x.zip"), "url-scheme: ftp:// rejected")
check(!ThemeCatalogEntry.isHTTPSURL("not a url at all"), "url-scheme: scheme-less string rejected")

// --- Management CLI (`agentisland`): pure parse/dispatch, config allowlist, uninstall plan, theme-add
// classification. All network-free + real-FS-free — the executable performs the effects. ---

// Command parsing (total: every input → a Command).
check(CommandParser.parse([]) == .help, "cli-parse: no args -> help")
check(CommandParser.parse(["--help"]) == .help, "cli-parse: --help -> help")
check(CommandParser.parse(["help"]) == .help, "cli-parse: help -> help")
check(CommandParser.parse(["version"]) == .version, "cli-parse: version")
check(CommandParser.parse(["--version"]) == .version, "cli-parse: --version")
check(CommandParser.parse(["theme"]) == .themeList, "cli-parse: bare theme -> list")
check(CommandParser.parse(["theme", "list"]) == .themeList, "cli-parse: theme list")
check(CommandParser.parse(["theme", "add", "critter"]) == .themeAdd(idOrURL: "critter"), "cli-parse: theme add <id>")
check(CommandParser.parse(["theme", "set", "minimal"]) == .themeSet(id: "minimal"), "cli-parse: theme set <id>")
check({ if case .usageError = CommandParser.parse(["theme", "add"]) { return true }; return false }(),
      "cli-parse: theme add with no arg -> usageError")
check({ if case .usageError = CommandParser.parse(["theme", "bogus"]) { return true }; return false }(),
      "cli-parse: unknown theme subcommand -> usageError")
check(CommandParser.parse(["config"]) == .configList, "cli-parse: bare config -> list")
check(CommandParser.parse(["config", "get", "islandTheme"]) == .configGet(key: "islandTheme"), "cli-parse: config get")
check(CommandParser.parse(["config", "set", "soundCueSet", "default"]) == .configSet(key: "soundCueSet", value: "default"),
      "cli-parse: config set")
check({ if case .usageError = CommandParser.parse(["config", "set", "onlyKey"]) { return true }; return false }(),
      "cli-parse: config set missing value -> usageError")
check(CommandParser.parse(["update"]) == .update, "cli-parse: update")
check({ if case .usageError = CommandParser.parse(["update", "now"]) { return true }; return false }(),
      "cli-parse: update with extra arg -> usageError")
check(CommandParser.parse(["uninstall"]) == .uninstall(yes: false, dryRun: false, purge: false), "cli-parse: uninstall (no flags)")
check(CommandParser.parse(["uninstall", "--yes"]) == .uninstall(yes: true, dryRun: false, purge: false), "cli-parse: uninstall --yes")
check(CommandParser.parse(["uninstall", "--dry-run"]) == .uninstall(yes: false, dryRun: true, purge: false), "cli-parse: uninstall --dry-run")
check(CommandParser.parse(["uninstall", "--yes", "--dry-run"]) == .uninstall(yes: true, dryRun: true, purge: false),
      "cli-parse: uninstall --yes --dry-run")
check(CommandParser.parse(["uninstall", "--purge"]) == .uninstall(yes: false, dryRun: false, purge: true),
      "cli-parse: uninstall --purge (wipe custom themes too)")
check({ if case .usageError = CommandParser.parse(["uninstall", "--force"]) { return true }; return false }(),
      "cli-parse: uninstall unknown flag -> usageError")
check(CommandParser.parse(["start-on-boot"]) == .startOnBoot(.status), "cli-parse: bare start-on-boot -> status")
check(CommandParser.parse(["start-on-boot", "on"]) == .startOnBoot(.on), "cli-parse: start-on-boot on")
check(CommandParser.parse(["start-on-boot", "off"]) == .startOnBoot(.off), "cli-parse: start-on-boot off")
check({ if case .usageError = CommandParser.parse(["start-on-boot", "maybe"]) { return true }; return false }(),
      "cli-parse: start-on-boot bad verb -> usageError")
check(CommandParser.parse(["daemon"]) == .daemon(.status), "cli-parse: bare daemon -> status")
check(CommandParser.parse(["daemon", "stop"]) == .daemon(.stop), "cli-parse: daemon stop")
check(CommandParser.parse(["daemon", "restart"]) == .daemon(.restart), "cli-parse: daemon restart")
check(CommandParser.parse(["daemon", "--restart"]) == .daemon(.restart), "cli-parse: daemon --restart (flag alias)")
check({ if case .usageError = CommandParser.parse(["daemon", "frob"]) { return true }; return false }(),
      "cli-parse: daemon bad verb -> usageError")
check({ if case .unknown(let t) = CommandParser.parse(["frobnicate"]) { return t == "frobnicate" }; return false }(),
      "cli-parse: unknown top-level command")

// Help/usage surface mentions every subcommand (so README and --help can't silently drift apart).
let usage = Help.usage
for token in ["theme list", "theme add", "theme set", "config", "config get", "config set",
              "update", "start-on-boot", "uninstall", "version"] {
    check(usage.contains(token), "cli-help: usage mentions '\(token)'")
}

// Config allowlist + validation (pure — no defaults store touched).
check(ConfigKeys.lookup("islandTheme") != nil, "cli-config: islandTheme is a known key")
check(ConfigKeys.lookup("madeUpKey") == nil, "cli-config: an unknown key isn't on the allowlist")
check({ if case .failure(.unknownKey) = ConfigKeys.validate(key: "nope", rawValue: "x") { return true }; return false }(),
      "cli-config: validate rejects an unknown key")
check(ConfigKeys.validate(key: "islandKeepAwake", rawValue: "true") == .success(.bool(true)),
      "cli-config: bool key accepts 'true'")
check(ConfigKeys.validate(key: "islandKeepAwake", rawValue: "off") == .success(.bool(false)),
      "cli-config: bool key accepts 'off' -> false")
check({ if case .failure(.invalidBool) = ConfigKeys.validate(key: "islandKeepAwake", rawValue: "maybe") { return true }; return false }(),
      "cli-config: bool key rejects a non-bool")
check(ConfigKeys.validate(key: "soundCueSet", rawValue: "default") == .success(.string("default")),
      "cli-config: enum key accepts an allowed value")
check({ if case .failure(.notAllowed) = ConfigKeys.validate(key: "soundCueSet", rawValue: "loud") { return true }; return false }(),
      "cli-config: enum key rejects an off-list value")
check(ConfigKeys.validate(key: "islandTheme", rawValue: "anything") == .success(.string("anything")),
      "cli-config: free-string key (islandTheme) accepts any value (ids are dynamic)")

// Uninstall PLAN against a temp HOME — assert EXACTLY what it would target (nothing performed).
let cliSandboxHome = "/tmp/agentisland-selftest-\(UUID().uuidString)"
let cliPaths = InstallPaths(home: cliSandboxHome, appPath: cliSandboxHome + "/App/AgentIsland.app",
                            binDir: cliSandboxHome + "/bin")
let cliPlan = UninstallPlan.plan(cliPaths)
check(cliPlan.first == .reverseHooks(settingsPath: cliSandboxHome + "/.claude/settings.json"),
      "cli-uninstall: plan reverses hooks FIRST (so a half-done uninstall still works)")
check(cliPlan.contains(.unregisterLoginItem), "cli-uninstall: plan unregisters the login item")
check(cliPlan.contains(.removeDataKeepingThemes(path: cliSandboxHome + "/.agent-island")),
      "cli-uninstall: default plan removes ~/.agent-island but KEEPS custom themes (themes/)")
// --purge wipes the whole data dir (custom themes included) for a true clean slate.
let cliPurgePlan = UninstallPlan.plan(cliPaths, purge: true)
check(cliPurgePlan.contains(.removeDirectory(path: cliSandboxHome + "/.agent-island")),
      "cli-uninstall: --purge removes the whole ~/.agent-island (themes too)")
check(!cliPurgePlan.contains(.removeDataKeepingThemes(path: cliSandboxHome + "/.agent-island")),
      "cli-uninstall: --purge does NOT use the keep-themes action")
check(cliPlan.contains(.removeApp(path: cliSandboxHome + "/App/AgentIsland.app")),
      "cli-uninstall: plan removes the .app")
check(cliPlan.contains(.removeBinary(path: cliSandboxHome + "/bin/agentisland")),
      "cli-uninstall: plan removes the agentisland binary")
check(cliPlan.contains(.removeBinary(path: cliSandboxHome + "/bin/agentisland-hook")),
      "cli-uninstall: plan removes the agentisland-hook binary")
// CRITICAL: every path the plan targets stays UNDER the (sandbox) home — never the real system.
let homeDerived: [String?] = cliPlan.map { action in
    switch action {
    case .reverseHooks(let p), .removeBinary(let p), .removeDirectory(let p),
         .removeDataKeepingThemes(let p), .removeApp(let p): return p
    case .unregisterLoginItem: return nil
    }
}
check(homeDerived.compactMap { $0 }.allSatisfy { $0.hasPrefix(cliSandboxHome) },
      "cli-uninstall: EVERY filesystem target is under the sandbox home (never escapes it)")
check(cliPlan.count == 6, "cli-uninstall: plan is exactly 6 actions (hooks, login item, 2 binaries, dir, app)")

// HomeDir validation (pure: `HomeValidation` decides whether a `$HOME` is usable; the effectful
// "is it an existing dir?" check is injected). A degenerate HOME ("/" or whitespace) must be REJECTED
// so the destructive uninstall can't silently "succeed" against `//.agent-island`; a real existing dir
// (the `HOME=$(mktemp -d)` sandbox) must be ACCEPTED so the dev workflow still lands in the sandbox.
let allDirsExist: (String) -> Bool = { _ in true }
check(!HomeValidation.isAcceptable("", dirExists: allDirsExist), "home-validation: empty HOME rejected")
check(!HomeValidation.isAcceptable("   ", dirExists: allDirsExist), "home-validation: whitespace-only HOME rejected")
check(!HomeValidation.isAcceptable("/", dirExists: allDirsExist), "home-validation: HOME='/' (filesystem root) rejected")
check(!HomeValidation.isAcceptable("relative/path", dirExists: allDirsExist), "home-validation: a non-absolute HOME rejected")
check(!HomeValidation.isAcceptable("/no/such/dir", dirExists: { _ in false }), "home-validation: an absolute but non-existent HOME rejected")
check(HomeValidation.isAcceptable("/Users/me", dirExists: allDirsExist), "home-validation: an absolute existing dir accepted")
check(HomeValidation.accepted("/Users/me", dirExists: allDirsExist) == "/Users/me", "home-validation: accepted returns the path when valid")
check(HomeValidation.accepted("  /Users/me  ", dirExists: allDirsExist) == "/Users/me", "home-validation: accepted trims surrounding whitespace")
check(HomeValidation.accepted("/", dirExists: allDirsExist) == nil, "home-validation: accepted returns nil for a rejected HOME (caller falls back)")
// The real sandbox path the destructive-test workflow uses (HOME=$(mktemp -d)) must pass when present.
let sandboxHome = NSTemporaryDirectory() + "ai-home-\(getpid())-\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: sandboxHome, withIntermediateDirectories: true)
let realDirExists: (String) -> Bool = { p in
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
}
check(HomeValidation.isAcceptable(sandboxHome, dirExists: realDirExists),
      "home-validation: a real existing temp dir (the HOME=$(mktemp -d) sandbox) is accepted")
try? FileManager.default.removeItem(atPath: sandboxHome)

// theme-add classification (pure: id vs https url vs refused).
check(ThemeAdd.classify("critter") == .catalogID("critter"), "cli-theme-add: a bare id classifies as a catalog id")
check(ThemeAdd.classify("https://example.com/x.zip") == .directURL("https://example.com/x.zip"),
      "cli-theme-add: an https url classifies as a direct download")
check(ThemeAdd.classify("http://example.com/x.zip") == nil, "cli-theme-add: a plaintext http url is refused")
check(ThemeAdd.classify("file:///etc/passwd") == nil, "cli-theme-add: a file:// url is refused (no id fallback)")
check(ThemeAdd.classify("..") == nil, "cli-theme-add: an unsafe id ('..') is refused")
check(ThemeAdd.classify("a/b") == nil, "cli-theme-add: an id with a separator is refused")
// The self-verifying entry for a direct-url add has size/sha == the downloaded bytes (so the shared
// installer's integrity verify is a tautology — every OTHER gate still runs unchanged).
let cliBlob = Data("theme-bytes".utf8)
let cliEntry = ThemeAdd.selfVerifyingEntry(id: "mytheme", url: "https://example.com/x.zip", data: cliBlob)
check(cliEntry.id == "mytheme" && cliEntry.sizeBytes == cliBlob.count
      && cliEntry.sha256 == ThemeCatalogEntry.sha256Hex(cliBlob),
      "cli-theme-add: self-verifying entry's size+sha match the downloaded bytes")
check(cliEntry.verify(cliBlob) == nil, "cli-theme-add: the self-verifying entry passes the shared integrity verify on its own bytes")
check(cliEntry.verify(Data("tampered".utf8)) != nil, "cli-theme-add: a different blob still fails the shared verify")

// =====================================================================================
// Multi-agent providers: SessionProvider abstraction + OpenCode (Codex deferred — seam only).
// =====================================================================================

// --- Provider badge / kind (drives the small per-row tag distinguishing OpenCode from Claude) ---
check(SessionProviderKind.claude.badge == "C" && SessionProviderKind.opencode.badge == "OC",
      "provider: badge glyphs (C / OC)")

// --- ClaudeCodeProvider parity: the extracted pure mapping must equal composing the original seams
//     (StateEngine + Rollup + the >10-min waiting→idle downgrade + TranscriptDigest). This is the
//     regression guard that refactoring Claude behind the protocol changed NO behavior. ---
let claudeNow = Date(timeIntervalSince1970: 1_700_000_000)
func claudeOldStyle(lines: [String], subStatuses: [AgentStatus], mtime: Date, now: Date) -> AgentStatus {
    let records = TranscriptAdapter.parse(lines: lines)
    let s = StateEngine.deriveStatus(records: records, openPermission: false, lastActivity: mtime, now: now)
    var rolled = Rollup.rollUp(session: s, subAgents: subStatuses)
    if case .waitingForInput = rolled, now.timeIntervalSince(mtime) > 600 { rolled = .finished(.success) }
    return rolled
}
// (a) a stopped text-tail, just touched → working (mid-turn preamble), matches old logic.
let claudeLinesWorking = [
    #"{"type":"user","cwd":"/Users/x/projects/repo-a","message":{"content":"hi"}}"#,
    #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text"}],"usage":{"input_tokens":10,"output_tokens":5}},"timestamp":"2023-11-14T22:00:00.000Z"}"#,
]
let claudeWorking = ClaudeCodeProvider.session(lines: claudeLinesWorking, fullID: "sess-a", mtime: claudeNow,
                                               subDigests: [], now: claudeNow.addingTimeInterval(3))
check(claudeWorking.status == claudeOldStyle(lines: claudeLinesWorking, subStatuses: [], mtime: claudeNow, now: claudeNow.addingTimeInterval(3)),
      "ClaudeCodeProvider: recent text-tail status matches old inline logic (working)")
check(claudeWorking.provider == .claude, "ClaudeCodeProvider: provider kind tagged .claude")
check(claudeWorking.label == "repo-a", "ClaudeCodeProvider: label from transcript cwd lastPathComponent")
check(claudeWorking.tokens == TranscriptDigest.scan(lines: claudeLinesWorking).tokens && claudeWorking.tokens > 0,
      "ClaudeCodeProvider: token figure == TranscriptDigest.scan")
// (b) a stopped text-tail gone quiet past the idle window → finished/idle downgrade, matches old logic.
let claudeStale = ClaudeCodeProvider.session(lines: claudeLinesWorking, fullID: "sess-a", mtime: claudeNow,
                                             subDigests: [], now: claudeNow.addingTimeInterval(900))
check(claudeStale.status == .finished(.success)
      && claudeStale.status == claudeOldStyle(lines: claudeLinesWorking, subStatuses: [], mtime: claudeNow, now: claudeNow.addingTimeInterval(900)),
      "ClaudeCodeProvider: waiting→idle downgrade past 10min matches old logic")
// (c) a waiting text-tail BEFORE the idle window stays waiting (not yet downgraded).
let claudeWaiting = ClaudeCodeProvider.session(lines: claudeLinesWorking, fullID: "sess-a", mtime: claudeNow,
                                               subDigests: [], now: claudeNow.addingTimeInterval(120))
check(claudeWaiting.status == .waitingForInput(.stoppedTurn)
      && claudeWaiting.status == claudeOldStyle(lines: claudeLinesWorking, subStatuses: [], mtime: claudeNow, now: claudeNow.addingTimeInterval(120)),
      "ClaudeCodeProvider: stopped turn pre-idle stays waiting, matches old logic")
// (d) sub-agent rollup precedence preserved. A trailing tool_use makes the SESSION itself working;
//     rolling in a finished sub-agent keeps it working (Rollup: any working ⇒ working) — and the
//     idle downgrade can't fire because the rolled status isn't a wait. Identical to the old logic.
let claudeToolUse = [
    #"{"type":"user","cwd":"/Users/x/projects/repo-a","message":{"content":"hi"}}"#,
    #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text"},{"type":"tool_use"}]}}"#,
]
let claudeRolled = ClaudeCodeProvider.session(lines: claudeToolUse, fullID: "sess-a", mtime: claudeNow,
        subDigests: [SubagentDigest(name: "t", status: .finished(.success), tokens: 0, durationSeconds: nil)],
        now: claudeNow.addingTimeInterval(900))
check(claudeRolled.status == .working
      && claudeRolled.status == claudeOldStyle(lines: claudeToolUse, subStatuses: [.finished(.success)], mtime: claudeNow, now: claudeNow.addingTimeInterval(900)),
      "ClaudeCodeProvider: working session + finished sub-agent stays working (Rollup preserved)")
// (e) discovery against a real on-disk projects dir: a fresh transcript is found, an old one filtered.
let claudeProjRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("ai-claude-\(getpid())-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: claudeProjRoot, withIntermediateDirectories: true)
fixtureWorkDirs.append(claudeProjRoot)
let claudeProjDir = claudeProjRoot.appendingPathComponent("-Users-x-projects-repo-a")
try? FileManager.default.createDirectory(at: claudeProjDir, withIntermediateDirectories: true)
let claudeFresh = claudeProjDir.appendingPathComponent("sess-fresh.jsonl")
try? claudeLinesWorking.joined(separator: "\n").write(to: claudeFresh, atomically: true, encoding: .utf8)
let claudeOld = claudeProjDir.appendingPathComponent("sess-old.jsonl")
try? claudeLinesWorking.joined(separator: "\n").write(to: claudeOld, atomically: true, encoding: .utf8)
// Backdate the "old" transcript past the 30-min active window so discovery filters it out.
try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: claudeOld.path)
let claudeDiscovered = ClaudeCodeProvider(projectsDir: claudeProjRoot.path).poll(now: Date())
check(claudeDiscovered.map(\.fullID) == ["sess-fresh"],
      "ClaudeCodeProvider: discovery finds the fresh transcript, filters the >30-min-old one")
check(ClaudeCodeProvider(projectsDir: "/no/such/projects/dir").poll() == [],
      "ClaudeCodeProvider: an absent projects dir yields no sessions (never crashes)")

// --- OpenCode message.data JSON → typed struct (parse fixtures, grounded in real db data) ---
let ocAssistant = #"""
{"role":"assistant","finish":"tool-calls","time":{"created":1771229252576,"completed":1771229407719},"tokens":{"total":35400,"input":2089,"output":243,"reasoning":90,"cache":{"read":33068,"write":0}},"path":{"cwd":"/Users/x/projects/svc"}}
"""#
let ocMsg = OpenCodeMessage.parse(ocAssistant)
check(ocMsg?.role == "assistant" && ocMsg?.isAssistant == true, "OpenCode parse: role=assistant")
check(ocMsg?.createdMs == 1771229252576 && ocMsg?.completedMs == 1771229407719,
      "OpenCode parse: time.created/completed (large ms as Double coerced to Int)")
check(ocMsg?.tokensTotal == 35400, "OpenCode parse: tokens.total extracted")
check(ocMsg?.finish == "tool-calls", "OpenCode parse: finish extracted")
check(ocMsg?.cwd == "/Users/x/projects/svc", "OpenCode parse: path.cwd extracted")
let ocUser = #"{"role":"user","time":{"created":1771229162313}}"#
let ocUserMsg = OpenCodeMessage.parse(ocUser)
check(ocUserMsg?.role == "user" && ocUserMsg?.completedMs == nil && ocUserMsg?.tokensTotal == nil && ocUserMsg?.isAssistant == false,
      "OpenCode parse: a user message has no completed/tokens")
check(OpenCodeMessage.parse("not json") == nil && OpenCodeMessage.parse("") == nil,
      "OpenCode parse: garbage / empty → nil")
check(OpenCodeMessage.parse(#"{"time":{"created":1}}"#) == nil, "OpenCode parse: a blob with no role → nil")

// --- OpenCode state mapping (poll-style; mirrors the Claude recency approach). now-anchored. ---
let ocNow = Date(timeIntervalSince1970: 1_771_229_500)   // just after the real-data timestamps above
func ms(_ secondsBeforeNow: Double) -> Int { Int((ocNow.timeIntervalSince1970 - secondsBeforeNow) * 1000) }
func upd(_ secondsBeforeNow: Double) -> Date { ocNow.addingTimeInterval(-secondsBeforeNow) }
// (1) assistant streaming (no completed) + recent → working.
let ocStreaming = [OpenCodeMessage(role: "assistant", createdMs: ms(5), completedMs: nil, tokensTotal: 1200, finish: nil)]
check(OpenCodeState.deriveStatus(messages: ocStreaming, lastUpdated: upd(3), now: ocNow) == .working,
      "OpenCode state: streaming turn (no completed) → working")
// (2) assistant finished on the tool-loop finish, recent → still working (mid-loop, like Claude's tool_use tail).
let ocToolLoop = [OpenCodeMessage(role: "assistant", createdMs: ms(60), completedMs: ms(20), tokensTotal: 35400, finish: "tool-calls")]
check(OpenCodeState.deriveStatus(messages: ocToolLoop, lastUpdated: upd(8), now: ocNow) == .working,
      "OpenCode state: finish=tool-calls + recent → working (mid tool-loop)")
// (3) terminal finish, idle within the wait window → waiting on the developer.
let ocTerminal = [OpenCodeMessage(role: "assistant", createdMs: ms(120), completedMs: ms(60), tokensTotal: 9000, finish: "stop")]
check(OpenCodeState.deriveStatus(messages: ocTerminal, lastUpdated: upd(60), now: ocNow) == .waitingForInput(.stoppedTurn),
      "OpenCode state: terminal finish + idle (within wait window) → waiting(stoppedTurn)")
// (4) terminal finish gone quiet past the idle window → finished/idle (downgrade, mirrors Claude poll).
check(OpenCodeState.deriveStatus(messages: ocTerminal, lastUpdated: upd(900), now: ocNow) == .finished(.success),
      "OpenCode state: terminal finish quiet >10min → finished/idle")
// (5) tool-loop turn gone cold past idle → no longer looping → finished/idle.
check(OpenCodeState.deriveStatus(messages: ocToolLoop, lastUpdated: upd(900), now: ocNow) == .finished(.success),
      "OpenCode state: tool-loop gone cold past idle → finished/idle")
// (6) streaming turn gone cold past idle (crashed/abandoned partial) → finished/idle, not stuck working.
check(OpenCodeState.deriveStatus(messages: ocStreaming, lastUpdated: upd(900), now: ocNow) == .finished(.success),
      "OpenCode state: streaming gone cold past idle → finished/idle (not stuck working)")
// (7) a bare user message last (no assistant reply yet) → working (agent is processing).
let ocUserLast = [OpenCodeMessage(role: "user", createdMs: ms(2))]
check(OpenCodeState.deriveStatus(messages: ocUserLast, lastUpdated: upd(2), now: ocNow) == .working,
      "OpenCode state: user message last → working")
// (8) no usable messages → working (spinning up).
check(OpenCodeState.deriveStatus(messages: [], lastUpdated: upd(1), now: ocNow) == .working,
      "OpenCode state: empty messages → working")
// (9) terminal finish, very recent (within working window) → working (brief mid-turn lull).
check(OpenCodeState.deriveStatus(messages: ocTerminal, lastUpdated: upd(5), now: ocNow) == .working,
      "OpenCode state: terminal finish but very recent (<window) → working")
// (10) PHANTOM-WORKING regression: a STALE user-last session (quiet past the idle window) must
//      DOWNGRADE to finished/idle, NOT pin .working forever. Pre-fix this returned .working
//      unconditionally (the unconditional user-last branch), pinning a stale row → defeats the
//      keep-awake sleep assertion with no way to dismiss it. (FAILS before the recency gate.)
check(OpenCodeState.deriveStatus(messages: ocUserLast, lastUpdated: upd(900), now: ocNow) == .finished(.success),
      "OpenCode state: STALE user-last (quiet past idle) → finished/idle, NOT phantom-working")
// (11) PHANTOM-WORKING regression: a STALE empty session (no usable messages, quiet past the idle
//      window) must DOWNGRADE too. Pre-fix the empty-messages branch returned .working
//      unconditionally — a session that never produced a message would pin .working forever.
check(OpenCodeState.deriveStatus(messages: [], lastUpdated: upd(900), now: ocNow) == .finished(.success),
      "OpenCode state: STALE empty session (quiet past idle) → finished/idle, NOT phantom-working")
// (12) the FRESH counterparts still read as working (the gate only fires past the idle window).
check(OpenCodeState.deriveStatus(messages: ocUserLast, lastUpdated: upd(2), now: ocNow) == .working
      && OpenCodeState.deriveStatus(messages: [], lastUpdated: upd(2), now: ocNow) == .working,
      "OpenCode state: FRESH user-last / empty session still → working (gate fires only past idle)")
// (13) a nil time_updated is treated conservatively as stale → finished/idle, not pinned working.
check(OpenCodeState.deriveStatus(messages: ocUserLast, lastUpdated: nil, now: ocNow) == .finished(.success)
      && OpenCodeState.deriveStatus(messages: [], lastUpdated: nil, now: ocNow) == .finished(.success),
      "OpenCode state: missing time_updated treated as stale → finished/idle (conservative)")

// --- OpenCode token extraction: latest assistant tokens.total (NOT summed). ---
let ocTokMsgs = [
    OpenCodeMessage(role: "user"),
    OpenCodeMessage(role: "assistant", tokensTotal: 1000, finish: "tool-calls"),
    OpenCodeMessage(role: "assistant", tokensTotal: 35400, finish: "tool-calls"),   // latest assistant
]
check(OpenCodeState.tokens(messages: ocTokMsgs) == 35400, "OpenCode tokens: latest assistant tokens.total (not summed)")
check(OpenCodeState.tokens(messages: [OpenCodeMessage(role: "user")]) == 0, "OpenCode tokens: no assistant tokens → 0")

// --- OpenCodeStore row → ProviderSession mapping (pure; archived excluded, sub-session excluded) ---
let ocRowTop = OpenCodeStore.SessionRow(
    id: "ses_top", parentID: nil, directory: "/Users/x/projects/svc-dir", title: "Refactor journey",
    timeCreatedMs: ms(300), timeUpdatedMs: ms(60), timeArchivedMs: nil,
    messages: [OpenCodeMessage(role: "assistant", createdMs: ms(120), completedMs: ms(60), tokensTotal: 35400, finish: "stop")])
let ocRowSub = OpenCodeStore.SessionRow(
    id: "ses_sub", parentID: "ses_top", directory: "/Users/x/projects/svc-dir", title: "sub task",
    timeCreatedMs: ms(120), timeUpdatedMs: ms(60), timeArchivedMs: nil, messages: [])
let ocRowArchived = OpenCodeStore.SessionRow(
    id: "ses_arch", parentID: nil, directory: "/Users/x/projects/old", title: "Old",
    timeCreatedMs: ms(9000), timeUpdatedMs: ms(8000), timeArchivedMs: ms(7000), messages: [])
let ocMapped = OpenCodeStore.sessions(from: [ocRowTop, ocRowSub, ocRowArchived], now: ocNow)
check(ocMapped.map(\.fullID) == ["ses_top"],
      "OpenCodeStore: only top-level non-archived session becomes a row (sub-session + archived excluded)")
// RECENCY drop: a non-archived top-level row whose time_updated is older than the activeWindow
// (1800s) is DROPPED (mirroring the Claude poll path's discovery filter — no permanent phantom row),
// while a freshly-updated sibling is KEPT. A row with NO time_updated is dropped (conservative).
let ocRowStale = OpenCodeStore.SessionRow(
    id: "ses_stale", parentID: nil, directory: "/Users/x/projects/stale-dir", title: "Stale work",
    timeCreatedMs: ms(9000), timeUpdatedMs: ms(2000), timeArchivedMs: nil,   // updated 2000s ago > 1800s window
    messages: [OpenCodeMessage(role: "user", createdMs: ms(2000))])
let ocRowNoUpdated = OpenCodeStore.SessionRow(
    id: "ses_noupd", parentID: nil, directory: "/Users/x/projects/noupd-dir", title: "No timestamp",
    timeCreatedMs: ms(9000), timeUpdatedMs: nil, timeArchivedMs: nil, messages: [])
let ocRecencyMapped = OpenCodeStore.sessions(from: [ocRowTop, ocRowStale, ocRowNoUpdated], now: ocNow)
check(ocRecencyMapped.map(\.fullID) == ["ses_top"],
      "OpenCodeStore.sessions(from:): DROPS a top-level row older than the activeWindow (and one with no time_updated), KEEPS the fresh one")
check(ocMapped.first?.provider == .opencode, "OpenCodeStore: mapped session tagged .opencode")
check(ocMapped.first?.label == "svc-dir", "OpenCodeStore: label = directory lastPathComponent")
check(ocMapped.first?.title == "Refactor journey", "OpenCodeStore: title from session.title")
check(ocMapped.first?.tokens == 35400, "OpenCodeStore: tokens from latest assistant tokens.total")
check(ocMapped.first?.status == .waitingForInput(.stoppedTurn), "OpenCodeStore: terminal+idle → waiting (via OpenCodeState)")
// title falls back to nil when blank → the App uses the label instead.
let ocBlankTitle = OpenCodeStore.providerSession(from: OpenCodeStore.SessionRow(
    id: "s", parentID: nil, directory: "/a/b/proj", title: "   ", timeCreatedMs: nil, timeUpdatedMs: nil,
    timeArchivedMs: nil, messages: []), now: ocNow)
check(ocBlankTitle.title == nil && ocBlankTitle.label == "proj",
      "OpenCodeStore: blank title → nil; label falls back to dir name")

// --- OpenCodeStore graceful failure: absent / non-db file → no sessions, never crashes ---
check(OpenCodeStore.readSessions(path: "/no/such/opencode.db") == [],
      "OpenCodeStore: absent db file → [] (no crash)")
let ocGarbageDB = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("ai-ocgarbage-\(getpid())-\(UUID().uuidString).db")
try? Data("this is not a sqlite database".utf8).write(to: ocGarbageDB)
fixtureWorkDirs.append(ocGarbageDB)
check(OpenCodeStore.readSessions(path: ocGarbageDB.path) == [],
      "OpenCodeStore: a non-sqlite file → [] (open/prepare fails gracefully)")
check(OpenCodeProvider(dbPath: "/no/such/opencode.db").poll() == [],
      "OpenCodeProvider: absent db → no sessions")

// --- OpenCodeStore live SQLite read against a TINY fixture db with the REAL schema + rows ---
//     (built in a temp dir; the real ~/.local/share/opencode/opencode.db is NEVER written.) ---
let ocFixtureDB = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("ai-ocfixture-\(getpid())-\(UUID().uuidString).db")
fixtureWorkDirs.append(ocFixtureDB)
func ocBuildFixtureDB(at path: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        sqlite3_close(db); return false
    }
    defer { sqlite3_close(db) }
    // Confirmed-schema subset (the columns the reader selects); NOT NULL/PK mirror the real db.
    let schema = """
    CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT,
        slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL, version TEXT NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER);
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
    """
    guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { return false }
    func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }
    // One top-level session (terminal finish, idle) + one archived + one sub-session.
    let tCreated = ms(300), tUpdated = ms(60)
    let dataJSON = #"{"role":"assistant","finish":"stop","time":{"created":1,"completed":2},"tokens":{"total":12345},"path":{"cwd":"/x"}}"#
        .replacingOccurrences(of: "'", with: "''")
    var ok = exec("INSERT INTO session VALUES ('ses_live','prj',NULL,'slug','/Users/x/projects/live-repo','Live title','v1',\(tCreated),\(tUpdated),NULL);")
    ok = ok && exec("INSERT INTO session VALUES ('ses_arch','prj',NULL,'slug','/x/old','Old','v1',\(ms(9000)),\(ms(8000)),\(ms(7000)));")
    ok = ok && exec("INSERT INTO session VALUES ('ses_sub','prj','ses_live','slug','/x/live','Sub','v1',\(ms(120)),\(ms(60)),NULL);")
    ok = ok && exec("INSERT INTO message VALUES ('msg1','ses_live',\(ms(120)),\(ms(60)),'\(dataJSON)');")
    return ok
}
check(ocBuildFixtureDB(at: ocFixtureDB.path), "OpenCodeStore fixture: built a temp db with the real schema + rows")
// `now: ocNow` so the SQL recency cutoff is anchored to the fixture's timestamps (which are built
// relative to ocNow), not the wall clock. The fresh top-level row + the archived & sub rows are all
// read (archived/sub are kept by the WHERE regardless of recency; sessions(from:) excludes them).
let ocLiveRows = OpenCodeStore.readSessions(path: ocFixtureDB.path, now: ocNow)
check(ocLiveRows.count == 3, "OpenCodeStore fixture: read all 3 session rows from SQLite")
check(ocLiveRows.first(where: { $0.id == "ses_live" })?.messages.first?.tokensTotal == 12345,
      "OpenCodeStore fixture: message.data JSON parsed off the live db (tokens.total)")
check(ocLiveRows.first(where: { $0.id == "ses_sub" })?.isSubSession == true,
      "OpenCodeStore fixture: parent_id set → isSubSession")
check(ocLiveRows.first(where: { $0.id == "ses_arch" })?.isArchived == true,
      "OpenCodeStore fixture: time_archived set → isArchived")
let ocLiveSessions = OpenCodeStore.sessions(from: ocLiveRows, now: ocNow)
check(ocLiveSessions.map(\.fullID) == ["ses_live"],
      "OpenCodeStore fixture: end-to-end read+map yields only the live top-level session")
check(ocLiveSessions.first?.label == "live-repo" && ocLiveSessions.first?.tokens == 12345
      && ocLiveSessions.first?.provider == .opencode,
      "OpenCodeStore fixture: mapped session has dir label, tokens, .opencode kind")
// The whole provider end-to-end (poll → read → map) against the fixture db.
check(OpenCodeProvider(dbPath: ocFixtureDB.path).poll(now: ocNow).map(\.fullID) == ["ses_live"],
      "OpenCodeProvider: poll() against the fixture db yields the live session")

// --- OpenCodeStore SQL-level recency cutoff: a STALE top-level row is dropped IN THE SQL READ (not
//     just the pure mapping), so the per-poll read of sessions+messages is bounded by recency. Build
//     a second fixture with a fresh AND a stale top-level row + a stale message on each. ---
let ocRecencyDB = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("ai-ocrecency-\(getpid())-\(UUID().uuidString).db")
fixtureWorkDirs.append(ocRecencyDB)
func ocBuildRecencyDB(at path: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        sqlite3_close(db); return false
    }
    defer { sqlite3_close(db) }
    let schema = """
    CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT,
        slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL, version TEXT NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER);
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
    """
    guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { return false }
    func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }
    let assistantData = #"{"role":"assistant","finish":"stop","time":{"created":1,"completed":2},"tokens":{"total":7}}"#
    // fresh: updated 60s ago (< 1800s window). stale: updated 2000s ago (> window).
    var ok = exec("INSERT INTO session VALUES ('ses_fresh','prj',NULL,'slug','/x/fresh','Fresh','v1',\(ms(300)),\(ms(60)),NULL);")
    ok = ok && exec("INSERT INTO session VALUES ('ses_old','prj',NULL,'slug','/x/old','Old','v1',\(ms(9000)),\(ms(2000)),NULL);")
    ok = ok && exec("INSERT INTO message VALUES ('mf','ses_fresh',\(ms(120)),\(ms(60)),'\(assistantData)');")
    ok = ok && exec("INSERT INTO message VALUES ('mo','ses_old',\(ms(9000)),\(ms(2000)),'\(assistantData)');")
    return ok
}
check(ocBuildRecencyDB(at: ocRecencyDB.path), "OpenCodeStore recency fixture: built a temp db with a fresh + a stale top-level row")
let ocRecencyRows = OpenCodeStore.readSessions(path: ocRecencyDB.path, now: ocNow)
check(ocRecencyRows.map(\.id).sorted() == ["ses_fresh"],
      "OpenCodeStore: SQL read DROPS the stale top-level row (time_updated < cutoff), KEEPS the fresh one")
check(ocRecencyRows.first?.messages.count == 1,
      "OpenCodeStore: messages are only read for the kept (fresh) session, not the dropped stale one")
check(OpenCodeProvider(dbPath: ocRecencyDB.path).poll(now: ocNow).map(\.fullID) == ["ses_fresh"],
      "OpenCodeProvider: poll() drops the stale top-level session end-to-end")

// --- Daemon-fresh merge: OpenCode poll rows must appear ALONGSIDE the Claude daemon rows WITHOUT
//     perturbing the daemon rows' relative order. SessionMergeOrder is the exact rule the App's
//     activeSessions() daemon-fresh branch uses (priority asc, then lastActivity desc, STABLE). We
//     model the merge over ProviderSession (daemon rows carry no lastActivity → nil). ---
func pSess(_ id: String, _ status: AgentStatus, _ last: Date?, _ prov: SessionProviderKind = .claude) -> ProviderSession {
    ProviderSession(provider: prov, fullID: id, label: id, title: nil, status: status, tokens: 0,
                    startedAt: nil, lastActivity: last)
}
// Daemon rows (Claude), nil lastActivity, in their authoritative (sessionID-sorted) order. Two are
// waiting (rank 1, higher priority), one working (rank 3). OpenCode rows have real lastActivity.
// Ranks: waiting(stoppedTurn)=1, working=3 (waiting is HIGHER priority / sorts first).
let daemonRows = [
    pSess("c-a", .waitingForInput(.stoppedTurn), nil),
    pSess("c-b", .working, nil),
    pSess("c-c", .waitingForInput(.stoppedTurn), nil),
]
let ocMergeRows = [
    pSess("oc-work", .working, ocNow.addingTimeInterval(-5), .opencode),
    pSess("oc-wait", .waitingForInput(.stoppedTurn), ocNow.addingTimeInterval(-5), .opencode),
]
let mergedOrder = SessionMergeOrder.ordered(daemonRows + ocMergeRows, status: \.status, lastActivity: \.lastActivity)
// OpenCode rows are PRESENT in the merged list — i.e. visible alongside the daemon rows (the LOW fix).
check(Set(mergedOrder.map(\.fullID)) == ["c-a", "c-b", "c-c", "oc-work", "oc-wait"],
      "SessionMergeOrder: all daemon + OpenCode rows present after merge (OpenCode visible in daemon mode)")
// The Claude daemon rows preserve their RELATIVE order WITHIN a priority rank (the stability
// guarantee): both waiting daemon rows tie on rank+nil-activity, so c-a stays before c-c — not
// perturbed by the merge. This is the "daemon order not disturbed" invariant.
let daemonWaitsOrder = mergedOrder.filter { $0.provider == .claude && DisplayPriority.rank($0.status) == 1 }.map(\.fullID)
check(daemonWaitsOrder == ["c-a", "c-c"],
      "SessionMergeOrder: equal-rank daemon rows keep their relative order (stable — c-a before c-c)")
// Full order via the standard comparator (rank asc, then lastActivity desc, stable on ties):
//   rank 1 (waiting): oc-wait (fresh) > c-a > c-c (both nil, stable). rank 3 (working): oc-work > c-b.
check(mergedOrder.map(\.fullID) == ["oc-wait", "c-a", "c-c", "oc-work", "c-b"],
      "SessionMergeOrder: priority asc then recency desc; fresh OpenCode rows sort above nil-activity daemon rows within a rank")

// Tidy up every fixture / install-root / scratch dir built above. (Top-level `defer` would be skipped
// by the `exit()` below, so cleanup is explicit — matching the SettingsFile temp-dir teardown earlier.)
for dir in fixtureWorkDirs { try? FileManager.default.removeItem(at: dir) }

print("")
if failures == 0 {
    print("ALL PASS — \(total) checks")
    exit(0)
} else {
    print("FAILURES: \(failures) of \(total)")
    exit(1)
}
