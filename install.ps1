# Cortex - Windows installer (public distribution, no token needed).
#
# Windows counterpart of install.sh. By default it downloads the prebuilt
# Windows build anonymously from the PUBLIC distribution repo's latest GitHub
# Release - no GitHub token required:
#
#   irm https://raw.githubusercontent.com/appfactory123/cortex-ai-sessions-dist/main/install.ps1 | iex
#
# Installs the app to %LOCALAPPDATA%\Programs\Cortex (with Start Menu + Desktop
# shortcuts), provisions a data dir (%USERPROFILE%\.cortex-ai-sessions) with the
# bot + support files, and installs every runtime library (Node deps via Bun,
# Python cryptography/tls-client/curl_cffi/whisper, a managed local Pocket Jarvis voice
# environment, Google Chrome, and the Claude, Codex, Antigravity, and Grok CLIs
# Cortex drives). Safe to re-run.
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
#   CORTEX_LOCAL_DIR     install Cortex app/support artifacts from this directory
#                        instead of downloading them. Pocket's model remains a
#                        fixed verified download unless it is also present here
#                        - for testing; no token needed.

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
# The branded front-end (and any redirected console) captures stdout; emit UTF-8
# so the step phase markers it keys progress off survive the pipe intact.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}
$ProgressPreference = 'SilentlyContinue'   # hide Invoke-WebRequest's own progress bar
# Windows PowerShell 5.1 defaults to TLS 1.0/1.1; GitHub requires 1.2+.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# -- Config ------------------------------------------------------------------
$REPO        = 'appfactory123/claude-sessions'
$PUBLIC_REPO = if ($env:CORTEX_PUBLIC_REPO) { $env:CORTEX_PUBLIC_REPO } else { 'appfactory123/cortex-ai-sessions-dist' }
$APP_NAME    = 'Cortex'
$INSTALL_DIR = Join-Path $env:LOCALAPPDATA 'Programs\Cortex'
$APP_EXE     = Join-Path $INSTALL_DIR "$APP_NAME.exe"
$DATA_DIR    = Join-Path $env:USERPROFILE '.cortex-ai-sessions'
$CONFIG      = Join-Path $env:USERPROFILE '.cortex-ai-sessions.env'
$TOKEN       = if ($env:CORTEX_TOKEN) { $env:CORTEX_TOKEN } elseif ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }

# -- Pretty output (mirrors install.sh's ok/warn/step/die) -------------------
function Ok   ($m) { Write-Host "  $([char]0x2713) $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  ! $m"               -ForegroundColor Yellow }
function Step ($m) { Write-Host ""; Write-Host "$([char]0x25B6) $m" -ForegroundColor White }  # drives the GUI progress bar
function Die  ($m) { Write-Host "$([char]0x2717) $m" -ForegroundColor Red; exit 1 }

Write-Host "Cortex - installer"

# -- Preflight ---------------------------------------------------------------
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
$POCKET_MODEL_ASSET = 'Pocket-English-model.tar.gz'
$POCKET_MODEL_REPOSITORY = 'appfactory123/pocket-tts-model-weight-dist'
$POCKET_MODEL_RELEASE_TAG = 'pocket-tts-v2.1.0-english-1'
$POCKET_MODEL_RELEASE_ASSET_ID = '494264404'
$POCKET_MODEL_SHA256 = '473f47d99560bd50eb8b4509d3cacfe7f316ab20bdca86505403a2e6a936a6e9'
$POCKET_TOKENIZER_SHA256 = 'd461765ae179566678c93091c5fa6f2984c31bbe990bf1aa62d92c64d91bc3f6'
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

# -- Locate the release (skipped in local mode) ------------------------------
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

# dl <asset-name> <dest> - fetch a release asset (local copy, public anonymous
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

# Dl-PocketModel <dest> - The Pocket weights live in their own immutable public
# release, so Cortex app releases do not duplicate the large asset. GitHub's
# public asset API resolves the pinned asset to a short-lived storage redirect;
# hash checks below remain the final trust boundary. Local installer tests may
# supply the archive next to the app artifacts.
function Dl-PocketModel ($dest) {
  if ($env:CORTEX_LOCAL_DIR) {
    $local = Join-Path $env:CORTEX_LOCAL_DIR $POCKET_MODEL_ASSET
    if (Test-Path -LiteralPath $local -PathType Leaf) {
      Copy-Item -LiteralPath $local -Destination $dest -Force
      return
    }
  }
  $url = "https://api.github.com/repos/$POCKET_MODEL_REPOSITORY/releases/assets/$POCKET_MODEL_RELEASE_ASSET_ID"
  try {
    Invoke-WebRequest -Uri $url -Headers @{ Accept = 'application/octet-stream'; 'User-Agent' = 'cortex-installer' } -OutFile $dest
  } catch {
    Die "could not download the verified Pocket model release ($POCKET_MODEL_REPOSITORY@$POCKET_MODEL_RELEASE_TAG)"
  }
}

function Test-PocketModelFile {
  param([string]$Path, [string]$Hash)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    return [string]::Equals(
      (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash,
      $Hash,
      [System.StringComparison]::OrdinalIgnoreCase
    )
  } catch { return $false }
}

function Test-PocketReleaseModel {
  param([string]$Directory)
  return (Test-PocketModelFile -Path (Join-Path $Directory 'model.safetensors') -Hash $POCKET_MODEL_SHA256) -and
    (Test-PocketModelFile -Path (Join-Path $Directory 'tokenizer.model') -Hash $POCKET_TOKENIZER_SHA256)
}

# Refresh the current session's PATH from the registry so tools installed during
# this run (Bun, Node, the CLIs) are found without restarting the shell.
function Sync-Path {
  $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($machine, $user, "$env:USERPROFILE\.bun\bin") | Where-Object { $_ } ) -join ';'
}

# The installer owns only its known vendor/npm locations. A user-selected
# *_BIN path is an explicit opt-out from automatic mutation.
function Test-CliOverride {
  param([string]$Variable)
  return -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Variable, 'Process'))
}

# Electron also reads these path settings from the fixed user config. Import
# only literal assignments for this narrow allowlist; never dot-source a config
# file that can contain arbitrary user data. A real process environment value
# remains authoritative.
function Import-CliOverridesFromConfig {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
  try {
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
      $match = [regex]::Match([string]$line, '^\s*(CLAUDE_BIN|CODEX_BIN|AGY_BIN|GROK_BIN|GROK_HOME)\s*=\s*(.*?)\s*$')
      if (-not $match.Success) { continue }
      $name = $match.Groups[1].Value
      if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, 'Process'))) { continue }
      $value = $match.Groups[2].Value.Trim()
      if ($value.Length -ge 2 -and (
        ($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))
      )) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
      }
    }
  } catch {
    Warn "could not read CLI override config: $($_.Exception.Message)"
  }
}

# The public raw installer can be newer than the release support bundle it
# downloads. Keep a literal backup so an older bundled setup.ps1 cannot erase
# user-owned CLI paths or voice credentials/settings from the config Electron
# reads on next launch.
$script:PreservedConfigPattern = 'PYTHON_BIN|CLAUDE_BIN|CODEX_BIN|AGY_BIN|GROK_BIN|GROK_HOME|KIMI_BIN|KIMI_SHARE_DIR|UV_BIN|CORTEX_OPENAI_API_KEY|OPENAI_API_KEY|CORTEX_ELEVENLABS_API_KEY|ELEVENLABS_API_KEY|CORTEX_VOICE_TTS_PROVIDER|CORTEX_VOICE_TTS_PYTHON|CORTEX_VOICE_TTS_DEVICE|CORTEX_VOICE_TTS_MODEL|CORTEX_VOICE_TTS_VOICE|CORTEX_ELEVENLABS_VOICE_ID|CORTEX_ELEVENLABS_MODEL|CORTEX_VOICE_TTS_LOCAL_VOICE|CORTEX_VOICE_TTS_POCKET_CACHE|CORTEX_VOICE_TTS_QWEN_MODEL|CORTEX_VOICE_TTS_QWEN_REVISION|CORTEX_VOICE_TTS_QWEN_CACHE|CORTEX_VOICE_TTS_QWEN_PROFILE|CORTEX_VOICE_TTS_QWEN_VOICE_PROMPT|CORTEX_VOICE_DUPLEX|CORTEX_VOICE_TTS_CAPABILITY_READY_WAIT_MS|CORTEX_VOICE_TTS_LOCAL_READY_GRACE_MS|CORTEX_VOICE_TTS_DAEMON_READY_TIMEOUT_MS|CORTEX_VOICE_TTS_LOCAL_RESPONSE_TIMEOUT_MS'
function Get-PreservedConfigLines {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
  $lines = @()
  try {
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
      if (([string]$line) -match "^\s*($script:PreservedConfigPattern)\s*=") {
        $lines += ([string]$line).Trim()
      }
    }
  } catch {
    Warn "could not snapshot preserved app settings: $($_.Exception.Message)"
  }
  return $lines
}

function Restore-PreservedConfigLines {
  param([string]$Path, [string[]]$Lines)
  if ([string]::IsNullOrWhiteSpace($Path) -or $Lines.Count -eq 0) { return }
  $existingKeys = @{}
  foreach ($line in Get-PreservedConfigLines -Path $Path) {
    $match = [regex]::Match($line, "^\s*($script:PreservedConfigPattern)\s*=")
    if ($match.Success) { $existingKeys[$match.Groups[1].Value] = $true }
  }
  $missing = @()
  foreach ($line in $Lines) {
    $match = [regex]::Match([string]$line, "^\s*($script:PreservedConfigPattern)\s*=")
    if ($match.Success -and -not $existingKeys.ContainsKey($match.Groups[1].Value)) {
      $missing += $line
      $existingKeys[$match.Groups[1].Value] = $true
    }
  }
  if ($missing.Count -eq 0) { return }
  try {
    $prefix = if (Test-Path -LiteralPath $Path -PathType Leaf) { [Environment]::NewLine } else { '' }
    $content = $prefix + ($missing -join [Environment]::NewLine) + [Environment]::NewLine
    [System.IO.File]::AppendAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
  } catch {
    Warn "could not restore preserved app settings: $($_.Exception.Message)"
  }
}

function Test-SamePath {
  param([string]$Left, [string]$Right)
  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
  try {
    return [string]::Equals(
      [System.IO.Path]::GetFullPath($Left),
      [System.IO.Path]::GetFullPath($Right),
      [System.StringComparison]::OrdinalIgnoreCase
    )
  } catch { return $false }
}

# Match the Windows app's `where <cli>`-first lookup and npm fallback. A
# canonical vendor path is only a fallback when it is not already the executable
# Cortex will use.
function Get-CliPath {
  param(
    [string]$Name,
    [string[]]$CanonicalPaths = @(),
    [string]$NpmShim = '',
    [switch]$PreferCanonical
  )
  try {
    $whereMatches = @(& where.exe $Name 2>$null)
    if ($LASTEXITCODE -eq 0) {
      $found = $whereMatches | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
      if ($found) { return (Get-Item -LiteralPath $found).FullName }
    }
  } catch {}
  if ($PreferCanonical) {
    foreach ($candidate in $CanonicalPaths) {
      if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        return (Get-Item -LiteralPath $candidate).FullName
      }
    }
  }
  if ($NpmShim -and (Test-Path -LiteralPath $NpmShim -PathType Leaf)) {
    return (Get-Item -LiteralPath $NpmShim).FullName
  }
  if (-not $PreferCanonical) {
    foreach ($candidate in $CanonicalPaths) {
      if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        return (Get-Item -LiteralPath $candidate).FullName
      }
    }
  }
  return $null
}

function Show-CliVersion {
  param([string]$Name, [string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Warn "$Name is not available after this installer run"
    return
  }
  $version = ''
  try {
    $version = ((& $Path --version 2>&1 | Select-Object -First 1 | Out-String).Trim())
  } catch {}
  if ($version) { Ok "$Name: $Path ($version)" }
  else { Ok "$Name: $Path" }
}

function Get-NpmGlobalPrefix {
  $npm = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $npm) { return $null }
  try {
    $npmPath = if ($npm.Path) { $npm.Path } else { $npm.Source }
    if (-not $npmPath) { return $null }
    $prefix = ((& $npmPath prefix -g 2>$null | Select-Object -First 1 | Out-String).Trim())
    if ($prefix) { return $prefix }
  } catch {}
  return $null
}

function Test-NpmManagedCli {
  param([string]$Name, [string]$Package, [string]$Path)
  $prefix = Get-NpmGlobalPrefix
  if (-not $prefix) { return $false }
  $expected = @(
    (Join-Path $prefix "$Name.cmd"),
    (Join-Path $prefix "$Name.ps1")
  )
  $packageDir = Join-Path $prefix "node_modules\$Package"
  return (@($expected | Where-Object { Test-SamePath $Path $_ }).Count -gt 0) -and (Test-Path -LiteralPath $packageDir -PathType Container)
}

function Invoke-NpmLatest {
  param([string]$Package)
  $npm = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $npm) {
    Warn "npm is unavailable; cannot update $Package"
    return $false
  }
  try {
    $npmPath = if ($npm.Path) { $npm.Path } else { $npm.Source }
    if (-not $npmPath) { throw 'npm command path could not be resolved' }
    & $npmPath install -g "$Package@latest"
    return ($LASTEXITCODE -eq 0)
  } catch {
    Warn "npm update failed: $($_.Exception.Message)"
    return $false
  }
}

# Match the official Codex bootstrapper's exact pre-junction layout detection.
# That bootstrapper deliberately asks before moving this directory; Cortex must
# not pretend a redirected installer can answer on the user's behalf.
function Test-LegacyCodexStandaloneLayout {
  $visibleBinDir = Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin'
  if (-not (Test-Path -LiteralPath $visibleBinDir -PathType Container)) { return $false }
  try {
    $item = Get-Item -LiteralPath $visibleBinDir -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    $entries = @(Get-ChildItem -LiteralPath $visibleBinDir -Force)
    $required = @('codex.exe', 'rg.exe')
    $known = @(
      'codex.exe',
      'rg.exe',
      'codex-command-runner.exe',
      'codex-windows-sandbox.exe',
      'codex-windows-sandbox-setup.exe'
    )
    if ($entries.Name -notcontains $required[0] -or $entries.Name -notcontains $required[1]) { return $false }
    foreach ($entry in $entries) {
      if ($entry.PSIsContainer -or $known -notcontains $entry.Name) { return $false }
    }
    return $true
  } catch { return $false }
}

# Run vendor PowerShell installers in a child process. Their scripts use exit
# on failure; isolating them keeps a failed CLI update from aborting Cortex's
# app install or the remaining provider updates.
function Invoke-OfficialPowerShellInstaller {
  param(
    [string]$Label,
    [string]$Url,
    [switch]$Codex
  )
  $tmp = Join-Path $WORK ("cortex-" + [Guid]::NewGuid().ToString('N') + '.ps1')
  $oldCodexRelease = $env:CODEX_RELEASE
  $hadCodexRelease = Test-Path Env:CODEX_RELEASE
  try {
    Invoke-WebRequest -Uri $Url -OutFile $tmp
    $psHost = Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $psHost) { $psHost = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($null -eq $psHost) {
      Warn "could not find a PowerShell host for the official $Label installer"
      return $false
    }
    if ($Codex) {
      # Keep the release deterministic, but let the vendor installer ask its
      # one-time legacy-layout migration question in this ordinary terminal.
      # Setting CODEX_NON_INTERACTIVE would make that safe migration fail.
      $env:CODEX_RELEASE = 'latest'
    }
    $psHostPath = if ($psHost.Path) { $psHost.Path } else { $psHost.Source }
    if (-not $psHostPath) { throw 'PowerShell host path could not be resolved' }
    $requiresVisibleCodexMigration = $Codex -and (Test-LegacyCodexStandaloneLayout) -and (
      [Console]::IsInputRedirected -or [Console]::IsOutputRedirected
    )
    if ($requiresVisibleCodexMigration) {
      # The WPF/branded installer captures output, but the official Codex
      # script correctly refuses to replace this layout without a real prompt.
      # Give that vendor-owned migration an ordinary visible console instead.
      Warn 'Older Codex layout needs one confirmation; opening PowerShell for the vendor migration...'
      $quotedTmp = '"' + $tmp.Replace('"', '""') + '"'
      $child = Start-Process -FilePath $psHostPath -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $quotedTmp" -Wait -PassThru
      $exitCode = $child.ExitCode
    } else {
      & $psHostPath -NoProfile -ExecutionPolicy Bypass -File $tmp
      $exitCode = $LASTEXITCODE
    }
    if ($exitCode -ne 0) {
      Warn "official $Label installer exited with code $exitCode"
      return $false
    }
    return $true
  } catch {
    Warn "official $Label installer failed: $($_.Exception.Message)"
    return $false
  } finally {
    if ($hadCodexRelease) { $env:CODEX_RELEASE = $oldCodexRelease }
    else { Remove-Item Env:CODEX_RELEASE -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Test-ClaudeNativeCli {
  param([string]$Path)
  $candidates = @(
    (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Claude\bin\claude.exe')
  )
  $matches = @($candidates | Where-Object { Test-SamePath $Path $_ })
  return ($matches.Count -gt 0)
}

function Test-CodexNativeCli {
  param([string]$Path)
  return (Test-SamePath $Path (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'))
}

function Test-AgyNativeCli {
  param([string]$Path)
  return (Test-SamePath $Path (Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'))
}

function Get-GrokCliHome {
  if (-not [string]::IsNullOrWhiteSpace($env:GROK_HOME)) { return $env:GROK_HOME }
  return (Join-Path $env:USERPROFILE '.grok')
}

function Test-GrokNativeCli {
  param([string]$Path)
  # findGrokBin() checks PATH first. Keep the vendor's default launcher managed
  # too when it wins PATH ahead of a configured GROK_HOME launcher.
  return (Test-SamePath $Path (Join-Path (Get-GrokCliHome) 'bin\grok.exe')) -or
    (Test-SamePath $Path (Join-Path $env:USERPROFILE '.grok\bin\grok.exe'))
}

# Antigravity's Windows bootstrapper intentionally leaves an existing binary
# alone and relies on self-update. For a deterministic installer rerun, use the
# same vendor manifest and SHA-512 verification as that bootstrapper, but only
# at its documented canonical path.
function Install-AgyFromManifest {
  param([switch]$ConfigureShell)
  $targetDir = Join-Path $env:LOCALAPPDATA 'agy\bin'
  $target = Join-Path $targetDir 'agy.exe'
  $platform = if ($ARCH -eq 'arm64') { 'windows_arm64' } else { 'windows_amd64' }
  $tmp = Join-Path $WORK ("agy-" + [Guid]::NewGuid().ToString('N') + '.exe')
  try {
    $manifest = Invoke-RestMethod -Uri "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/$platform.json"
    $url = [string]$manifest.url
    $expectedHash = ([string]$manifest.sha512).ToLowerInvariant()
    if (-not $url -or -not ($expectedHash -match '^[0-9a-f]{128}$')) {
      throw 'the Antigravity release manifest was incomplete or malformed'
    }
    Invoke-WebRequest -Uri $url -OutFile $tmp
    $actualHash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA512).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw 'Antigravity download checksum verification failed' }
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    Copy-Item -LiteralPath $tmp -Destination $target -Force
    Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue
    & $target --version *> $null
    if ($LASTEXITCODE -ne 0) { throw 'downloaded Antigravity CLI failed its version check' }
    if ($ConfigureShell) {
      try { & $target install *> $null } catch {}
    }
    Ok "Antigravity CLI $($manifest.version) installed"
    return $true
  } catch {
    Warn "Antigravity CLI update failed: $($_.Exception.Message)"
    return $false
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

# Keep Grok on the vendor-supported installer path. The script runs in a child
# PowerShell process so an upstream `exit` cannot stop Cortex's own installer.
function Install-GrokCliWindows {
  param([string]$BinDir = '')
  # xAI's installer supports GROK_BIN_DIR, while Cortex exposes GROK_HOME as
  # the user-facing provider-home override. Keep the app-selected launcher in
  # that home without changing the vendor's shared ~/.grok auth/config files.
  $hadBinDir = Test-Path Env:GROK_BIN_DIR
  $oldBinDir = $env:GROK_BIN_DIR
  try {
    if (-not [string]::IsNullOrWhiteSpace($BinDir)) { $env:GROK_BIN_DIR = $BinDir }
    return (Invoke-OfficialPowerShellInstaller -Label 'Grok CLI' -Url 'https://x.ai/cli/install.ps1')
  } finally {
    if ($hadBinDir) { $env:GROK_BIN_DIR = $oldBinDir }
    else { Remove-Item Env:GROK_BIN_DIR -ErrorAction SilentlyContinue }
  }
}

function Stop-RunningApp {
  $procs = Get-Process -Name $APP_NAME -ErrorAction SilentlyContinue
  if (-not $procs) { return }
  Warn "$APP_NAME is running - quitting it before replacing the app"
  $procs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (-not (Get-Process -Name $APP_NAME -ErrorAction SilentlyContinue)) { Ok 'stopped running app'; return }
  }
  Get-Process -Name $APP_NAME -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Ok 'stopped running app'
}

try {
  # -- Install the app -------------------------------------------------------
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

  # -- Provision data dir ----------------------------------------------------
  Step "Provisioning $DATA_DIR"
  New-Item -ItemType Directory -Force -Path $DATA_DIR | Out-Null
  $tarPath = Join-Path $WORK $SUPPORT_TAR
  Dl $SUPPORT_TAR $tarPath
  # Windows 10 1803+ ships bsdtar as tar.exe, which reads .tar.gz directly.
  if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
    & tar.exe -xzf $tarPath -C $DATA_DIR
    if ($LASTEXITCODE -ne 0) { Die "could not extract $SUPPORT_TAR" }
  } else {
    Die 'tar.exe not found - Windows 10 1803+ is required.'
  }
  Ok 'extracted bot + support files'

  # -- Pocket release model -------------------------------------------------
  # The model stays a distinct, versioned GitHub Release asset. It is not part
  # of the app archive or Git history; exact SHA-256 checks gate installation
  # and Pocket runs offline after this point.
  Step 'Pocket voice model'
  $pocketModelDir = Join-Path $DATA_DIR 'voice-tts\pocket-model'
  if (Test-PocketReleaseModel -Directory $pocketModelDir) {
    Ok 'verified Pocket model already installed'
  } else {
    if (Test-Path -LiteralPath $pocketModelDir -PathType Container) {
      $item = Get-Item -LiteralPath $pocketModelDir -Force
      if ($item.LinkType) { Die "Pocket model directory must not be a symlink: $pocketModelDir" }
    }
    New-Item -ItemType Directory -Force -Path $pocketModelDir | Out-Null
    foreach ($name in @('model.safetensors', 'tokenizer.model')) {
      $candidate = Join-Path $pocketModelDir $name
      if ((Test-Path -LiteralPath $candidate) -and (Get-Item -LiteralPath $candidate -Force).LinkType) {
        Die "Pocket model file must not be a symlink: $candidate"
      }
    }
    $pocketArchive = Join-Path $WORK $POCKET_MODEL_ASSET
    Dl-PocketModel $pocketArchive
    $pocketStage = Join-Path $pocketModelDir ('.release-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $pocketStage | Out-Null
    $pocketContents = @(& tar.exe -tzf $pocketArchive)
    if ($LASTEXITCODE -ne 0 -or $pocketContents.Count -ne 2 -or $pocketContents[0] -ne 'model.safetensors' -or $pocketContents[1] -ne 'tokenizer.model') {
      Die "$POCKET_MODEL_ASSET has unexpected contents"
    }
    & tar.exe -xzf $pocketArchive -C $pocketStage
    if ($LASTEXITCODE -ne 0 -or -not (Test-PocketReleaseModel -Directory $pocketStage)) {
      Die "$POCKET_MODEL_ASSET failed checksum verification"
    }
    Copy-Item -LiteralPath (Join-Path $pocketStage 'model.safetensors') -Destination (Join-Path $pocketModelDir 'model.safetensors') -Force
    Copy-Item -LiteralPath (Join-Path $pocketStage 'tokenizer.model') -Destination (Join-Path $pocketModelDir 'tokenizer.model') -Force
    Remove-Item -LiteralPath $pocketStage -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-PocketReleaseModel -Directory $pocketModelDir)) {
      Die 'could not install the verified Pocket model'
    }
    Ok 'downloaded and verified Pocket model'
  }

  # -- Bun (powers the WhatsApp bot + data-dir Node deps) --------------------
  # NOT required for the main app - the packaged build bundles its own
  # node_modules. So a Bun failure here warns and continues instead of aborting
  # the whole install (Bun also needs Windows 10 1809+, which not every box has).
  Step 'Bun'
  Sync-Path
  if (Get-Command bun -ErrorAction SilentlyContinue) {
    Ok "bun: $((Get-Command bun).Source)"
  } else {
    Warn 'bun not found - installing...'
    try { Invoke-RestMethod 'https://bun.sh/install.ps1' | Invoke-Expression }
    catch { Warn "bun web installer failed: $($_.Exception.Message)" }
    Sync-Path
    # Fall back to winget if the web installer didn't land bun on PATH.
    if (-not (Get-Command bun -ErrorAction SilentlyContinue) -and (Get-Command winget -ErrorAction SilentlyContinue)) {
      Warn 'trying winget (Oven-sh.Bun)...'
      & winget install --id Oven-sh.Bun -e --silent --accept-source-agreements --accept-package-agreements 2>$null | Out-Null
      Sync-Path
    }
    # The installer drops bun.exe under ~\.bun\bin even when PATH isn't refreshed
    # in this session - pick it up directly before giving up.
    $bunExe = Join-Path $env:USERPROFILE '.bun\bin\bun.exe'
    if (-not (Get-Command bun -ErrorAction SilentlyContinue) -and (Test-Path $bunExe)) {
      $env:Path = "$env:USERPROFILE\.bun\bin;$env:Path"
    }
    if (Get-Command bun -ErrorAction SilentlyContinue) {
      Ok 'bun installed'
    } else {
      Warn 'bun could not be installed (it needs Windows 10 1809+). The app still works; the WhatsApp bot needs bun - install it later from https://bun.sh.'
    }
  }

  # -- Dependencies (delegate to setup.ps1) ----------------------------------
  # setup.ps1 (shipped in the support bundle) installs Node deps via bun, the
  # Python libs, and writes %USERPROFILE%\.cortex-ai-sessions.env. Reuse it so the
  # dependency logic lives in one place - fall back to inline basics if an older
  # bundle predates it.
  Step 'Dependencies (delegating to setup.ps1)'
  # Snapshot user-managed paths and voice settings before setup rewrites the
  # shared config. The later restore also protects these values when the
  # support bundle predates setup-side preservation.
  $preservedConfigBackup = @(Get-PreservedConfigLines -Path $CONFIG)
  Import-CliOverridesFromConfig -Path $CONFIG
  $setup = Join-Path $DATA_DIR 'setup.ps1'
  if (Test-Path $setup) {
    $previousPocketAssets = [Environment]::GetEnvironmentVariable('CORTEX_VOICE_TTS_BUNDLED_ASSET_DIR', 'Process')
    [Environment]::SetEnvironmentVariable(
      'CORTEX_VOICE_TTS_BUNDLED_ASSET_DIR',
      (Join-Path $INSTALL_DIR 'resources\standalone\scripts\voice-assets'),
      'Process'
    )
    & powershell -NoProfile -ExecutionPolicy Bypass -File $setup
    if ($LASTEXITCODE -ne 0) { Warn 'setup.ps1 reported problems (see above)' }
    [Environment]::SetEnvironmentVariable('CORTEX_VOICE_TTS_BUNDLED_ASSET_DIR', $previousPocketAssets, 'Process')
  } else {
    Warn 'setup.ps1 not in support bundle - installing Node deps inline'
    Push-Location $DATA_DIR
    try { & bun install } catch { Warn 'bun install failed' }
    Pop-Location
  }
  Restore-PreservedConfigLines -Path $CONFIG -Lines $preservedConfigBackup
  Import-CliOverridesFromConfig -Path $CONFIG

  # -- Managed local CLI updates ---------------------------------------------
  # A rerunnable Cortex installer is an explicit request to update the stable
  # provider CLIs Cortex manages. Explicit *_BIN overrides and unknown paths
  # remain user-managed, so a failed/foreign CLI can never block app install.
  function Update-ClaudeCli {
    Step 'Claude CLI'
    if (Test-CliOverride 'CLAUDE_BIN') {
      Warn 'CLAUDE_BIN is set; leaving that user-managed Claude CLI unchanged'
      return
    }
    $canonical = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    $officialCanonical = Join-Path $env:LOCALAPPDATA 'Programs\Claude\bin\claude.exe'
    $npmShim = Join-Path $env:APPDATA 'npm\claude.cmd'
    $bin = Get-CliPath -Name 'claude' -CanonicalPaths @($canonical, $officialCanonical) -NpmShim $npmShim
    if (-not $bin) {
      Warn 'claude not found - installing the latest stable Claude CLI...'
      if (Invoke-OfficialPowerShellInstaller -Label 'Claude CLI' -Url 'https://claude.ai/install.ps1') {
        Ok 'Claude CLI installed via the official installer'
      } elseif (Invoke-NpmLatest '@anthropic-ai/claude-code') {
        Ok 'Claude CLI installed via npm'
      } else {
        Warn 'Claude CLI could not be installed - see https://claude.ai/install'
      }
    } elseif (Test-NpmManagedCli -Name 'claude' -Package '@anthropic-ai/claude-code' -Path $bin) {
      Warn 'updating npm-managed Claude CLI...'
      if (Invoke-NpmLatest '@anthropic-ai/claude-code') { Ok 'Claude CLI updated via npm' }
      else { Warn 'Claude npm update failed - keeping the existing CLI' }
    } elseif (Test-ClaudeNativeCli $bin) {
      $updated = $false
      try {
        & $bin update
        $updated = ($LASTEXITCODE -eq 0)
      } catch {}
      if (-not $updated) {
        Warn 'claude update failed; retrying with the official installer...'
        $updated = Invoke-OfficialPowerShellInstaller -Label 'Claude CLI' -Url 'https://claude.ai/install.ps1'
      }
      if ($updated) { Ok 'Claude CLI update completed' }
      else { Warn 'Claude CLI update failed - keeping the existing CLI' }
    } else {
      Warn "leaving externally managed Claude CLI unchanged: $bin"
    }
    Sync-Path
    Show-CliVersion 'claude' (Get-CliPath -Name 'claude' -CanonicalPaths @($canonical, $officialCanonical) -NpmShim $npmShim)
  }

  function Update-CodexCli {
    Step 'Codex CLI'
    if (Test-CliOverride 'CODEX_BIN') {
      Warn 'CODEX_BIN is set; leaving that user-managed Codex CLI unchanged'
      return
    }
    $canonical = Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'
    $npmShim = Join-Path $env:APPDATA 'npm\codex.cmd'
    $bin = Get-CliPath -Name 'codex' -CanonicalPaths @($canonical) -NpmShim $npmShim
    if (-not $bin) {
      Warn 'codex not found - installing the latest stable Codex CLI...'
      if (Invoke-OfficialPowerShellInstaller -Label 'Codex CLI' -Url 'https://chatgpt.com/codex/install.ps1' -Codex) {
        Ok 'Codex CLI installed via the official installer'
      } elseif (Invoke-NpmLatest '@openai/codex') {
        Ok 'Codex CLI installed via npm'
      } else {
        Warn 'Codex CLI could not be installed - see https://chatgpt.com/codex/install.ps1'
      }
    } elseif (Test-NpmManagedCli -Name 'codex' -Package '@openai/codex' -Path $bin) {
      Warn 'updating npm-managed Codex CLI...'
      if (Invoke-NpmLatest '@openai/codex') { Ok 'Codex CLI updated via npm' }
      else { Warn 'Codex npm update failed - keeping the existing CLI' }
    } elseif (Test-CodexNativeCli $bin) {
      Warn 'updating the official Codex CLI...'
      if (Invoke-OfficialPowerShellInstaller -Label 'Codex CLI' -Url 'https://chatgpt.com/codex/install.ps1' -Codex) {
        Ok 'Codex CLI update completed'
      } else {
        Warn 'Codex CLI update failed - keeping the existing CLI'
      }
    } else {
      Warn "leaving externally managed Codex CLI unchanged: $bin"
    }
    Sync-Path
    Show-CliVersion 'codex' (Get-CliPath -Name 'codex' -CanonicalPaths @($canonical) -NpmShim $npmShim)
  }

  function Update-AgyCli {
    Step 'Antigravity CLI'
    if (Test-CliOverride 'AGY_BIN') {
      Warn 'AGY_BIN is set; leaving that user-managed Antigravity CLI unchanged'
      return
    }
    $canonical = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
    $bin = Get-CliPath -Name 'agy' -CanonicalPaths @($canonical)
    if (-not $bin) {
      Warn 'agy not found - installing the latest stable Antigravity CLI...'
      [void](Install-AgyFromManifest -ConfigureShell)
    } elseif (Test-AgyNativeCli $bin) {
      Warn 'checking the verified Antigravity release manifest...'
      [void](Install-AgyFromManifest)
    } else {
      Warn "leaving externally managed Antigravity CLI unchanged: $bin"
    }
    Sync-Path
    Show-CliVersion 'agy' (Get-CliPath -Name 'agy' -CanonicalPaths @($canonical))
  }

  function Update-GrokCli {
    Step 'Grok CLI'
    if (Test-CliOverride 'GROK_BIN') {
      Warn 'GROK_BIN is set; leaving that user-managed Grok CLI unchanged'
      return
    }
    $grokHome = Get-GrokCliHome
    $canonical = Join-Path $grokHome 'bin\grok.exe'
    $npmShim = Join-Path $env:APPDATA 'npm\grok.cmd'
    # Match findGrokBin(): PATH wins, then the configured provider home, then
    # npm.  Otherwise an invisible native Grok can stay old while an unrelated
    # npm shim is updated.
    $bin = Get-CliPath -Name 'grok' -CanonicalPaths @($canonical) -NpmShim $npmShim -PreferCanonical
    if (-not $bin) {
      Warn 'grok not found - installing the latest stable Grok CLI...'
      [void](Install-GrokCliWindows -BinDir (Split-Path -Parent $canonical))
    } elseif (Test-NpmManagedCli -Name 'grok' -Package '@xai-official/grok' -Path $bin) {
      Warn 'updating npm-managed Grok CLI...'
      if (Invoke-NpmLatest '@xai-official/grok') { Ok 'Grok CLI updated via npm' }
      else { Warn 'Grok npm update failed - keeping the existing CLI' }
    } elseif (Test-GrokNativeCli $bin) {
      $updated = $false
      try {
        & $bin update --check --json
        if ($LASTEXITCODE -ne 0) { Warn 'grok update check failed; trying the selected channel update' }
        & $bin update
        $updated = ($LASTEXITCODE -eq 0)
      } catch {}
      if ($updated) {
        Ok 'Grok CLI update completed'
      } else {
        Warn 'Grok CLI update failed - keeping the existing selected channel'
      }
    } else {
      Warn "leaving externally managed Grok CLI unchanged: $bin"
    }
    Sync-Path
    Show-CliVersion 'grok' (Get-CliPath -Name 'grok' -CanonicalPaths @($canonical) -NpmShim $npmShim -PreferCanonical)
  }

  Update-ClaudeCli
  Update-CodexCli
  Update-AgyCli
  Update-GrokCli

  # -- Computer-control MCP server ------------------------------------------
  Step 'Computer-control MCP server'
  $mcpServer = Join-Path $DATA_DIR 'scripts\computer-mcp\server.mjs'
  $nodeCmd = (Get-Command node -ErrorAction SilentlyContinue).Source; if (-not $nodeCmd) { $nodeCmd = 'node' }
  if (-not (Test-Path $mcpServer)) {
    Warn 'server.mjs not in support bundle - skipping computer-control selftest'
  } elseif (-not (Test-Path (Join-Path $DATA_DIR 'node_modules\@nut-tree-fork\nut-js'))) {
    Warn 'MCP Node deps missing - re-run setup.ps1, then test again'
  } else {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
      try { & claude mcp remove -s user computer_control 2>$null | Out-Null } catch {}
      Ok 'removed stale Claude computer-control registration'
    } else { Warn 'claude CLI missing - skipped stale Claude registration cleanup' }
    if (Get-Command codex -ErrorAction SilentlyContinue) {
      try { & codex mcp remove computer_control 2>$null | Out-Null } catch {}
      Ok 'removed stale Codex computer-control registration'
    } else { Warn 'codex CLI missing - skipped stale Codex registration cleanup' }
    $selftest = Join-Path $DATA_DIR 'scripts\computer-mcp\selftest.mjs'
    if (Test-Path $selftest) {
      & $nodeCmd $selftest --node $nodeCmd --server $mcpServer 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { Ok 'computer-control selftest passed' }
      else { Warn 'computer-control selftest failed - live tool calls need attention' }
    } else { Warn 'selftest.mjs missing - could not verify live computer-control tool calls' }
  }

  # -- Obsidian MCP server (vault read/write for agent sessions) -------------
  Step 'Obsidian MCP server'
  $obsidianMcpServer = Join-Path $DATA_DIR 'scripts\obsidian-mcp\server.mjs'
  if (-not (Test-Path $obsidianMcpServer)) {
    Warn 'server.mjs not in support bundle - skipping Obsidian MCP selftest'
  } else {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
      try { & claude mcp remove -s user obsidian 2>$null | Out-Null } catch {}
      try { & claude mcp remove -s local obsidian 2>$null | Out-Null } catch {}
      Ok 'removed stale Claude obsidian registration'
    } else { Warn 'claude CLI missing - skipped stale Claude registration cleanup' }
    if (Get-Command codex -ErrorAction SilentlyContinue) {
      try { & codex mcp remove obsidian 2>$null | Out-Null } catch {}
      Ok 'removed stale Codex obsidian registration'
    } else { Warn 'codex CLI missing - skipped stale Codex registration cleanup' }
    if (-not (Get-Command obsidian -ErrorAction SilentlyContinue)) {
      Warn 'obsidian CLI not found - install Obsidian >=1.12 and enable it (Settings > General > Command line interface)'
    } else {
      $obsidianSelftest = Join-Path $DATA_DIR 'scripts\obsidian-mcp\selftest.mjs'
      if (Test-Path $obsidianSelftest) {
        & $nodeCmd $obsidianSelftest $obsidianMcpServer 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok 'Obsidian MCP selftest passed' }
        else { Warn 'Obsidian MCP selftest failed - the Obsidian app must be running with a vault open' }
      } else { Warn 'selftest.mjs missing - could not verify live Obsidian tool calls' }
    }
  }

  # -- Google Chrome (WhatsApp bot via Puppeteer) ----------------------------
  Step 'Google Chrome'
  $chromePaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  )
  if ($chromePaths | Where-Object { Test-Path $_ }) {
    Ok 'Google Chrome installed'
  } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
    Warn 'Google Chrome not found - installing via winget...'
    & winget install --id Google.Chrome -e --silent --accept-source-agreements --accept-package-agreements 2>$null | Out-Null
    if ($chromePaths | Where-Object { Test-Path $_ }) { Ok 'Google Chrome installed' }
    else { Warn 'install failed - install manually (https://www.google.com/chrome/); needed for the WhatsApp bot.' }
  } else {
    Warn 'Google Chrome not found - install it (https://www.google.com/chrome/); needed for the WhatsApp bot.'
  }

  # -- Other prerequisites (informational) -----------------------------------
  Step 'Other prerequisites (informational)'
  $claudeDesktop = @(
    "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe",
    "$env:LOCALAPPDATA\Programs\Claude\Claude.exe"
  )
  if ($claudeDesktop | Where-Object { Test-Path $_ }) { Ok 'Claude Desktop installed' }
  else { Warn 'Claude Desktop not found - needed to read your claude.ai session.' }
}
finally {
  Remove-Item $WORK -Recurse -Force -ErrorAction SilentlyContinue
}

# -- Done --------------------------------------------------------------------
Write-Host ""
Ok 'Install complete.'
Write-Host ""
Write-Host "  Launch the app:   $APP_EXE"
Write-Host "  WhatsApp bot:     $DATA_DIR\start-bot.cmd"
Write-Host "  Shared state:     $DATA_DIR  (settings.json, sessions.json)"
Write-Host ""
try { Start-Process $APP_EXE } catch {}
