#!/bin/bash
# Cortex — installer (public distribution, no token needed).
#
# By default this downloads the prebuilt .app anonymously from the PUBLIC
# distribution repo's latest GitHub Release — no GitHub token required:
#
#   curl -fsSL https://raw.githubusercontent.com/appfactory123/cortex-ai-sessions-dist/main/install.sh | bash
#
# Installs the app to /Applications, provisions a data dir (~/.cortex-ai-sessions)
# with the bot + support files, and installs every runtime library (Node deps
# via Bun, Python cryptography/tls-client, a managed MLX-or-Whisper realtime
# speech model, a managed local Pocket Jarvis voice, ffmpeg,
# Google Chrome, and the Claude, Codex, Antigravity, and Grok CLIs Cortex drives).
# Unsigned: the app's quarantine flag is stripped so
# Gatekeeper doesn't block it. Safe to re-run.
#
# Developers can instead pull an unreleased build from the PRIVATE source repo
# by exporting a GitHub token with read access to it (GH_TOKEN); when a token is
# present the installer downloads from the private repo via the authenticated
# API rather than the public dist repo.
#
# Overrides (env):
#   GH_TOKEN / GITHUB_TOKEN / CORTEX_TOKEN   token → pull from PRIVATE
#                              source repo (optional; default is tokenless public).
#   CORTEX_SOURCE_REPO  override the authenticated private repo (owner/name).
#   CORTEX_PUBLIC_REPO  override the public dist repo (owner/name).
#   CORTEX_VERSION    pin a release tag (default: latest)
#   CORTEX_LOCAL_DIR  install Cortex app/support artifacts from this directory
#                              instead of downloading them. Pocket's model
#                              remains a fixed verified download unless it is
#                              also present here — for testing; no token needed.

set -euo pipefail

REPO="${CORTEX_SOURCE_REPO:-appfactory123/claude-sessions}"
PUBLIC_REPO="${CORTEX_PUBLIC_REPO:-appfactory123/cortex-ai-sessions-dist}"
APP_NAME="Cortex"
APP_PATH="/Applications/${APP_NAME}.app"
# Cortex Builder publishes a renamed build (customizeCortexDevelopAppIdentity in
# the Cortex repository) so a development Cortex can sit beside the released one.
# Those are two apps, so they get two data dirs: sharing one would mean sharing
# settings.json, sessions.json and the bot's state. Re-derived from the bundle
# that was actually downloaded, once its name is known; CORTEX_DATA_DIR pins it
# for an in-app update, which already knows which app it is updating.
app_data_dir() {
  local suffix
  suffix="$(printf '%s' "${1:-}" \
    | sed 's/^Cortex//' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')"
  if [ -n "$suffix" ]; then
    printf '%s' "$HOME/.cortex-ai-sessions-$suffix"
  else
    printf '%s' "$HOME/.cortex-ai-sessions"
  fi
}
DATA_DIR="${CORTEX_DATA_DIR:-$(app_data_dir "$APP_NAME")}"
CONFIG="$DATA_DIR.env"
TOKEN="${CORTEX_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
IN_APP_UPDATE="${CORTEX_IN_APP_UPDATE:-}"

# Mirror all installer output (stdout + stderr) to a log file in the data dir,
# in addition to the terminal, so a failed run piped from `curl | bash` can
# still be inspected afterward.
mkdir -p "$DATA_DIR"
LOG_FILE="$DATA_DIR/install.log"
exec > >(tee "$LOG_FILE") 2>&1
echo "Cortex installer log — $(date)"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m▶ [%s] %s\033[0m\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$1"; }
die()  {
  printf '\033[31m✗ %s\033[0m\n' "$1" >&2
  printf '\033[31m  Full log: %s\033[0m\n' "$LOG_FILE" >&2
  exit 1
}

# Run a command, retrying up to <attempts> times with a short linear backoff.
# Used for network steps (release download, bun bootstrap) that fail
# transiently on flaky links rather than for a real, permanent error.
retry() {
  local attempts="$1"; shift
  local n=1
  while true; do
    "$@" && return 0
    if [ "$n" -ge "$attempts" ]; then return 1; fi
    warn "attempt $n/$attempts failed — retrying in $((n * 2))s…"
    sleep "$((n * 2))"
    n=$((n + 1))
  done
}

app_executable_pattern() {
  printf '%s/Contents/MacOS/%s' "$APP_PATH" "$APP_NAME"
}

app_pids() {
  pgrep -f "$(app_executable_pattern)" 2>/dev/null || true
}

APP_RELAUNCH_REQUIRED=""
APP_RELAUNCHED=""
APP_BACKUP=""

relaunch_installed_app() {
  [ "$IN_APP_UPDATE" = "1" ] || return 0
  [ -d "$APP_PATH" ] || {
    warn "cannot relaunch ${APP_NAME}: $APP_PATH is missing"
    return 1
  }
  if [ -n "$(app_pids)" ]; then
    APP_RELAUNCHED=1
    return 0
  fi

  local attempt check
  for attempt in 1 2 3; do
    open "$APP_PATH" >/dev/null 2>&1 || true
    for check in 1 2 3 4 5 6 7 8 9 10; do
      if [ -n "$(app_pids)" ]; then
        APP_RELAUNCHED=1
        ok "${APP_NAME} relaunched; finishing setup in the background"
        return 0
      fi
      sleep 0.5
    done
    warn "relaunch attempt $attempt/3 did not start ${APP_NAME}"
  done
  return 1
}

refresh_launchservices() {
  local action="$1"
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [ -x "$lsregister" ] || return 0
  case "$action" in
    unregister) [ -d "$APP_PATH" ] && "$lsregister" -u "$APP_PATH" >/dev/null 2>&1 || true ;;
    register)   [ -d "$APP_PATH" ] && "$lsregister" -f "$APP_PATH" >/dev/null 2>&1 || true ;;
  esac
}

quit_running_app() {
  local pids bundle_id
  pids="$(app_pids)"
  [ -n "$pids" ] || return 0

  warn "${APP_NAME} is running — quitting it before replacing the app bundle"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
  if [ -n "$bundle_id" ]; then
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  else
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  fi

  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -z "$(app_pids)" ] && { ok "stopped running app"; return 0; }
    sleep 0.5
  done

  warn "app did not quit in time — stopping the old installed executable"
  pkill -TERM -f "$(app_executable_pattern)" >/dev/null 2>&1 || true
  sleep 1
  if [ -n "$(app_pids)" ]; then
    pkill -KILL -f "$(app_executable_pattern)" >/dev/null 2>&1 || true
  fi
  [ -z "$(app_pids)" ] && ok "stopped running app" || warn "old app process may still be running"
}

installed_build_tag() {
  local vf="$APP_PATH/Contents/Resources/standalone/version.json"
  [ -f "$vf" ] || return 0
  awk -F'"' '/"tag":[[:space:]]*"/ { print $4; exit }' "$vf"
}

# Resolve the login-shell PATH so Bun/conda/pyenv are found even when this runs
# piped from curl (a non-interactive, minimal-PATH shell). Mirrors setup.command.
# -ilc sources rc files so PATH matches a real terminal, but those (and macOS
# Terminal's session restore) can print banners like "Restored session: …" to
# stdout. Wrap the value in a sentinel and extract only what's between the
# markers, so banner/MOTD noise can't pollute PATH.
if _CSRAW="$(${SHELL:-/bin/zsh} -ilc 'printf "<<CSPATH:%s:CSPATH>>" "$PATH"' 2>/dev/null)" \
   && case "$_CSRAW" in *"<<CSPATH:"*":CSPATH>>"*) true ;; *) false ;; esac; then
  _CSPATH="${_CSRAW#*<<CSPATH:}"; _CSPATH="${_CSPATH%:CSPATH>>*}"
  export PATH="$_CSPATH"
else
  export PATH="$HOME/.bun/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi

LOCAL_BIN="$HOME/.local/bin"
# Filled after the fixed config is parsed below. Cortex resolves Grok from
# GROK_HOME first; the upstream installer instead exposes GROK_BIN_DIR.
GROK_CLI_HOME=""
GROK_CLI_BIN_DIR=""

# The packaged Electron app also reads these path settings from the fixed config
# file. Read only literal assignments for this narrow allowlist — never source
# the config as shell code — so an installer rerun respects the same executable
# and Grok provider home as the app.
load_cli_overrides_from_config() {
  [ -f "$CONFIG" ] || return 0
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ "$line" =~ ^(CLAUDE_BIN|CODEX_BIN|AGY_BIN|GROK_BIN|GROK_HOME)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
    else
      continue
    fi
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    [ -n "$value" ] || continue
    [ -z "${!key:-}" ] && export "$key=$value"
  done < "$CONFIG"
}

# Keep a literal backup across setup.command. The raw public installer can be
# newer than the release support bundle it downloads, so that bundle may still
# contain an older setup.command which rewrites the config without preserving
# user-owned CLI paths or voice credentials/settings. Never source these values.
PRESERVED_CONFIG_KEYS='PYTHON_BIN|CLAUDE_BIN|CODEX_BIN|AGY_BIN|GROK_BIN|GROK_HOME|KIMI_BIN|KIMI_SHARE_DIR|UV_BIN|CORTEX_OPENAI_API_KEY|OPENAI_API_KEY|CORTEX_ELEVENLABS_API_KEY|ELEVENLABS_API_KEY|CORTEX_VOICE_TTS_PROVIDER|CORTEX_VOICE_TTS_PYTHON|CORTEX_VOICE_TTS_DEVICE|CORTEX_VOICE_TTS_MODEL|CORTEX_VOICE_TTS_VOICE|CORTEX_ELEVENLABS_VOICE_ID|CORTEX_ELEVENLABS_MODEL|CORTEX_VOICE_TTS_LOCAL_VOICE|CORTEX_VOICE_TTS_POCKET_CACHE|CORTEX_VOICE_TTS_QWEN_MODEL|CORTEX_VOICE_TTS_QWEN_REVISION|CORTEX_VOICE_TTS_QWEN_CACHE|CORTEX_VOICE_TTS_QWEN_PROFILE|CORTEX_VOICE_TTS_QWEN_VOICE_PROMPT|CORTEX_VOICE_DUPLEX|CORTEX_VOICE_TTS_CAPABILITY_READY_WAIT_MS|CORTEX_VOICE_TTS_LOCAL_READY_GRACE_MS|CORTEX_VOICE_TTS_DAEMON_READY_TIMEOUT_MS|CORTEX_VOICE_TTS_LOCAL_RESPONSE_TIMEOUT_MS'
capture_preserved_config_lines() {
  [ -f "$CONFIG" ] || return 0
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ "$line" =~ ^($PRESERVED_CONFIG_KEYS)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      [ -n "$value" ] && printf '%s=%s\n' "$key" "$value"
    fi
  done < "$CONFIG"
}

restore_preserved_config_lines() {
  local saved="$1" line key
  [ -n "$saved" ] || return 0
  if ! touch "$CONFIG"; then
    warn "could not restore user settings to $CONFIG"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    [[ "$key" =~ ^($PRESERVED_CONFIG_KEYS)$ ]] || continue
    if ! grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG"; then
      # Prefix a newline so a legacy setup file without a final newline cannot
      # merge its last assignment with this restored one.
      printf '\n%s\n' "$line" >> "$CONFIG" \
        || { warn "could not restore $key to $CONFIG"; return 0; }
    fi
  done <<< "$saved"
}

refresh_grok_cli_home() {
  # xAI's installer stores auth/download metadata under ~/.grok even when its
  # GROK_BIN_DIR places the launcher in Cortex's configured provider home.
  GROK_CLI_HOME="${GROK_HOME:-$HOME/.grok}"
  GROK_CLI_BIN_DIR="$GROK_CLI_HOME/bin"
}

load_cli_overrides_from_config
refresh_grok_cli_home

# A CLI path set explicitly by the user is outside of Cortex's ownership.  The
# installer must never replace it just because a newer vendor build exists.
cli_override_is_set() {
  local variable="$1"
  [ -n "${!variable:-}" ]
}

# `readlink -f` is not available on the macOS version of readlink. Resolve a
# symlink chain ourselves so npm-managed CLIs linked through ~/.local/bin are
# still recognised as npm-managed rather than mistaken for custom binaries.
resolve_cli_path() {
  local path="$1" target parent
  [ -n "$path" ] || return 1
  case "$path" in
    /*) ;;
    *)
      parent="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
      path="$parent/$(basename "$path")"
      ;;
  esac
  while [ -L "$path" ]; do
    target="$(readlink "$path" 2>/dev/null || true)"
    [ -n "$target" ] || break
    case "$target" in
      /*) path="$target" ;;
      *)
        parent="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
        path="$parent/$target"
        ;;
    esac
  done
  parent="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "$parent" "$(basename "$path")"
}

# Return a PATH candidate other than ~/.local/bin. This lets us repair an old
# Cortex fallback symlink after a managed installer has put a newer command
# elsewhere on PATH, without ever replacing a regular user-owned file.
find_non_local_cli() {
  local name="$1" dir candidate old_ifs
  old_ifs="$IFS"
  IFS=":"
  for dir in $PATH; do
    [ -n "$dir" ] || dir="."
    [ "$dir" = "$LOCAL_BIN" ] && continue
    candidate="$dir/$name"
    if [ -x "$candidate" ]; then
      IFS="$old_ifs"
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  IFS="$old_ifs"
  return 1
}

# The local app's resolver prefers these paths, so inspect the same locations
# before terminal PATH. That prevents a custom fallback binary from being
# silently bypassed/overwritten during an installer rerun.
find_cli_bin() {
  local name="$1" canonical="$2" candidate
  for candidate in "$canonical" "$LOCAL_BIN/$name"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  command -v "$name" 2>/dev/null || true
}

cli_is_npm_managed() {
  local path="$1" package="$2" npm_root resolved
  command -v npm >/dev/null 2>&1 || return 1
  npm_root="$(npm root -g 2>/dev/null || true)"
  [ -n "$npm_root" ] || return 1
  resolved="$(resolve_cli_path "$path" 2>/dev/null || printf '%s' "$path")"
  npm_root="$(resolve_cli_path "$npm_root" 2>/dev/null || printf '%s' "$npm_root")"
  case "$resolved" in
    "$npm_root/$package"/*) return 0 ;;
  esac
  return 1
}

cli_is_claude_native() {
  local resolved
  resolved="$(resolve_cli_path "$1" 2>/dev/null || true)"
  case "$resolved" in
    "$HOME/.local/share/claude/versions/"*) return 0 ;;
  esac
  return 1
}

cli_is_codex_native() {
  local resolved
  resolved="$(resolve_cli_path "$1" 2>/dev/null || true)"
  case "$resolved" in
    "$HOME/.codex/packages/standalone/releases/"*) return 0 ;;
  esac
  return 1
}

cli_is_agy_native() {
  # Antigravity's official Unix installer owns this exact canonical path. A
  # differently located agy is treated as externally managed.
  [ "$(resolve_cli_path "$1" 2>/dev/null || true)" = "$LOCAL_BIN/agy" ]
}

cli_is_grok_native() {
  local resolved root
  resolved="$(resolve_cli_path "$1" 2>/dev/null || true)"
  # The upstream installer always keeps downloaded artifacts under ~/.grok,
  # even when GROK_BIN_DIR puts the launcher in a Cortex GROK_HOME override.
  # Accept both locations so an existing selected launcher is updated rather
  # than mistaken for an external executable.
  for root in "$HOME/.grok/downloads" "$GROK_CLI_HOME/downloads"; do
    case "$resolved" in
      "$root/grok-"*) return 0 ;;
    esac
  done
  return 1
}

show_cli_version() {
  local name="$1" bin="$2" version
  [ -n "$bin" ] && [ -x "$bin" ] || { warn "$name is not available after this installer run"; return 0; }
  version="$("$bin" --version 2>&1 | head -n 1 || true)"
  version="${version//$'\r'/}"
  if [ -n "$version" ]; then
    ok "$name: $bin ($version)"
  else
    ok "$name: $bin"
  fi
}

# Download the vendor installer before running it. Besides avoiding shell
# quoting surprises, this keeps the outer `curl | bash` installer stdin intact.
run_vendor_bash_installer() {
  local label="$1" url="$2" tmp status=1
  if ! command -v curl >/dev/null 2>&1; then
    warn "$label installer needs curl, but curl is unavailable"
    return 1
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/cortex-${label// /-}.XXXXXX")" || {
    warn "could not create a temporary file for the $label installer"
    return 1
  }
  if curl -fsSL --connect-timeout 15 --max-time 60 "$url" -o "$tmp"; then
    chmod 700 "$tmp" 2>/dev/null || true
    if bash "$tmp" </dev/null; then status=0; fi
  else
    warn "could not download the $label installer"
  fi
  rm -f "$tmp"
  return "$status"
}

run_codex_vendor_installer() {
  local tmp status=1
  if ! command -v curl >/dev/null 2>&1; then
    warn "Codex installer needs curl, but curl is unavailable"
    return 1
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/cortex-codex.XXXXXX")" || {
    warn "could not create a temporary file for the Codex installer"
    return 1
  }
  if curl -fsSL --connect-timeout 15 --max-time 60 https://chatgpt.com/codex/install.sh -o "$tmp"; then
    chmod 700 "$tmp" 2>/dev/null || true
    # Never prompt from a rerunnable Cortex installer. The official installer
    # still verifies the release archive and updates atomically.
    if CODEX_RELEASE=latest CODEX_NON_INTERACTIVE=1 bash "$tmp" </dev/null; then status=0; fi
  else
    warn "could not download the Codex installer"
  fi
  rm -f "$tmp"
  return "$status"
}

# Guarantee ~/.local/bin/<name> exists for a CLI the app drives.
#
# Cortex is launched from the macOS GUI (Finder/Dock), where PATH is launchd's
# minimal default (/usr/bin:/bin:/usr/sbin:/sbin) — NOT the login-shell PATH.
# So an npm-global `claude`/`codex` that works in Terminal is invisible to the
# app, and lib/paths.ts (findClaudeBin/findCodexBin) falls back to
# ~/.local/bin/<name>. If nothing is there the app spawns a missing path and
# dies with "spawn /Users/<user>/.local/bin/<name> ENOENT" at sign-in.
# Symlink whatever the CLI resolved to into ~/.local/bin so that fallback holds.
ensure_local_bin_link() {
  local name="$1" preferred="${2:-}" resolved local_path existing_real resolved_real
  mkdir -p "$LOCAL_BIN"
  hash -r 2>/dev/null || true
  local_path="$LOCAL_BIN/$name"
  if [ -n "$preferred" ] && [ -x "$preferred" ]; then
    resolved="$preferred"
  else
    resolved="$(find_non_local_cli "$name" 2>/dev/null || true)"
    [ -n "$resolved" ] || resolved="$(command -v "$name" 2>/dev/null || true)"
  fi
  if [ -z "$resolved" ]; then
    if [ -x "$local_path" ]; then
      ok "$name available at $local_path (app fallback path)"
    else
      warn "$name not found on PATH — the app expects it at $local_path"
    fi
    return 0
  fi
  if [ -e "$local_path" ] || [ -L "$local_path" ]; then
    if [ ! -L "$local_path" ]; then
      if [ "$local_path" != "$resolved" ]; then
        warn "leaving user-owned $local_path in place (not replacing it with $resolved)"
      else
        ok "$name available at $local_path (app fallback path)"
      fi
      return 0
    fi
    existing_real="$(resolve_cli_path "$local_path" 2>/dev/null || true)"
    resolved_real="$(resolve_cli_path "$resolved" 2>/dev/null || true)"
    if [ -n "$resolved_real" ] && [ "$existing_real" != "$resolved_real" ] && [ "$resolved" != "$local_path" ]; then
      ln -sfn "$resolved" "$local_path" \
        && ok "refreshed $name link → $local_path (now $resolved)" \
        || warn "could not refresh $name link in $LOCAL_BIN — sign-in may use an older CLI"
    else
      ok "$name available at $local_path (app fallback path)"
    fi
    return 0
  fi
  [ "$resolved" = "$local_path" ] && { ok "$name available at $local_path (app fallback path)"; return 0; }
  ln -s "$resolved" "$local_path" \
    && ok "linked $name → $local_path (was $resolved)" \
    || warn "could not link $name into $LOCAL_BIN — sign-in may fail with ENOENT"
}

# Ensure Node.js + npm are available.
#
# The Claude/Codex CLIs the bot drives are installed via `npm install -g`, and
# the app's MCP servers run on `node`. A machine with no Node has no npm, so
# those steps were silently skipped ("npm unavailable") and sign-in then failed.
# Install Node without assuming any package manager: prefer Homebrew when it's
# present, otherwise drop the official Node LTS build into ~/.local (its bin dir
# is already on PATH and is the app's CLI fallback root). Depends on $ARCH, so
# call this only after Preflight has set it.
ensure_node() {
  hash -r 2>/dev/null || true
  if command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
    ok "node: $(command -v node) · npm: $(command -v npm)"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    warn "node/npm not found — installing via Homebrew…"
    # `</dev/null`: the installer is run as `curl … | bash`, so the script IS
    # stdin. A real `brew install` reads stdin during its fetch/first-run path
    # and would swallow the rest of the script, silently ending the run right
    # after this step. Detach stdin so brew can't eat the remaining commands.
    if brew install node </dev/null >/dev/null 2>&1; then
      hash -r 2>/dev/null || true
      command -v npm >/dev/null 2>&1 && { ok "Node installed via Homebrew"; return 0; }
    fi
    warn "Homebrew node install failed — falling back to the official Node build"
  fi

  # Official prebuilt Node from nodejs.org — no package manager required. The
  # dist filenames use x64/arm64, matching our $ARCH values.
  local node_arch tmp url srcdir node_ver
  case "$ARCH" in
    arm64) node_arch="arm64" ;;
    x64)   node_arch="x64" ;;
    *) warn "cannot auto-install Node for arch $ARCH — install it from https://nodejs.org"; return 1 ;;
  esac
  warn "node/npm not found — downloading the official Node LTS build…"
  tmp="$(mktemp -d)"
  # index.json lists releases newest-first; the first entry whose "lts" is a
  # codename (not false) is the current LTS line. Derive its version and build
  # the versioned dist URL — the /latest-lts/ alias has no stable filename.
  # `|| true`: a non-matching grep in the pipeline must not abort the installer
  # under `set -euo pipefail` — the emptiness check below handles that case.
  node_ver="$(curl -fsSL --connect-timeout 15 --max-time 30 https://nodejs.org/dist/index.json 2>/dev/null \
    | tr '{' '\n' | grep '"lts":"' | head -1 \
    | grep -oE '"version":"v[0-9.]+"' | grep -oE 'v[0-9.]+' | head -1 || true)"
  if [ -z "$node_ver" ]; then
    warn "could not resolve the latest Node LTS version — install Node from https://nodejs.org"
    rm -rf "$tmp"; return 1
  fi
  url="https://nodejs.org/dist/${node_ver}/node-${node_ver}-darwin-${node_arch}.tar.gz"
  if ! curl -fL --connect-timeout 15 --speed-limit 1024 --speed-time 30 "$url" -o "$tmp/node.tar.gz"; then
    warn "Node download failed — install Node from https://nodejs.org"
    rm -rf "$tmp"; return 1
  fi
  if ! tar -xzf "$tmp/node.tar.gz" -C "$tmp"; then
    warn "could not extract Node archive"; rm -rf "$tmp"; return 1
  fi
  srcdir="$(find "$tmp" -maxdepth 1 -type d -name 'node-v*' | head -1)"
  if [ -z "$srcdir" ]; then
    warn "unexpected Node archive layout"; rm -rf "$tmp"; return 1
  fi
  # Merge the toolchain into ~/.local so bin/node + bin/npm land on PATH and the
  # npm symlink still resolves against ~/.local/lib/node_modules.
  mkdir -p "$HOME/.local/bin" "$HOME/.local/lib" "$HOME/.local/include" "$HOME/.local/share"
  cp -R "$srcdir/bin/." "$HOME/.local/bin/" 2>/dev/null || true
  cp -R "$srcdir/lib/." "$HOME/.local/lib/" 2>/dev/null || true
  cp -R "$srcdir/include/." "$HOME/.local/include/" 2>/dev/null || true
  cp -R "$srcdir/share/." "$HOME/.local/share/" 2>/dev/null || true
  rm -rf "$tmp"
  export PATH="$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null || true
  if command -v npm >/dev/null 2>&1; then
    ok "Node installed → $(command -v node)"
    return 0
  fi
  warn "Node install did not put npm on PATH — install Node from https://nodejs.org"
  return 1
}

echo "Cortex — installer"

# ── Preflight ───────────────────────────────────────────
step "Preflight"
[ "$(uname -s)" = "Darwin" ] || die "This installer is macOS-only (found $(uname -s))."
# Use the hardware capability bit, not `uname -m`: under Rosetta (e.g. a
# Terminal with "Open using Rosetta" enabled) `uname -m` reports x86_64 even
# on Apple Silicon, which would download the wrong-arch .app entirely.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
  ARCH="arm64"
elif [ "$(uname -m)" = "x86_64" ]; then
  ARCH="x64"
else
  die "Unsupported architecture: $(uname -m)"
fi
if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null)" = "1" ]; then
  warn "running translated under Rosetta — installing native $ARCH build anyway"
fi
ok "macOS / $ARCH"

APP_ZIP="Cortex-${ARCH}.zip"
SUPPORT_TAR="support.tar.gz"
POCKET_MODEL_ASSET="Pocket-English-model.tar.gz"
POCKET_MODEL_REPOSITORY="appfactory123/pocket-tts-model-weight-dist"
POCKET_MODEL_RELEASE_TAG="pocket-tts-v2.1.0-english-1"
POCKET_MODEL_RELEASE_ASSET_ID="494264404"
POCKET_MODEL_ROOT="$HOME/.cortex-ai-sessions/voice-tts/pocket-model"
POCKET_MODEL_SHA256="473f47d99560bd50eb8b4509d3cacfe7f316ab20bdca86505403a2e6a936a6e9"
POCKET_TOKENIZER_SHA256="d461765ae179566678c93091c5fa6f2984c31bbe990bf1aa62d92c64d91bc3f6"

WORK="$(mktemp -d)"
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$APP_BACKUP" ] && [ -d "$APP_BACKUP" ]; then
    if [ ! -d "$APP_PATH" ]; then
      mv "$APP_BACKUP" "$APP_PATH" 2>/dev/null || true
    else
      rm -rf "$APP_BACKUP"
    fi
  fi
  if [ "$IN_APP_UPDATE" = "1" ] \
     && [ -n "$APP_RELAUNCH_REQUIRED" ] \
     && [ -z "$APP_RELAUNCHED" ]; then
    relaunch_installed_app || true
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

# Resolve the release and its assets (skipped entirely in local mode).
#   • Default (no token): resolve the PUBLIC dist repo's latest release through
#     the normal GitHub release redirect, then download assets from deterministic
#     public release URLs. This avoids anonymous GitHub API rate limits.
#   • Token present: authenticated request to the PRIVATE source repo; the
#     release JSON lists each asset with a numeric id, downloaded from the assets
#     endpoint with `Accept: application/octet-stream` (the browser_download_url
#     404s for private repos).
REL_JSON=""
SOURCE_REPO="$PUBLIC_REPO"
TAG=""
if [ -z "${CORTEX_LOCAL_DIR:-}" ]; then
  step "Locating release"
  REF="latest"
  [ -n "${CORTEX_VERSION:-}" ] && REF="tags/${CORTEX_VERSION}"
  if [ -n "$TOKEN" ]; then
    SOURCE_REPO="$REPO"
    REL_JSON="$(curl -fsSL --connect-timeout 15 --max-time 30 \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${REPO}/releases/${REF}")" \
      || die "Could not fetch the release from ${REPO} (bad token, no read access, no release published yet, or the connection stalled)."
    TAG="$(printf '%s' "$REL_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')"
  else
    if [ -n "${CORTEX_VERSION:-}" ]; then
      TAG="$CORTEX_VERSION"
    else
      LATEST_URL="$(curl -fsSL --connect-timeout 15 --max-time 30 -o /dev/null -w '%{url_effective}' \
        "https://github.com/${PUBLIC_REPO}/releases/latest")" \
        || die "Could not resolve the latest release from ${PUBLIC_REPO} (no response or the connection stalled)."
      TAG="${LATEST_URL##*/}"
      [ -n "$TAG" ] && [ "$TAG" != "latest" ] \
        || die "Could not resolve the latest release tag from ${PUBLIC_REPO}."
    fi
  fi
  ok "release ${TAG:-?} (${SOURCE_REPO})"
fi

# asset_id <name> — print the numeric id of the named asset from REL_JSON.
# GitHub returns pretty-printed JSON; within an asset object "id" precedes
# "name", so the last id seen before a matching name line is the asset's id.
asset_id() {
  awk -v want="$1" '
    /"id":/ { v=$0; gsub(/[^0-9]/,"",v); last=v }
    $0 ~ ("\"name\": \"" want "\"") { print last; exit }
  ' <<<"$REL_JSON"
}

# asset_url <name> — print the public browser_download_url of the named asset.
# Within each asset object "name" precedes "browser_download_url", so once the
# matching name is seen the next browser_download_url is that asset's.
asset_url() {
  awk -v want="$1" '
    $0 ~ ("\"name\": \"" want "\"") { found=1 }
    found && /"browser_download_url":/ {
      u=$0; sub(/.*"browser_download_url":[[:space:]]*"/,"",u); sub(/".*/,"",u);
      print u; exit
    }
  ' <<<"$REL_JSON"
}

# dl <asset-name> <dest> — fetch a release asset (local copy, public anonymous
# download, or private authenticated download depending on mode).
dl() {
  local name="$1" dest="$2" id url
  if [ -n "${CORTEX_LOCAL_DIR:-}" ]; then
    cp "$CORTEX_LOCAL_DIR/$name" "$dest" \
      || die "missing local artifact: $CORTEX_LOCAL_DIR/$name"
  elif [ -n "$TOKEN" ]; then
    id="$(asset_id "$name")"
    [ -n "$id" ] || die "release ${TAG:-?} has no asset named $name"
    # --speed-limit/--speed-time abort a genuinely stalled transfer (sustained
    # near-zero throughput) without penalizing a slow-but-active download, which
    # a hard --max-time would.
    retry 3 curl -fL --progress-bar --connect-timeout 15 --speed-limit 1024 --speed-time 30 --continue-at - \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/octet-stream" \
      "https://api.github.com/repos/${REPO}/releases/assets/${id}" -o "$dest" \
      || die "download failed: $name (no response or the connection stalled after 3 attempts)"
  else
    url="https://github.com/${PUBLIC_REPO}/releases/download/${TAG}/${name}"
    retry 3 curl -fL --progress-bar --connect-timeout 15 --speed-limit 1024 --speed-time 30 --continue-at - "$url" -o "$dest" \
      || die "download failed: $name (no response or the connection stalled after 3 attempts)"
  fi
}

# dl_pocket_model <dest> — Pocket's immutable public release is deliberately
# separate from each Cortex app release. This keeps the large weight asset out
# of app updates while the pinned release asset and file checksums keep the
# model input deterministic. A local artifact remains available for installer
# testing.
dl_pocket_model() {
  local dest="$1" url
  if [ -n "${CORTEX_LOCAL_DIR:-}" ] && [ -f "$CORTEX_LOCAL_DIR/$POCKET_MODEL_ASSET" ]; then
    cp "$CORTEX_LOCAL_DIR/$POCKET_MODEL_ASSET" "$dest" \
      || die "could not copy local Pocket model artifact"
    return 0
  fi
  # GitHub's asset API resolves the immutable public asset to a short-lived
  # storage redirect. It does not require a token and avoids app-release asset
  # discovery or the regular release page's cache propagation delay.
  url="https://api.github.com/repos/${POCKET_MODEL_REPOSITORY}/releases/assets/${POCKET_MODEL_RELEASE_ASSET_ID}"
  retry 3 curl -fL --progress-bar --connect-timeout 15 --speed-limit 1024 --speed-time 30 --continue-at - \
    -H "Accept: application/octet-stream" \
    "$url" -o "$dest" \
    || die "could not download the verified Pocket model release (${POCKET_MODEL_REPOSITORY}@${POCKET_MODEL_RELEASE_TAG})"
}

# ── Prepare update assets while the old app remains usable ───────────────
step "Preparing update assets"
dl "$APP_ZIP" "$WORK/$APP_ZIP"
ok "downloaded $APP_ZIP"
ditto -x -k "$WORK/$APP_ZIP" "$WORK/app" || die "could not unzip $APP_ZIP"
SRC_APP="$(find "$WORK/app" -maxdepth 2 -name '*.app' -type d | head -n1)"
[ -n "$SRC_APP" ] || die "no .app found inside $APP_ZIP"
# A Develop build renames its bundle (customizeCortexDevelopAppIdentity in the
# Cortex repository) so it can live beside the released Cortex. Install under the
# name that was actually built: with the default name, that build replaces
# /Applications/Cortex.app and the user loses the app they were already running.
APP_NAME="$(basename "$SRC_APP" .app)"
APP_PATH="/Applications/${APP_NAME}.app"
if [ -z "${CORTEX_DATA_DIR:-}" ]; then
  # The log stays where this run opened it; everything else follows the app.
  DATA_DIR="$(app_data_dir "$APP_NAME")"
  CONFIG="$DATA_DIR.env"
  mkdir -p "$DATA_DIR"
fi
dl "$SUPPORT_TAR" "$WORK/$SUPPORT_TAR"
mkdir -p "$WORK/support"
tar -xzf "$WORK/$SUPPORT_TAR" -C "$WORK/support" || die "could not extract $SUPPORT_TAR"
ok "prepared app + support files"

# ── Install the .app ────────────────────────────────────
step "Installing ${APP_NAME}.app"
[ "$IN_APP_UPDATE" = "1" ] && APP_RELAUNCH_REQUIRED=1
quit_running_app
refresh_launchservices unregister
# /Applications is writable by admins without sudo, but a locked bundle, a
# managed (MDM) volume, or a non-admin account will block the swap. Check up
# front so the failure names the real cause instead of a generic "permissions?".
APP_DIR="$(dirname "$APP_PATH")"
[ -w "$APP_DIR" ] || die "cannot write to $APP_DIR — install as an admin user, or move ${APP_NAME}.app there manually from $WORK/app"
if [ -e "$APP_PATH" ]; then
  # Keep the previous bundle beside the destination until the replacement is
  # complete. A failed copy can then restore the runnable old app before the
  # relaunch failsafe fires.
  APP_BACKUP="$APP_DIR/.${APP_NAME}.app.cortex-update-backup-$$"
  rm -rf "$APP_BACKUP"
  if ! mv "$APP_PATH" "$APP_BACKUP" 2>/dev/null; then
    quit_running_app
    mv "$APP_PATH" "$APP_BACKUP" 2>/dev/null \
      || die "could not move the old ${APP_NAME}.app for replacement — quit ${APP_NAME} fully, then re-run the installer"
  fi
fi
# Prefer mv (atomic on the same volume); fall back to a ditto copy when the
# source and /Applications live on different volumes, where mv can fail.
if ! mv "$SRC_APP" "$APP_PATH" 2>/dev/null; then
  rm -rf "$APP_PATH" 2>/dev/null || true
  if ! ditto "$SRC_APP" "$APP_PATH"; then
    rm -rf "$APP_PATH" 2>/dev/null || true
    if [ -n "$APP_BACKUP" ] && [ -d "$APP_BACKUP" ]; then
      if mv "$APP_BACKUP" "$APP_PATH" 2>/dev/null; then
        APP_BACKUP=""
      fi
    fi
    die "could not install the app into $APP_DIR — restored the previous app when possible; check that the volume isn't full or read-only, then re-run"
  fi
fi
if [ -n "$APP_BACKUP" ] && [ -d "$APP_BACKUP" ]; then
  rm -rf "$APP_BACKUP"
  APP_BACKUP=""
fi
ok "installed → $APP_PATH"
refresh_launchservices register
INSTALLED_TAG="$(installed_build_tag)"
if [ -n "$INSTALLED_TAG" ]; then
  ok "installed build ${INSTALLED_TAG}"
elif [ -n "$TAG" ]; then
  warn "could not read bundled build tag; expected release ${TAG}"
fi
# Unsigned build: clear the quarantine flag so Gatekeeper doesn't block launch.
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null && ok "cleared quarantine" \
  || warn "could not clear quarantine — right-click → Open on first launch"

# ── Provision data dir ──────────────────────────────────
step "Provisioning $DATA_DIR"
mkdir -p "$DATA_DIR"
ditto "$WORK/support" "$DATA_DIR" || die "could not install the prepared support files"
chmod +x "$DATA_DIR"/*.command "$DATA_DIR"/*.sh 2>/dev/null || true
ok "extracted bot + support files"

# The packaged app is self-contained. Bring the new UI back immediately after
# the atomic bundle/support swap; the detached installer keeps running and the
# relaunched app resumes progress from update.log while dependencies finish.
if [ "$IN_APP_UPDATE" = "1" ]; then
  relaunch_installed_app \
    || warn "${APP_NAME} has not relaunched yet; the exit failsafe will retry"
fi

# ── Pocket release model ───────────────────────────────
# The model lives in an immutable, dedicated GitHub Release rather than inside
# Cortex.app or Git history. The helper accepts only the pinned archive shape
# and checksums, then runs offline after this point.
pocket_file_matches() {
  [ -f "$1" ] && [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ]
}

pocket_release_model_ready() {
  pocket_file_matches "$POCKET_MODEL_ROOT/model.safetensors" "$POCKET_MODEL_SHA256" \
    && pocket_file_matches "$POCKET_MODEL_ROOT/tokenizer.model" "$POCKET_TOKENIZER_SHA256"
}

step "Pocket voice model"
if pocket_release_model_ready; then
  ok "verified Pocket model already installed"
else
  [ ! -L "$POCKET_MODEL_ROOT" ] || die "Pocket model directory must not be a symlink: $POCKET_MODEL_ROOT"
  mkdir -p "$POCKET_MODEL_ROOT" || die "could not create Pocket model directory"
  chmod 700 "$POCKET_MODEL_ROOT" 2>/dev/null || true
  [ ! -L "$POCKET_MODEL_ROOT/model.safetensors" ] || die "Pocket model file must not be a symlink"
  [ ! -L "$POCKET_MODEL_ROOT/tokenizer.model" ] || die "Pocket tokenizer file must not be a symlink"
  dl_pocket_model "$WORK/$POCKET_MODEL_ASSET"
  MODEL_STAGE="$(mktemp -d "$POCKET_MODEL_ROOT/.release.XXXXXX")"
  MODEL_CONTENTS="$(tar -tzf "$WORK/$POCKET_MODEL_ASSET")" \
    || die "could not inspect $POCKET_MODEL_ASSET"
  [ "$MODEL_CONTENTS" = $'model.safetensors\ntokenizer.model' ] \
    || die "$POCKET_MODEL_ASSET has unexpected contents"
  tar -xzf "$WORK/$POCKET_MODEL_ASSET" -C "$MODEL_STAGE" \
    || die "could not extract $POCKET_MODEL_ASSET"
  pocket_file_matches "$MODEL_STAGE/model.safetensors" "$POCKET_MODEL_SHA256" \
    && pocket_file_matches "$MODEL_STAGE/tokenizer.model" "$POCKET_TOKENIZER_SHA256" \
    || die "$POCKET_MODEL_ASSET failed checksum verification"
  mv "$MODEL_STAGE/model.safetensors" "$POCKET_MODEL_ROOT/model.safetensors" \
    && mv "$MODEL_STAGE/tokenizer.model" "$POCKET_MODEL_ROOT/tokenizer.model" \
    && rmdir "$MODEL_STAGE" \
    || die "could not install the verified Pocket model"
  chmod 600 "$POCKET_MODEL_ROOT/model.safetensors" "$POCKET_MODEL_ROOT/tokenizer.model" 2>/dev/null || true
  ok "downloaded and verified Pocket model"
fi

# ── Bun (required for Node deps + the bot) ──────────────
step "Bun"
if command -v bun >/dev/null 2>&1; then
  ok "bun: $(command -v bun)"
else
  warn "bun not found — installing…"
  retry 3 bash -c 'curl -fsSL --connect-timeout 15 --max-time 60 https://bun.sh/install | bash' \
    || die "bun install failed (could not download from bun.sh after 3 attempts — check your network, then re-run)"
  export PATH="$HOME/.bun/bin:$PATH"
  command -v bun >/dev/null 2>&1 && ok "bun installed" || die "bun still not on PATH — add \$HOME/.bun/bin to PATH, then re-run"
fi

# ── Node.js + npm (runtime for MCP servers and npm-managed provider CLIs) ──
step "Node.js"
ensure_node || warn "continuing without Node — npm-managed provider CLIs and node-based MCP servers may be unavailable"

# ── Delegate Node + Python deps + config to setup.command ─
# setup.command (run from the data dir) installs Node deps via bun, installs the
# Python libs, and writes ~/.cortex-ai-sessions.env → the data dir. Reusing it keeps
# dependency logic in one place.
step "Dependencies (delegating to setup.command)"
# Snapshot config-file overrides before setup.command rewrites the shared config;
# restore them after delegation as well because the support bundle can predate
# the setup-side preservation logic.
PRESERVED_CONFIG_BACKUP="$(capture_preserved_config_lines)"
load_cli_overrides_from_config
refresh_grok_cli_home
( cd "$DATA_DIR" && \
  CORTEX_RELEASE_INSTALL=1 \
  CORTEX_DATA_DIR="$DATA_DIR" \
  CORTEX_VOICE_TTS_BUNDLED_ASSET_DIR="$APP_PATH/Contents/Resources/standalone/scripts/voice-assets" \
  bash setup.command ) || warn "setup.command reported problems (see above)"
restore_preserved_config_lines "$PRESERVED_CONFIG_BACKUP"
load_cli_overrides_from_config
refresh_grok_cli_home

# ── Managed realtime speech model ──────────────────────
# Prefer MLX only where upstream supports it. The provisioner retries MLX and
# then installs OpenAI Whisper in the same managed runtime if MLX's package or
# Hugging Face model cannot be prepared. A speech failure must not prevent the
# text application from installing; Live voice exposes the same repair action.
step "Realtime speech model"
STT_RUNTIME_DIR="$HOME/Library/Application Support/Cortex/voice-stt"
STT_PROVISIONER="$APP_PATH/Contents/Resources/standalone/scripts/provision-realtime-stt.sh"
STT_DAEMON="$APP_PATH/Contents/Resources/standalone/scripts/stt_daemon.py"
STT_VOICE_TTS_PYTHON="$HOME/.cortex-ai-sessions/voice-tts/.venv/bin/python3"
STT_CONFIG_TTS_PYTHON=""
STT_CONFIG_PYTHON=""

stt_python_is_compatible() {
  [ -n "$1" ] && [ -x "$1" ] \
    && "$1" -c 'import platform, sys
expected = "arm64" if sys.argv[1] == "arm64" else "x86_64"
ok = platform.system() == "Darwin" and platform.machine() == expected and (3, 10) <= sys.version_info[:2] < (3, 13)
sys.exit(0 if ok else 1)' "$ARCH" >/dev/null 2>&1
}

stt_macos_supports_mlx() {
  local version major remainder minor
  version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
  major="${version%%.*}"
  remainder="${version#*.}"
  minor="${remainder%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] && [[ "$minor" =~ ^[0-9]+$ ]] || return 1
  [ "$major" -gt 13 ] || { [ "$major" -eq 13 ] && [ "$minor" -ge 5 ]; }
}

stt_uv_is_compatible() {
  local description
  [ -n "$1" ] && [ -x "$1" ] || return 1
  description="$(/usr/bin/file -L "$1" 2>/dev/null || true)"
  if [ "$ARCH" = "arm64" ]; then
    [[ "$description" == *arm64* ]]
  else
    [[ "$description" == *x86_64* ]]
  fi
}

# setup.command normally leaves a native Python 3.10–3.12 Pocket TTS venv behind.
# Read its persisted path and PYTHON_BIN as inert values in case either points
# somewhere else; never source the credential-bearing config file.
if [ -f "$CONFIG" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^(CORTEX_VOICE_TTS_PYTHON|PYTHON_BIN)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
      esac
      if [ "$key" = "CORTEX_VOICE_TTS_PYTHON" ]; then
        STT_CONFIG_TTS_PYTHON="$value"
      else
        STT_CONFIG_PYTHON="$value"
      fi
    fi
  done < "$CONFIG"
fi

STT_BASE_PYTHON=""
for candidate in \
  "${CORTEX_VOICE_PYTHON:-}" \
  "${CORTEX_VOICE_TTS_PYTHON:-}" \
  "$STT_CONFIG_TTS_PYTHON" \
  "$STT_VOICE_TTS_PYTHON" \
  "${PYTHON_BIN:-}" \
  "$STT_CONFIG_PYTHON" \
  "$(command -v python3.12 || true)" \
  "$(command -v python3.11 || true)" \
  "$(command -v python3.10 || true)" \
  "$HOME/.local/bin/python3.12" \
  /opt/homebrew/bin/python3.12 \
  /usr/local/bin/python3.12 \
  /opt/homebrew/bin/python3.11 \
  /usr/local/bin/python3.11 \
  /opt/homebrew/bin/python3.10 \
  /usr/local/bin/python3.10 \
  /opt/homebrew/bin/python3 \
  /usr/local/bin/python3 \
  /usr/bin/python3 \
  "$(command -v python3 || true)"; do
  if stt_python_is_compatible "$candidate"; then
    STT_BASE_PYTHON="$candidate"
    break
  fi
done

# A clean Mac may have only Apple's older system Python. Bootstrap uv and its
# architecture-native Python 3.12 as a final managed base instead of failing
# the entire Cortex installation.
if [ -z "$STT_BASE_PYTHON" ]; then
  STT_UV="$(command -v uv || true)"
  for candidate in "$STT_UV" "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
    stt_uv_is_compatible "$candidate" && { STT_UV="$candidate"; break; }
  done
  if ! stt_uv_is_compatible "$STT_UV"; then
    echo "  installing uv to provision a native Python 3.12 speech runtime…"
    if [ "$ARCH" = "arm64" ]; then
      curl --proto '=https' --tlsv1.2 -LsSf https://astral.sh/uv/install.sh \
        | env UV_NO_MODIFY_PATH=1 arch -arm64 /bin/sh \
        || warn "uv installation failed; Live voice can be repaired later"
    else
      curl --proto '=https' --tlsv1.2 -LsSf https://astral.sh/uv/install.sh \
        | env UV_NO_MODIFY_PATH=1 /bin/sh \
        || warn "uv installation failed; Live voice can be repaired later"
    fi
    STT_UV=""
    for candidate in "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
      stt_uv_is_compatible "$candidate" && { STT_UV="$candidate"; break; }
    done
  fi
  if stt_uv_is_compatible "$STT_UV"; then
    echo "  provisioning managed Python 3.12 for realtime speech…"
    "$STT_UV" python install 3.12 >/dev/null \
      || warn "managed Python 3.12 download failed"
    STT_UV_PYTHON="$("$STT_UV" python find 3.12 2>/dev/null || true)"
    stt_python_is_compatible "$STT_UV_PYTHON" && STT_BASE_PYTHON="$STT_UV_PYTHON"
  fi
fi

STT_ENGINE="whisper"
if [ "$ARCH" = "arm64" ] && stt_macos_supports_mlx; then
  STT_ENGINE="mlx"
elif [ "$ARCH" = "arm64" ]; then
  ok "this macOS version does not support MLX — selecting managed OpenAI Whisper"
else
  ok "Intel Mac detected — selecting managed OpenAI Whisper"
fi

if [ ! -f "$STT_PROVISIONER" ] || [ ! -f "$STT_DAEMON" ]; then
  warn "the installed app is missing realtime speech support files; text features remain available"
elif ! stt_python_is_compatible "$STT_BASE_PYTHON"; then
  warn "no native Python 3.10–3.12 runtime is available; install completed without local speech recognition"
elif CORTEX_STT_ENGINE="$STT_ENGINE" bash "$STT_PROVISIONER" \
  "$STT_RUNTIME_DIR" \
  "$STT_BASE_PYTHON" \
  "$STT_DAEMON" \
  "${INSTALLED_TAG:-unknown}"; then
  STT_INSTALLED_ENGINE="$(awk -F= '$1 == "engine" { print $2; exit }' "$STT_RUNTIME_DIR/release-provisioned" 2>/dev/null || true)"
  ok "verified managed realtime speech (${STT_INSTALLED_ENGINE:-$STT_ENGINE})"
else
  warn "local speech provisioning failed; Cortex installed and Live voice can retry from the app"
fi

# ── Managed local CLI updates ───────────────────────────
# A rerunnable Cortex installer is an explicit request to bring the local
# providers it owns to their current stable releases. Never replace a CLI that
# was selected via an explicit *_BIN override or that lives outside the vendor
# and npm locations recognised below: those are user-managed installations.

update_claude_cli() {
  local bin
  step "Claude CLI"
  if cli_override_is_set CLAUDE_BIN; then
    warn "CLAUDE_BIN is set; leaving that user-managed Claude CLI unchanged"
    return 0
  fi
  bin="$(find_cli_bin claude "$LOCAL_BIN/claude")"
  if [ -z "$bin" ]; then
    warn "claude not found — installing the latest stable Claude CLI…"
    if run_vendor_bash_installer "Claude-CLI" https://claude.ai/install.sh; then
      ok "Claude CLI installed via the official installer"
    elif command -v npm >/dev/null 2>&1; then
      warn "official Claude installer failed; trying npm's latest package…"
      npm install -g '@anthropic-ai/claude-code@latest' </dev/null \
        && ok "Claude CLI installed via npm" \
        || warn "npm fallback failed — run: npm install -g @anthropic-ai/claude-code"
    else
      warn "Claude CLI could not be installed — install it from https://claude.ai/install"
    fi
  elif cli_is_npm_managed "$bin" '@anthropic-ai/claude-code'; then
    warn "updating npm-managed Claude CLI…"
    npm install -g '@anthropic-ai/claude-code@latest' </dev/null \
      && ok "Claude CLI updated via npm" \
      || warn "Claude npm update failed — keeping the existing CLI"
  elif cli_is_claude_native "$bin"; then
    warn "checking for a Claude CLI update…"
    if "$bin" update </dev/null; then
      ok "Claude CLI update completed"
    else
      warn "claude update failed; retrying with the official installer…"
      run_vendor_bash_installer "Claude-CLI" https://claude.ai/install.sh \
        && ok "Claude CLI updated via the official installer" \
        || warn "Claude CLI update failed — keeping the existing CLI"
    fi
  else
    warn "leaving externally managed Claude CLI unchanged: $bin"
  fi
  hash -r 2>/dev/null || true
  bin="$(find_cli_bin claude "$LOCAL_BIN/claude")"
  show_cli_version "claude" "$bin"
  # The GUI-launched app resolves claude at ~/.local/bin/claude. Only refresh a
  # symlink; a regular file at that path remains user-owned.
  ensure_local_bin_link claude "$bin"
}

update_codex_cli() {
  local bin
  step "Codex CLI"
  if cli_override_is_set CODEX_BIN; then
    warn "CODEX_BIN is set; leaving that user-managed Codex CLI unchanged"
    return 0
  fi
  bin="$(find_cli_bin codex "$LOCAL_BIN/codex")"
  if [ -z "$bin" ]; then
    warn "codex not found — installing the latest stable Codex CLI…"
    if run_codex_vendor_installer; then
      ok "Codex CLI installed via the official installer"
    elif command -v npm >/dev/null 2>&1; then
      warn "official Codex installer failed; trying npm's latest package…"
      npm install -g '@openai/codex@latest' </dev/null \
        && ok "Codex CLI installed via npm" \
        || warn "npm fallback failed — run: npm install -g @openai/codex"
    else
      warn "Codex CLI could not be installed — install it from https://chatgpt.com/codex/install.sh"
    fi
  elif cli_is_npm_managed "$bin" '@openai/codex'; then
    warn "updating npm-managed Codex CLI…"
    npm install -g '@openai/codex@latest' </dev/null \
      && ok "Codex CLI updated via npm" \
      || warn "Codex npm update failed — keeping the existing CLI"
  elif cli_is_codex_native "$bin"; then
    warn "updating the official Codex CLI…"
    run_codex_vendor_installer \
      && ok "Codex CLI update completed" \
      || warn "Codex CLI update failed — keeping the existing CLI"
  else
    warn "leaving externally managed Codex CLI unchanged: $bin"
  fi
  hash -r 2>/dev/null || true
  bin="$(find_cli_bin codex "$LOCAL_BIN/codex")"
  show_cli_version "codex" "$bin"
  # Same GUI-PATH fallback as Claude. This also repairs an older symlink when
  # a managed updater has provided a newer target elsewhere on PATH.
  ensure_local_bin_link codex "$bin"
}

update_agy_cli() {
  local bin
  step "Antigravity CLI"
  if cli_override_is_set AGY_BIN; then
    warn "AGY_BIN is set; leaving that user-managed Antigravity CLI unchanged"
    return 0
  fi
  bin="$(find_cli_bin agy "$LOCAL_BIN/agy")"
  if [ -z "$bin" ]; then
    warn "agy not found — installing the latest stable Antigravity CLI…"
    run_vendor_bash_installer "Antigravity-CLI" https://antigravity.google/cli/install.sh \
      && ok "Antigravity CLI installed via the official installer" \
      || warn "Antigravity CLI install failed — keeping Cortex installation running"
  elif cli_is_agy_native "$bin"; then
    # The vendor's bootstrap script deliberately does not replace a preexisting
    # agy binary; its native updater is the supported rerun/update mechanism.
    warn "checking for an Antigravity CLI update…"
    "$bin" update </dev/null \
      && ok "Antigravity CLI update completed" \
      || warn "Antigravity CLI update failed — keeping the existing CLI"
  else
    warn "leaving externally managed Antigravity CLI unchanged: $bin"
  fi
  hash -r 2>/dev/null || true
  bin="$(find_cli_bin agy "$LOCAL_BIN/agy")"
  show_cli_version "agy" "$bin"
}

update_grok_cli() {
  local bin
  step "Grok CLI"
  if cli_override_is_set GROK_BIN; then
    warn "GROK_BIN is set; leaving that user-managed Grok CLI unchanged"
    return 0
  fi
  bin="$(find_cli_bin grok "$GROK_CLI_BIN_DIR/grok")"
  if [ -z "$bin" ]; then
    warn "grok not found — installing the latest stable Grok CLI…"
    GROK_CHANNEL=stable GROK_BIN_DIR="$GROK_CLI_BIN_DIR" \
      run_vendor_bash_installer "Grok-CLI" https://x.ai/cli/install.sh \
      && ok "Grok CLI installed via the official installer" \
      || warn "Grok CLI install failed — keeping Cortex installation running"
  elif cli_is_npm_managed "$bin" '@xai-official/grok'; then
    warn "updating npm-managed Grok CLI…"
    npm install -g '@xai-official/grok@latest' </dev/null \
      && ok "Grok CLI updated via npm" \
      || warn "Grok npm update failed — keeping the existing CLI"
  elif cli_is_grok_native "$bin"; then
    warn "checking for a Grok CLI update…"
    "$bin" update --check --json </dev/null \
      || warn "Grok CLI could not complete its update check; attempting an update in its selected channel"
    "$bin" update </dev/null \
      && ok "Grok CLI update completed" \
      || warn "Grok CLI update failed — keeping the existing CLI"
  else
    warn "leaving externally managed Grok CLI unchanged: $bin"
  fi
  hash -r 2>/dev/null || true
  bin="$(find_cli_bin grok "$GROK_CLI_BIN_DIR/grok")"
  show_cli_version "grok" "$bin"
}

if [ "$IN_APP_UPDATE" = "1" ]; then
  step "Provider CLI updates"
  ok "skipped during app self-update; provider updates remain explicit in About"
else
  update_claude_cli
  update_codex_cli
  update_agy_cli
  update_grok_cli
fi

# ── Computer-control MCP server (mouse / keyboard / screen) ─
# Cortex injects this MCP server per opted-in session. Do not register it at
# user/global CLI scope here; remove stale global registrations from older
# installs, then run the live server selftest.
step "Computer-control MCP server"
MCP_SERVER="$DATA_DIR/scripts/computer-mcp/server.mjs"
MCP_NODE="$(command -v node || echo node)"
if [ ! -f "$MCP_SERVER" ]; then
  warn "server.mjs not in support bundle — skipping computer-control selftest"
elif [ ! -d "$DATA_DIR/node_modules/@nut-tree-fork/nut-js" ]; then
  warn "MCP Node deps missing — re-run setup.command, then test again"
else
  if command -v claude >/dev/null 2>&1; then
    claude mcp remove -s user computer_control >/dev/null 2>&1 || true
    ok "removed stale Claude computer-control registration"
  else
    warn "claude CLI missing — skipped stale Claude registration cleanup"
  fi
  if command -v codex >/dev/null 2>&1; then
    codex mcp remove computer_control >/dev/null 2>&1 || true
    ok "removed stale Codex computer-control registration"
  else
    warn "codex CLI missing — skipped stale Codex registration cleanup"
  fi
  MCP_SELFTEST="$DATA_DIR/scripts/computer-mcp/selftest.mjs"
  if [ -f "$MCP_SELFTEST" ]; then
    if "$MCP_NODE" "$MCP_SELFTEST" --node "$MCP_NODE" --server "$MCP_SERVER" >/dev/null 2>&1; then
      ok "computer-control selftest passed"
    else
      warn "computer-control selftest failed — live tool calls need attention"
    fi
  else
    warn "selftest.mjs missing — could not verify live computer-control tool calls"
  fi
  warn "Grant Accessibility + Screen Recording to the app (System Settings → Privacy & Security) for mouse/screen control."
fi

# ── Obsidian MCP server (vault read/write for agent sessions) ─
# Cortex injects this MCP server per opted-in session (composer "Obsidian"
# toggle). Do not register it at user/global CLI scope here; remove stale
# global registrations from older setups, then run the live server selftest.
step "Obsidian MCP server"
OBSIDIAN_MCP_SERVER="$DATA_DIR/scripts/obsidian-mcp/server.mjs"
if [ ! -f "$OBSIDIAN_MCP_SERVER" ]; then
  warn "server.mjs not in support bundle — skipping Obsidian MCP selftest"
else
  if command -v claude >/dev/null 2>&1; then
    claude mcp remove -s user obsidian >/dev/null 2>&1 || true
    claude mcp remove -s local obsidian >/dev/null 2>&1 || true
    ok "removed stale Claude obsidian registration"
  else
    warn "claude CLI missing — skipped stale Claude registration cleanup"
  fi
  if command -v codex >/dev/null 2>&1; then
    codex mcp remove obsidian >/dev/null 2>&1 || true
    ok "removed stale Codex obsidian registration"
  else
    warn "codex CLI missing — skipped stale Codex registration cleanup"
  fi
  if ! command -v obsidian >/dev/null 2>&1; then
    warn "obsidian CLI not found — install Obsidian ≥1.12 and enable it (Settings → General → Command line interface)"
  else
    OBSIDIAN_MCP_SELFTEST="$DATA_DIR/scripts/obsidian-mcp/selftest.mjs"
    if [ -f "$OBSIDIAN_MCP_SELFTEST" ]; then
      if "$MCP_NODE" "$OBSIDIAN_MCP_SELFTEST" "$OBSIDIAN_MCP_SERVER" >/dev/null 2>&1; then
        ok "Obsidian MCP selftest passed"
      else
        warn "Obsidian MCP selftest failed — the Obsidian app must be running with a vault open"
      fi
    else
      warn "selftest.mjs missing — could not verify live Obsidian tool calls"
    fi
  fi
fi

# ── Google Chrome (WhatsApp bot via Puppeteer) ─
# The WhatsApp bot needs Chrome for Puppeteer. Best-effort install via Homebrew
# cask; warn if unavailable.
step "Google Chrome"
if [ -d "/Applications/Google Chrome.app" ]; then
  ok "Google Chrome installed"
elif command -v brew >/dev/null 2>&1; then
  warn "Google Chrome not found — installing via Homebrew…"
  brew install --cask google-chrome </dev/null >/dev/null 2>&1 && ok "Google Chrome installed" \
    || warn "install failed — install manually (https://www.google.com/chrome/); needed for the WhatsApp bot."
else
  warn "Google Chrome not found — install it (https://www.google.com/chrome/); needed for the WhatsApp bot."
fi

# ── Detect-and-warn: Claude Desktop ─────────────────────
step "Other prerequisites (informational)"
[ -d "/Applications/Claude.app" ] && ok "Claude Desktop installed" \
  || warn "Claude Desktop not found — needed to read your claude.ai session."

# ── Done ────────────────────────────────────────────────
echo
ok "Install complete."
echo
echo "  Launch the app:   open \"$APP_PATH\""
echo "  WhatsApp bot:     open \"$DATA_DIR/start-bot.command\""
echo "  Shared state:     $DATA_DIR  (settings.json, sessions.json)"
echo "  Install log:      $LOG_FILE"
echo
if [ "$IN_APP_UPDATE" = "1" ]; then
  relaunch_installed_app \
    || die "the update finished, but ${APP_NAME} could not be relaunched automatically"
else
  open "$APP_PATH" 2>/dev/null || true
fi
