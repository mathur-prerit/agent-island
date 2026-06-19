#!/usr/bin/env bash
set -euo pipefail

# Build AgentIslandApp (release) and wrap it into a double-clickable AgentIsland.app.
# No Apple ID, signing, or notarization needed: an app you build locally carries no
# Gatekeeper "quarantine" flag, so it opens without any "unidentified developer" warning.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The single source of truth for the app's release version. Stamped into the Info.plist below as
# CFBundleShortVersionString so the running app reports the REAL version via `AppInfo.version`
# (the "update available" indicator compares this against the latest GitHub release). Keep this in
# lockstep with the `AppInfo.version` fallback in ManifestThemeDiscovery.swift — that fallback is the
# version a bare `swift run AgentIslandApp` reports (no bundle plist), so they must agree.
# Overridable so the release CI can stamp the git tag into the plist (VERSION=${TAG#v} bash build-app.sh).
# Keep the 0.3.0 fallback in lockstep with CLIConstants.version + the AppInfo.version fallback.
VERSION="${VERSION:-0.4.0}"

echo "Building AgentIslandApp + daemon + hook bridge + management CLI (release)…"
swift build -c release --product AgentIslandApp
swift build -c release --product agentislandd
swift build -c release --product AgentIslandHookCLI
swift build -c release --product agentisland

APP="$ROOT/build/AgentIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The GUI executable MUST NOT be named "AgentIsland": macOS is case-INSENSITIVE, so a sibling named
# "AgentIsland" collides with the "agentisland" management CLI copied below — the CLI cp silently
# clobbers the app, and launching the bundle then runs the CLI (no menu-bar item ever appears). Name it
# "AgentIslandApp" (the product name); CFBundleExecutable below points at it. Sibling resolution
# (EventDrivenSetup / locateManagementCLI) keys off the executable's directory, not this name.
cp "$ROOT/.build/release/AgentIslandApp" "$APP/Contents/MacOS/AgentIslandApp"
# Siblings next to the app executable so EventDrivenSetup can resolve them by name
# (event-driven mode: the hook relay command + the daemon spawn). The management CLI is bundled too
# so the app's "Get update…" can run `agentisland update` as a sibling (and `install.sh` copies it to PATH).
cp "$ROOT/.build/release/agentislandd" "$APP/Contents/MacOS/agentislandd"
cp "$ROOT/.build/release/AgentIslandHookCLI" "$APP/Contents/MacOS/AgentIslandHookCLI"
cp "$ROOT/.build/release/agentisland" "$APP/Contents/MacOS/agentisland"

# CRITICAL: copy the SwiftPM resource bundle into Contents/Resources (NOT the .app root). AgentIslandApp
# uses `.copy` resources (bundled themes + sounds), so SwiftPM generates `<Package>_<Target>.bundle` =
# `AgentIsland_AgentIslandApp.bundle`. Two macOS rules collide here:
#   • SwiftPM's stock `Bundle.module` only resolves it from the .app ROOT (Bundle.main.bundleURL/<name>).
#   • `codesign` FORBIDS any non-Contents/ item at the .app root ("unsealed contents present in the bundle
#     root") — putting the bundle at the root makes the release CI's codesign step fail on macos-13/14.
# So we ship it in the standard Contents/Resources and resolve it ourselves at runtime via
# `AppResources.bundle` (AppResources.swift), which prefers Contents/Resources and falls back to root +
# Bundle.module. (`swift run`/self-test find it via Bundle.module's baked-in .build/ path; the release.yml
# smoke test hides .build so a MISPLACED bundle can't false-pass on the build machine.)
RES_BUNDLE="$ROOT/.build/release/AgentIsland_AgentIslandApp.bundle"
if [ -d "$RES_BUNDLE" ]; then
  cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
else
  echo "warning: resource bundle not found at $RES_BUNDLE — bundled themes won't load (the app WILL crash)" >&2
fi

# --- App icon ----------------------------------------------------------------
# Generate AppIcon.icns at build time from the committed 1024px master (one source of truth, no drifting
# binary), and drop it in Resources/ where CFBundleIconFile (below) points. Guarded so set -euo pipefail
# doesn't abort the whole build if the asset or iconutil/sips is missing — it warns and ships without an
# icon instead. iconutil + sips ship with macOS (no Xcode needed).
ICON_SRC="$ROOT/Resources/AppIcon.png"
if [ -f "$ICON_SRC" ] && command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  ICONSET_PARENT="$(mktemp -d)"
  ICONSET="$ICONSET_PARENT/AgentIsland.iconset"
  mkdir -p "$ICONSET"
  # logical:pixel pairs — 1x and 2x for every macOS icon size iconutil expects.
  for pair in 16:16 16:32 32:32 32:64 128:128 128:256 256:256 256:512 512:512 512:1024; do
    logical="${pair%%:*}"; px="${pair##*:}"
    if [ "$px" = "$logical" ]; then name="icon_${logical}x${logical}.png"; else name="icon_${logical}x${logical}@2x.png"; fi
    # Guarded: a corrupt/non-image source makes sips exit non-zero, which under `set -euo pipefail`
    # would abort the ENTIRE build (and, in CI, a zero-artifact release). Degrade to no-icon instead.
    sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/$name" >/dev/null 2>&1 \
      || { echo "warning: icon conversion failed (size $px); shipping without a custom icon" >&2; break; }
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
    echo "Generated AppIcon.icns"
  else
    echo "warning: iconutil failed; the app will fall back to the generic icon" >&2
  fi
  rm -rf "$ICONSET_PARENT"
else
  echo "warning: skipping app icon (need Resources/AppIcon.png + iconutil + sips on PATH)" >&2
fi

# Unquoted heredoc so $VERSION expands; the plist has no other shell metacharacters to escape.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentIsland</string>
  <key>CFBundleDisplayName</key><string>agent-island</string>
  <key>CFBundleIdentifier</key><string>com.mathur-prerit.agentisland</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>AgentIslandApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <!-- Click-to-focus sends Apple Events to the terminal (e.g. iTerm2) to raise the owning
       window. macOS requires this usage string to present the Automation consent prompt;
       without it the event is denied with no UI and focus silently does nothing. -->
  <key>NSAppleEventsUsageDescription</key><string>agent-island focuses the terminal window running your agent session when you click its island.</string>
</dict>
</plist>
PLIST

echo ""
echo "Built: $APP"
echo "Launch:  open \"$APP\"      (a menu-bar item appears at the top-right)"
echo "Autostart: drag it into  System Settings ▸ General ▸ Login Items."
