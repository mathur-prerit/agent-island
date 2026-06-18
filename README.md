# agent-island

A quirky, quiet, always-on-top macOS status **island** that watches your Claude Code sessions — including their nested sub-agents — and shows, per session, whether each is **working**, **waiting for you**, or **done**, plus a one-line "what it's doing." Each session wears a randomized **persona** (Pirate, Astronaut, Herald, …); working sessions spin with a live step count; it's muted by default and stays out of your way.

> **Status:** working v0 — menu-bar item + a collapsible, priority-ordered floating island (collapsed by default; expands to a scrollable list that animates only the running session), personas, live step + token counts, and an event-driven daemon (the default, via a reversible first-launch setup) are all in. Verified core logic with 98 self-test checks. A settings UI is still to come.

## Requirements

- **macOS 13+**
- **Swift 6+** — via **Xcode** *or* the **Command Line Tools** (`xcode-select --install`). AppKit builds under either; no full Xcode required.
- No Apple Developer account needed (see below).

## Installation

Gatekeeper's "unidentified developer" warning only affects *downloaded, unsigned* apps — building locally avoids it entirely, so **no Apple ID, code-signing, or notarization is involved**. Pick whichever fits you:

### Option A — Run from source (quickest)

```sh
git clone https://github.com/mathur-prerit/agent-island
cd agent-island
swift run AgentIslandApp
```

### Option B — Build a double-clickable app

```sh
git clone https://github.com/mathur-prerit/agent-island
cd agent-island
./Scripts/build-app.sh
open build/AgentIsland.app          # opens with no warning — you built it locally
```

To keep it around: drag `build/AgentIsland.app` into `/Applications`, then add it under **System Settings ▸ General ▸ Login Items** to launch it at login.

### Option C — Homebrew (build-from-source)

```sh
brew tap mathur-prerit/agent-island https://github.com/mathur-prerit/agent-island
brew install --HEAD agent-island
agent-island
```

### After launching

- A small glyph appears in your **menu bar** (top-right), colored by aggregate state: gray `○` idle · teal `◐` working · red, gently pulsing `● N` when N sessions wait on you. Click it for the session list, a **Show floating island** toggle, an **Event-driven mode** toggle, and **Quit**.
- The **floating island** sits at the top-right, **collapsed by default** to a one-line summary (e.g. `agent-island · ❗1 waiting · ◐2 running ▸`). Click the header to expand a **scrollable, height-capped** list of active sessions (touched in the last 30 min), sorted by priority: **waiting for you → failed → running → finished**. Each row shows a persona glyph, project name, and state; **running** rows carry a live `N steps · T tok` line (steps = tool calls; tokens = peak request context + generated output) and are the **only** rows that animate (a rotating aurora ring) — waiting/failed/finished rows are dimmed and still, so only active work draws the eye. Motion respects macOS **Reduce Motion**. The collapsed/expanded choice is remembered; click a row's `▸` to expand its sub-agents.
- **Quit** from the menu-bar item (or `⌘Q`).

## Event-driven mode

On first launch the app offers to **enable event-driven mode** — it installs the Claude Code hooks into `~/.claude/settings.json` (safe: backup + atomic write) and starts the `agentislandd` daemon for you. This gives instant updates plus the precise "needs your action" state and the done flourish. Decline and it polls every few seconds instead; toggle it anytime from the menu-bar item ▸ **Event-driven mode**. You can also set it up manually:

```sh
# 1. register hooks in ~/.claude/settings.json (safe: backup + atomic write; undo with `uninstall`)
swift run AgentIslandHookCLI install

# 2. run the daemon (or copy launchd/com.mathur-prerit.agentisland.plist into
#    ~/Library/LaunchAgents/ — with the binary path filled in — to auto-start it at login)
swift run agentislandd
```

With the daemon running, the app reads its `~/.agent-island/state.json` instead of polling; if the daemon isn't running, the app automatically falls back to polling. Remove the hooks anytime with `swift run AgentIslandHookCLI uninstall`.

## How it works

No Claude Code hook cleanly separates "waiting for input" from "finished" (`Stop` fires for both). agent-island derives state from the session transcript: it reads the **last conversational record** (skipping metadata records like `ai-title` / `permission-mode`), where a trailing assistant `tool_use` block means *working* and a stopped turn means *waiting for you*; an open permission prompt is an explicit block; `SessionEnd` / quit / staleness means *finished*. Sub-agents are read from `<session-uuid>/subagents/**/agent-*.jsonl`. All of this was verified against real `~/.claude` transcripts — see [`spike/FINDINGS.md`](spike/FINDINGS.md).

## Build & test

```sh
swift build
swift run AgentIslandSelfTest   # framework-free self-test runner (82 checks)
swift run AgentIslandDemo       # the engine on your real ~/.claude transcripts
```

## Project layout

- `Sources/AgentIslandCore` — transcript adapter, state engine, sub-agent rollup, task-line sanitizer
- `Sources/PersonaKit` — persona model + runtime + built-in personas + the hardened pack-loader validation
- `Sources/AgentIslandDaemon` — Unix-socket IPC (framing, peer-cred auth), event router, state store
- `Sources/HookInstall` — safe `settings.json` merge for the hook installer
- `Sources/AgentIslandApp` — the menu-bar + floating-island AppKit app
- `Sources/AgentIslandHookCLI` (`agentisland-hook`) — install/uninstall hooks + relay events
- `Sources/agentislandd` — the background daemon
- `Sources/AgentIslandDemo`, `Sources/AgentIslandSelfTest` — console demo + framework-free tests
- `Scripts/build-app.sh`, `Formula/agent-island.rb`, `launchd/` — distribution
- `spike/FINDINGS.md` — seam-verification findings (the integration-risk gate)

## License

MIT © 2026 Prerit Mathur
