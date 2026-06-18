#!/usr/bin/env bash
set -euo pipefail

# agent-island one-line installer (BUILD FROM SOURCE — there are no binary releases yet).
#
#   curl -fsSL https://raw.githubusercontent.com/mathur-prerit/agent-island/main/install.sh | sh
#
# What it does (all idempotent — safe to re-run to upgrade):
#   1. Ensures a checkout of the repo (clones it if this script isn't already inside one).
#   2. Builds the .app + daemon + both CLIs via Scripts/build-app.sh (release, no signing needed).
#   3. Copies AgentIsland.app to /Applications (replacing any prior copy).
#   4. Installs the `agentisland` + `agentisland-hook` binaries to a PATH dir.
#   5. Wires the Claude Code lifecycle hooks (via `agentisland-hook install` — backup + atomic write).
#   6. Optionally enables start-on-boot (login item) — only when run interactively and confirmed.
#
# It never deletes user data. Reverse everything with:  agentisland uninstall
#
# Requirements: macOS 13+, git, and Swift (Xcode or the Command Line Tools: xcode-select --install).

REPO_URL="https://github.com/mathur-prerit/agent-island"
APP_NAME="AgentIsland.app"
APP_DEST="/Applications/${APP_NAME}"
BIN_DIR="${AGENT_ISLAND_BIN_DIR:-/usr/local/bin}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------
command -v git >/dev/null 2>&1   || die "git is required (install Xcode Command Line Tools: xcode-select --install)"
command -v swift >/dev/null 2>&1 || die "swift is required (install Xcode or the Command Line Tools: xcode-select --install)"

# --- 1. Locate or clone the repo ---------------------------------------------
# If this script lives inside the repo (a local checkout), build there; otherwise clone to a temp dir.
SCRIPT_SRC="${BASH_SOURCE[0]:-}"
REPO_ROOT=""
if [ -n "$SCRIPT_SRC" ] && [ -f "$SCRIPT_SRC" ]; then
  maybe_root="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"
  if [ -f "${maybe_root}/Package.swift" ] && [ -f "${maybe_root}/Scripts/build-app.sh" ]; then
    REPO_ROOT="$maybe_root"
  fi
fi

CLONE_DIR=""
if [ -z "$REPO_ROOT" ]; then
  CLONE_DIR="$(mktemp -d)"
  log "Cloning ${REPO_URL} into ${CLONE_DIR}…"
  git clone --depth 1 "$REPO_URL" "$CLONE_DIR"
  REPO_ROOT="$CLONE_DIR"
fi
# Clean up a temp clone on exit (a local checkout is left untouched).
cleanup() { [ -n "$CLONE_DIR" ] && [ -d "$CLONE_DIR" ] && rm -rf "$CLONE_DIR"; }
trap cleanup EXIT

# --- 2. Build ----------------------------------------------------------------
log "Building agent-island from source (release)…"
( cd "$REPO_ROOT" && bash Scripts/build-app.sh )
# Also build the user-facing management CLI (build-app.sh builds the app + daemon + hook bridge).
log "Building the management CLI…"
( cd "$REPO_ROOT" && swift build -c release --product agentisland )

BUILT_APP="${REPO_ROOT}/build/${APP_NAME}"
RELEASE_BIN="${REPO_ROOT}/.build/release"
[ -d "$BUILT_APP" ] || die "build did not produce ${BUILT_APP}"

# --- 3. Install the .app -----------------------------------------------------
# Fail-safe replace: copy into a staging path FIRST, and only swap it in once the copy fully
# succeeds. On the documented re-run/upgrade path this means a failed copy (/Applications not
# writable, disk full, interrupted `curl|sh`) never destroys the already-installed app — under
# `set -euo pipefail` the old `rm -rf` + unguarded `cp` left the user with no app at all.
log "Installing ${APP_NAME} to /Applications…"
APP_STAGE="${APP_DEST}.new"
rm -rf "$APP_STAGE"
if ! cp -R "$BUILT_APP" "$APP_STAGE" 2>/dev/null; then
  rm -rf "$APP_STAGE"
  die "could not copy ${APP_NAME} to ${APP_DEST} (existing install left intact; if /Applications isn't writable, re-run with sudo)"
fi
rm -rf "$APP_DEST"
mv "$APP_STAGE" "$APP_DEST"

# --- 4. Install the CLI binaries on PATH -------------------------------------
log "Installing CLI binaries to ${BIN_DIR}…"
if [ ! -d "$BIN_DIR" ]; then
  mkdir -p "$BIN_DIR" 2>/dev/null || warn "could not create ${BIN_DIR}; you may need: sudo mkdir -p ${BIN_DIR}"
fi
install_bin() {
  # $1 = source binary, $2 = destination name
  src="${RELEASE_BIN}/$1"
  dest="${BIN_DIR}/$2"
  [ -f "$src" ] || { warn "missing built binary $src; skipping $2"; return; }
  if cp "$src" "$dest" 2>/dev/null; then
    chmod +x "$dest"
  else
    warn "could not write ${dest} (try re-running with sudo, or set AGENT_ISLAND_BIN_DIR to a writable dir)"
  fi
}
install_bin "agentisland" "agentisland"
install_bin "AgentIslandHookCLI" "agentisland-hook"

# --- 5. Wire the Claude Code hooks -------------------------------------------
# Use the just-installed hook CLI if it's on PATH, else the freshly built one (so a non-writable
# BIN_DIR still wires hooks). The installer is backup-aware + atomic (see SettingsFile).
log "Wiring Claude Code lifecycle hooks…"
if command -v agentisland-hook >/dev/null 2>&1; then
  agentisland-hook install || warn "hook wiring failed; you can retry later with: agentisland-hook install"
else
  "${RELEASE_BIN}/AgentIslandHookCLI" install || warn "hook wiring failed; retry later with: agentisland-hook install"
fi

# --- 6. Optional: start on boot ----------------------------------------------
# Only prompt when interactive (a piped `curl | sh` has no TTY — never block a non-interactive install).
if [ -t 0 ]; then
  printf 'Launch agent-island automatically at login? [y/N] '
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES)
      if command -v agentisland >/dev/null 2>&1; then
        agentisland start-on-boot on || warn "could not enable start-on-boot; add it under System Settings > Login Items"
      fi
      ;;
    *) log "Skipped start-on-boot (enable later with: agentisland start-on-boot on)" ;;
  esac
fi

# --- Done --------------------------------------------------------------------
log "Done. Launch it now with:  open \"${APP_DEST}\""
log "Manage it with:  agentisland --help"
log "Remove everything with:  agentisland uninstall"
