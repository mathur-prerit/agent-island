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
   be **bundled or downloaded**. _(Engine not built yet — see backlog `theme-manifest-engine.md`.)_

The same `Themes/<id>/` folder shape is used whether a data theme is **bundled** (read via
`Bundle.module`) or **downloaded** to `~/.agent-island/themes/<id>/` (read at runtime). Code themes
stay first in the registry, so the default theme is always `journey`.

## Code-theme contract (`IslandTheme`, in `ThemeCore.swift`)

```
id: String                              // stable, persisted; never rename
displayName: String                     // menu label; cosmetic, safe to change
showsPersonaGlyph: Bool                 // show the persona emoji beside the cue?
animates(_ row) -> Bool                 // does the cue animate (run the shared ticker)?
cue(for row, frame) -> Cue              // .text | .icon | .road — the indicator this frame
tint(for row) -> NSColor                // row background base tint (.clear = none)
sound(for transition) -> URL?           // lifecycle clip, or nil (default) for silence
```

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
- **Render canary**: `swift run AgentIslandApp -renderRoadSample /tmp/road.png` (Road-Runner-specific).
- **Install a local data theme** (once the engine ships): drop the folder into
  `~/.agent-island/themes/<id>/` and pick it from the menu.

## TODO themes

- [ ] **`mario`** — data theme. Running Mario sprite while working; `?`-block on waiting; coin/jump
  on milestone; flagpole on goal; game-over jingle on failure. Accent `#E52521`.
- [ ] **`the-witcher`** — data theme. Medieval palette; torch/medallion imagery; per-state sounds
  (sword draw on permission, quest-complete on goal). Needs the manifest engine + (ideally) download.
