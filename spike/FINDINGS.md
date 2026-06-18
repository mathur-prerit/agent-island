# U1 — Seam-Verification Spike: FINDINGS

Date: 2026-06-16
Method: read-only analysis of real `~/.claude/projects/` transcripts (including a live session with a nested sub-agent tree). No live hooks installed yet — existing transcripts substitute for most of the verification.

## Verdict: GO

Every structural assumption the design depends on is confirmed against real data. The WAITING-vs-FINISHED worry is resolved by the refined state model below, so a FINISHED-only fallback is not needed for v1.

## Verified facts

### Transcript layout
- Session transcript: `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`
- Sub-agent transcript: `<encoded-cwd>/<session-uuid>/subagents/agent-<id>.jsonl`
- Workflow sub-agents nest deeper: `<session-uuid>/subagents/workflows/wf_<id>/agent-<id>.jsonl`
- → Recursive discovery glob required (`<session-uuid>/subagents/**/agent-*.jsonl`).

### Record vocabulary (sampled session: 471 records)
- Conversational (drive state): `user`, `assistant`
- Metadata (skip when finding the last conversational record): `permission-mode`, `mode`, `last-prompt`, `ai-title`, `attachment`, `file-history-snapshot`, `system`, `queue-operation`
- The transcript tail frequently ends on a metadata record (observed: `last-prompt`, `ai-title`, `mode`, `permission-mode`). A naive "last line type" read is wrong.

### Mid-turn tool_use
- Assistant content-block kinds observed: `tool_use` ×68, `thinking` ×52, `text` ×52.
- → A trailing `tool_use` block means the agent is WORKING (about to receive a tool_result), not finished. Inspect the last assistant record's content-block kinds.

### Sub-agent discrimination
- Top-level session lines: `isSidechain` absent (471/471).
- Sub-agent file lines: `isSidechain: true`. Reliable discriminator.

## Refined state-derivation model (implemented in AgentIslandCore)

- WORKING            = last conversational record is assistant with trailing `tool_use`, OR a user record is last
- WAITING-FOR-INPUT  = turn stopped on assistant-final-text, no pending tool, no open permission
- WAITING (blocking) = open `PermissionRequest` / `Elicitation` (incl. sub-agent-caused)
- FINISHED(verdict)  = `SessionEnd` / quit / staleness; verdict from exit context
- Re-engagement      = `UserPromptSubmit` (not fired for `/commands` or `--resume` — staleness/next-event is the backstop)

There is no separate mid-run "done" state to disambiguate; a stopped turn is WAITING until the session ends.

## Residual (does not block; folds into early daemon testing)
- A live-hooks trial to confirm `Notification` / `PermissionRequest` timing and that the "stopped turn = waiting" model matches lived feel.

## Golden-file sources (capture as fixtures later; sanitize first — real prompt content)
- Session w/ nested sub-agents + metadata tail
- A flat sub-agent file
- A workflow-nested sub-agent file

---

# Multi-agent providers — OpenCode (verified) + Codex (deferred seam)

Date: 2026-06-18
Method: read-only analysis of a real `~/.local/share/opencode/opencode.db` (2 sessions / 16 messages),
plus a SQLite3-in-SwiftPM compile probe. The Claude path above stays the verified reference.

The three Claude-specific seams (discovery scan, `TranscriptAdapter` record parsing, `StateEngine`
state derivation) are generalized behind a `SessionProvider` protocol in `AgentIslandCore`. Each
provider maps its own on-disk format → the shared `ProviderSession`/`AgentStatus` model. The protocol
is POLLING-only; Claude's event-driven hooks→daemon path stays Claude-specific and outside it.

## OpenCode — VERIFIED (GO; implemented as `OpenCodeProvider`)

OpenCode stores sessions in **SQLite**, NOT flat JSONL — `~/.local/share/opencode/opencode.db`
(WAL mode; `-wal` + `-shm` siblings present, db may be open while OpenCode runs).

### `import SQLite3` in SwiftPM
- Works with no new dependency and no Package.swift linker flags (macOS system module). Verified:
  `sqlite3_libversion()` → **3.51.0**.
- Open **read-only** with plain `SQLITE_OPEN_READONLY` (NOT `immutable=1` — immutable ignores the
  WAL and would read a stale snapshot of a live db). `PRAGMA query_only=ON` belt-and-suspenders.
  Verified a plain-RO open reads the *current* state (count via WAL) and leaves `-shm` mtime
  untouched, i.e. it does not write.

### Confirmed schema (columns the reader uses)
- `project(id, worktree, name, time_created, time_updated, …)` — `worktree` is the repo path.
- `session(id, project_id, parent_id, slug, directory, title, version, time_created, time_updated,
  time_compacting, time_archived, …)` — `directory` = cwd, `title` = label (NOT NULL),
  `parent_id` non-null = a SUB-session, `time_archived` set = archived. Indices on project + parent.
- `message(id, session_id, time_created, time_updated, data TEXT)` — `data` is a JSON string.
- `part(id, message_id, session_id, data TEXT)` — finer message parts (not needed for state).

### `message.data` JSON (assistant, real sample)
```
role: "assistant"
time: { created: 1771229252576, completed: 1771229407719 }   // ms; completed present ⇒ turn done generating
tokens: { total: 35400, input, output, reasoning, cache:{read,write} }
finish: "tool-calls"                                          // mid-loop; terminal stop would differ
path: { cwd: "/Users/…/svc", root: "…" }
```
A `user` message carries only `role` + `time.created` (no `tokens`, no `finish`). Big ms timestamps
round-trip as JSON Double → coerced to Int in the parser.

### State mapping chosen (poll-style; mirrors the Claude recency approach) — `OpenCodeState`
Inferred from the LAST conversational message + the row's `time_updated` recency:
- **user message last** → WORKING (agent is processing it) — like Claude's "user record last".
- **assistant streaming** (`completed` absent) → WORKING; but gone cold past the idle window
  (10 min) ⇒ FINISHED/idle (a crashed partial turn shouldn't pin "working" forever).
- **assistant `finish == "tool-calls"`** (mid tool-loop, the OpenCode analogue of Claude's trailing
  `tool_use` block) → WORKING while recent; quiet past idle ⇒ FINISHED/idle.
- **assistant terminal finish** (anything else / none) → very recent (<12 s working window) reads as
  WORKING (brief mid-turn lull); idle within the wait window ⇒ WAITING(stoppedTurn); quiet past the
  10-min idle window ⇒ FINISHED/idle. Same downgrade the Claude polling path applies.
- **sub-session** (`parent_id` set) → NOT a top-level row (rolled up / excluded, like a Claude
  sub-agent rollup; the parent represents the work). **archived** (`time_archived`) → excluded.

Empirically one live session ended on `finish="tool-calls"` with `completed` present (mid-loop) and
another's last assistant had no `completed`/`finish` (still streaming) — both map to WORKING, which
matched the lived state.

### Token source
The latest assistant message's `tokens.total`. OpenCode's `total` is already the full per-turn
request context (input + cache + output + reasoning), so — unlike Claude's per-record fan-out which
we dedup+sum — we just take the last assistant turn's total (not summed).

### Failure handling (all → no sessions, never crash)
Absent file (fast `fileExists` bail), unreadable/locked open, a non-SQLite file (prepare fails),
missing `session` table, empty db. All covered by self-tests; the live read against a real db is
by-eye (a temp **fixture db** with the real schema is what the tests build — the real
`opencode.db` is NEVER written).

### Pure-tested vs by-eye
- Pure-tested (fixtures, no live db): `OpenCodeMessage.parse`, the full `OpenCodeState.deriveStatus`
  matrix (working / tool-loop-working / terminal-waiting / terminal-idle / streaming / cold-streaming
  / user-last / empty / very-recent), token extraction, the row→`ProviderSession` mapping
  (sub-session + archived exclusion, label/title fallback), graceful-failure paths, AND a real SQLite
  read+map against a temp fixture db built with the confirmed schema.
- By-eye (left for live verification): real OpenCode sessions showing up in the running app with the
  `[OC]` badge alongside Claude rows, and confirming the working/waiting feel against a live session.

## Codex — DEFERRED (seam only; NOT implemented)

Per user decision: `codex` (OpenAI Codex CLI) is **not installed** on this machine and there is no
real data to verify a parser against, so shipping an unverified Codex parser was explicitly rejected.
The `SessionProvider` protocol is ready for it (add a `case codex` + a `CodexProvider`), but no parser
exists. Research-level expectations to confirm during a future Codex spike (do NOT trust until
verified against real data):
- Codex CLI session/rollout logs are expected under `~/.codex/` (e.g. a `sessions/` or `history`
  area; JSONL rollout files have been reported). Confirm the exact dir + record format first.
- Determine the record vocabulary, where cwd/label live, the token figure, and the
  working-vs-waiting-vs-finished signal — the same facts the Claude/OpenCode spikes established.
- No hook/event mechanism is assumed; treat as poll-only like OpenCode unless a spike finds otherwise.
- Only then implement `CodexProvider` behind the protocol with fixture-backed self-tests.
