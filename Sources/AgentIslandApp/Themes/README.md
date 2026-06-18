# agent-island themes

A **theme** decides what the island's per-session status cue looks (and sounds) like: the indicator
for each state, the row's background tint, whether the persona emoji shows, and any lifecycle sound
cues. Themes are swapped at runtime from the menu-bar **Animation theme** submenu and persisted in
`UserDefaults["islandTheme"]` (by theme **id**, not display name — ids are forever).

This folder holds the theme **code** (one Swift file per built-in theme) plus each theme's bundled
**resources** (e.g. `RoadRunner/*.wav`). The contract below is intentionally frozen ahead of the
features that consume it, so a future data-theme engine and theme download drop in without churn.

## Two tiers of theme

A sandboxed SwiftPM app can't load downloaded Swift code, so themes come in two kinds:

1. **Code themes** — procedural / algorithmic, compiled into the app, one Swift file each. They can
   do anything Core Graphics can (the Road Runner theme animates a scrolling token journey that no
   static manifest could express). Registered in `Themes.all` in `ThemeCore.swift`.
   - `JourneyTheme.swift` — **Road Runner** (id `journey`): the token-burn journey + arcade sounds.
   - `MinimalTheme.swift` — **Minimal (CLI)** (id `minimal`): braille spinner / caret / ✓ / ✗.
2. **Data themes** — a declarative `theme.json` manifest + asset files (images, sprite sheets,
   sounds). No Swift. One generic interpreter renders any such folder. These are the ones that can
   be **bundled or downloaded**. The engine is the `AgentIslandThemes` target (AppKit-free
   `ThemeManifest` + strict, path-safe `ThemeManifestLoader`) plus the App-side `ManifestTheme` /
   `ManifestScene` interpreter; themes are discovered by `ManifestThemeDiscovery`. The bundled
   **`critter`** theme (id `critter`, in `Themes/critter/`) is the worked example.

The same `Themes/<id>/` folder shape is used whether a data theme is **bundled** (read via
`Bundle.module`) or **downloaded** to `~/.agent-island/themes/<id>/` (read at runtime). Code themes
stay first in the registry, so the default theme is always `journey`.

## Code-theme contract (`IslandTheme` + `ThemeScene`, in `ThemeCore.swift`)

```
id: String                              // stable, persisted; never rename
displayName: String                     // menu label; cosmetic, safe to change
showsPersonaGlyph: Bool                 // show the persona emoji beside the indicator?
makeScene() -> ThemeScene               // fresh per-row indicator scene (owns its NSView(s))
tint(for row) -> NSColor                // row background base tint (.clear = none)
sound(for transition) -> URL?           // lifecycle clip, or nil (default) for silence
```

The theme owns the indicator entirely through a **`ThemeScene`** — there's no shared `Cue` enum or
fixed set of host subviews. A new code theme touches only its own file. One scene per row, rebuilt
when the theme changes:

```
view: NSView                            // the active sub-view to place (or a container)
prefersOwnRow: Bool                     // read AFTER apply(): wide banner row vs. inline beside title
apply(_ snapshot: RowSnapshot)          // set static state (which sub-view, tokens, colours)
tick(_ frame: Int)                      // advance the animation frame
animates(_ snapshot) -> Bool            // does this state run the shared ticker?
```

`RowSnapshot` (id · tokens · `ThemeStateKey`) is AppKit-free and lives in `AgentIslandCore`. The
host derives the state key from the row's primitive fields via `RowStateMapper.stateKey(...)` (the
single source of state precedence: idle → working → waiting → failed → finished), so every theme
speaks one canonical vocabulary instead of re-deriving precedence. The row view places `scene.view`
in a wide banner row (when `prefersOwnRow`, e.g. the scrolling road) or inline beside the title
(CLI labels/icons), re-parenting between two permanently-arranged slots.

`SoundTransition` (in `AgentIslandCore/Transitions.swift`) is edge-triggered:
`startedWorking` · `enteredWaiting(reason)` · `enteredFinished(verdict)`. The host diffs each
session between refreshes, plays the selected theme's clip via `SoundManager` (quiet by default,
no-overlap, throttled). Road Runner's mapping: game-start (begins working) / checkpoint (stops &
waits for you) / goal (success) / game-over (failure).

## Data-theme manifest schema (`theme.json`, frozen — v1)

```jsonc
{
  "schemaVersion": 1,                 // int, required
  "id": "mario",                      // required; MUST equal the folder name; the persisted id
  "displayName": "Super Mario",       // required; menu label
  "minAppVersion": "0.3.0",           // optional; refuse to load on older app
  "showsPersonaGlyph": false,         // optional, default false
  "palette": { "accent": "#E52521" }, // optional named colours (#RRGGBB / #RRGGBBAA)
  "tint": {                           // optional per-state background tint
    "working": "accent",              //   palette name | hex | "system:teal" | "clear"
    "waitingPermission": "system:orange"
  },
  "states": {                         // required; keys are canonical state ids (see below)
    "working": {
      "visual": {                     // exactly one "kind"
        "kind": "sprite",             //   "image" | "sprite" | "text" | "symbol"
        "sheet": "sprites/run.png",   //   relative path (no "..", no absolute, allowlisted ext)
        "frameWidth": 32, "frameHeight": 32, "frameCount": 6, "fps": 12
      },
      "sound": { "file": "sounds/jump.wav", "trigger": "onEnter", "volume": 0.6 }
    },
    "waitingPermission": { "visual": { "kind": "image", "file": "images/block.png" } },
    "waitingTurnEnd":   { "visual": { "kind": "image", "file": "images/pause.png" } },
    "finished": { "visual": { "kind": "symbol", "name": "flag.checkered", "tint": "system:green" } },
    "failed":   { "visual": { "kind": "symbol", "name": "xmark.octagon.fill", "tint": "system:red" } },
    "idle":     { "visual": { "kind": "text", "string": "·", "color": "system:tertiaryLabel" } }
  },
  "layout": { "ownRow": false, "size": { "width": 32, "height": 26 } }  // optional
}
```

- **Canonical state ids** (a theme may not invent new ones): `idle`, `working`, `waitingPermission`,
  `waitingTurnEnd`, `failed`, `finished`. They mirror the host's row state machine.
- **`visual.kind`**: `image` (static), `sprite` (sheet sliced `frameWidth × frameHeight`, animated
  at `fps`, `frameCount` frames), `text` (monospace string + colour), `symbol` (SF Symbol + tint).
  Sprite `frameWidth/frameHeight` are **pixel** measurements of a **1× sheet** (a single horizontal
  strip of `frameCount` cells); export at 1× so the slicer's cells line up. Sprite dimensions are
  bounded (frame ≤ 4096², `frameCount` ≤ 1024, `fps` ≤ 240) — larger is rejected.
- **`system:<name>`** must name a supported colour (`ThemeColorNames.system`): the system palette
  (`red orange yellow green mint teal cyan blue indigo purple pink brown gray`) or a semantic label
  (`label secondaryLabel tertiaryLabel quaternaryLabel`). An unknown name is rejected at load.
- **`sound.trigger`**: `onEnter` (fire once when the state begins) | `loop`. `volume` 0–1.
- **Colour refs**: `#RRGGBB[AA]` · a `palette` name · `system:<name>` (an `NSColor.system*`) · `clear`.

## Asset & path rules

- Images: `png jpg jpeg gif heic pdf` (no `svg`). Audio: `wav aiff caf m4a` — prefer short **WAV
  PCM** for instant, decode-free `NSSound` (FLAC is unsupported; mp3 only if forced).
- All asset paths are **relative**, inside the theme folder; `..` and absolute paths are rejected
  (Zip-Slip). Validation reuses `PersonaKit/PackValidation.swift` (`PackValidator`).

## Folder layout

```
Themes/<id>/
  theme.json            # data themes only
  images/  sprites/  sounds/  colors.json
```
(Built-in code themes keep their resources here too — e.g. `RoadRunner/01_game_start.wav`.)

## Build · test · install

- **Build/run**: `swift build` · `swift run AgentIslandApp`. Bundled resources resolve via
  `Bundle.module` under both `swift run` and a packaged `.app`.
- **Test**: `swift run AgentIslandSelfTest` (framework-free). Manifest decode/validation + the
  transition/throttle logic are covered there; NSView rendering is verified by eye.
- **Render canary**: `swift run AgentIslandApp -renderTheme <id> /tmp/out.png` renders all six states
  of ANY theme (code or data) to a labelled PNG strip — the headless way to eyeball a theme. (The
  older `-renderRoadSample /tmp/road.png` stays as the Road-Runner-specific banner-grid canary.)
- **Install a local data theme**: drop the folder into `~/.agent-island/themes/<id>/` (the folder
  name must equal the manifest `id`) and pick it from the menu. Asset paths are validated twice — a
  string check at load (rejects `..`/absolute) and a disk-side symlink-containment check at open, so
  a downloaded theme can't read outside its own folder.

## Themes

- [x] **`critter`** — bundled data theme; the worked example proving the engine. Original pixel art
  (a blobby slime): a 4-frame bounce sprite while working, a `!`-antenna image on a permission wait,
  `zZ` text on a turn-end wait, SF-Symbol ✓/✗ for finished/failed, a `·` when idle, and a short
  chirp on start. All art is original (generated), not derived from any existing character.
- [ ] **`mario` / `the-witcher`** — named themes from the original vision use copyrighted game art
  and so can't ship bundled. They belong as **downloadable community themes** once
  `theme-download.md` ships (the manifest engine they needed is now in place).
