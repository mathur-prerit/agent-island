# Design: vivid state animations, waiting-state clarity, token usage, and bug fixes

**Date:** 2026-06-17
**Status:** approved design, pre-implementation
**Scope:** `AgentIslandApp` (island UI + menu bar), `AgentIslandCore` (token helper), `AgentIslandSelfTest`

## Summary

Make the floating island and menu-bar item visibly communicate per-session state through
colorful, lively (but Reduce-Motion-respecting) animations; distinguish the two *waiting*
states so "the agent needs your action" reads differently from "the agent finished its turn";
show per-session token usage; and fix the confirmed bugs flagged in `HANDOFF.md`.

## Goals

1. **Vivid, quirky per-state animation** on the island, plus a colorized menu-bar glyph.
2. **Distinguish the two waiting states** — `stoppedTurn` (awaiting your next prompt) vs
   `permission` (blocked, needs your action) — visually and in priority.
3. **Show per-session token usage** (fresh = input + output), compactly.
4. **Fix the known bugs**: the `preritmathur` label bug; verify the refresh-timer fix;
   audit state derivation.
5. **Make the daemon the default** via a reversible first-launch auto-setup, so the full
   experience works out of the box (polling remains the automatic fallback).
6. Keep the app's "quiet, peripheral, out-of-your-way" character — color and life, not noise.

## Non-goals (explicitly out of scope)

- Settings UI (README "ongoing") — separate task.
- Daemon token tracking / daemon richer labels — daemon path keeps `steps:0` and `tokens:0`;
  steps + tokens shown in polling mode only for now (see Token usage).
- Polling-mode permission detection — by decision, polling stays honest (a tool-blocked
  session shows as `working`); accurate "needs your action" requires the daemon (now the default).
- launchd auto-start at login — the app spawns the daemon for its own lifetime; persistent
  login auto-start stays a documented manual step (`launchd/…plist`).

## Decisions (locked with the user)

| Decision | Choice |
| --- | --- |
| Animation vibe | **Vivid & quirky** (aurora working shimmer, one-shot done pop, etc.) |
| Surfaces | **Island rows + menu-bar glyph** |
| Action-needed detection | **Daemon-accurate only** — no polling heuristic, no false positives |
| Token metric | **Fresh only** = `input_tokens + output_tokens`, compact (e.g. `146k tok`) |
| Rendering approach | **Reconcile rows by session id** (view reuse), not full teardown per refresh |
| Label fix | Use the **last** `cwd` in the transcript (not first; not decode-dir) |
| Daemon default | **Full auto-setup** — first-launch consent → install hooks + start daemon; polling is fallback |

## Architecture: reconcile-by-id rendering

`IslandPanel.update(rows:)` today tears down and rebuilds every subview on each ~3s refresh.
That makes looping animations snap back to frame zero every tick and gives one-shot
animations no stable view to anchor to. We replace it with reconciliation:

- `IslandPanel` keeps `rowViews: [String: SessionRowView]` keyed by session id.
- `update(rows:)` diffs incoming rows by `id`: reuse + update existing views, create new ones,
  remove departed ones, and reorder the stack to match.
- `Row` gains a stable `id: String` (the session `fullID`).
- A reused `SessionRowView` remembers its previous `AgentStatus`, so it can detect a
  **transition** (e.g. `working/waiting → finished`) and fire one-shot animations exactly once —
  no app-level "celebrate" flag needed.

Looping animations (`repeatCount = .infinity`) live on the persistent view's layers and run
uninterrupted across refreshes.

## State → visual mapping

| State | Color | Animation |
| --- | --- | --- |
| **working** | aurora (teal→indigo→magenta) | rotating conic gradient ring (replaces gray spinner) + gradient shimmer sweeping the state text + faint aurora underline; live `N steps · X tok` |
| **waiting · stoppedTurn** ("awaitin' yer orders") | amber↔red | calm color-breathing pulse on glyph + text (~1s autoreverse), gentle ±4% scale |
| **waiting · permission** ("needs your go-ahead") | insistent orange-red + ❗accent | faster pulse (~0.6s), stronger; row **sorted to top**; this is the "needs your action" state |
| **finished · success** | green | one-shot: glyph scale-pop (1.0→1.25→1.0 spring) + brief green radial glow → settle dimmed |
| **finished · failed** | red | one-shot: small red shake + red glow → settle dimmed |
| **idle** (no sessions) | muted spectrum | the `·` placeholder slowly hue-drifts (~6s loop) |

Sub-agent rows get the same color coding, lighter weight (no rings/pops).

**Implementation note:** the working "shimmer/underline" and idle "color drift" are realized on
fixed-size elements — a rotating conic aurora ring + lively text color for working, a
color-cycling dot for idle — to avoid fragile row-width layer-frame tracking in AppKit
auto-layout. Still vivid; the full-width sweep can be revisited later.

**Ordering:** sessions sort by `DisplayPriority.rank` (needs-you first), then recency:
`permission (0) < stoppedTurn (1) < working (2) < finished (3)`.

**Note (finished only fires in daemon mode):** polling never yields `.finished`
(`deriveStatus` returns only `working`/`waiting`; sessions simply age out of the 30-min
window). So the done flourish is exercised under the daemon path. It is still built and
correct; polling rows just never reach it. Documented, not a bug.

## Waiting-state detection

- `StateEngine.deriveStatus` already returns `.waitingForInput(.stoppedTurn)` for a stopped
  assistant turn and `.waitingForInput(.permission)` when `openPermission` is true.
- The **daemon** already routes `PermissionRequest → .waitingForInput(.permission)`
  (`EventRouter`), and `AgentIslandHookCLI` already relays `PermissionRequest`. So the
  `permission` state is *already* produced end-to-end in event-driven mode.
- **App work:** stop collapsing both waits to one look. `main.swift` currently maps every
  `.waitingForInput` to `.systemRed` with one pulse. Split by `WaitReason`: distinct color +
  animation per the table, and sort `permission` rows to the top of the island.
- **Polling stays honest** (decision): `polledSessions` keeps `openPermission: false`; a
  session blocked mid-tool shows as `working`. Accurate "needs your action" needs the daemon.

## Daemon as default (first-launch auto-setup)

To deliver the full experience (the `finished` flourish and the accurate `permission`
"needs your action" state both require the daemon), the app makes event-driven mode the
default via a guided, reversible first-launch setup:

- **First launch:** a one-time consent dialog ("Enable event-driven mode? This adds
  agent-island hooks to `~/.claude/settings.json` (reversible) and runs a small background
  daemon."). The choice is persisted in `UserDefaults` (`eventDrivenSetupDecision`).
- **On consent:** the app calls `SettingsFile.install(settingsPath:command:events:)` directly
  (reusing the exact `events` list + relay command from `AgentIslandHookCLI`) — same safe
  backup + atomic write — then ensures `agentislandd` is running.
- **Ensure-daemon:** if `~/.agent-island/state.json` is stale/absent and the socket isn't live,
  spawn `agentislandd` via `Process`. The app keeps reading `state.json`; if the daemon dies it
  falls back to polling automatically (existing `daemonSessions() ?? polledSessions()` path).
- **Binary path resolution (key integration point):** the relay command and the daemon spawn
  need absolute paths to the sibling `agentisland-hook` and `agentislandd` executables. Resolve
  them relative to the app's own executable dir (`Bundle.main` / `CommandLine.arguments[0]`):
  works under `swift run` (`.build/<config>/`) and in the bundled `.app`. `Scripts/build-app.sh`
  must copy both binaries into the bundle next to the app executable.
- **Reversibility / control:** menu-bar items to **Enable / Disable event-driven mode**
  (Disable calls `SettingsFile.uninstall` and stops the daemon). Declining the prompt keeps
  polling and does not ask again (until re-enabled from the menu).

## Token usage

- New `AgentIslandCore` helper `TokenUsage.freshTokens(lines:) -> Int` summing
  `usage.input_tokens + usage.output_tokens` across assistant records (handles both
  top-level `usage` and `message.usage` shapes). Unit-tested.
- `Session` gains `tokens: Int`; `polledSessions` populates it. Daemon path leaves `0`.
- Compact formatting (`< 1000 → "N"`, `< 1e6 → "Nk"`, else `"N.NM"`), suffix ` tok`.
- Displayed on **active** rows (working + waiting) when `> 0`, appended to the state line:
  - working: `the work proceeds · 11 steps · 146k tok`
  - waiting: `awaitin' yer orders · 146k tok`
  - finished/idle rows omit it (keep tombstones clean).

## "Steps" clarification

`steps` = count of assistant `tool_use` blocks = number of tool calls the session has made.
Kept as-is (label stays "steps"); documented here and shown alongside tokens.

## Bug fixes

1. **Label bug (`preritmathur`) — confirmed, fix here.** `projectName(fromLines:)` returns the
   `lastPathComponent` of the **first** `cwd` (the launch dir; home when Claude is started from
   `~`). Fix: scan all lines and use the **last** `cwd` seen. Ground-truthed against real
   transcripts: last `cwd` yields `agent-island` where first yields `preritmathur`. The
   decode-parent-dir alternative is rejected — folder names containing `-` (e.g. `agent-island`)
   decode ambiguously to `island`. Add a self-test.
2. **Frozen-refresh timer.** Already fixed in `e516ffc` (unscheduled `Timer`, registered once in
   `.common`). Correct by inspection; verify live by running the app and watching a row tick.
3. **State-derivation audit.** `deriveStatus` (trailing `tool_use` ⇒ working; stopped turn ⇒
   waiting) and `Rollup` (any block ⇒ waiting; else any working ⇒ working; else finished) are
   correct. The "stuck on waiting" symptom is explained by the frozen timer + label bug, not a
   derivation error. No change.

## Cross-cutting

- **Reduce Motion:** when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true,
  drop all loops/pops to static colors (still colorful, just still).
- **Performance:** Core Animation loops run render-server-side; negligible cost. Reconciliation
  avoids per-refresh view churn.

## Files

- `Sources/AgentIslandApp/IslandPanel.swift` — reconcile-by-id; `SessionRowView` with persistent
  animation layers + transition detection; `Row` gains `id`, `waitReason`, `verdict`, `tokens`.
- `Sources/AgentIslandApp/IslandAnimations.swift` *(new)* — the gradient-ring / shimmer /
  color-pulse / celebrate-pop / idle-drift builders, plus the Reduce-Motion gate. Keeps the
  panel file focused.
- `Sources/AgentIslandApp/main.swift` — split `WaitReason` into distinct color/animation; sort
  `permission` rows first; colorize + pulse the menu-bar glyph; compute and pass `tokens`; use
  last-`cwd` for the label; pass `id`/`verdict` into `Row`.
- `Sources/AgentIslandCore/TokenUsage.swift` *(new)* — `freshTokens(lines:)`.
- `Sources/AgentIslandApp/EventDrivenSetup.swift` *(new)* — first-launch consent +
  `UserDefaults` decision, `SettingsFile.install/uninstall` wiring, sibling-binary path
  resolution, ensure-daemon (`Process` spawn + liveness check), and Enable/Disable menu actions.
- `Package.swift` — add `HookInstall` to `AgentIslandApp` dependencies (for `SettingsFile`).
- `Scripts/build-app.sh` — copy `agentislandd` and `agentisland-hook` into the bundle next to
  the app executable so path resolution works in the installed `.app`.
- `Sources/AgentIslandSelfTest/main.swift` — checks for: last-`cwd` label extraction;
  `freshTokens` summation; compact token formatting; `permission` sorts above `stoppedTurn`.

## Data-model changes

```swift
// IslandPanel.Row
let id: String                // session fullID — reconciliation key
let waitReason: WaitReason?   // distinguishes the two waiting looks
let verdict: Verdict?         // success/failed → which done flourish

// AppController.Session
let tokens: Int               // fresh tokens; the app composes the "N steps · T tok"
                              // display string, so Row carries no separate token field
```

## Testing

- Framework-free self-test additions (animations themselves verified live by the user):
  last-`cwd` extraction, `freshTokens` sum, compact formatting, permission-first ordering.
- Manual: run `swift run AgentIslandApp`; confirm a working row shows the aurora ring +
  `steps · tok` and ticks every ~3s; a stopped row breathes amber↔red; (daemon) a permission
  row is insistent and on top; the menu-bar glyph is colored and pulses when waiting.

## Risks / open items

- One-shot "done" flourish is only reachable in daemon mode (polling never marks finished) —
  accepted; daemon is now the default, so it is reachable out of the box.
- Token usage is polling-only until hooks carry usage — accepted, documented.
- Menu-bar colored text is non-template; fine on macOS 13+ light/dark menu bars, verify on run.
- **Sibling-binary path resolution** is the riskiest integration point: the relay command and
  daemon spawn must point at real absolute paths in both `swift run` and the bundled `.app`.
  Mitigation: resolve from the app executable dir + `build-app.sh` bundling; if resolution
  fails, skip auto-setup gracefully and stay on polling (never write a broken hook command).
- First-launch dialog must not block/steal focus disruptively (accessory app); shown once,
  decision persisted; fully reversible from the menu.
