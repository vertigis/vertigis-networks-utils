#Requires -Version 5.1

<#
.SYNOPSIS
    Sewer Backend - Deployment Script (Windows)

.DESCRIPTION
    Deploys the consolidated Sewer backend (all services in one container,
    port 8080) on a Windows host, as a Linux container (Docker Desktop, Podman)
    or a Windows container (Docker Engine).

    Features: new/update/dry-run modes, Docker or Podman (auto-detected),
    configuration file, registry login, readiness check, offline use of a
    pre-loaded image.

.PARAMETER Version
    Image version to deploy, for example 2.2.0. The Windows image tag gets the
    Windows Server suffix of the host, for example 2.2.0-ltsc2022.

.PARAMETER EnvFile
    Environment file passed to the container. Default: sewer.env, if it exists.

.PARAMETER ConfigFile
    Configuration file path. Default: sewer-consolidated-deployment.conf

.PARAMETER Mode
    Deployment mode: new|update (default: new)

.PARAMETER Update
    Replace an existing container (same as -Mode update)

.PARAMETER Runtime
    Container runtime: docker|podman (default: auto-detect)

.PARAMETER ContainerType
    Container OS: linux|windows (default: windows on Windows Server, otherwise linux)

.PARAMETER Image
    Full image name; overrides -Version

.PARAMETER Port
    Host port (default: 8080)

.PARAMETER CorsOrigin
    Comma-separated CORS origins

.PARAMETER AcrUser
    Container registry user name

.PARAMETER AcrPass
    Container registry password

.PARAMETER NoPull
    Use an image that is already on the host (for example loaded with docker load);
    no registry login, no pull

.PARAMETER DryRun
    Show what would be done without making changes

.EXAMPLE
    .\sewer_windows.ps1 -Version 2.2.0
    Deploy version 2.2.0; prompts for the registry credentials

.EXAMPLE
    .\sewer_windows.ps1 -Version 2.2.1 -Update
    Replace the running container with version 2.2.1

.EXAMPLE
    docker load -i sewer-windows-2.2.0-ltsc2022.tar
    .\sewer_windows.ps1 -Version 2.2.0 -NoPull
    Deploy on a host without registry access
#>

[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$DryRun,
    [string]$ConfigFile = "sewer-consolidated-deployment.conf",
    [ValidateSet("new", "update")]
    [string]$Mode = "new",
    [switch]$Update,
    [ValidateSet("docker", "podman", "")]
    [string]$Runtime = "",
    [ValidateSet("linux", "windows", "")]
    [string]$ContainerType = "",
    [string]$Version = "",
    [string]$EnvFile = "",
    [string]$Image = "",
    [string]$Port = "",
    [string]$CorsOrigin = "",
    [string]$AcrUser = "",
    [string]$AcrPass = "",
    [switch]$NoPull
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Help) { Get-Help $PSCommandPath -Detailed; return }
if ($Update) { $Mode = 'update' }

# PowerShell variable names are not case-sensitive: none of the names below may
# repeat a parameter name.
$ScriptTitle   = "Sewer Deployment"
$ScriptVersion = "2.0"
$LogFile       = Join-Path $env:TEMP ("sewer-deployment-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$ForceRun      = $env:FORCE -eq "yes"
$CanPrompt     = (-not $ForceRun) -and ($Host.Name -ne 'ServerRemoteHost') -and (-not [Console]::IsInputRedirected)
$ContainerName = "sewer"
$InternalPort  = 8080

$Cfg = @{
    ImageName     = ""
    Version       = ""
    Port          = "8080"
    AcrUser       = ""
    AcrPass       = ""
    CorsOrigin    = ""
    Runtime       = ""
    ContainerType = ""
    Registry      = "vertigisapps.azurecr.io"
    EnvFile       = ""
    MediaVolume   = "sewer-media"
    LogsVolume    = "sewer-import-logs"
}

$Rt = @{
    Engine        = ""   # docker | podman
    Os            = ""   # linux | windows
    DockerContext = ""
    WindowsBuild  = ""   # ltsc2022, ...
    Image         = ""   # full image reference
}

$CreatedContainers = New-Object System.Collections.ArrayList

# ==============================
# Logging
# ==============================
function Write-ColorOutput {
    param([string]$Message, [ConsoleColor]$Color = 'White')
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}
function Write-Section { param([string]$M) Write-ColorOutput "`n=== $M ===" Blue }
function Write-Ok      { param([string]$M) Write-ColorOutput "[OK]   $M" Green }
function Write-Info    { param([string]$M) Write-ColorOutput "[i]    $M" Yellow }
function Write-Err     { param([string]$M) Write-ColorOutput "[ERR]  $M" Red }
function Write-Warn    { param([string]$M) Write-ColorOutput "[WARN] $M" Yellow }

# ==============================
# Configuration
# ==============================
function Import-ConfigFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        # Relative names are also looked up next to the script.
        $besideScript = Join-Path $PSScriptRoot $Path
        if (-not [IO.Path]::IsPathRooted($Path) -and (Test-Path $besideScript)) { $Path = $besideScript }
        else { Write-Info "No config file ($Path), using parameters and defaults"; return }
    }
    Write-Info "Loading config: $Path"
    foreach ($line in (Get-Content $Path)) {
        $line = $line.Trim()
        if ($line.StartsWith('#') -or $line -eq '') { continue }
        $parts = $line -split '=', 2
        if ($parts.Count -ne 2) { continue }
        $k = $parts[0].Trim(); $v = $parts[1].Trim().Trim('"')
        if (-not $v) { continue }
        switch ($k) {
            'IMAGE_NAME'     { $Cfg.ImageName = $v }
            'VERSION'        { $Cfg.Version = $v }
            'PORT'           { $Cfg.Port = $v }
            'ACR_USER'       { $Cfg.AcrUser = $v }
            'ACR_PASS'       { $Cfg.AcrPass = $v }
            'CORS_ORIGIN'    { $Cfg.CorsOrigin = $v }
            'RUNTIME'        { $Cfg.Runtime = $v }
            'CONTAINER_TYPE' { $Cfg.ContainerType = $v }
            'REGISTRY'       { $Cfg.Registry = $v }
            'ENV_FILE'       { $Cfg.EnvFile = $v }
            'MEDIA_VOLUME'   { $Cfg.MediaVolume = $v }
            'LOGS_VOLUME'    { $Cfg.LogsVolume = $v }
        }
    }
    Write-Ok "Config loaded"
}

# ==============================
# Runtime detection
# ==============================
function Get-WindowsBuildTag {
    $build = [Environment]::OSVersion.Version.Build
    switch ($build) {
        17763 { return 'ltsc2019' }
        20348 { return 'ltsc2022' }
        26100 { return 'ltsc2025' }
        default { return '' }
    }
}

function Invoke-ContainerCmd {
    # Windows PowerShell 5.1 turns redirected stderr of a native command into
    # errors; with "Stop" a harmless message would end the script.
    $ErrorActionPreference = 'Continue'
    $cmdArgs = @($args)
    if ($Rt.Engine -eq "docker") {
        if ($Rt.DockerContext) { $cmdArgs = @("--context", $Rt.DockerContext) + $cmdArgs }
        & docker @cmdArgs
    }
    else {
        & podman @cmdArgs
    }
}

function Resolve-Runtime {
    $hasDocker = $null -ne (Get-Command docker -ErrorAction SilentlyContinue)
    $hasPodman = $null -ne (Get-Command podman -ErrorAction SilentlyContinue)
    $isServer  = (Get-CimInstance Win32_OperatingSystem).ProductType -ne 1

    # Container OS
    if ($Cfg.ContainerType) { $Rt.Os = $Cfg.ContainerType }
    elseif ($Cfg.ImageName -match '-windows') { $Rt.Os = "windows" }
    elseif ($isServer) { $Rt.Os = "windows" }
    else { $Rt.Os = "linux" }

    # Engine
    if ($Cfg.Runtime) { $Rt.Engine = $Cfg.Runtime }
    elseif ($Rt.Os -eq 'windows') { $Rt.Engine = "docker" }
    elseif ($hasPodman) { $Rt.Engine = "podman" }
    elseif ($hasDocker) { $Rt.Engine = "docker" }
    else { Write-Err "No container runtime found. Install Docker or Podman."; exit 1 }

    if ($Rt.Engine -eq "docker" -and -not $hasDocker) { Write-Err "Docker is not installed"; exit 1 }
    if ($Rt.Engine -eq "podman" -and -not $hasPodman) { Write-Err "Podman is not installed"; exit 1 }
    if ($Rt.Os -eq "windows" -and $Rt.Engine -eq "podman") {
        Write-Err "Podman does not support Windows containers. Use -Runtime docker"; exit 1
    }

    # Docker Desktop keeps Windows containers in a separate context.
    if ($Rt.Os -eq "windows" -and $Rt.Engine -eq "docker") {
        $contexts = docker context ls --format '{{.Name}}' 2>$null
        if ($contexts -contains 'windows-docker') { $Rt.DockerContext = "windows-docker" }
        $Rt.WindowsBuild = Get-WindowsBuildTag
    }

    if (-not $DryRun) {
        $null = Invoke-ContainerCmd info 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Err "$($Rt.Engine) is not running"; exit 1 }
        if ($Rt.Engine -eq "docker") {
            $osType = (Invoke-ContainerCmd info --format '{{.OSType}}' 2>$null | Out-String).Trim()
            if ($osType -and $osType -ne $Rt.Os) {
                Write-Err "Docker runs $osType containers, but a $($Rt.Os) container is requested. Switch the engine or use -ContainerType $osType"
                exit 1
            }
        }
    }

    $ctx = if ($Rt.DockerContext) { " (context $($Rt.DockerContext))" } else { "" }
    Write-Ok "Runtime: $($Rt.Engine)$ctx | container OS: $($Rt.Os)"
}

function Resolve-Image {
    $img = $Cfg.ImageName
    if (-not $img) {
        if (-not $Cfg.Version) {
            if ($CanPrompt) { $Cfg.Version = Read-Host "Version to deploy (for example 2.2.0)" }
            if (-not $Cfg.Version) { Write-Err "No version given. Use -Version <x.y.z> or -Image"; exit 1 }
        }
        if ($Rt.Os -eq 'windows') {
            if (-not $Rt.WindowsBuild) {
                Write-Err "No Windows image for this host (build $([Environment]::OSVersion.Version.Build)). The Windows image is built for Windows Server 2022 (ltsc2022)."
                exit 1
            }
            $img = "networks/sewer-windows:$($Cfg.Version)-$($Rt.WindowsBuild)"
        }
        else {
            $img = "networks/sewer:$($Cfg.Version)"
        }
    }
    # Add the registry unless the name already has one (contains a host with a dot or port).
    $firstPart = $img.Split('/')[0]
    if (-not ($img.Contains('/') -and ($firstPart.Contains('.') -or $firstPart.Contains(':')))) {
        $img = "$($Cfg.Registry)/$img"
    }
    $Rt.Image = $img
}

# ==============================
# Helpers
# ==============================
function Test-PortInUse {
    param([int]$PortNum)
    $listener = Get-NetTCPConnection -LocalPort $PortNum -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $listener)
}

function Get-ContainerPath([string]$LinuxPath) {
    if ($Rt.Os -eq 'windows') { return 'C:' + $LinuxPath.Replace('/', '\') }
    return $LinuxPath
}

# ==============================
# Container operations
# ==============================
function Connect-Registry {
    Write-Section "Registry Authentication"
    if ($NoPull) { Write-Info "Skipped (-NoPull)"; return }
    if ($DryRun) { Write-Info "[DRY] $($Rt.Engine) login $($Cfg.Registry)"; return }
    if (-not $Cfg.AcrUser -or -not $Cfg.AcrPass) {
        Write-Info "No credentials given, using the existing login for $($Cfg.Registry)"
        return
    }
    $prefix = if ($Rt.DockerContext) { @('--context', $Rt.DockerContext) } else { @() }
    $Cfg.AcrPass | & $Rt.Engine @prefix login $Cfg.Registry -u $Cfg.AcrUser --password-stdin
    if ($LASTEXITCODE -eq 0) { Write-Ok "Logged in to $($Cfg.Registry)" }
    else { Write-Err "Login failed"; exit 1 }
}

function Get-Image {
    Write-Section "Image"
    if ($NoPull) {
        if ($DryRun) { Write-Info "[DRY] use local image $($Rt.Image)"; return }
        $null = Invoke-ContainerCmd image inspect $Rt.Image 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Err "Image not found on this host: $($Rt.Image)"; exit 1 }
        Write-Ok "Using local image $($Rt.Image)"
        return
    }
    Write-Info "Pulling: $($Rt.Image)"
    if ($DryRun) { Write-Info "[DRY] pull $($Rt.Image)"; return }
    Invoke-ContainerCmd pull $Rt.Image
    if ($LASTEXITCODE -ne 0) { Write-Err "Pull failed: $($Rt.Image)"; exit 1 }
    Write-Ok "Image pulled"
}

function Get-ServiceStatus {
    if ($Rt.Os -eq 'windows') {
        $out = Invoke-ContainerCmd exec $ContainerName powershell -NoProfile -File C:\app\start-services.ps1 -Status 2>&1
    }
    else {
        $out = Invoke-ContainerCmd exec $ContainerName supervisorctl -c /etc/supervisor/conf.d/sewer.conf status 2>&1
    }
    $ok = $LASTEXITCODE -eq 0
    $lines = @($out | ForEach-Object { "$_" } | Where-Object { $_ })
    if ($ok -and $lines.Count -ge 5 -and -not ($lines | Where-Object { $_ -notmatch 'RUNNING' })) {
        return @{ Ready = $true; Lines = $lines }
    }
    return @{ Ready = $false; Lines = $lines }
}

# Ready when every service in the container runs; works also where the runtime
# does not evaluate the image health check.
function Wait-ContainerReady {
    $maxAttempts = if ($Rt.Os -eq "windows") { 36 } else { 24 }
    $waitSecs = 5
    Write-Info "Waiting for readiness (up to $($maxAttempts * $waitSecs)s)..."

    for ($i = 1; $i -le $maxAttempts; $i++) {
        $state = (Invoke-ContainerCmd inspect --format "{{.State.Status}}" $ContainerName 2>$null | Out-String).Trim()
        if ($state -ne 'running') {
            Write-Err "Container is not running (state: $state). Logs:"
            Invoke-ContainerCmd logs --tail 50 $ContainerName 2>&1 | Out-Host
            return $false
        }
        $status = Get-ServiceStatus
        if ($status.Ready) {
            $status.Lines | ForEach-Object { Write-Info "  $_" }
            Write-Ok "All services are running"
            return $true
        }
        Write-Info "Waiting... ($i/$maxAttempts) services are starting"
        Start-Sleep -Seconds $waitSecs
    }

    Write-Err "Not ready after $($maxAttempts * $waitSecs)s. Logs:"
    Invoke-ContainerCmd logs --tail 50 $ContainerName 2>&1 | Out-Host
    return $false
}

function Deploy-Application {
    Write-Section "Deploying $ContainerName"

    $existing = Invoke-ContainerCmd ps -a --format '{{.Names}}' 2>$null | Where-Object { $_ -eq $ContainerName }
    if ($existing) {
        if ($Mode -ne 'update') { Write-Warn "Container $ContainerName exists. Use -Update to replace it."; return }
        Write-Info "Removing existing container"
        if (-not $DryRun) { Invoke-ContainerCmd rm -f $ContainerName 2>$null | Out-Null }
    }
    elseif ($Mode -eq 'update') {
        Write-Info "No existing container, installing new"
    }

    if (-not $DryRun -and (Test-PortInUse ([int]$Cfg.Port))) { Write-Err "Port $($Cfg.Port) is in use"; exit 1 }

    # Named volumes keep media and import logs across updates.
    foreach ($volume in $Cfg.MediaVolume, $Cfg.LogsVolume) {
        if ($DryRun) { Write-Info "[DRY] volume create $volume"; continue }
        $null = Invoke-ContainerCmd volume inspect $volume 2>$null
        if ($LASTEXITCODE -ne 0) {
            Invoke-ContainerCmd volume create $volume | Out-Null
            Write-Ok "Created volume $volume"
        }
    }

    # The image has its own health check and runs the services itself.
    $runArgs = @(
        'run', '-d',
        '--name', $ContainerName,
        '--restart', 'unless-stopped',
        '-p', "$($Cfg.Port):$InternalPort"
    )
    if ($Cfg.EnvFile) { $runArgs += @('--env-file', $Cfg.EnvFile) }
    if ($Cfg.CorsOrigin) { $runArgs += @('-e', "CORS_ORIGIN=$($Cfg.CorsOrigin)") }
    $runArgs += @(
        '--mount', "type=volume,source=$($Cfg.MediaVolume),target=$(Get-ContainerPath '/app/media')",
        '--mount', "type=volume,source=$($Cfg.LogsVolume),target=$(Get-ContainerPath '/app/sewer-management/ImportLogs')",
        $Rt.Image
    )

    if ($DryRun) { Write-Info "[DRY] $($Rt.Engine) $($runArgs -join ' ')"; return }

    Invoke-ContainerCmd @runArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err "Failed to start the container"; exit 1 }
    [void]$CreatedContainers.Add($ContainerName)

    if (Wait-ContainerReady) {
        Write-Ok "$ContainerName deployed"
        Invoke-ContainerCmd ps --filter "name=$ContainerName"
    }
    else {
        Write-Err "Deployment failed"
        exit 1
    }
}

# ==============================
# MAIN
# ==============================
Set-Content -Path $LogFile -Value "=== $ScriptTitle - $(Get-Date) ==="
Write-Section "$ScriptTitle v$ScriptVersion"
if ($DryRun) { Write-Warn "DRY RUN MODE" }

Import-ConfigFile $ConfigFile

# Parameters override the config file
if ($Image)         { $Cfg.ImageName = $Image }
if ($Version)       { $Cfg.Version = $Version }
if ($Port)          { $Cfg.Port = $Port }
if ($AcrUser)       { $Cfg.AcrUser = $AcrUser }
if ($AcrPass)       { $Cfg.AcrPass = $AcrPass }
if ($CorsOrigin)    { $Cfg.CorsOrigin = $CorsOrigin }
if ($Runtime)       { $Cfg.Runtime = $Runtime }
if ($ContainerType) { $Cfg.ContainerType = $ContainerType }
if ($EnvFile)       { $Cfg.EnvFile = $EnvFile }

if (-not $Cfg.EnvFile -and (Test-Path 'sewer.env')) { $Cfg.EnvFile = 'sewer.env' }
if ($Cfg.EnvFile -and -not (Test-Path $Cfg.EnvFile)) { Write-Err "Environment file not found: $($Cfg.EnvFile)"; exit 1 }
if ($Cfg.EnvFile) { $Cfg.EnvFile = (Resolve-Path $Cfg.EnvFile).Path }

$portNumber = 0
if (-not [int]::TryParse($Cfg.Port, [ref]$portNumber) -or $portNumber -lt 1 -or $portNumber -gt 65535) {
    Write-Err "Invalid port: $($Cfg.Port)"; exit 1
}

Resolve-Runtime
Resolve-Image

if (-not $NoPull -and -not $DryRun -and $CanPrompt) {
    if (-not $Cfg.AcrUser) { $Cfg.AcrUser = Read-Host "Registry user name for $($Cfg.Registry) (empty: use existing login)" }
    if ($Cfg.AcrUser -and -not $Cfg.AcrPass) {
        $sec = Read-Host "Registry password" -AsSecureString
        $Cfg.AcrPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    }
}

$envLabel = if ($Cfg.EnvFile) { $Cfg.EnvFile } else { '<none>' }
Write-Info "  Mode:      $Mode"
Write-Info "  Runtime:   $($Rt.Engine)"
Write-Info "  OS:        $($Rt.Os)"
Write-Info "  Image:     $($Rt.Image)"
Write-Info "  Port:      $($Cfg.Port)"
Write-Info "  Env file:  $envLabel"
Write-Info "  Volumes:   $($Cfg.MediaVolume), $($Cfg.LogsVolume)"
if (-not $Cfg.EnvFile -and -not $Cfg.CorsOrigin) {
    Write-Warn "Neither an environment file nor CORS origins are set. The web application cannot call the backend until CORS_ORIGIN is set."
}

if (-not $DryRun -and $CanPrompt) {
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -notin @('y', 'Y')) { Write-Info "Cancelled"; return }
}

try {
    Connect-Registry
    Get-Image
    Deploy-Application
    Write-Section "Deployment Complete"
    Write-Ok "$ContainerName listens on port $($Cfg.Port)"
    Write-Info "Log: $LogFile"
}
catch {
    Write-Err "Deployment failed: $_"
    foreach ($c in $CreatedContainers) { Invoke-ContainerCmd rm -f $c 2>$null | Out-Null }
    throw
}
