#Requires -Version 5.1

<#
.SYNOPSIS
    Sewer Services - Deployment Script (Windows)

.DESCRIPTION
    Deploys SewerManagement or Condition Classification container:
    - Multiple deployment modes (new/update/dry-run)
    - Container runtime: Docker or Podman (auto-detected)
    - Container OS: Linux or Windows containers (auto-detected)
    - Configuration file support
    - Health check with TCP fallback

.PARAMETER Service
    Service to deploy: sewer | sewercc (required)

.PARAMETER Help
    Show help information

.PARAMETER ConfigFile
    Configuration file path

.PARAMETER Mode
    Deployment mode: new|update (default: new)

.PARAMETER Update
    Update existing deployment

.PARAMETER Runtime
    Container runtime: docker|podman (default: auto-detect)

.PARAMETER ContainerType
    Container OS: linux|windows (default: auto-detect from image name)

.PARAMETER Image
    Docker/Podman image name

.PARAMETER Port
    Host port for API

.PARAMETER CorsOrigin
    Comma-separated CORS origins

.PARAMETER AcrUser
    Azure Container Registry username

.PARAMETER AcrPass
    Azure Container Registry password

.PARAMETER DryRun
    Show what would be done without making changes

.EXAMPLE
    .\sewer_windows.ps1 -Service sewer
    Deploy SewerManagement with prompts

.EXAMPLE
    .\sewer_windows.ps1 -Service sewercc -Update
    Update Condition Classification container

.EXAMPLE
    .\sewer_windows.ps1 -Service sewer -Runtime docker -ContainerType windows
    Deploy SewerManagement Windows container via Docker
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("sewer", "sewercc")]
    [string]$Service,
    [switch]$Help,
    [switch]$DryRun,
    [string]$ConfigFile = "",
    [ValidateSet("new", "update")]
    [string]$Mode = "new",
    [switch]$Update,
    [ValidateSet("docker", "podman", "")]
    [string]$Runtime = "",
    [ValidateSet("linux", "windows", "")]
    [string]$ContainerType = "",
    [string]$Image = "",
    [string]$Port = "",
    [string]$CorsOrigin = "",
    [string]$AcrUser = "",
    [string]$AcrPass = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Globals
$script:SCRIPT_NAME = "Sewer Deployment"
$script:VERSION = "1.0"
$script:LOG_FILE = Join-Path $env:TEMP ("sewer-deployment-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# Defaults (resolved per service)
$script:REGISTRY_NAME = "vertigisnetworks.azurecr.io"
$script:DEFAULT_IMAGE = ""
$script:DEFAULT_PORT = 0
$script:CONTAINER_NAME = ""
$script:INTERNAL_PORT = 0

# Runtime state
$script:RUNTIME = ""
$script:CONTAINER_OS = ""
$script:DOCKER_CONTEXT = ""

# State
$script:CREATED_CONTAINERS = @()
$script:FORCE = $env:FORCE -eq "yes"
$script:CAN_PROMPT = (-not $script:FORCE) -and ($Host.Name -ne 'ServerRemoteHost') -and (-not [Console]::IsInputRedirected)

# Config
$script:CFG = @{
    ImageName     = ""
    Port          = ""
    AcrUser       = ""
    AcrPass       = ""
    CorsOrigin    = ""
    Runtime       = ""
    ContainerType = ""
    Registry      = ""
}

# ==============================
# Logging
# ==============================
function Write-ColorOutput {
    param([string]$Message, [ConsoleColor]$Color = 'White')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$ts $Message"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $script:LOG_FILE -Value $line -ErrorAction SilentlyContinue
}
function Write-Section  { param([string]$M) Write-ColorOutput "`n=== $M ===" Blue }
function Write-Ok       { param([string]$M) Write-ColorOutput "[OK]   $M" Green }
function Write-Info     { param([string]$M) Write-ColorOutput "[i]    $M" Yellow }
function Write-Err      { param([string]$M) Write-ColorOutput "[ERR]  $M" Red }
function Write-Warn     { param([string]$M) Write-ColorOutput "[WARN] $M" Yellow }

# ==============================
# Service resolution
# ==============================
function Resolve-Service {
    switch ($Service) {
        'sewer' {
            $script:CONTAINER_NAME = "sewer-service"
            $script:DEFAULT_IMAGE = "networks/sewer:latest"
            $script:DEFAULT_PORT = 5050
            $script:INTERNAL_PORT = 5050
            if ([string]::IsNullOrWhiteSpace($ConfigFile)) { $ConfigFile = "sewer-deployment.conf" }
        }
        'sewercc' {
            $script:CONTAINER_NAME = "sewercc-service"
            $script:DEFAULT_IMAGE = "networks/sewercc:latest"
            $script:DEFAULT_PORT = 8080
            $script:INTERNAL_PORT = 8080
            if ([string]::IsNullOrWhiteSpace($ConfigFile)) { $ConfigFile = "sewercc-deployment.conf" }
        }
    }
}

# ==============================
# Runtime detection
# ==============================
function Resolve-Runtime {
    $hasDocker = $null -ne (Get-Command docker -ErrorAction SilentlyContinue)
    $hasPodman = $null -ne (Get-Command podman -ErrorAction SilentlyContinue)

    if ($script:Runtime) {
        $script:RUNTIME = $script:Runtime
    } elseif ($script:CFG.Runtime) {
        $script:RUNTIME = $script:CFG.Runtime
    } elseif ($ContainerType -eq 'windows' -or $script:CFG.ContainerType -eq 'windows') {
        $script:RUNTIME = "docker"
    } elseif ($hasPodman -and $hasDocker) {
        $script:RUNTIME = "podman"
    } elseif ($hasPodman) { $script:RUNTIME = "podman" }
    elseif ($hasDocker)   { $script:RUNTIME = "docker" }
    else { Write-Err "No container runtime found."; exit 1 }

    if ($script:RUNTIME -eq "docker" -and -not $hasDocker) { Write-Err "Docker not installed"; exit 1 }
    if ($script:RUNTIME -eq "podman" -and -not $hasPodman) { Write-Err "Podman not installed"; exit 1 }

    # Container OS
    if ($ContainerType) { $script:CONTAINER_OS = $ContainerType }
    elseif ($script:CFG.ContainerType) { $script:CONTAINER_OS = $script:CFG.ContainerType }
    elseif ($script:CFG.ImageName -match 'windows') { $script:CONTAINER_OS = "windows" }
    else { $script:CONTAINER_OS = "linux" }

    if ($script:CONTAINER_OS -eq "windows" -and $script:RUNTIME -eq "podman") {
        Write-Err "Podman does not support Windows containers. Use -Runtime docker"; exit 1
    }

    # Docker context for Windows containers
    if ($script:CONTAINER_OS -eq "windows" -and $script:RUNTIME -eq "docker") {
        $ctxList = docker context ls --format '{{.Name}}' 2>$null
        if ($ctxList -contains 'windows-docker') {
            $script:DOCKER_CONTEXT = "windows-docker"
        }
    }

    Write-Ok "Runtime: $($script:RUNTIME) | OS: $($script:CONTAINER_OS)"
}

function Invoke-ContainerCmd {
    $cmdArgs = @($args)
    if ($script:RUNTIME -eq "docker") {
        if ($script:DOCKER_CONTEXT) {
            $allArgs = @("--context", $script:DOCKER_CONTEXT) + $cmdArgs
        } else { $allArgs = $cmdArgs }
        & docker @allArgs
    } else {
        & podman @cmdArgs
    }
}

# ==============================
# Helpers
# ==============================
function Test-PortInUse {
    param([int]$PortNum)
    $listener = Get-NetTCPConnection -LocalPort $PortNum -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $listener)
}

function Import-ConfigFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { Write-Warn "Config not found: $Path"; return }
    Write-Info "Loading config: $Path"
    foreach ($line in (Get-Content $Path)) {
        $line = $line.Trim()
        if ($line.StartsWith('#') -or $line -eq '') { continue }
        $parts = $line -split '=', 2
        if ($parts.Count -ne 2) { continue }
        $k = $parts[0].Trim(); $v = $parts[1].Trim().Trim('"')
        switch ($k) {
            'IMAGE_NAME'     { $script:CFG.ImageName = $v }
            'PORT'           { $script:CFG.Port = $v }
            'ACR_USER'       { $script:CFG.AcrUser = $v }
            'ACR_PASS'       { $script:CFG.AcrPass = $v }
            'CORS_ORIGIN'    { $script:CFG.CorsOrigin = $v }
            'RUNTIME'        { $script:CFG.Runtime = $v }
            'CONTAINER_TYPE' { $script:CFG.ContainerType = $v }
            'REGISTRY'       { $script:CFG.Registry = $v }
        }
    }
    Write-Ok "Config loaded"
}

# ==============================
# Container operations
# ==============================
function Connect-Registry {
    Write-Section "Registry Authentication"
    if ($DryRun) { Write-Info "[DRY] $($script:RUNTIME) login $($script:REGISTRY_NAME)"; return }
    if ($script:RUNTIME -eq "docker" -and $script:DOCKER_CONTEXT) {
        $script:CFG.AcrPass | & docker --context $script:DOCKER_CONTEXT login $script:REGISTRY_NAME -u $script:CFG.AcrUser --password-stdin
    } elseif ($script:RUNTIME -eq "docker") {
        $script:CFG.AcrPass | & docker login $script:REGISTRY_NAME -u $script:CFG.AcrUser --password-stdin
    } else {
        $script:CFG.AcrPass | & podman login $script:REGISTRY_NAME -u $script:CFG.AcrUser --password-stdin
    }
    if ($LASTEXITCODE -eq 0) { Write-Ok "Logged in to $($script:REGISTRY_NAME)" }
    else { Write-Err "Login failed"; exit 1 }
}

function Get-Image {
    Write-Section "Pulling Image"
    $img = $script:CFG.ImageName
    if (-not $img.StartsWith($script:REGISTRY_NAME)) { $img = "$($script:REGISTRY_NAME)/$img" }
    Write-Info "Pulling: $img"
    if ($DryRun) { Write-Info "[DRY] pull $img"; return }
    $oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    Invoke-ContainerCmd pull $img 2>$null
    $ErrorActionPreference = $oldEAP
    if ($LASTEXITCODE -ne 0) { Write-Err "Pull failed: $img"; exit 1 }
    Write-Ok "Image pulled"
}

function Wait-ContainerHealth {
    $maxAttempts = if ($script:CONTAINER_OS -eq "windows") { 36 } else { 12 }
    $waitSecs = 5
    Write-Info "Waiting for readiness (up to $($maxAttempts * $waitSecs)s)..."

    for ($i = 1; $i -le $maxAttempts; $i++) {
        $state = Invoke-ContainerCmd inspect --format "{{.State.Status}}" $script:CONTAINER_NAME 2>$null
        if ($state -ne 'running') {
            Write-Err "Container not running (state: $state). Logs:"
            Invoke-ContainerCmd logs --tail 50 $script:CONTAINER_NAME 2>&1 | Out-Host
            return $false
        }

        $health = Invoke-ContainerCmd inspect --format "{{.State.Health.Status}}" $script:CONTAINER_NAME 2>$null
        if ($health -eq 'healthy') { Write-Ok "Container healthy"; return $true }
        if ($health -eq 'unhealthy') {
            Write-Err "Unhealthy. Logs:"
            Invoke-ContainerCmd logs --tail 50 $script:CONTAINER_NAME 2>&1 | Out-Host
            return $false
        }

        # TCP fallback
        $port = [int]$script:CFG.Port
        $tcp = $null
        try { $tcp = New-Object System.Net.Sockets.TcpClient; $tcp.Connect('127.0.0.1', $port) } catch {}
        if ($tcp -and $tcp.Connected) { $tcp.Close(); Write-Ok "Port $port open"; return $true }
        if ($tcp) { try { $tcp.Close() } catch {} }

        $label = if ($health) { $health } else { 'no healthcheck' }
        Write-Info "Waiting... ($i/$maxAttempts) health: $label"
        Start-Sleep -Seconds $waitSecs
    }

    Write-Err "Not ready after $($maxAttempts * $waitSecs)s. Logs:"
    Invoke-ContainerCmd logs --tail 50 $script:CONTAINER_NAME 2>&1 | Out-Host
    return $false
}

function Deploy-Application {
    Write-Section "Deploying $($script:CONTAINER_NAME)"
    $img = $script:CFG.ImageName
    if (-not $img.StartsWith($script:REGISTRY_NAME)) { $img = "$($script:REGISTRY_NAME)/$img" }
    $port = $script:CFG.Port

    $existing = Invoke-ContainerCmd ps -a --format '{{.Names}}' 2>$null | Where-Object { $_ -eq $script:CONTAINER_NAME }
    if ($existing) {
        if ($Mode -eq 'update') {
            Write-Info "Removing existing container"
            if (-not $DryRun) { Invoke-ContainerCmd rm -f $script:CONTAINER_NAME 2>$null | Out-Null }
        } else {
            Write-Warn "Container exists. Use -Update to replace."
            return
        }
    }

    $envArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($script:CFG.CorsOrigin)) {
        $envArgs += "-e"; $envArgs += "CORS_ORIGIN=$($script:CFG.CorsOrigin)"
    }

    $internalPort = $script:INTERNAL_PORT
    $healthCmdValue = if ($script:CONTAINER_OS -eq "windows") {
        "curl.exe -f http://localhost:$internalPort/"
    } else {
        "curl -f http://localhost:$internalPort/ || exit 1"
    }

    if ($DryRun) {
        Write-Info "[DRY] run -d --name $($script:CONTAINER_NAME) -p ${port}:$internalPort $img"
        return
    }

    $healthStartPeriod = if ($script:CONTAINER_OS -eq 'windows') { '90s' } else { '15s' }

    $runArgs = @(
        'run', '-d',
        '--name', $script:CONTAINER_NAME,
        '--restart', 'unless-stopped',
        '-p', "${port}:${internalPort}",
        "--health-cmd=$healthCmdValue",
        '--health-interval', '30s',
        '--health-timeout', '10s',
        '--health-retries', '3',
        '--health-start-period', $healthStartPeriod
    )

    if ($script:RUNTIME -eq "docker") {
        $runArgs += @('--memory', '512m', '--cpus', '0.5')
    }

    $runArgs += $envArgs
    $runArgs += $img

    Invoke-ContainerCmd @runArgs
    if ($LASTEXITCODE -ne 0) { Write-Err "Failed to start container"; exit 1 }

    $script:CREATED_CONTAINERS += $script:CONTAINER_NAME
    if (Wait-ContainerHealth) {
        Write-Ok "$($script:CONTAINER_NAME) deployed successfully"
        Invoke-ContainerCmd ps --filter "name=$($script:CONTAINER_NAME)"
    } else {
        Write-Err "Deployment failed"
        exit 1
    }
}

# ==============================
# MAIN
# ==============================
function Main {
    if ($Help) { Get-Help $MyInvocation.ScriptName -Detailed; return }
    if ($Update) { $Mode = 'update' }

    Resolve-Service
    Write-Section "$($script:SCRIPT_NAME) v$($script:VERSION) - $Service"
    if ($DryRun) { Write-Warn "DRY RUN MODE" }

    Set-Content -Path $script:LOG_FILE -Value "=== $($script:SCRIPT_NAME) - $(Get-Date) ==="
    Import-ConfigFile $ConfigFile

    # CLI overrides
    if ($Image)         { $script:CFG.ImageName = $Image }
    if ($Port)          { $script:CFG.Port = $Port }
    if ($AcrUser)       { $script:CFG.AcrUser = $AcrUser }
    if ($AcrPass)       { $script:CFG.AcrPass = $AcrPass }
    if ($CorsOrigin)    { $script:CFG.CorsOrigin = $CorsOrigin }
    if ($Runtime)       { $script:CFG.Runtime = $Runtime }
    if ($ContainerType) { $script:CFG.ContainerType = $ContainerType }
    if ($script:CFG.Registry) { $script:REGISTRY_NAME = $script:CFG.Registry }

    # Defaults
    if ([string]::IsNullOrWhiteSpace($script:CFG.ImageName)) { $script:CFG.ImageName = $script:DEFAULT_IMAGE }
    if ([string]::IsNullOrWhiteSpace($script:CFG.Port)) { $script:CFG.Port = "$($script:DEFAULT_PORT)" }

    # Interactive prompts
    if ([string]::IsNullOrWhiteSpace($script:CFG.AcrUser) -and $script:CAN_PROMPT) {
        $script:CFG.AcrUser = Read-Host "ACR Username"
    }
    if ([string]::IsNullOrWhiteSpace($script:CFG.AcrPass) -and $script:CAN_PROMPT) {
        $sec = Read-Host "ACR Password" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $script:CFG.AcrPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }

    Resolve-Runtime

    $p = [int]$script:CFG.Port
    if ($p -lt 1 -or $p -gt 65535) { Write-Err "Invalid port: $p"; exit 1 }
    if (-not $DryRun -and (Test-PortInUse $p)) { Write-Err "Port $p in use"; exit 1 }

    Write-Info "  Service:   $Service"
    Write-Info "  Mode:      $Mode"
    Write-Info "  Runtime:   $($script:RUNTIME)"
    Write-Info "  OS:        $($script:CONTAINER_OS)"
    Write-Info "  Image:     $($script:CFG.ImageName)"
    Write-Info "  Port:      $($script:CFG.Port)"

    if (-not $DryRun -and $script:CAN_PROMPT -and -not $script:FORCE) {
        $confirm = Read-Host "Continue? (y/N)"
        if ($confirm -notin @('y','Y')) { Write-Info "Cancelled"; return }
    }

    try {
        Connect-Registry
        Get-Image
        Deploy-Application
        Write-Section "Deployment Complete"
        Write-Ok "$($script:CONTAINER_NAME) running on port $($script:CFG.Port)"
        Write-Info "Log: $($script:LOG_FILE)"
    }
    catch {
        Write-Err "Deployment failed: $_"
        foreach ($c in $script:CREATED_CONTAINERS) {
            Invoke-ContainerCmd rm -f $c 2>$null | Out-Null
        }
        throw
    }
}

Main
