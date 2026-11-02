# Sigil installer for Windows - https://sigilagent.com
#
#   irm https://github.com/sigilagent/sigil/releases/latest/download/install.ps1 | iex
#
# Sigil runs on jac, and jac ships no Windows build yet, so on Windows Sigil runs on
# Linux underneath. Two pathways; this script picks one and sets it up:
#
#   docker  Sigil in a container (docker/Dockerfile), on Docker Desktop. Picked when
#           Docker is running. The container is the service: it restarts with
#           Docker, holds the scheduler and the Observatory, and the code your
#           agent runs stays inside it. Your user folder is mounted at /host.
#   wsl     Sigil inside a WSL2 distro, installed by the same install.sh macOS and
#           Linux use. Picked when Docker is not running and a distro exists.
#
# Either way you get a `sigil` command on your Windows PATH that forwards to it,
# translating the folder you are in and any paths you pass, and the Observatory
# at http://localhost:8199.
#
# Nothing here needs Administrator. Re-running is safe: it updates the install.
#
# Env knobs:
#   SIGIL_MODE        docker | wsl            (default: docker if running, else wsl)
#   SIGIL_REF         branch / tag to install (default: main in the repo copy; a
#                     release asset is rewritten to pin its own tag)
#   SIGIL_IMAGE       docker: the image to run (default: ghcr.io/sigilagent/sigil:<tag>,
#                     built from source when it cannot be pulled)
#   SIGIL_WORKSPACE   docker: the folder mounted at /host  (default: your user folder)
#   SIGIL_WSL_DISTRO  wsl: the distro                      (default: the WSL default)
#   SIGIL_BIN_DIR     where `sigil.cmd` goes  (default: %LOCALAPPDATA%\Sigil\bin)
#   SIGIL_WIZARD=0    skip `sigil setup` at the end
#   SIGIL_AUTOSTART=1|0  wsl: start Sigil when you log in to Windows (asks otherwise)

& {
# Continue, not Stop: Windows PowerShell 5.1 turns a native command's stderr into a
# terminating error under Stop, so `docker version 2>$null` would throw instead of
# failing quietly. Native calls are checked through $LASTEXITCODE; cmdlets that
# must not fail say -ErrorAction Stop.
$ErrorActionPreference = 'Continue'
$Repo = 'sigilagent/sigil'
# Self-pinning releases, as install.sh: the release workflow rewrites this line to
# the tag in the copy it attaches to a GitHub Release.
$DefaultRef = 'main'
$Ref = if ($env:SIGIL_REF) { $env:SIGIL_REF } else { $DefaultRef }

function Info($m) { Write-Host ":: $m" -ForegroundColor Magenta }
function Warn($m) { Write-Host "!! $m" -ForegroundColor Yellow }
function Die($m)  { throw "xx $m" }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function Interactive { [Environment]::UserInteractive -and -not [Console]::IsInputRedirected }
function Ask($q, $default) {
  $hint = if ($default -eq 'Y') { '[Y/n]' } else { '[y/N]' }
  $a = Read-Host "?? $q $hint"
  if (-not $a) { $a = $default }
  return $a -match '^[Yy]'
}

Write-Host "`n  * Sigil installer (Windows)`n" -ForegroundColor Magenta

$Home_ = $env:USERPROFILE
$State = Join-Path $env:LOCALAPPDATA 'Sigil'
$BinDir = if ($env:SIGIL_BIN_DIR) { $env:SIGIL_BIN_DIR } else { Join-Path $State 'bin' }
New-Item -ItemType Directory -Force -Path $State, $BinDir | Out-Null

# wsl.exe writes UTF-16 unless told otherwise; this makes its output readable here.
$env:WSL_UTF8 = '1'
function Wsl-Out { (& wsl.exe @args 2>$null | Out-String) -replace "`0", '' }

function Docker-Running {
  if (-not (Have docker)) { return $false }
  & docker version --format '{{.Server.Version}}' *> $null
  return $LASTEXITCODE -eq 0
}
function Wsl-Distros {
  if (-not (Have wsl.exe)) { return @() }
  return @((Wsl-Out -l -q) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# ---- pick a pathway ----------------------------------------------------------
$Mode = $env:SIGIL_MODE
if (-not $Mode) {
  if (Docker-Running) { $Mode = 'docker' }
  elseif ((Wsl-Distros).Count -gt 0) { $Mode = 'wsl' }
  else {
    Write-Host @"
Sigil needs Linux underneath on Windows, and neither route is ready yet:

  WSL2    open PowerShell as Administrator, run:   wsl --install -d Ubuntu
          restart, finish Ubuntu's first-run setup, then re-run this installer.
  Docker  install Docker Desktop (https://www.docker.com/products/docker-desktop/),
          start it, then re-run this installer.

Details: https://github.com/$Repo/blob/main/docs/reference/windows.md
"@
    return
  }
}
if ($Mode -notin @('docker', 'wsl')) { Die "SIGIL_MODE must be docker or wsl, not '$Mode'." }
Info "Pathway: $Mode"

$Cfg = [ordered]@{ mode = $Mode; ref = $Ref }

if ($Mode -eq 'docker') {
  # ---- docker ----------------------------------------------------------------
  if (-not (Docker-Running)) { Die 'Docker is not running. Start Docker Desktop and re-run.' }
  $Tag = if ($Ref -match '^v\d') { $Ref.Substring(1) } else { 'latest' }
  $Image = if ($env:SIGIL_IMAGE) { $env:SIGIL_IMAGE } else { "ghcr.io/sigilagent/sigil:$Tag" }
  Info "Pulling $Image"
  & docker pull $Image
  if ($LASTEXITCODE -ne 0) {
    # No published image (a branch, or a release from before images were
    # published): build this ref from source. The image must run the jac the tree
    # pins, so read the pin first.
    Warn "could not pull $Image - building Sigil ($Ref) from source instead (several minutes)."
    $toml = (Invoke-WebRequest -UseBasicParsing -ErrorAction Stop "https://raw.githubusercontent.com/$Repo/$Ref/jac.toml").Content
    if ($toml -notmatch '(?m)^jac-version\s*=\s*"=*([0-9][0-9.]*)"') { Die "no jac-version pin in jac.toml at '$Ref'." }
    $Image = 'sigil:local'
    & docker build -t $Image --build-arg "JAC_VERSION=$($Matches[1])" -f docker/Dockerfile "https://github.com/$Repo.git#$Ref"
    if ($LASTEXITCODE -ne 0) { Die 'the image build failed (output above).' }
  }

  $Workspace = if ($env:SIGIL_WORKSPACE) { $env:SIGIL_WORKSPACE } else { $Home_ }
  $Workspace = (Resolve-Path $Workspace -ErrorAction Stop).ProviderPath.TrimEnd('\')

  # Replace the container, keep the volumes: that is an update. The graph lives in
  # sigil-graph, compiled skills in sigil-skills, and the config, secrets and logs
  # in sigil-state.
  & docker container inspect sigil *> $null
  if ($LASTEXITCODE -eq 0) {
    Info 'Replacing the existing Sigil container (your graph and settings stay in their volumes)...'
    & docker rm -f sigil | Out-Null
  }
  # 8199 the Observatory, 1455 browser sign-ins (ChatGPT, OpenRouter): loopback
  # only, so nothing on your network reaches them. host.docker.internal is how
  # the container reaches an Ollama running on Windows.
  $run = @('run', '-d', '--name', 'sigil', '--init', '--restart', 'unless-stopped',
           '-p', '127.0.0.1:8199:8199', '-p', '127.0.0.1:1455:1455',
           '--add-host', 'host.docker.internal:host-gateway',
           '-e', "OLLAMA_HOST=$(if ($env:OLLAMA_HOST) { $env:OLLAMA_HOST } else { 'http://host.docker.internal:11434' })",
           '-v', 'sigil-state:/home/jac/.sigil', '-v', 'sigil-graph:/opt/jac/state/pg',
           '-v', 'sigil-skills:/opt/sigil/app/src/crystallized',
           '-v', "${Workspace}:/host", $Image)
  Info 'Starting Sigil...'
  & docker @run | Out-Null
  if ($LASTEXITCODE -ne 0) { Die 'docker run failed (output above).' }
  $Cfg.container = 'sigil'
  $Cfg.workspace = $Workspace
  $Cfg.image = $Image
} else {
  # ---- wsl -------------------------------------------------------------------
  $distros = Wsl-Distros
  if ($distros.Count -eq 0) { Die 'no WSL distro found. Run `wsl --install -d Ubuntu` (as Administrator), restart, and re-run.' }
  # The distro, named explicitly from here on so the installer and the shim agree:
  # SIGIL_WSL_DISTRO, else the one `wsl -l -v` stars as default, else the first.
  $verbose = Wsl-Out -l -v
  $name = $env:SIGIL_WSL_DISTRO
  if (-not $name) { $name = ($verbose -split "`r?`n" | Where-Object { $_ -match '^\s*\*' } | Select-Object -First 1) -replace '^\s*\*\s*', '' -replace '\s+.*$', '' }
  if (-not $name) { $name = $distros[0] }
  $d = @('-d', $name)
  # WSL1 cannot run jac's embedded Postgres reliably; say so instead of failing later.
  if ($verbose -match "(?m)^\s*\*?\s*$([regex]::Escape($name))\s+\S+\s+1\s*$") {
    Die "$name is a WSL1 distro. Convert it: wsl --set-version $name 2"
  }
  Info "Installing Sigil inside WSL ($name) with the regular installer..."
  $url = "https://raw.githubusercontent.com/$Repo/$Ref/install.sh"
  if ($Ref -match '^v\d') { $url = "https://github.com/$Repo/releases/download/$Ref/install.sh" }
  # Start-at-login is a Windows scheduled task below, not systemd: WSL stops an idle
  # distro, and a task holding `wsl.exe` open is what keeps it up.
  & wsl.exe @d --exec env "SIGIL_REF=$Ref" SIGIL_AUTOSTART=0 "SIGIL_WIZARD=$(if ($env:SIGIL_WIZARD) { $env:SIGIL_WIZARD } else { '1' })" bash -c "curl -fsSL '$url' | bash"
  if ($LASTEXITCODE -ne 0) { Die 'the install inside WSL failed (output above).' }
  # No double quotes in arguments to native commands: Windows PowerShell 5.1 passes
  # them unescaped, and WSL would receive a different command.
  $linuxHome = (Wsl-Out @d --exec sh -c 'echo $HOME').Trim()
  if (-not $linuxHome) { Die 'could not read your home folder inside WSL.' }
  $Cfg.distro = $name
  $Cfg.sigil = "$linuxHome/.local/bin/sigil"

  $auto = $env:SIGIL_AUTOSTART
  if (-not $auto -and (Interactive)) { $auto = if (Ask 'Start Sigil when you log in to Windows?' 'Y') { '1' } else { '0' } }
  if ($auto -eq '1') {
    # The daemon in the foreground, as the macOS/Linux login service runs it, with
    # the variable that service sets to bring the Observatory up too.
    $wslArgs = "-d $name --exec env SIGIL_SERVICE_SERVE=1 $($Cfg.sigil) daemon run 30"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
      -Argument "-NoProfile -WindowStyle Hidden -Command `"wsl.exe $wslArgs`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    try {
      Register-ScheduledTask -TaskName 'Sigil' -Action $action -Trigger $trigger -Settings $settings -Force -ErrorAction Stop | Out-Null
      Start-ScheduledTask -TaskName 'Sigil' -ErrorAction Stop
      Info 'Sigil starts when you log in (scheduled task "Sigil"). Undo: Unregister-ScheduledTask Sigil'
    } catch {
      Warn "could not add the login task: $($_.Exception.Message)"
      Warn '  start it by hand instead: sigil daemon start'
    }
  }
}

# ---- the `sigil` command -----------------------------------------------------
($Cfg | ConvertTo-Json) | Set-Content -Encoding UTF8 (Join-Path $State 'config.json')

# A .cmd, not a .ps1 on PATH: Windows' default execution policy blocks scripts, and
# PowerShell would pick a sigil.ps1 over sigil.cmd. The .cmd hands off to the shim
# with the policy bypassed for that one process.
Set-Content -Encoding ASCII (Join-Path $BinDir 'sigil.cmd') @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sigil-shim.ps1" %*
exit /b %ERRORLEVEL%
"@

Set-Content -Encoding UTF8 (Join-Path $BinDir 'sigil-shim.ps1') @'
# sigil-shim.ps1: forwards `sigil` from Windows to Sigil in Docker or WSL.
# Written by install.ps1, which records the pathway in %LOCALAPPDATA%\Sigil\config.json.
# Continue, not Stop: under Stop, Windows PowerShell 5.1 makes docker's stderr fatal.
$cfgPath = Join-Path $env:LOCALAPPDATA 'Sigil\config.json'
if (-not (Test-Path $cfgPath)) { [Console]::Error.WriteLine("sigil: not installed - run the installer again."); exit 1 }
$cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json
$cwd = (Get-Location).ProviderPath

# `sigil update` re-runs this installer: inside Docker, install.sh would update a
# container that is about to be replaced; in WSL it would skip the Windows side.
if ($args.Count -gt 0 -and $args[0] -eq 'update') {
  $u = 'https://github.com/sigilagent/sigil/releases/latest/download/install.ps1'
  if ($env:SIGIL_INSTALL_PS1_URL) { $u = $env:SIGIL_INSTALL_PS1_URL }
  Invoke-Expression (Invoke-RestMethod $u); exit 0
}

# Windows paths -> Linux paths, for the folder you are in and for any argument that
# names an existing file or folder (`sigil compile .\SKILL.md`, `C:\data\a.csv`).
function Map-Path([string]$p) {
  $full = [IO.Path]::GetFullPath((Join-Path $cwd $p))
  if ($cfg.mode -eq 'docker') {
    $ws = [string]$cfg.workspace
    if ($full -ieq $ws) { return '/host' }
    if ($full.StartsWith($ws + '\', [StringComparison]::OrdinalIgnoreCase)) {
      return '/host/' + $full.Substring($ws.Length + 1).Replace('\', '/')
    }
    return $null
  }
  if ($full -match '^([A-Za-z]):\\?(.*)$') { return '/mnt/' + $Matches[1].ToLower() + '/' + $Matches[2].Replace('\', '/') }
  return $null
}
$fwd = @(foreach ($a in $args) {
  $s = [string]$a
  if ($s -match '[\\/]' -and $s -notmatch '^[a-z]+://' -and (Test-Path -LiteralPath $s)) {
    $m = Map-Path $s
    if ($m) { $m } else { $s }
  } else { $s }
})

if ($cfg.mode -eq 'docker') {
  $state = (& docker container inspect -f '{{.State.Running}}' $cfg.container 2>$null)
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("sigil: Docker is not running, or the '$($cfg.container)' container is gone. Start Docker Desktop; if that is not it, re-run the installer.")
    exit 1
  }
  if ($state -ne 'true') { & docker start $cfg.container | Out-Null }
  $inside = Map-Path '.'
  if (-not $inside) {
    [Console]::Error.WriteLine("sigil: $cwd is outside $($cfg.workspace), the folder Sigil's container can see; running from there instead.")
    $inside = '/host'
  }
  $flags = @('exec', '-i', '-w', $inside, '-e', "SIGIL_PWD=$inside")
  # -t only on a real terminal: a pipe (Claude Code's MCP stdio, a script) must
  # stay a plain stream, and docker refuses -t without a TTY.
  if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) { $flags += '-t' }
  & docker @flags $cfg.container sigil @fwd
  exit $LASTEXITCODE
}

& wsl.exe -d $cfg.distro --cd $cwd --exec $cfg.sigil @fwd
exit $LASTEXITCODE
'@

# PATH: the user's, persistently, and this session's, now.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($userPath -split ';') -contains $BinDir)) {
  [Environment]::SetEnvironmentVariable('Path', ($(if ($userPath) { "$userPath;" } else { '' }) + $BinDir), 'User')
  Info "Added $BinDir to your PATH (new terminals pick it up)."
}
if (-not (($env:Path -split ';') -contains $BinDir)) { $env:Path = "$env:Path;$BinDir" }

# ---- first run ---------------------------------------------------------------
# WSL ran install.sh's own wizard already; the container has not met you yet.
if ($Mode -eq 'docker' -and $env:SIGIL_WIZARD -ne '0' -and (Interactive)) {
  & (Join-Path $BinDir 'sigil.cmd') setup
  if ($LASTEXITCODE -ne 0) { Warn 'setup did not finish - run `sigil setup` when you are ready.' }
}

Write-Host "`n  OK: Sigil installed ($Mode)`n" -ForegroundColor Green
Write-Host @"
    sigil                              # chat with your agent
    sigil compile .\SKILL.md           # compile a skill
    http://localhost:8199              # the Observatory (first start takes a minute or two)

  Docs: https://github.com/$Repo/blob/main/docs/reference/windows.md
"@
}
