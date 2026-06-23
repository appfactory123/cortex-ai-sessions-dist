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

echo "Cortex — installer"

# ── Preflight ───────────────────────────────────────────
step "Preflight"
[ "$(uname -s)" = "Darwin" ] || die "This installer is macOS-only (found $(uname -s))."
case "$(uname -m)" in
  arm64)  ARCH="arm64" ;;
  x86_64) ARCH="x64" ;;
  *)      die "Unsupported architecture: $(uname -m)" ;;
esac
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
    REL_JSON="$(curl -fsSL \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${REPO}/releases/${REF}")" \
      || die "Could not fetch the release from ${REPO} (bad token, no read access, or no release published yet)."
    TAG="$(printf '%s' "$REL_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')"
  else
    if [ -n "${CORTEX_VERSION:-}" ]; then
      TAG="$CORTEX_VERSION"
    else
      LATEST_URL="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        "https://github.com/${PUBLIC_REPO}/releases/latest")" \
        || die "Could not resolve the latest release from ${PUBLIC_REPO}."
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
    curl -fL --progress-bar \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/octet-stream" \
      "https://api.github.com/repos/${REPO}/releases/assets/${id}" -o "$dest" \
      || die "download failed: $name"
  else
    url="https://github.com/${PUBLIC_REPO}/releases/download/${TAG}/${name}"
    curl -fL --progress-bar "$url" -o "$dest" \
      || die "download failed: $name"
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
  curl -fsSL https://bun.sh/install | bash || die "bun install failed"
  export PATH="$HOME/.bun/bin:$PATH"
  command -v bun >/dev/null 2>&1 && ok "bun installed" || die "bun still not on PATH"
fi

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

# ── Computer-control MCP server (mouse / keyboard / screen) ─
# Registers the local MCP server (scripts/computer-mcp/server.mjs — shipped in the
# support bundle; its Node deps were installed by setup.command above) with both
# CLIs at user/global scope, so the in-app agents (and interactive claude/codex)
# can drive the desktop. Best-effort: skip a CLI that isn't installed. The server
# resolves its deps from $DATA_DIR/node_modules, so it must run by absolute path.
step "Computer-control MCP server"
MCP_SERVER="$DATA_DIR/scripts/computer-mcp/server.mjs"
MCP_NODE="$(command -v node || echo node)"
if [ ! -f "$MCP_SERVER" ]; then
  warn "server.mjs not in support bundle — skipping MCP registration"
elif [ ! -d "$DATA_DIR/node_modules/@nut-tree-fork/nut-js" ]; then
  warn "MCP Node deps missing — re-run setup.command, then register manually"
else
  if command -v claude >/dev/null 2>&1; then
    claude mcp remove -s user computer_control >/dev/null 2>&1 || true
    # -e is variadic: keep -s after the env value so the list ends before the name.
    if claude mcp add -e ELECTRON_RUN_AS_NODE=1 -s user computer_control -- "$MCP_NODE" "$MCP_SERVER" >/dev/null 2>&1; then
      ok "registered with Claude"
    else
      warn "could not register with Claude"
    fi
  else
    warn "claude CLI missing — skipped Claude MCP registration"
  fi
  if command -v codex >/dev/null 2>&1; then
    codex mcp remove computer_control >/dev/null 2>&1 || true
    if codex mcp add --env ELECTRON_RUN_AS_NODE=1 computer_control -- "$MCP_NODE" "$MCP_SERVER" >/dev/null 2>&1; then
      ok "registered with Codex"
    else
      warn "could not register with Codex"
    fi
  else
    warn "codex CLI missing — skipped Codex MCP registration"
  fi
  warn "Grant Accessibility + Screen Recording to the app (System Settings → Privacy & Security) for mouse/screen control."
fi

# ── Google Chrome (WhatsApp bot via Puppeteer) ─
# The WhatsApp bot needs Chrome for Puppeteer. Best-effort install via Homebrew
# cask; warn if unavailable.
step "Google Chrome"
if [ -d "/Applications/Google Chrome.app" ]; then
  ok "Google Chrome installed"
elif command -v brew >/dev/null 2>&1; then
  warn "Google Chrome not found — installing via Homebrew…"
  brew install --cask google-chrome >/dev/null 2>&1 && ok "Google Chrome installed" \
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
echo
open "$APP_PATH" 2>/dev/null || true
