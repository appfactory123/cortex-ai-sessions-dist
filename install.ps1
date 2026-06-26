# Cortex — Windows installer (public distribution, no token needed).
#
# Windows counterpart of install.sh. By default it downloads the prebuilt
# Windows build anonymously from the PUBLIC distribution repo's latest GitHub
# Release — no GitHub token required:
#
#   irm https://raw.githubusercontent.com/appfactory123/cortex-ai-sessions-dist/main/install.ps1 | iex
#
# Installs the app to %LOCALAPPDATA%\Programs\Cortex (with Start Menu + Desktop
# shortcuts), provisions a data dir (%USERPROFILE%\.cortex-ai-sessions) with the
# bot + support files, and installs every runtime library (Node deps via Bun,
# Python cryptography/tls-client/curl_cffi/whisper, Google Chrome, and the
# Claude + Codex CLIs the auto-reply bot drives). Safe to re-run.
#
# Developers can instead pull an unreleased build from the PRIVATE source repo
# by setting a GitHub token with read access (CORTEX_TOKEN / GH_TOKEN /
# GITHUB_TOKEN); when a token is present the installer downloads from the private
# repo via the authenticated API rather than the public dist repo.
#
# Overrides (env):
#   CORTEX_TOKEN / GH_TOKEN / GITHUB_TOKEN   token -> pull from PRIVATE source repo
#   CORTEX_PUBLIC_REPO   override the public dist repo (owner/name)
#   CORTEX_VERSION       pin a release tag (default: latest)
#   CORTEX_LOCAL_DIR     install from local artifacts in this dir instead of
#                        downloading (expects Cortex-win-<arch>.zip and
#                        support.tar.gz) — for testing; no token needed.

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
# The branded front-end (and any redirected console) captures stdout; emit UTF-8
# so the "▶" phase markers it keys progress off survive the pipe intact.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}
$ProgressPreference = 'SilentlyContinue'   # hide Invoke-WebRequest's own progress bar
# Windows PowerShell 5.1 defaults to TLS 1.0/1.1; GitHub requires 1.2+.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# ── Config ──────────────────────────────────────────────
$REPO        = 'appfactory123/claude-sessions'
$PUBLIC_REPO = if ($env:CORTEX_PUBLIC_REPO) { $env:CORTEX_PUBLIC_REPO } else { 'appfactory123/cortex-ai-sessions-dist' }
$APP_NAME    = 'Cortex'
$INSTALL_DIR = Join-Path $env:LOCALAPPDATA 'Programs\Cortex'
$APP_EXE     = Join-Path $INSTALL_DIR "$APP_NAME.exe"
$DATA_DIR    = Join-Path $env:USERPROFILE '.cortex-ai-sessions'
$CONFIG      = Join-Path $env:USERPROFILE '.cortex-ai-sessions.env'
$TOKEN       = if ($env:CORTEX_TOKEN) { $env:CORTEX_TOKEN } elseif ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }

# ── Pretty output (mirrors install.sh's ok/warn/step/die) ─
function Ok   ($m) { Write-Host "  $([char]0x2713) $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  ! $m"               -ForegroundColor Yellow }
function Step ($m) { Write-Host ""; Write-Host "$([char]0x25B6) $m" -ForegroundColor White }  # ▶ — drives the GUI progress bar
function Die  ($m) { Write-Host "$([char]0x2717) $m" -ForegroundColor Red; exit 1 }

Write-Host "Cortex — installer"

# ── Preflight ───────────────────────────────────────────
Step 'Preflight'
if (-not $IsWindows -and $env:OS -ne 'Windows_NT') { Die 'This installer is Windows-only.' }
# PROCESSOR_ARCHITECTURE reports the *process* arch; on 32-bit PowerShell under
# 64-bit Windows the real arch is in PROCESSOR_ARCHITEW6432.
$rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch ($rawArch) {
  'AMD64' { $ARCH = 'x64' }
  'ARM64' { $ARCH = 'arm64' }
  default { Die "Unsupported architecture: $rawArch" }
}
Ok "Windows / $ARCH"

$APP_ZIP     = "Cortex-win-$ARCH.zip"
$SUPPORT_TAR = 'support.tar.gz'
$WORK = Join-Path ([System.IO.Path]::GetTempPath()) ("cortex-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $WORK | Out-Null

# Helper: GET with auth/redirect control via .NET HttpClient (stable across PS
# 5.1 and 7; Invoke-WebRequest's redirect handling differs between them).
function Get-Redirect-Location ($url) {
  Add-Type -AssemblyName System.Net.Http
  $handler = [System.Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect = $false
  $client = [System.Net.Http.HttpClient]::new($handler)
  try {
    $resp = $client.GetAsync($url).GetAwaiter().GetResult()
    if ($resp.Headers.Location) { return $resp.Headers.Location.ToString() }
    return $null
  } finally { $client.Dispose(); $handler.Dispose() }
}

# ── Locate the release (skipped in local mode) ──────────
$REL_JSON     = $null
$SOURCE_REPO  = $PUBLIC_REPO
$TAG          = ''
if (-not $env:CORTEX_LOCAL_DIR) {
  Step 'Locating release'
  if ($TOKEN) {
    # Authenticated: hit the PRIVATE source repo's API and parse the JSON.
    $SOURCE_REPO = $REPO
    $ref = if ($env:CORTEX_VERSION) { "tags/$env:CORTEX_VERSION" } else { 'latest' }
    $headers = @{ Authorization = "Bearer $TOKEN"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'cortex-installer' }
    try {
      $REL_JSON = Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO/releases/$ref" -Headers $headers
    } catch {
      Die "Could not fetch the release from $REPO (bad token, no read access, or no release published yet)."
    }
    $TAG = $REL_JSON.tag_name
  }
  elseif ($env:CORTEX_VERSION) {
    $TAG = $env:CORTEX_VERSION
  }
  else {
    # Anonymous: follow the /releases/latest redirect to learn the tag, then
    # download from deterministic public URLs (avoids the anon API rate limit).
    $loc = Get-Redirect-Location "https://github.com/$PUBLIC_REPO/releases/latest"
    if (-not $loc) { Die "Could not resolve the latest release from $PUBLIC_REPO." }
    $TAG = $loc.Split('/')[-1]
    if (-not $TAG -or $TAG -eq 'latest') { Die "Could not resolve the latest release tag from $PUBLIC_REPO." }
  }
  Ok "release $(if ($TAG) { $TAG } else { '?' }) ($SOURCE_REPO)"
}

# dl <asset-name> <dest> — fetch a release asset (local copy, public anonymous
# download, or private authenticated download depending on mode).
function Dl ($name, $dest) {
  if ($env:CORTEX_LOCAL_DIR) {
    $src = Join-Path $env:CORTEX_LOCAL_DIR $name
    if (-not (Test-Path $src)) { Die "missing local artifact: $src" }
    Copy-Item $src $dest -Force
  }
  elseif ($TOKEN) {
    $asset = $REL_JSON.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $asset) { Die "release $(if ($TAG) { $TAG } else { '?' }) has no asset named $name" }
    $headers = @{ Authorization = "Bearer $TOKEN"; Accept = 'application/octet-stream'; 'User-Agent' = 'cortex-installer' }
    try { Invoke-WebRequest -Uri "https://api.github.com/repos/$REPO/releases/assets/$($asset.id)" -Headers $headers -OutFile $dest }
    catch { Die "download failed: $name" }
  }
  else {
    $url = "https://github.com/$PUBLIC_REPO/releases/download/$TAG/$name"
    try { Invoke-WebRequest -Uri $url -OutFile $dest }
    catch { Die "download failed: $name" }
  }
}

# Refresh the current session's PATH from the registry so tools installed during
# this run (Bun, Node, the CLIs) are found without restarting the shell.
function Sync-Path {
  $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($machine, $user, "$env:USERPROFILE\.bun\bin") | Where-Object { $_ } ) -join ';'
}

function Stop-RunningApp {
  $procs = Get-Process -Name $APP_NAME -ErrorAction SilentlyContinue
  if (-not $procs) { return }
  Warn "$APP_NAME is running — quitting it before replacing the app"
  $procs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (-not (Get-Process -Name $APP_NAME -ErrorAction SilentlyContinue)) { Ok 'stopped running app'; return }
  }
  Get-Process -Name $APP_NAME -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Ok 'stopped running app'
}

try {
  # ── Install the app ──────────────────────────────────
  Step "Installing $APP_NAME"
  $zipPath = Join-Path $WORK $APP_ZIP
  Dl $APP_ZIP $zipPath
  Ok "downloaded $APP_ZIP"
  $unpack = Join-Path $WORK 'app'
  Expand-Archive -Path $zipPath -DestinationPath $unpack -Force
  # The zip may contain the app at its root or nested one level (electron-builder
  # "zip" target packs the unpacked dir's contents); find the dir holding the exe.
  $exe = Get-ChildItem -Path $unpack -Recurse -Filter "$APP_NAME.exe" -File | Select-Object -First 1
  if (-not $exe) { Die "no $APP_NAME.exe found inside $APP_ZIP" }
  $srcDir = $exe.Directory.FullName
  Stop-RunningApp
  if (Test-Path $INSTALL_DIR) { Remove-Item $INSTALL_DIR -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
  Copy-Item -Path (Join-Path $srcDir '*') -Destination $INSTALL_DIR -Recurse -Force
  Ok "installed -> $INSTALL_DIR"

  # Start Menu + Desktop shortcuts.
  $ws = New-Object -ComObject WScript.Shell
  $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
  foreach ($lnkDir in @($startMenu, [Environment]::GetFolderPath('Desktop'))) {
    try {
      $lnk = $ws.CreateShortcut((Join-Path $lnkDir "$APP_NAME.lnk"))
      $lnk.TargetPath = $APP_EXE
      $lnk.WorkingDirectory = $INSTALL_DIR
      $lnk.IconLocation = $APP_EXE
      $lnk.Save()
    } catch {}
  }
  Ok 'created Start Menu + Desktop shortcuts'

  $vf = Join-Path $INSTALL_DIR 'resources\standalone\version.json'
  if (Test-Path $vf) {
    try { Ok "installed build $((Get-Content $vf -Raw | ConvertFrom-Json).tag)" } catch {}
  } elseif ($TAG) {
    Warn "could not read bundled build tag; expected release $TAG"
  }

  # ── Provision data dir ───────────────────────────────
  Step "Provisioning $DATA_DIR"
  New-Item -ItemType Directory -Force -Path $DATA_DIR | Out-Null
  $tarPath = Join-Path $WORK $SUPPORT_TAR
  Dl $SUPPORT_TAR $tarPath
  # Windows 10 1803+ ships bsdtar as tar.exe, which reads .tar.gz directly.
  if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
    & tar.exe -xzf $tarPath -C $DATA_DIR
    if ($LASTEXITCODE -ne 0) { Die "could not extract $SUPPORT_TAR" }
  } else {
    Die 'tar.exe not found — Windows 10 1803+ is required.'
  }
  Ok 'extracted bot + support files'

  # ── Bun (powers the WhatsApp bot + data-dir Node deps) ─
  # NOT required for the main app — the packaged build bundles its own
  # node_modules. So a Bun failure here warns and continues instead of aborting
  # the whole install (Bun also needs Windows 10 1809+, which not every box has).
  Step 'Bun'
  Sync-Path
  if (Get-Command bun -ErrorAction SilentlyContinue) {
    Ok "bun: $((Get-Command bun).Source)"
  } else {
    Warn 'bun not found — installing…'
    try { Invoke-RestMethod 'https://bun.sh/install.ps1' | Invoke-Expression }
    catch { Warn "bun web installer failed: $($_.Exception.Message)" }
    Sync-Path
    # Fall back to winget if the web installer didn't land bun on PATH.
    if (-not (Get-Command bun -ErrorAction SilentlyContinue) -and (Get-Command winget -ErrorAction SilentlyContinue)) {
      Warn 'trying winget (Oven-sh.Bun)…'
      & winget install --id Oven-sh.Bun -e --silent --accept-source-agreements --accept-package-agreements 2>$null | Out-Null
      Sync-Path
    }
    # The installer drops bun.exe under ~\.bun\bin even when PATH isn't refreshed
    # in this session — pick it up directly before giving up.
    $bunExe = Join-Path $env:USERPROFILE '.bun\bin\bun.exe'
    if (-not (Get-Command bun -ErrorAction SilentlyContinue) -and (Test-Path $bunExe)) {
      $env:Path = "$env:USERPROFILE\.bun\bin;$env:Path"
    }
    if (Get-Command bun -ErrorAction SilentlyContinue) {
      Ok 'bun installed'
    } else {
      Warn 'bun could not be installed (it needs Windows 10 1809+). The app still works; the WhatsApp bot needs bun — install it later from https://bun.sh.'
    }
  }

  # ── Dependencies (delegate to setup.ps1) ─────────────
  # setup.ps1 (shipped in the support bundle) installs Node deps via bun, the
  # Python libs, and writes %USERPROFILE%\.cortex-ai-sessions.env. Reuse it so the
  # dependency logic lives in one place — fall back to inline basics if an older
  # bundle predates it.
  Step 'Dependencies (delegating to setup.ps1)'
  $setup = Join-Path $DATA_DIR 'setup.ps1'
  if (Test-Path $setup) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $setup
    if ($LASTEXITCODE -ne 0) { Warn 'setup.ps1 reported problems (see above)' }
  } else {
    Warn 'setup.ps1 not in support bundle — installing Node deps inline'
    Push-Location $DATA_DIR
    try { & bun install } catch { Warn 'bun install failed' }
    Pop-Location
  }

  # ── Claude CLI ───────────────────────────────────────
  Step 'Claude CLI'
  Sync-Path
  if (Get-Command claude -ErrorAction SilentlyContinue) {
    Ok "claude: $((Get-Command claude).Source)"
  } elseif (Get-Command npm -ErrorAction SilentlyContinue) {
    Warn 'claude not found — installing @anthropic-ai/claude-code…'
    & npm install -g '@anthropic-ai/claude-code'
    Sync-Path
    if (Get-Command claude -ErrorAction SilentlyContinue) { Ok 'Claude CLI installed' }
    else { Warn 'install failed — run: npm install -g @anthropic-ai/claude-code' }
  } else {
    Warn 'claude not found and npm unavailable — install Node.js (https://nodejs.org), then: npm install -g @anthropic-ai/claude-code'
  }

  # ── Codex CLI ────────────────────────────────────────
  Step 'Codex CLI'
  Sync-Path
  if (Get-Command codex -ErrorAction SilentlyContinue) {
    Ok "codex: $((Get-Command codex).Source)"
  } elseif (Get-Command npm -ErrorAction SilentlyContinue) {
    Warn 'codex not found — installing @openai/codex…'
    & npm install -g '@openai/codex'
    Sync-Path
    if (Get-Command codex -ErrorAction SilentlyContinue) { Ok 'Codex CLI installed' }
    else { Warn 'install failed — run: npm install -g @openai/codex' }
  } else {
    Warn 'codex not found and npm unavailable — install Node.js, then: npm install -g @openai/codex'
  }

  # ── Computer-control MCP server ──────────────────────
  Step 'Computer-control MCP server'
  $mcpServer = Join-Path $DATA_DIR 'scripts\computer-mcp\server.mjs'
  $nodeCmd = (Get-Command node -ErrorAction SilentlyContinue).Source; if (-not $nodeCmd) { $nodeCmd = 'node' }
  if (-not (Test-Path $mcpServer)) {
    Warn 'server.mjs not in support bundle — skipping MCP registration'
  } elseif (-not (Test-Path (Join-Path $DATA_DIR 'node_modules\@nut-tree-fork\nut-js'))) {
    Warn 'MCP Node deps missing — re-run setup.ps1, then register manually'
  } else {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
      try { & claude mcp remove -s user computer_control 2>$null | Out-Null } catch {}
      & claude mcp add -e ELECTRON_RUN_AS_NODE=1 -s user computer_control -- $nodeCmd $mcpServer 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { Ok 'registered with Claude' } else { Warn 'could not register with Claude' }
    } else { Warn 'claude CLI missing — skipped Claude MCP registration' }
    if (Get-Command codex -ErrorAction SilentlyContinue) {
      try { & codex mcp remove computer_control 2>$null | Out-Null } catch {}
      & codex mcp add --env ELECTRON_RUN_AS_NODE=1 computer_control -- $nodeCmd $mcpServer 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { Ok 'registered with Codex' } else { Warn 'could not register with Codex' }
    } else { Warn 'codex CLI missing — skipped Codex MCP registration' }
  }

  # ── Google Chrome (WhatsApp bot via Puppeteer) ───────
  Step 'Google Chrome'
  $chromePaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  )
  if ($chromePaths | Where-Object { Test-Path $_ }) {
    Ok 'Google Chrome installed'
  } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
    Warn 'Google Chrome not found — installing via winget…'
    & winget install --id Google.Chrome -e --silent --accept-source-agreements --accept-package-agreements 2>$null | Out-Null
    if ($chromePaths | Where-Object { Test-Path $_ }) { Ok 'Google Chrome installed' }
    else { Warn 'install failed — install manually (https://www.google.com/chrome/); needed for the WhatsApp bot.' }
  } else {
    Warn 'Google Chrome not found — install it (https://www.google.com/chrome/); needed for the WhatsApp bot.'
  }

  # ── Other prerequisites (informational) ──────────────
  Step 'Other prerequisites (informational)'
  $claudeDesktop = @(
    "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe",
    "$env:LOCALAPPDATA\Programs\Claude\Claude.exe"
  )
  if ($claudeDesktop | Where-Object { Test-Path $_ }) { Ok 'Claude Desktop installed' }
  else { Warn 'Claude Desktop not found — needed to read your claude.ai session.' }
}
finally {
  Remove-Item $WORK -Recurse -Force -ErrorAction SilentlyContinue
}

# ── Done ────────────────────────────────────────────────
Write-Host ""
Ok 'Install complete.'
Write-Host ""
Write-Host "  Launch the app:   $APP_EXE"
Write-Host "  WhatsApp bot:     $DATA_DIR\start-bot.cmd"
Write-Host "  Shared state:     $DATA_DIR  (settings.json, sessions.json)"
Write-Host ""
try { Start-Process $APP_EXE } catch {}
