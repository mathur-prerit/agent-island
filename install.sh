#!/usr/bin/env bash
set -euo pipefail

# agent-island one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/mathur-prerit/agent-island/main/install.sh | sh
#
# RELEASE-FIRST: by default this downloads the latest PUBLISHED RELEASE's prebuilt artifacts (no Xcode
# or Swift toolchain needed) and falls back to BUILDING FROM SOURCE only when there's no matching
# release asset (e.g. your CPU arch isn't published, you're offline, or no release exists yet).
#
# Knobs (env):
#   AGENT_ISLAND_RELEASE   release to install: "latest" (default) or a pinned tag like "v0.3.0".
#                          Set to "source" to force a from-source build.
#   AGENT_ISLAND_BIN_DIR   where the CLIs go (default: /opt/homebrew/bin on Apple Silicon,
#                          /usr/local/bin on Intel).
#
# What it does (all idempotent — safe to re-run to upgrade):
#   1. Installs AgentIsland.app to /Applications (prebuilt download, or built from source).
#   2. Installs the `agentisland` + `agentisland-hook` binaries to a PATH dir.
#   3. Wires the Claude Code lifecycle hooks (backup + atomic write).
#   4. Optionally enables start-on-boot (login item) — only when run interactively and confirmed.
#
# It never deletes user data. Reverse everything with:  agentisland uninstall
#
# Requirements: macOS 13+. The from-source FALLBACK additionally needs git + Swift (Xcode or the
# Command Line Tools: xcode-select --install).

REPO_SLUG="mathur-prerit/agent-island"
REPO_URL="https://github.com/${REPO_SLUG}"
APP_NAME="AgentIsland.app"
APP_DEST="/Applications/${APP_NAME}"
RELEASE="${AGENT_ISLAND_RELEASE:-latest}"

# Arch-aware default bin dir. On Apple Silicon /usr/local/bin isn't writable without sudo and isn't on
# PATH by default — /opt/homebrew/bin is (and is what the app already searches). Intel keeps /usr/local/bin.
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) DEFAULT_BIN_DIR="/opt/homebrew/bin" ;;
  *)     DEFAULT_BIN_DIR="/usr/local/bin" ;;
esac
BIN_DIR="${AGENT_ISLAND_BIN_DIR:-$DEFAULT_BIN_DIR}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- Shared install helpers --------------------------------------------------

# Fail-safe atomic .app replace: stage a full copy beside the destination, then swap it in only once the
# copy fully succeeds. A failed copy (/Applications not writable, disk full, interrupted) never destroys
# an already-installed app. $1 = path to the AgentIsland.app to install.
install_app_atomic() {
  local src="$1" stage="${APP_DEST}.new"
  log "Installing ${APP_NAME} to /Applications…"
  rm -rf "$stage"
  if ! cp -R "$src" "$stage" 2>/dev/null; then
    rm -rf "$stage"
    die "could not copy ${APP_NAME} to ${APP_DEST} (existing install left intact; if /Applications isn't writable, re-run with sudo)"
  fi
  rm -rf "$APP_DEST"
  mv "$stage" "$APP_DEST"
}

ensure_bin_dir() {
  if [ ! -d "$BIN_DIR" ]; then
    mkdir -p "$BIN_DIR" 2>/dev/null || warn "could not create ${BIN_DIR}; you may need: sudo mkdir -p ${BIN_DIR}"
  fi
}

# install_bin <src-binary-path> <dest-name>: copy one binary to BIN_DIR under <dest-name> (+x). Used by
# BOTH the download and the source paths so the on-PATH names are ALWAYS agentisland / agentisland-hook
# (the hook bridge ships as AgentIslandHookCLI but MUST land as agentisland-hook — hooks + uninstall +
# the self-test all assume that name).
install_bin() {
  local src="$1" dest="${BIN_DIR}/$2"
  [ -f "$src" ] || { warn "missing binary $src; skipping $2"; return 1; }
  # Atomic: copy to a temp name, chmod, then rename over the dest. `agentisland update` re-runs this
  # while the very `agentisland` being overwritten is the running process; an in-place `cp` (O_TRUNC)
  # could ETXTBSY or leave a torn binary. rename() swaps the directory entry without touching the inode
  # the running process holds open.
  if cp "$src" "${dest}.new" 2>/dev/null && chmod +x "${dest}.new" && mv -f "${dest}.new" "$dest" 2>/dev/null; then
    return 0
  else
    rm -f "${dest}.new" 2>/dev/null || true
    warn "could not write ${dest}. Re-run with sudo, or set AGENT_ISLAND_BIN_DIR to a writable dir, e.g.:"
    warn "    AGENT_ISLAND_BIN_DIR=\$HOME/.local/bin sh -c \"\$(curl -fsSL ${REPO_URL}/raw/main/install.sh)\""
    return 1
  fi
}

# Warn if BIN_DIR isn't on PATH (so the freshly installed `agentisland` is actually found).
check_bin_on_path() {
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) : ;;
    *) warn "${BIN_DIR} is not on your PATH — add it (e.g. echo 'export PATH=\"${BIN_DIR}:\$PATH\"' >> ~/.zshrc)" ;;
  esac
}

# True iff both CLIs actually landed in BIN_DIR. Lets the caller avoid claiming success when a
# non-writable BIN_DIR meant the .app installed but the `agentisland` CLI never made it onto PATH.
clis_installed() { [ -x "${BIN_DIR}/agentisland" ] && [ -x "${BIN_DIR}/agentisland-hook" ]; }

wire_hooks() {
  # Use the just-installed hook CLI if it's on PATH, else the freshly built/extracted one. Backup-aware
  # + atomic (see SettingsFile). $1 = optional fallback path to the hook binary.
  log "Wiring Claude Code lifecycle hooks…"
  if command -v agentisland-hook >/dev/null 2>&1; then
    agentisland-hook install || warn "hook wiring failed; retry later with: agentisland-hook install"
  elif [ -n "${1:-}" ] && [ -x "$1" ]; then
    "$1" install || warn "hook wiring failed; retry later with: agentisland-hook install"
  else
    warn "agentisland-hook not found; wire hooks later with: agentisland-hook install"
  fi
}

maybe_start_on_boot() {
  # Only prompt when interactive (a piped `curl | sh` has no TTY — never block a non-interactive install).
  [ -t 0 ] || return 0
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
}

# Ask which look (animation theme) to use. Interactive only — a piped `curl | sh` keeps the default
# (Road Runner). The three offered themes ship with the app (built-in + bundled); more can be downloaded
# any time via `agentisland theme add` or the menu-bar ▸ Animation theme ▸ Download more.
maybe_pick_theme() {
  [ -t 0 ] || return 0
  command -v agentisland >/dev/null 2>&1 || return 0   # need the CLI on PATH to set the preference
  printf '\nPick a look (animation theme) — change it any time:\n'
  printf '  1) Road Runner   — a token-burn road trip   (default)\n'
  printf '  2) Minimal       — a clean CLI-style spinner\n'
  printf '  3) Pixel Critter — a bouncy pixel sprite\n'
  printf 'Choice [1-3, Enter=1]: '
  read -r theme_choice || theme_choice=""
  case "$theme_choice" in
    2) agentisland theme set minimal >/dev/null 2>&1 && log "Theme set to Minimal." ;;
    3) agentisland theme set critter >/dev/null 2>&1 && log "Theme set to Pixel Critter." ;;
    *) agentisland theme set journey >/dev/null 2>&1 && log "Theme set to Road Runner." ;;
  esac
  log "Want more looks? Install themes any time:  agentisland theme add <id|url>"
  log "  …or pick from the menu-bar ▸ Animation theme ▸ Download more."
}

# --- Release (prebuilt) install path -----------------------------------------
# Returns 0 on a successful prebuilt install, 1 to signal "fall back to source".
try_release_install() {
  [ "$RELEASE" = "source" ] && return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v ditto >/dev/null 2>&1 || return 1

  local tag ver tmp appurl cliurl appzip clizip
  if [ "$RELEASE" = "latest" ]; then
    # /releases/latest is the newest NON-prerelease, non-draft release. Fall back to the /releases list
    # (which includes prereleases) and take the first (newest) tag, so a 0.x prerelease still installs
    # prebuilt instead of forcing every one-liner user through a from-source build.
    tag="$(curl -fsSL "https://api.github.com/repos/${REPO_SLUG}/releases/latest" 2>/dev/null \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "${tag:-}" ] || tag="$(curl -fsSL "https://api.github.com/repos/${REPO_SLUG}/releases?per_page=1" 2>/dev/null \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  else
    tag="$RELEASE"
  fi
  [ -n "${tag:-}" ] || { log "No published release found; falling back to source build."; return 1; }

  ver="${tag#v}"
  appzip="AgentIsland-${ver}-${ARCH}.zip"
  clizip="agentisland-cli-${ver}-${ARCH}.zip"
  appurl="${REPO_URL}/releases/download/${tag}/${appzip}"
  cliurl="${REPO_URL}/releases/download/${tag}/${clizip}"

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  log "Downloading agent-island ${tag} (${ARCH}) prebuilt…"
  if ! curl -fL --retry 3 -o "$tmp/$appzip" "$appurl" 2>/dev/null; then
    log "No ${ARCH} release asset for ${tag}; falling back to source build."
    return 1
  fi
  curl -fL --retry 3 -o "$tmp/$clizip" "$cliurl" 2>/dev/null || { log "CLI asset missing; falling back to source."; return 1; }

  # Verify checksums if the release publishes them (best-effort: skip silently if absent). Per-arch file
  # (checksums-<arch>.txt) so the two CI matrix jobs don't collide on one uploaded checksums file.
  if curl -fsSL -o "$tmp/checksums-${ARCH}.txt" "${REPO_URL}/releases/download/${tag}/checksums-${ARCH}.txt" 2>/dev/null; then
    ( cd "$tmp" && shasum -a 256 -c --ignore-missing "checksums-${ARCH}.txt" ) >/dev/null 2>&1 \
      || die "checksum verification failed for ${tag} — refusing to install a tampered/incomplete download"
  fi

  ditto -x -k "$tmp/$appzip" "$tmp/app" 2>/dev/null || { warn "could not unpack the app zip; falling back to source."; return 1; }
  ditto -x -k "$tmp/$clizip" "$tmp/cli" 2>/dev/null || { warn "could not unpack the CLI zip; falling back to source."; return 1; }

  local staged_app="$tmp/app/${APP_NAME}"
  [ -d "$staged_app" ] || { warn "downloaded app bundle not found; falling back to source."; return 1; }

  # A downloaded .app carries com.apple.quarantine and isn't Developer-ID signed → Gatekeeper blocks it
  # ("unidentified developer"/"damaged"). Strip quarantine + ad-hoc sign so it opens without a right-click
  # dance. (A from-source build never gets quarantined, so this is download-path-only.)
  xattr -dr com.apple.quarantine "$staged_app" 2>/dev/null || true
  codesign --force --deep --sign - "$staged_app" >/dev/null 2>&1 || true

  install_app_atomic "$staged_app"
  log "Installing CLI binaries to ${BIN_DIR}…"
  ensure_bin_dir
  install_bin "$tmp/cli/agentisland" "agentisland" || true
  install_bin "$tmp/cli/agentisland-hook" "agentisland-hook" || true
  check_bin_on_path
  wire_hooks "$tmp/cli/agentisland-hook"
  if clis_installed; then
    log "Installed prebuilt ${tag}."
  else
    log "Installed prebuilt ${tag} app — but the CLI didn't land in ${BIN_DIR} (see the warning above)."
    log "Re-run with sudo, or: AGENT_ISLAND_BIN_DIR=\$HOME/.local/bin sh -c \"\$(curl -fsSL ${REPO_URL}/raw/main/install.sh)\""
  fi
  return 0
}

# --- Source (build) install path ---------------------------------------------
source_install() {
  command -v git >/dev/null 2>&1   || die "git is required for the from-source fallback (xcode-select --install)"
  command -v swift >/dev/null 2>&1 || die "swift is required for the from-source fallback (xcode-select --install)"

  # If this script lives inside a repo checkout, build there; otherwise clone (pinned to the tag when one
  # was requested, else main).
  local script_src maybe_root repo_root clone_dir=""
  script_src="${BASH_SOURCE[0]:-}"
  repo_root=""
  if [ -n "$script_src" ] && [ -f "$script_src" ]; then
    maybe_root="$(cd "$(dirname "$script_src")" && pwd)"
    if [ -f "${maybe_root}/Package.swift" ] && [ -f "${maybe_root}/Scripts/build-app.sh" ]; then
      repo_root="$maybe_root"
    fi
  fi
  if [ -z "$repo_root" ]; then
    clone_dir="$(mktemp -d)"
    if [ "$RELEASE" != "latest" ] && [ "$RELEASE" != "source" ]; then
      log "Cloning ${REPO_URL} @ ${RELEASE} into ${clone_dir}…"
      # On a tag-clone failure (bad tag, or an interrupted transfer that left clone_dir non-empty), reset
      # the dir before the fallback clone — `git clone` into a non-empty dir errors out.
      git clone --depth 1 --branch "$RELEASE" "$REPO_URL" "$clone_dir" \
        || { rm -rf "$clone_dir"; mkdir -p "$clone_dir"; git clone --depth 1 "$REPO_URL" "$clone_dir"; }
    else
      log "Cloning ${REPO_URL} into ${clone_dir}…"
      git clone --depth 1 "$REPO_URL" "$clone_dir"
    fi
    repo_root="$clone_dir"
    # shellcheck disable=SC2064
    trap "rm -rf '$clone_dir'" RETURN
  fi

  log "Building agent-island from source (release)…"
  ( cd "$repo_root" && bash Scripts/build-app.sh )
  ( cd "$repo_root" && swift build -c release --product agentisland )

  local built_app="${repo_root}/build/${APP_NAME}" release_bin="${repo_root}/.build/release"
  [ -d "$built_app" ] || die "build did not produce ${built_app}"

  install_app_atomic "$built_app"
  log "Installing CLI binaries to ${BIN_DIR}…"
  ensure_bin_dir
  install_bin "${release_bin}/agentisland" "agentisland"
  install_bin "${release_bin}/AgentIslandHookCLI" "agentisland-hook"
  check_bin_on_path
  wire_hooks "${release_bin}/AgentIslandHookCLI"
}

# --- Run ---------------------------------------------------------------------
if ! try_release_install; then
  source_install
fi
maybe_pick_theme
maybe_start_on_boot

log "Done. Launch it now with:  open \"${APP_DEST}\""
log "Manage it with:  agentisland --help"
log "Remove everything with:  agentisland uninstall"
