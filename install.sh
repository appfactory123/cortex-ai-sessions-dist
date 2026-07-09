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
# via Bun, Python cryptography/tls-client/openai-whisper, ffmpeg, Google Chrome,
# and the Claude + Codex CLIs the auto-reply bot drives). Unsigned: the app's quarantine flag is stripped so
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
#   CORTEX_PUBLIC_REPO  override the public dist repo (owner/name).
#   CORTEX_VERSION    pin a release tag (default: latest)
#   CORTEX_LOCAL_DIR  install from local artifacts in this dir instead
#                              of downloading (expects Cortex-<arch>.zip
#                              and support.tar.gz) — for testing; no token needed.

set -euo pipefail

REPO="appfactory123/claude-sessions"
PUBLIC_REPO="${CORTEX_PUBLIC_REPO:-appfactory123/cortex-ai-sessions-dist}"
APP_NAME="Cortex"
APP_PATH="/Applications/${APP_NAME}.app"
DATA_DIR="$HOME/.cortex-ai-sessions"
CONFIG="$HOME/.cortex-ai-sessions.env"
TOKEN="${CORTEX_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"

# Mirror all installer output (stdout + stderr) to a log file in the data dir,
# in addition to the terminal, so a failed run piped from `curl | bash` can
# still be inspected afterward.
mkdir -p "$DATA_DIR"
LOG_FILE="$DATA_DIR/install.log"
exec > >(tee "$LOG_FILE") 2>&1
echo "Cortex installer log — $(date)"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

app_executable_pattern() {
  printf '%s/Contents/MacOS/%s' "$APP_PATH" "$APP_NAME"
}

app_pids() {
  pgrep -f "$(app_executable_pattern)" 2>/dev/null || true
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
  local name="$1" resolved
  mkdir -p "$LOCAL_BIN"
  hash -r 2>/dev/null || true
  if [ -x "$LOCAL_BIN/$name" ]; then
    ok "$name available at $LOCAL_BIN/$name (app fallback path)"
    return 0
  fi
  resolved="$(command -v "$name" 2>/dev/null || true)"
  if [ -z "$resolved" ]; then
    warn "$name not found on PATH — the app expects it at $LOCAL_BIN/$name"
    return 0
  fi
  if [ "$resolved" != "$LOCAL_BIN/$name" ]; then
    ln -sf "$resolved" "$LOCAL_BIN/$name" \
      && ok "linked $name → $LOCAL_BIN/$name (was $resolved)" \
      || warn "could not link $name into $LOCAL_BIN — sign-in may fail with ENOENT"
  fi
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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
    curl -fL --progress-bar --connect-timeout 15 --speed-limit 1024 --speed-time 30 \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/octet-stream" \
      "https://api.github.com/repos/${REPO}/releases/assets/${id}" -o "$dest" \
      || die "download failed: $name (no response or the connection stalled)"
  else
    url="https://github.com/${PUBLIC_REPO}/releases/download/${TAG}/${name}"
    curl -fL --progress-bar --connect-timeout 15 --speed-limit 1024 --speed-time 30 "$url" -o "$dest" \
      || die "download failed: $name (no response or the connection stalled)"
  fi
}

# ── Install the .app ────────────────────────────────────
step "Installing ${APP_NAME}.app"
dl "$APP_ZIP" "$WORK/$APP_ZIP"
ok "downloaded $APP_ZIP"
ditto -x -k "$WORK/$APP_ZIP" "$WORK/app" || die "could not unzip $APP_ZIP"
SRC_APP="$(find "$WORK/app" -maxdepth 2 -name '*.app' -type d | head -n1)"
[ -n "$SRC_APP" ] || die "no .app found inside $APP_ZIP"
quit_running_app
refresh_launchservices unregister
rm -rf "$APP_PATH"
mv "$SRC_APP" "$APP_PATH" || die "could not move app to /Applications (permissions?)"
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
dl "$SUPPORT_TAR" "$WORK/$SUPPORT_TAR"
tar -xzf "$WORK/$SUPPORT_TAR" -C "$DATA_DIR" || die "could not extract $SUPPORT_TAR"
chmod +x "$DATA_DIR"/*.command "$DATA_DIR"/*.sh 2>/dev/null || true
ok "extracted bot + support files"

# ── Bun (required for Node deps + the bot) ──────────────
step "Bun"
if command -v bun >/dev/null 2>&1; then
  ok "bun: $(command -v bun)"
else
  warn "bun not found — installing…"
  curl -fsSL --connect-timeout 15 --max-time 30 https://bun.sh/install | bash || die "bun install failed"
  export PATH="$HOME/.bun/bin:$PATH"
  command -v bun >/dev/null 2>&1 && ok "bun installed" || die "bun still not on PATH"
fi

# ── Node.js + npm (runtime for MCP servers; installs the Claude/Codex CLIs) ─
step "Node.js"
ensure_node || warn "continuing without Node — the Claude/Codex CLIs and node-based MCP servers may be unavailable"

# ── Delegate Node + Python deps + config to setup.command ─
# setup.command (run from the data dir) installs Node deps via bun, installs the
# Python libs, and writes ~/.cortex-ai-sessions.env → the data dir. Reusing it keeps
# dependency logic in one place.
step "Dependencies (delegating to setup.command)"
( cd "$DATA_DIR" && bash setup.command ) || warn "setup.command reported problems (see above)"

# ── Claude CLI ──────────────────────────────────────────
step "Claude CLI"
if command -v claude >/dev/null 2>&1; then
  ok "claude: $(command -v claude)"
elif command -v npm >/dev/null 2>&1; then
  warn "claude not found — installing @anthropic-ai/claude-code…"
  npm install -g @anthropic-ai/claude-code && ok "Claude CLI installed" \
    || warn "install failed — run: npm install -g @anthropic-ai/claude-code"
else
  warn "claude not found and npm unavailable — install Node, then: npm install -g @anthropic-ai/claude-code"
fi
# The GUI-launched app resolves claude at ~/.local/bin/claude (see findClaudeBin);
# npm-global installs land elsewhere, so link it there or sign-in fails w/ ENOENT.
ensure_local_bin_link claude

# ── Codex CLI ───────────────────────────────────────────
# The bot can auto-reply with Codex as well as Claude. The @openai/codex npm
# package drops the standalone binary and symlinks ~/.local/bin/codex, which is
# where lib/paths.ts (findCodexBin) and the bot look for it.
step "Codex CLI"
if command -v codex >/dev/null 2>&1; then
  ok "codex: $(command -v codex)"
elif command -v npm >/dev/null 2>&1; then
  warn "codex not found — installing @openai/codex…"
  npm install -g @openai/codex && ok "Codex CLI installed" \
    || warn "install failed — run: npm install -g @openai/codex"
else
  warn "codex not found and npm unavailable — install Node, then: npm install -g @openai/codex"
fi
# Same GUI-PATH fallback as claude: findCodexBin resolves ~/.local/bin/codex.
ensure_local_bin_link codex

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
open "$APP_PATH" 2>/dev/null || true
