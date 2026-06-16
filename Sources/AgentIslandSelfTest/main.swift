import Foundation
import AgentIslandCore
import PersonaKit

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

print("")
if failures == 0 {
    print("ALL PASS — \(total) checks")
    exit(0)
} else {
    print("FAILURES: \(failures) of \(total)")
    exit(1)
}
