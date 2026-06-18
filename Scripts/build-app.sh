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
VERSION="0.3.0"

echo "Building AgentIslandApp + daemon + hook bridge + management CLI (release)…"
swift build -c release --product AgentIslandApp
swift build -c release --product agentislandd
swift build -c release --product AgentIslandHookCLI
swift build -c release --product agentisland

APP="$ROOT/build/AgentIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/AgentIslandApp" "$APP/Contents/MacOS/AgentIsland"
# Siblings next to the app executable so EventDrivenSetup can resolve them by name
# (event-driven mode: the hook relay command + the daemon spawn). The management CLI is bundled too
# so the app's "Get update…" can run `agentisland update` as a sibling (and `install.sh` copies it to PATH).
cp "$ROOT/.build/release/agentislandd" "$APP/Contents/MacOS/agentislandd"
cp "$ROOT/.build/release/AgentIslandHookCLI" "$APP/Contents/MacOS/AgentIslandHookCLI"
cp "$ROOT/.build/release/agentisland" "$APP/Contents/MacOS/agentisland"

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
  <key>CFBundleExecutable</key><string>AgentIsland</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo ""
echo "Built: $APP"
echo "Launch:  open \"$APP\"      (a menu-bar item appears at the top-right)"
echo "Autostart: drag it into  System Settings ▸ General ▸ Login Items."
