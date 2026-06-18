# agent-island

A quirky, quiet, always-on-top macOS status **island** that watches your Claude Code sessions — including their nested sub-agents — and shows, per session, whether each is **working**, **waiting for you**, or **done**, plus a one-line "what it's doing." Each session wears a randomized **persona** (Pirate, Astronaut, Herald, …); working sessions spin with a live step count; it's muted by default and stays out of your way.

> **Status:** working v0 — menu-bar item + a collapsible, priority-ordered floating island (collapsed by default; expands to a scrollable list that animates only the running session), personas, live step + token counts, and an event-driven daemon (the default, via a reversible first-launch setup) are all in. Verified core logic with 458 self-test checks. A settings UI is still to come.

## Requirements

- **macOS 13+**
- **Swift 6+** — via **Xcode** *or* the **Command Line Tools** (`xcode-select --install`). AppKit builds under either; no full Xcode required.
- No Apple Developer account needed (see below).

## Installation

Gatekeeper's "unidentified developer" warning affects *downloaded, unsigned* apps. The installer handles it for you — it strips the quarantine flag and ad-hoc-signs the downloaded app so it opens normally — and the from-source fallback avoids it entirely (a locally built app is never quarantined). **No Apple ID, code-signing, or notarization is involved.** Pick whichever fits you:

### Option 0 — One-line installer (prebuilt release, falls back to source)

```sh
curl -fsSL https://raw.githubusercontent.com/mathur-prerit/agent-island/main/install.sh | sh
```

By default this **downloads the latest published release's prebuilt artifacts** — no Xcode or Swift toolchain needed: it fetches the `AgentIsland.app` + CLI zips for your CPU arch, verifies their checksums, de-quarantines + ad-hoc-signs the app, copies it to `/Applications`, installs the `agentisland` and `agentisland-hook` binaries to **`/opt/homebrew/bin`** on Apple Silicon (or `/usr/local/bin` on Intel; set `AGENT_ISLAND_BIN_DIR` to override), and wires the Claude Code lifecycle hooks (backup + atomic write). If there's no release asset for your arch (or you're offline), it **automatically falls back to building from source** (`git` + `swift` required only on that path). Run interactively, it also lets you **pick a look (theme)** and offers to enable start-on-boot. It's **idempotent** — re-run it to upgrade. Pin a specific release with `AGENT_ISLAND_RELEASE=v0.3.0`, or force a source build with `AGENT_ISLAND_RELEASE=source`. Reverse everything with `agentisland uninstall`.

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

### Option C — Homebrew (build-from-source) — *planned*

A `Formula/agent-island.rb` is checked in, but the Homebrew tap isn't published yet, so this is **aspirational** for now — use Option 0 or B. Once the tap lands:

```sh
brew tap mathur-prerit/agent-island https://github.com/mathur-prerit/agent-island
brew install --HEAD agent-island
agent-island
```

### After launching

- A small glyph appears in your **menu bar** (top-right), colored by aggregate state: gray `○` idle · teal `◐` working · red, gently pulsing `● N` when N sessions wait on you. Click it for the session list, a **Show floating island** toggle, an **Event-driven mode** toggle, and **Quit**.
- The **floating island** sits at the top-right, **collapsed by default** to a one-line summary (e.g. `agent-island · ❗1 waiting · ◐2 running ▸`). Click the header to expand a **scrollable, height-capped** list of active sessions (touched in the last 30 min), sorted by priority: **waiting for you → failed → running → finished**. Each row shows a persona glyph, project name, and state; **running** rows carry a live `N steps · T tok` line (steps = tool calls; tokens = peak request context + generated output) and are the **only** rows that animate (a rotating aurora ring) — waiting/failed/finished rows are dimmed and still, so only active work draws the eye. Motion respects macOS **Reduce Motion**. The collapsed/expanded choice is remembered; click a row's `▸` to expand its sub-agents.
- **Quit** from the menu-bar item (or `⌘Q`).

### Updating

Re-run the one-line installer any time — it's **idempotent** and upgrades in place, keeping your settings, wired hooks, and installed themes:

```sh
curl -fsSL https://raw.githubusercontent.com/mathur-prerit/agent-island/main/install.sh | sh
```

Or from the installed CLI:

```sh
agentisland update        # checks GitHub Releases; if newer, installs that release in place
```

Pin a specific version by prefixing the installer with `AGENT_ISLAND_RELEASE=v0.3.0` (or `=source` to force a from-source build).

### Uninstalling

```sh
agentisland uninstall              # lists what it will do, asks to confirm, then reverses everything
agentisland uninstall --dry-run    # print exactly what would be removed — changes nothing
agentisland uninstall --yes        # skip the confirmation prompt
```

It reverses the Claude Code hooks (**preserving** any non-agent-island hooks and your other settings), unregisters the login item, and removes `~/.agent-island` and `/Applications/AgentIsland.app`. It **never** touches your `~/.claude` transcripts or other data. From a source checkout with no CLI on PATH, use `swift run agentisland uninstall`.

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

## Management CLI — `agentisland`

The one-line installer puts an `agentisland` binary on your PATH (or build + run it directly with `swift run agentisland …`). It manages themes, preferences, updates, start-on-boot, and uninstall. Run `agentisland --help` for the full list. Every subcommand:

```sh
agentisland theme list                # installed + bundled + downloadable themes (* = active)
agentisland theme add <id>            # download + install a theme by its catalog id
agentisland theme add <https-url>     # …or install directly from an https zip url
agentisland theme set <id>            # make <id> the active theme

agentisland config                    # list the settable preferences + current values
agentisland config get <key>          # print one preference's value
agentisland config set <key> <value>  # set one preference (validated against an allowlist)

agentisland update                    # check for a newer release; offer to update in place
agentisland start-on-boot [on|off|status]   # launch agent-island at login (login item)
agentisland uninstall [--yes] [--dry-run]    # remove hooks, login item, ~/.agent-island, and the app
agentisland version                   # print the CLI version
```

Notes that keep it honest:

- **`config`** reads and writes the **app's own preferences domain** (`com.mathur-prerit.agentisland`), so a `config set` is exactly what the running app reads — restart agent-island to pick up a change. Settable keys: `islandTheme`, `soundEnabled`, `soundCueSet` (`theme`|`default`), `islandKeepAwake`, and `eventDrivenSetupDecision` (`enabled`|`declined`|`error`). Unknown keys and off-allowlist values are refused.
- **`theme add`** downloads over **https only** and runs the *same* validate-then-install pipeline the app's menu uses — integrity check → zip-bomb / zip-slip / symlink inspection → sandboxed extraction → strict manifest validation → atomic install. A bad archive is rejected with no partial install left behind. Catalog ids carry a published SHA-256/size; a raw `https` url is installed as-is (its bytes are its own integrity claim).
- **`update`** compares your installed version against the latest GitHub release; if newer, it offers to re-run the installer pinned to that release (downloading the prebuilt artifact, or building from source if none is available). No silent self-mutation.
- **`start-on-boot`** uses macOS 13+ `SMAppService` to register the **app** as a login item (the daemon follows the app — there's no separate LaunchAgent). A bare `start-on-boot` just reports status. Because the CLI binary isn't itself the app bundle, on/off also print the manual fallback (System Settings ▸ General ▸ Login Items) in case the automatic toggle doesn't take. *(The app's menu-bar ▸ **Launch at login** toggle does this directly from inside the bundle — the most reliable path.)*
- **`uninstall`** reverses the hooks (preserving any non-agent-island hooks and your other settings), unregisters the login item, and removes `~/.agent-island` and the `.app`. It **confirms first** (skip with `--yes`); `--dry-run` prints exactly what it would do and changes nothing.

> Prebuilt binaries ship via GitHub Releases (built + attached by CI on each `v*` tag; ad-hoc-signed, de-quarantined on install). They are **not** Developer-ID signed or notarized yet — a notarized release and a real Homebrew tap are future work.

## Creating a theme

A **theme** decides what each session's status indicator looks (and sounds) like per state — idle / working / waiting / finished / failed — plus the row's background tint and any lifecycle sounds. There are two kinds; you author the **data** kind (no Swift, no compiling):

- **Code themes** are compiled into the app (e.g. *Road Runner*'s scrolling token journey). Adding one means a Swift file — see the spec below.
- **Data themes** are a declarative `theme.json` + asset files (images, sprite sheets, sounds). One generic interpreter renders any such folder, so they can be **bundled, installed locally, or downloaded**. This is what you make.

### 1. Lay out the folder

The folder name **must** equal the manifest `id` (the id is persisted forever — never rename it):

```
mytheme/
  theme.json
  images/      sprites/      sounds/
```

### 2. Write `theme.json` (schema v1)

A minimal example (see `Sources/AgentIslandApp/Themes/critter/theme.json` for the full worked example):

```jsonc
{
  "schemaVersion": 1,
  "id": "mytheme",                    // MUST equal the folder name
  "displayName": "My Theme",
  "minAppVersion": "0.3.0",           // optional: refuse to load on an older app
  "showsPersonaGlyph": false,
  "palette": { "accent": "#5AC8FA" },
  "tint": { "working": "accent", "waitingPermission": "system:orange" },
  "states": {                          // the six canonical state ids — you can't invent new ones
    "working":           { "visual": { "kind": "sprite", "sheet": "sprites/run.png",
                                        "frameWidth": 24, "frameHeight": 24, "frameCount": 4, "fps": 8 },
                           "sound":  { "file": "sounds/blip.wav", "trigger": "onEnter", "volume": 0.5 } },
    "waitingPermission": { "visual": { "kind": "image",  "file": "images/alert.png" } },
    "waitingTurnEnd":    { "visual": { "kind": "text",   "string": "zZ", "color": "system:secondaryLabel" } },
    "finished":          { "visual": { "kind": "symbol", "name": "checkmark.circle.fill", "tint": "system:green" } },
    "failed":            { "visual": { "kind": "symbol", "name": "xmark.octagon.fill", "tint": "system:red" } },
    "idle":              { "visual": { "kind": "text",   "string": "·", "color": "system:tertiaryLabel" } }
  }
}
```

- **`visual.kind`**: `image` (static) · `sprite` (a 1× horizontal strip sliced `frameWidth × frameHeight`, animated at `fps`) · `text` (monospace string + colour) · `symbol` (SF Symbol + tint).
- **Colours**: `#RRGGBB[AA]` · a `palette` name · `system:<name>` (e.g. `system:teal`, `system:secondaryLabel`) · `clear`.
- **Assets** are images (`png jpg jpeg gif heic pdf`) and audio (prefer short **WAV PCM**); paths are relative and inside the folder — `..`/absolute paths are rejected (Zip-Slip-safe).

### 3. Preview + install

```sh
# Render all six states of any theme to a labelled PNG strip (headless eyeball):
swift run AgentIslandApp -renderTheme mytheme /tmp/mytheme.png

# Install locally: drop the folder in, then pick it from the menu-bar ▸ Animation theme submenu:
cp -R mytheme ~/.agent-island/themes/mytheme
```

Or install a packaged theme without copying by hand — zip the folder and use the CLI (same validated, sandboxed install the app's menu uses):

```sh
agentisland theme add https://example.com/mytheme.zip   # https only; integrity + zip-slip checked
agentisland theme set mytheme
```

### 4. Share it

To publish for others, host the zip over https and (optionally) add an entry to the themes catalog so it appears in everyone's **Download more** submenu. The **full, authoritative spec** — every field, the sprite/colour rules, sound triggers, and the code-theme contract — lives in [`Sources/AgentIslandApp/Themes/README.md`](Sources/AgentIslandApp/Themes/README.md).

## How it works

No Claude Code hook cleanly separates "waiting for input" from "finished" (`Stop` fires for both). agent-island derives state from the session transcript: it reads the **last conversational record** (skipping metadata records like `ai-title` / `permission-mode`), where a trailing assistant `tool_use` block means *working* and a stopped turn means *waiting for you*; an open permission prompt is an explicit block; `SessionEnd` / quit / staleness means *finished*. Sub-agents are read from `<session-uuid>/subagents/**/agent-*.jsonl`. All of this was verified against real `~/.claude` transcripts — see [`spike/FINDINGS.md`](spike/FINDINGS.md).

## Development

Plain SwiftPM — no Xcode project, no XCTest. Everything runs under the Command Line Tools (`xcode-select --install`).

```sh
swift build                       # debug build of every product
swift run AgentIslandApp          # the menu-bar app (dev)
swift run AgentIslandSelfTest     # framework-free test runner (458 checks)
swift run AgentIslandDemo         # the state engine on your real ~/.claude transcripts
./Scripts/build-app.sh            # package build/AgentIsland.app (icon + version-stamped plist)
```

Handy while developing:

- **Render canaries** (headless, no GUI needed): `swift run AgentIslandApp -renderTheme <id> /tmp/out.png` renders all six states of any theme to a labelled PNG; `-renderRoadSample /tmp/road.png` renders the Road Runner banner grid.
- **Self-test discipline**: the runner is framework-free so it works without full Xcode. When you change behavior, add checks in `Sources/AgentIslandSelfTest/main.swift` and keep it green; NSView rendering is verified by eye.
- **Sandboxed effects**: the destructive paths (`uninstall`, hook install) honor `$HOME`, so exercise them with `HOME=$(mktemp -d) swift run agentisland uninstall --yes` to keep your real `~/.claude` / `~/.agent-island` untouched.
- **Releases**: pushing a `v*` tag triggers `.github/workflows/release.yml`, which builds + attaches the per-arch prebuilt `.app` and CLI zips that `install.sh` downloads. Keep `CLIConstants.version`, `Scripts/build-app.sh`'s `VERSION`, and the tag in lockstep.

### Project layout

- `Sources/AgentIslandCore` — transcript adapter, state engine, sub-agent rollup, task-line sanitizer
- `Sources/PersonaKit` — persona model + runtime + built-in personas + the hardened pack-loader validation
- `Sources/AgentIslandDaemon` — Unix-socket IPC (framing, peer-cred auth), event router, state store
- `Sources/HookInstall` — safe `settings.json` merge for the hook installer
- `Sources/AgentIslandApp` — the menu-bar + floating-island AppKit app
- `Sources/AgentIslandHookCLI` (`agentisland-hook`) — install/uninstall hooks + relay events
- `Sources/AgentIsland` (`agentisland`) — the user-facing management CLI (theme/config/update/uninstall/start-on-boot)
- `Sources/AgentIslandCLICore` — the CLI's pure, testable logic (arg parsing, config allowlist, uninstall plan)
- `Sources/agentislandd` — the background daemon
- `Sources/AgentIslandDemo`, `Sources/AgentIslandSelfTest` — console demo + framework-free tests
- `install.sh`, `Scripts/build-app.sh`, `Formula/agent-island.rb`, `launchd/` — distribution
- `spike/FINDINGS.md` — seam-verification findings (the integration-risk gate)

## Contributing & feature requests

- **Feature requests & ideas** — open a [GitHub issue](https://github.com/mathur-prerit/agent-island/issues/new). Describe the outcome you want and the use case (that helps more than a proposed implementation); tag it a feature request. 👍 existing issues you care about so priorities are visible.
- **Bug reports** — open an issue with: what you did, what you expected, what happened, your macOS + Swift version (`swift --version`), and any relevant output from Console.app or a crash report (`~/Library/Logs/DiagnosticReports/AgentIslandApp-*.ips`).
- **Themes** — community data themes are welcome; see [Creating a theme](#creating-a-theme).
- **Pull requests** — keep changes focused and follow the existing patterns; make sure `swift run AgentIslandSelfTest` stays green and add checks for new behavior. More in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

MIT © 2026 Prerit Mathur
