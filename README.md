# agent-island

A quirky, quiet, always-on-top macOS status **island** that watches your Claude Code sessions — including their nested sub-agents — and shows, per session, whether each is **working**, **waiting for you**, or **done**, plus a one-line "what it's doing." Randomized, legibility-gated **Persona Packs** give it personality; it's muted by default and remembers your settings.

> **Status: early.** The verified state-derivation core (transcript adapter, state engine, sub-agent rollup, task-line sanitizer) is built and tested. The daemon, hook bridge, persona system, and AppKit island UI are in progress.

## How it works

No Claude Code hook cleanly separates "waiting for input" from "finished" (`Stop` fires for both). agent-island derives state from the session transcript: it reads the **last conversational record** (skipping metadata records like `ai-title` / `permission-mode`), where a trailing assistant `tool_use` block means *working* and a stopped turn means *waiting for you*; an open permission prompt is an explicit block; `SessionEnd` / quit / staleness means *finished*. Sub-agents are read from `<session-uuid>/subagents/**/agent-*.jsonl`. All of this was verified against real `~/.claude` transcripts — see [`spike/FINDINGS.md`](spike/FINDINGS.md).

## Install & run (no Apple ID, no signing)

Gatekeeper's "unidentified developer" warning only affects *downloaded* unsigned apps — building locally avoids it entirely. Pick one (all need only Swift 6+, via Xcode or Command Line Tools — AppKit compiles under either):

**Run from source**
```sh
git clone https://github.com/mathur-prerit/agent-island
cd agent-island
swift run AgentIslandApp      # a menu-bar item appears at the top-right
```

**Build a double-clickable app**
```sh
./Scripts/build-app.sh
open build/AgentIsland.app    # opens with no warning — you built it locally
```

**Homebrew (build-from-source)**
```sh
brew tap mathur-prerit/agent-island https://github.com/mathur-prerit/agent-island
brew install --HEAD agent-island
agent-island
```

## Event-driven mode (optional)

By default the app polls your transcripts every few seconds. To switch to event-driven updates (lower overhead, instant), run the daemon and register the Claude Code hooks:

```sh
# 1. register hooks in ~/.claude/settings.json (safe: backup + atomic write; undo with `uninstall`)
swift run AgentIslandHookCLI install

# 2. run the daemon (or copy launchd/com.mathur-prerit.agentisland.plist into
#    ~/Library/LaunchAgents/ — with the binary path filled in — to auto-start it)
swift run agentislandd
```

With the daemon running, the app reads its `~/.agent-island/state.json` instead of polling; if the daemon isn't running, the app automatically falls back to polling.

## Build & test

```sh
swift build
swift run AgentIslandSelfTest   # framework-free self-test runner (82 checks)
swift run AgentIslandDemo       # the engine on your real ~/.claude transcripts
```

## Layout

- `Sources/AgentIslandCore` — transcript adapter, state engine, sub-agent rollup, task-line sanitizer (built + tested)
- `Sources/AgentIslandSelfTest` — framework-free test runner
- `spike/FINDINGS.md` — seam-verification findings (the integration-risk gate)
- *(in progress)* daemon + Unix-socket IPC, the hook-bridge CLI, PersonaKit, and the AppKit island app

## License

MIT © 2026 Prerit Mathur
