# Branding (app + state icons) + release-pinned install — design

**Date:** 2026-06-18 · **Branch:** `feat/backlog-final-four` · **Status:** approved (by-eye), ready to implement

## Problem

Three threads reported by the user, confirmed by investigation:

1. **CLI installed with a warning.** `install.sh` builds from source off `main` and copies the CLIs to
   `/usr/local/bin` by default — not writable without `sudo` on Apple Silicon, so it warns and the CLI
   never lands on PATH (confirmed: neither `/usr/local/bin` nor `/opt/homebrew/bin` has `agentisland`).
   There are **zero git tags / GitHub Releases**, yet `UpdateCheck` polls `releases/latest` — so the
   updater can never find anything. The ask: make installs **release-specific** (pinned + reproducible).
2. **App installed but "didn't work" — no menu-bar icon appeared.** The app is menu-bar-only
   (`LSUIElement`) and today the status item is a faint **text glyph** (`○` / `◐` / `● N`) that's easy to
   miss. Three startup crash reports from 6/17 land in `IslandPanel.update(rows:)` (NSException → SIGABRT)
   — must confirm whether current code still risks it. `AgentIsland.app` is not in `/Applications`, so the
   install's app-copy step did not complete on this machine.
3. **No branding.** The status item is a typographic circle; there is **no app icon at all** (no `.icns`,
   no `CFBundleIconFile` in the generated Info.plist) — Finder/installer show the blank generic icon.

## Locked design

Brand concept: **a lighthouse on an island** — a watcher that signals state with its light, exactly what
agent-island does (watches your sessions, signals working/waiting/done). An **agent** (flat robot) lives
on the island; its eye + antenna glow the lighthouse's lamp colour ("the agent runs on the island's
signal").

| Surface | Mark | State encoding |
|---|---|---|
| **App icon** | Teal-day lighthouse island **+ robot agent**, 1024px squircle, flat design | static brand |
| **Menu bar** | **Robot head** (candidate B — validated legible at true 18px on light & dark) | tint per state: gray idle · teal working · red waiting · green finished; pulse on waiting; waiting count appended |

Rationale for menu-bar = robot head (not the full scene): at 18px the full lighthouse+robot blurs; the
robot head stays crisp, unmistakably "an agent," and tints cleanly. Eyes are knocked out so they read on
any menu-bar background. Mockups: `/tmp/ai-icons/` (`app_lighthouse.png`, `menubar_agent.png`).

## Implementation tasks (ordered)

1. **Fix "no menu-bar icon" (priority 0).** Root-cause the `IslandPanel.update` startup crash; confirm
   whether current code still hits it and fix if so. The new bold robot glyph also removes the
   "too faint to spot `○`" failure mode. Verify the built `.app` launches and shows the item.
2. **Menu-bar state icons.** Replace the text glyph in `main.swift` with a code-drawn robot-head
   `NSImage` (vector, retina-correct), tinted per state. Preserve the existing pulse animation, the
   waiting count, and the tooltip. Keep light/dark adaptivity.
3. **App icon.** Generate `.icns` from the teal-day render (full iconset via `iconutil`), wire it into
   `build-app.sh` (Resources + `CFBundleIconFile`/`CFBundleIconName`). The icon source is checked in so
   the build is reproducible.
4. **Release + CLI.** Cut a real GitHub Release (tag + prebuilt `AgentIsland.app` + CLI zip); point
   `install.sh` at the release (download prebuilt, **fall back to build-from-source**), and make the
   updater/`agentisland update` consume releases. Fix the binary-install warning (prefer
   `/opt/homebrew/bin` on Apple Silicon, clearer `sudo` guidance).

## Constraints

- **Never push `main` / publish a release unprompted** — prepare everything; pause for explicit confirm
  before any outward `gh release create` / tag push.
- **Iterate by eye** — render/launch and confirm visuals with the user at each visual step.
- Icons are drawn in code / generated from a checked-in source — no external image deps, no API keys.
- Menu-bar icon keeps the app's existing colour-coded (non-template) status model.
