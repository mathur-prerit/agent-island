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
