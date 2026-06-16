import Foundation
import AgentIslandCore

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

print("")
if failures == 0 {
    print("ALL PASS — \(total) checks")
    exit(0)
} else {
    print("FAILURES: \(failures) of \(total)")
    exit(1)
}
