#!/usr/bin/env bash
set -euo pipefail

# Build AgentIslandApp (release) and wrap it into a double-clickable AgentIsland.app.
# No Apple ID, signing, or notarization needed: an app you build locally carries no
# Gatekeeper "quarantine" flag, so it opens without any "unidentified developer" warning.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building AgentIslandApp + daemon + hook bridge (release)…"
swift build -c release --product AgentIslandApp
swift build -c release --product agentislandd
swift build -c release --product AgentIslandHookCLI

APP="$ROOT/build/AgentIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/AgentIslandApp" "$APP/Contents/MacOS/AgentIsland"
# Siblings next to the app executable so EventDrivenSetup can resolve them by name
# (event-driven mode: the hook relay command + the daemon spawn).
cp "$ROOT/.build/release/agentislandd" "$APP/Contents/MacOS/agentislandd"
cp "$ROOT/.build/release/AgentIslandHookCLI" "$APP/Contents/MacOS/AgentIslandHookCLI"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentIsland</string>
  <key>CFBundleDisplayName</key><string>agent-island</string>
  <key>CFBundleIdentifier</key><string>com.mathur-prerit.agentisland</string>
  <key>CFBundleVersion</key><string>0.0.1</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
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
