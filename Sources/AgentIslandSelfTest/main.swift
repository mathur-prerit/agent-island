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

print("")
if failures == 0 {
    print("ALL PASS — \(total) checks")
    exit(0)
} else {
    print("FAILURES: \(failures) of \(total)")
    exit(1)
}
