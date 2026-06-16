# agent-island

A quirky, quiet, always-on-top macOS status **island** that watches your Claude Code sessions — including their nested sub-agents — and shows, per session, whether each is **working**, **waiting for you**, or **done**, plus a one-line "what it's doing." Randomized, legibility-gated **Persona Packs** give it personality; it's muted by default and remembers your settings.

> **Status: early.** The verified state-derivation core (transcript adapter, state engine, sub-agent rollup, task-line sanitizer) is built and tested. The daemon, hook bridge, persona system, and AppKit island UI are in progress.

## How it works

No Claude Code hook cleanly separates "waiting for input" from "finished" (`Stop` fires for both). agent-island derives state from the session transcript: it reads the **last conversational record** (skipping metadata records like `ai-title` / `permission-mode`), where a trailing assistant `tool_use` block means *working* and a stopped turn means *waiting for you*; an open permission prompt is an explicit block; `SessionEnd` / quit / staleness means *finished*. Sub-agents are read from `<session-uuid>/subagents/**/agent-*.jsonl`. All of this was verified against real `~/.claude` transcripts — see [`spike/FINDINGS.md`](spike/FINDINGS.md).

## Build & test

Requires Swift 6+. The core logic is framework-free and runs under **Command Line Tools** (no full Xcode needed):

```sh
swift build
swift run AgentIslandSelfTest
```

The AppKit island UI (under `App/`, in progress) requires full Xcode to build.

## Layout

- `Sources/AgentIslandCore` — transcript adapter, state engine, sub-agent rollup, task-line sanitizer (built + tested)
- `Sources/AgentIslandSelfTest` — framework-free test runner
- `spike/FINDINGS.md` — seam-verification findings (the integration-risk gate)
- *(in progress)* daemon + Unix-socket IPC, the hook-bridge CLI, PersonaKit, and the AppKit island app

## License

MIT © 2026 Prerit Mathur
