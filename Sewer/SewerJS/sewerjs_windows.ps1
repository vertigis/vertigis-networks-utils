#Requires -Version 5.1

<#
.SYNOPSIS
    SewerJS - Deployment Script (Windows)

.DESCRIPTION
    This script automates deployment of the SewerJS Service with:
    - Multiple deployment modes (new/update/dry-run)
    - Container runtime: Docker or Podman (auto-detected)
    - Container OS: Linux or Windows containers (auto-detected from image name)
    - Configuration file support
    - Parameter validation and error handling
    - Proper cleanup and rollback mechanisms
    - Enhanced security and logging

.PARAMETER Help
    Show help information

.PARAMETER ConfigFile
    Use configuration file (default: sewerjs-deployment.conf)

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
    Host port for API (default: 3000)

.PARAMETER CorsOrigin
    Comma-separated CORS origins

.PARAMETER AcrUser
    Azure Container Registry username

.PARAMETER AcrPass
    Azure Container Registry password

.PARAMETER ExportImage
    Export the container image to a tar file for offline deployment.
    Pulls the image from the registry and saves it locally.
    Use -ExportPath to specify a custom output filename (default: sewerjs-windows_<tag>.tar).

.PARAMETER ExportPath
    Output path for the exported tar file (used with -ExportImage).
    Default: sewerjs-windows_<tag>.tar in the current directory.

.PARAMETER LoadFromFile
    Load the container image from a local tar file instead of pulling from the registry.
    The tar file is typically created with -ExportImage on another machine.
    ACR credentials are not required when using this parameter.

.PARAMETER DryRun
    Show what would be done without making changes

.PARAMETER CreateConfig
    Create sample configuration file and exit

.EXAMPLE
    .\sewerjs_windows.ps1
    Basic deployment with prompts (auto-detects runtime)

.EXAMPLE
    .\sewerjs_windows.ps1 -Runtime podman -Image "networks/sewerjs:latest"
    Deploy Linux image via Podman

.EXAMPLE
    .\sewerjs_windows.ps1 -Runtime docker -ContainerType windows -Image "networks/sewerjs-windows:1.0.0"
    Deploy Windows container via Docker Engine

.EXAMPLE
    .\sewerjs_windows.ps1 -ContainerType windows -BuildTag "1.0.0-12345"
    Deploy a specific build of the Windows image (tag resolved to 1.0.0-12345-ltsc2022 based on host OS)

.EXAMPLE
    .\sewerjs_windows.ps1 -Update
    Update existing deployment

.EXAMPLE
    .\sewerjs_windows.ps1 -ExportImage -Runtime docker -ContainerType windows
    Export the Windows image to a tar file for offline (semi-manual) deployment.

.EXAMPLE
    .\sewerjs_windows.ps1 -Runtime docker -ContainerType windows -LoadFromFile .\sewerjs-windows_ltsc2022.tar
    Load image from a local tar file and deploy (skips registry authentication).
#>

[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$DryRun,
    [string]$ConfigFile = "sewerjs-deployment.conf",
    [ValidateSet("new", "update")]
    [string]$Mode = "new",
    [switch]$Update,
    [ValidateSet("docker", "podman", "")]
    [string]$Runtime = "",
    [ValidateSet("linux", "windows", "")]
    [string]$ContainerType = "",
    [string]$Image = "",
    [string]$BuildTag = "",
    [string]$Port = "",
    [string]$CorsOrigin = "",
    [string]$AcrUser = "",
    [string]$AcrPass = "",
    [switch]$ExportImage,
    [string]$ExportPath = "",
    [string]$LoadFromFile = "",
    [switch]$CreateConfig
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Globals
$script:SCRIPT_NAME = "SewerJS Deployment"
$script:VERSION = "1.0"
$script:LOG_FILE = Join-Path $env:TEMP ("sewerjs-deployment-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# Defaults
$script:REGISTRY_NAME = "vertigisnetworks.azurecr.io"
$script:DEFAULT_IMAGE_WINDOWS = "networks/sewerjs-windows"
$script:DEFAULT_IMAGE_LINUX = "networks/sewerjs:latest"
$script:DEFAULT_PORT = 3000
$script:CONTAINER_NAME = "sewerjs-service"

# Runtime state (resolved in Resolve-Runtime)
# Note: $RUNTIME intentionally NOT initialized here to avoid overwriting the $Runtime param
$script:CONTAINER_OS = ""      # linux | windows
$script:DOCKER_CONTEXT = ""    # windows-docker (only for docker + windows)

# State
$script:CLEANUP_NEEDED = $false
$script:TEMP_FILES = @()
$script:CREATED_CONTAINERS = @()

# Non-interactive mode (CI)
$script:FORCE = $env:FORCE -eq "yes"
$script:CAN_PROMPT = (-not $script:FORCE) -and ($Host.Name -ne 'ServerRemoteHost') -and (-not [Console]::IsInputRedirected)

# Config
$script:CFG = @{
    ImageName       = ""
    Port            = ""
    AcrUser         = ""
    AcrPass         = ""
    CorsOrigin      = ""
    Runtime         = ""
    ContainerType   = ""
    Registry        = ""
}

# ------------------------------
# Logging
# ------------------------------
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
function Write-Dry      { param([string]$M) if ($DryRun) { Write-ColorOutput "[DRY RUN] Would execute: $M" Cyan } }

# ------------------------------
# Cleanup
# ------------------------------
function Invoke-Cleanup {
    foreach ($c in $script:CREATED_CONTAINERS) {
        $exists = Invoke-ContainerCmd ps -a --format '{{.Names}}' 2>$null | Where-Object { $_ -eq $c }
        if ($exists) {
            Write-Info "Removing container: $c"
            if (-not $DryRun) { Invoke-ContainerCmd rm -f $c 2>$null | Out-Null }
        }
    }
    foreach ($f in $script:TEMP_FILES) {
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
}

# ------------------------------
# Runtime detection and abstraction
# ------------------------------
function Resolve-Runtime {
    # Detect available runtimes
    $hasDocker = $null -ne (Get-Command docker -ErrorAction SilentlyContinue)
    $hasPodman = $null -ne (Get-Command podman -ErrorAction SilentlyContinue)

    # Resolve runtime
    if ($script:Runtime) {
        $script:RUNTIME = $script:Runtime
    } elseif ($script:CFG.Runtime) {
        $script:RUNTIME = $script:CFG.Runtime
    } elseif ($script:ContainerType -eq 'windows' -or $script:CFG.ContainerType -eq 'windows' -or $script:CFG.ImageName -match 'windows') {
        # Windows containers need Docker
        $script:RUNTIME = "docker"
        Write-Info "Auto-detected: Windows containers require Docker"
    } elseif ($hasPodman -and $hasDocker) {
        $script:RUNTIME = "podman"
        Write-Info "Auto-detected: both docker and podman available, defaulting to podman"
    } elseif ($hasPodman) {
        $script:RUNTIME = "podman"
    } elseif ($hasDocker) {
        $script:RUNTIME = "docker"
    } else {
        Write-Err "No container runtime found. Install docker or podman."
        exit 1
    }

    # Validate the chosen runtime exists
    if ($script:RUNTIME -eq "docker" -and -not $hasDocker) {
        Write-Err "Docker is not installed."; exit 1
    }
    if ($script:RUNTIME -eq "podman" -and -not $hasPodman) {
        Write-Err "Podman is not installed."; exit 1
    }

    # Resolve container OS
    if ($script:ContainerType) {
        $script:CONTAINER_OS = $script:ContainerType
    } elseif ($script:CFG.ContainerType) {
        $script:CONTAINER_OS = $script:CFG.ContainerType
    } elseif ($script:CFG.ImageName -match 'windows') {
        $script:CONTAINER_OS = "windows"
    } else {
        $script:CONTAINER_OS = "linux"
    }

    # Windows containers require Docker Engine
    if ($script:CONTAINER_OS -eq "windows") {
        if ($script:RUNTIME -eq "podman") {
            Write-Err "Podman does not support Windows containers. Use -Runtime docker"
            exit 1
        }
        # Use 'windows-docker' context only if it exists (dev machine with Podman on default pipe)
        $ctxList = docker context ls --format '{{.Name}}' 2>$null
        if ($ctxList -contains 'windows-docker') {
            $script:DOCKER_CONTEXT = "windows-docker"
            Write-Info "Windows containers: using Docker context '$($script:DOCKER_CONTEXT)'"
        } else {
            $script:DOCKER_CONTEXT = ""
            Write-Info "Windows containers: using default Docker context"
        }
    } else {
        $script:DOCKER_CONTEXT = ""
    }

    Write-Ok "Runtime: $($script:RUNTIME) | Container OS: $($script:CONTAINER_OS)"
}

function Invoke-ContainerCmd {
    <#
    .SYNOPSIS
        Unified wrapper: calls docker (with optional --context) or podman.
    #>
    $cmdArgs = @($args)

    if ($script:RUNTIME -eq "docker") {
        if ($script:DOCKER_CONTEXT) {
            $allArgs = @("--context", $script:DOCKER_CONTEXT) + $cmdArgs
        } else {
            $allArgs = $cmdArgs
        }
        & docker @allArgs
    } else {
        & podman @cmdArgs
    }
}

# ------------------------------
# Helpers
# ------------------------------
function Get-WindowsLtscTag {
    $buildNum = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).CurrentBuildNumber
    switch ($buildNum) {
        '17763' { return 'ltsc2019' }   # Windows Server 2019
        '20348' { return 'ltsc2022' }   # Windows Server 2022
        '26100' { return 'ltsc2025' }   # Windows Server 2025
        default { return 'latest' }
    }
}

function Test-PortInUse {
    param([int]$PortNum)
    $listener = Get-NetTCPConnection -LocalPort $PortNum -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $listener)
}

function Assert-Port {
    param([string]$PortVal, [string]$Label)
    $p = 0
    if (-not [int]::TryParse($PortVal, [ref]$p) -or $p -lt 1 -or $p -gt 65535) {
        Write-Err "Invalid $Label : $PortVal (must be 1-65535)"; return $false
    }
    if (Test-PortInUse $p) {
        Write-Err "$Label $p is already in use"; return $false
    }
    return $true
}

function Read-PromptOrDefault {
    param([string]$Prompt, [string]$Default)
    if ($script:CAN_PROMPT) {
        $val = Read-Host "$Prompt (default: $Default)"
        if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
        return $val
    }
    return $Default
}

function Read-SecurePrompt {
    param([string]$Prompt)
    if ($script:CAN_PROMPT) {
        $sec = Read-Host $Prompt -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    return ""
}

# ------------------------------
# Config file
# ------------------------------
function Import-ConfigFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { Write-Warn "Config file not found: $Path"; return }
    Write-Info "Loading configuration from: $Path"
    foreach ($line in (Get-Content $Path)) {
        $line = $line.Trim()
        if ($line.StartsWith('#') -or $line -eq '') { continue }
        $parts = $line -split '=', 2
        if ($parts.Count -ne 2) { continue }
        $k = $parts[0].Trim(); $v = $parts[1].Trim().Trim('"')
        switch ($k) {
            'IMAGE_NAME'          { $script:CFG.ImageName = $v }
            'PORT'                { $script:CFG.Port = $v }
            'ACR_USER'            { $script:CFG.AcrUser = $v }
            'ACR_PASS'            { $script:CFG.AcrPass = $v }
            'CORS_ORIGIN'         { $script:CFG.CorsOrigin = $v }
            'RUNTIME'             { $script:CFG.Runtime = $v }
            'CONTAINER_TYPE'      { $script:CFG.ContainerType = $v }
            'REGISTRY'            { $script:CFG.Registry = $v }
        }
    }
    Write-Ok "Configuration loaded"
}

function New-SampleConfig {
    $content = @"
# SewerJS Deployment Configuration

# IMAGE_NAME - use sewerjs:latest for Linux, sewerjs-windows:latest for Windows
IMAGE_NAME=$($script:DEFAULT_IMAGE_LINUX)
PORT=$($script:DEFAULT_PORT)
ACR_USER=your_acr_username
ACR_PASS=your_acr_password
CORS_ORIGIN=

# REGISTRY - container registry hostname
REGISTRY=$($script:REGISTRY_NAME)

# RUNTIME - container runtime: docker or podman (leave empty for auto-detect)
#RUNTIME=docker

# CONTAINER_TYPE - container OS: linux or windows (leave empty for auto-detect from image name)
#CONTAINER_TYPE=linux
"@
    Set-Content -Path $ConfigFile -Value $content
    Write-Ok "Sample configuration created: $ConfigFile"
}

# ------------------------------
# Container runtime check
# ------------------------------
function Assert-Runtime {
    Write-Section "Checking Container Runtime"
    if ($script:RUNTIME -eq "docker") {
        Write-Ok "Docker found: $(docker --version)"
        if ($script:CONTAINER_OS -eq "windows") {
            $info = Invoke-ContainerCmd info 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Err "Docker Engine (Windows) is not running. Start the 'docker' service."
                exit 1
            }
            Write-Ok "Docker Engine (Windows containers) is running"
        } else {
            $info = docker info 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Err "Docker daemon is not reachable."; exit 1 }
        }
    } else {
        Write-Ok "Podman found: $(podman --version)"
        $info = podman info 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Err "Podman is not running. Start the podman machine."; exit 1 }
        Write-Ok "Podman machine is running"
    }
}

# ------------------------------
# Registry
# ------------------------------
function Connect-Registry {
    Write-Section "Container Registry Authentication"
    if ($DryRun) { Write-Dry "$($script:RUNTIME) login $($script:REGISTRY_NAME) -u $($script:CFG.AcrUser)"; return }

    # Build the command directly -- piping through a wrapper function breaks --password-stdin
    if ($script:RUNTIME -eq "docker" -and $script:DOCKER_CONTEXT) {
        $script:CFG.AcrPass | & docker --context $script:DOCKER_CONTEXT login $script:REGISTRY_NAME -u $script:CFG.AcrUser --password-stdin
    } elseif ($script:RUNTIME -eq "docker") {
        $script:CFG.AcrPass | & docker login $script:REGISTRY_NAME -u $script:CFG.AcrUser --password-stdin
    } else {
        $script:CFG.AcrPass | & podman login $script:REGISTRY_NAME -u $script:CFG.AcrUser --password-stdin
    }

    if ($LASTEXITCODE -eq 0) { Write-Ok "Logged in to $($script:REGISTRY_NAME) via $($script:RUNTIME)" }
    else { Write-Err "Login to $($script:REGISTRY_NAME) failed (exit code $LASTEXITCODE)"; exit 1 }
}

function Get-Image {
    Write-Section "Pulling Container Image"
    $img = $script:CFG.ImageName
    if (-not $img.StartsWith($script:REGISTRY_NAME)) {
        $img = "$($script:REGISTRY_NAME)/$img"
    }
    Write-Info "Pulling image: $img (via $($script:RUNTIME))"
    if ($DryRun) { Write-Dry "$($script:RUNTIME) pull $img"; return }

    # Attempt normal pull -- stderr from docker pull can trigger ErrorActionPreference=Stop,
    # so temporarily switch to Continue for native commands
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Invoke-ContainerCmd pull $img 2>$null
    $pullExitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldEAP

    if ($pullExitCode -eq 0) {
        Write-Ok "Image pulled: $img"
        return
    }

    # On Windows, docker pull may fail due to OS version mismatch (e.g. Server 2022 image on Win10)
    # Fallback: use crane to download + docker load
    if ($script:CONTAINER_OS -eq "windows") {
        Write-Warn "Direct pull failed (OS version mismatch). Trying crane fallback..."
        $cranePath = Join-Path $env:TEMP "crane.exe"
        if (-not (Test-Path $cranePath)) {
            Write-Info "Downloading crane tool..."
            $craneUrl = "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Windows_x86_64.tar.gz"
            $craneArchive = Join-Path $env:TEMP "crane.tar.gz"
            Invoke-WebRequest -Uri $craneUrl -OutFile $craneArchive -UseBasicParsing
            tar -xzf $craneArchive -C $env:TEMP crane.exe
            Remove-Item $craneArchive -Force -ErrorAction SilentlyContinue
        }
        # Auth crane
        $ErrorActionPreference = "Continue"
        & $cranePath auth login $script:REGISTRY_NAME -u $script:CFG.AcrUser -p $script:CFG.AcrPass 2>$null
        # Pull as tarball
        $tarPath = Join-Path $env:TEMP "sewerjs-windows-pull.tar"
        Write-Info "Downloading image via crane (this may take a while for large Windows images)..."
        & $cranePath pull --platform windows/amd64 $img $tarPath
        $craneExit = $LASTEXITCODE
        $ErrorActionPreference = $oldEAP

        if ($craneExit -ne 0 -or -not (Test-Path $tarPath)) {
            Write-Err "crane pull failed for: $img (exit code: $craneExit)"; exit 1
        }
        # Load into Docker
        Write-Info "Loading image into Docker..."
        $ErrorActionPreference = "Continue"
        Invoke-ContainerCmd load -i $tarPath
        $loadExit = $LASTEXITCODE
        $ErrorActionPreference = $oldEAP
        if ($loadExit -ne 0) { Write-Err "docker load failed"; exit 1 }
        Remove-Item $tarPath -Force -ErrorAction SilentlyContinue
        Write-Ok "Image loaded: $img (via crane + docker load)"
    } else {
        Write-Err "Failed to pull image: $img"
        exit 1
    }
}

function Export-Image {
    Write-Section "Exporting Container Image"
    $img = $script:CFG.ImageName
    if (-not $img.StartsWith($script:REGISTRY_NAME)) {
        $img = "$($script:REGISTRY_NAME)/$img"
    }

    # Derive default tar filename from image tag (e.g. sewerjs-windows_ltsc2022.tar)
    $outPath = if (-not [string]::IsNullOrWhiteSpace($ExportPath)) {
        $ExportPath
    } else {
        $tarName = ($img -replace '^.*/', '' -replace ':', '_') + '.tar'
        Join-Path (Get-Location) $tarName
    }

    Write-Info "Image:  $img"
    Write-Info "Output: $outPath"
    if ($DryRun) { Write-Dry "$($script:RUNTIME) save -o $outPath $img"; return }

    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Invoke-ContainerCmd save -o $outPath $img
    $saveExit = $LASTEXITCODE
    $ErrorActionPreference = $oldEAP

    if ($saveExit -ne 0) { Write-Err "Failed to export image: $img"; exit 1 }

    $sizeMB = [math]::Round((Get-Item $outPath).Length / 1MB, 1)
    Write-Ok "Image exported: $outPath ($sizeMB MB)"
    Write-Info ""
    Write-Info "Next steps on the target machine:"
    Write-Info "  1. Copy $(Split-Path $outPath -Leaf) to C:\app\sewerjs\"
    Write-Info "  2. Run: .\sewerjs_windows.ps1 -Runtime docker -ContainerType windows -LoadFromFile .\$(Split-Path $outPath -Leaf)"
}

function Import-ImageFromFile {
    param([string]$FilePath)
    Write-Section "Loading Container Image from File"
    if (-not (Test-Path $FilePath)) {
        Write-Err "Image file not found: $FilePath"; exit 1
    }
    $sizeMB = [math]::Round((Get-Item $FilePath).Length / 1MB, 1)
    Write-Info "Loading: $FilePath ($sizeMB MB)"
    if ($DryRun) { Write-Dry "$($script:RUNTIME) load -i $FilePath"; return }

    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Invoke-ContainerCmd load -i $FilePath
    $loadExit = $LASTEXITCODE
    $ErrorActionPreference = $oldEAP

    if ($loadExit -ne 0) { Write-Err "Failed to load image from: $FilePath"; exit 1 }
    Write-Ok "Image loaded successfully"
}

# ------------------------------
# Application container
# ------------------------------
function Wait-ContainerHealth {
    # Windows containers (Node.js in Nano/Server Core) take 2-3 minutes to start.
    # Linux containers are much faster — 50s is enough.
    $maxAttempts = if ($script:CONTAINER_OS -eq "windows") { 36 } else { 10 }
    $waitSecs    = 5
    Write-Info "Waiting for container to be ready (up to $($maxAttempts * $waitSecs)s)..."

    for ($i = 1; $i -le $maxAttempts; $i++) {
        # 1. Check container is still running (double-quoted go-template — PS passes single-quoted ones literally)
        $state = Invoke-ContainerCmd inspect --format "{{.State.Status}}" $script:CONTAINER_NAME 2>$null
        if ($state -ne 'running') {
            Write-Err "Container is not running (state: $state). Logs:"
            # Out-Host prevents log lines from polluting the function's return value
            Invoke-ContainerCmd logs --tail 50 $script:CONTAINER_NAME 2>&1 | Out-Host
            return $false
        }

        # 2. Built-in HEALTHCHECK (double-quoted template, no stray PS quotes)
        $health = Invoke-ContainerCmd inspect --format "{{.State.Health.Status}}" $script:CONTAINER_NAME 2>$null
        if ($health -eq 'healthy') {
            Write-Ok "Container is healthy and ready"
            return $true
        }
        if ($health -eq 'unhealthy') {
            Write-Err "Container health check failed. Logs:"
            Invoke-ContainerCmd logs --tail 50 $script:CONTAINER_NAME 2>&1 | Out-Host
            return $false
        }

        # 3. TCP port fallback — works even when no HEALTHCHECK is defined in image
        $port = [int]$script:CFG.Port
        $tcp  = $null
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect('127.0.0.1', $port)
        } catch {}
        if ($tcp -and $tcp.Connected) {
            $tcp.Close()
            Write-Ok "Container is ready (port $port is open)"
            return $true
        }
        if ($tcp) { try { $tcp.Close() } catch {} }

        $healthLabel = if ($health) { $health } else { 'no healthcheck' }
        Write-Info "Waiting... ($i/$maxAttempts) port not open, health: $healthLabel"
        Start-Sleep -Seconds $waitSecs
    }

    Write-Err "Container did not become ready after $($maxAttempts * $waitSecs)s. Logs:"
    Invoke-ContainerCmd logs --tail 50 $script:CONTAINER_NAME 2>&1 | Out-Host
    return $false
}

function Deploy-Application {
    Write-Section "Deploying SewerJS Application"
    $img = $script:CFG.ImageName
    if (-not $img.StartsWith($script:REGISTRY_NAME)) {
        $img = "$($script:REGISTRY_NAME)/$img"
    }
    Write-Info "Image: $img"
    Write-Info "Runtime: $($script:RUNTIME) | Container OS: $($script:CONTAINER_OS)"

    $existing = Invoke-ContainerCmd ps -a --format '{{.Names}}' 2>$null | Where-Object { $_ -eq $script:CONTAINER_NAME }
    if ($existing) {
        if ($Mode -eq 'update') {
            Write-Info "Removing existing container for update"
            if (-not $DryRun) { Invoke-ContainerCmd rm -f $script:CONTAINER_NAME 2>$null | Out-Null }
        } else {
            $existingStatus = Invoke-ContainerCmd inspect --format '{{.State.Status}} (exit={{.State.ExitCode}})' $script:CONTAINER_NAME 2>$null
            Write-Warn "Container already exists: $existingStatus"
            Write-Warn "Use -Update to replace, or run: docker rm -f $($script:CONTAINER_NAME)"
            Write-Info "--- Last 20 log lines ---"
            Invoke-ContainerCmd logs --tail 20 $script:CONTAINER_NAME 2>&1
            return
        }
    }

    $port = $script:CFG.Port
    $envArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($script:CFG.CorsOrigin)) {
        $envArgs += "-e"
        $envArgs += "CORS_ORIGIN=$($script:CFG.CorsOrigin)"
    }

    # The app inside the container always listens on $internalPort (host port is mapped via -p).
    # Health check runs INSIDE the container, so it always connects to localhost:$internalPort.
    $internalPort = 3000

    # Health check command differs per container OS.
    # Use --health-cmd=VALUE (single arg) to avoid PS 5.1 quoting bugs with native commands.
    # Windows: curl.exe ships with Windows Server 2019+ / Nano Server 1803+.
    #   Avoids PowerShell quoting hell — Docker on Windows invokes health-cmd via
    #   "cmd /S /C <cmd>", which mangles PowerShell try{} blocks with curly braces.
    if ($script:CONTAINER_OS -eq "windows") {
        $healthCmdValue = "curl.exe -f http://localhost:$internalPort/"
    } else {
        $healthCmdValue = "curl -f http://localhost:$internalPort/ || exit 1"
    }

    if ($DryRun) {
        Write-Dry "$($script:RUNTIME) run -d --name $($script:CONTAINER_NAME) $($envArgs -join ' ') -p ${port}:3000 $img"
        return
    }

    # --health-start-period: Docker won't count failed checks during startup.
    # Windows containers (Node.js in Server Core) can take 60-120s before the app is ready.
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

    # Resource limits (--memory/--cpus not always supported in podman rootless)
    if ($script:RUNTIME -eq "docker") {
        $runArgs += @('--memory', '512m', '--cpus', '0.5')
    }

    # Windows containers: choose isolation mode.
    # Prefer process isolation (no hypervisor required) when host and image OS build match.
    # Fall back to Hyper-V only when there is a version mismatch and nested virtualisation is available.
    if ($script:CONTAINER_OS -eq "windows") {
        $hostVer        = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $hostBuildNum   = $hostVer.CurrentBuildNumber          # e.g. "20348"
        $hostBuildFull  = "$($hostVer.CurrentMajorVersionNumber).$($hostVer.CurrentMinorVersionNumber).$($hostVer.CurrentBuildNumber).$($hostVer.UBR)"
        $imgOsVer       = Invoke-ContainerCmd inspect --format "{{.OsVersion}}" $img 2>$null
        # Extract major build number from image OS version (e.g. "10.0.20348.4773" -> "20348")
        $imgBuildNum    = if ($imgOsVer -match '^\d+\.\d+\.(\d+)\.') { $Matches[1] } else { $null }
        Write-Info "Host OS:  $hostBuildFull"
        Write-Info "Image OS: $imgOsVer"

        # Process isolation works when the major build matches (same Windows Server generation).
        # UBR (4th component) differences within the same build are fine for process isolation.
        if (-not $imgBuildNum -or $imgBuildNum -eq $hostBuildNum) {
            $runArgs += @('--isolation', 'process')
            Write-Info "Using process isolation (same Windows build: $hostBuildNum)"
        } else {
            Write-Err "Windows build mismatch -- process isolation is not possible."
            Write-Err "  Host build  : $hostBuildNum  ($hostBuildFull)"
            Write-Err "  Image build : $imgBuildNum  ($imgOsVer)"
            Write-Err "Pull an image built for host build $hostBuildNum (e.g. -BuildTag with ltsc tag matching this host)."
            exit 1
        }
    }

    $runArgs += $envArgs
    $runArgs += $img

    Invoke-ContainerCmd @runArgs
    if ($LASTEXITCODE -ne 0) { Write-Err "Failed to start container"; exit 1 }

    $script:CREATED_CONTAINERS += $script:CONTAINER_NAME
    Write-Info "Container process started, checking readiness..."
    if (Wait-ContainerHealth) {
        Write-Ok "SewerJS container started successfully"
        Invoke-ContainerCmd ps --filter "name=$($script:CONTAINER_NAME)" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    } else {
        Write-Err "Container started but did not become ready. Deployment failed."
        exit 1
    }
}

# ==============================================================
# MAIN
# ==============================================================
function Main {
    if ($Help) {
        Get-Help $MyInvocation.ScriptName -Detailed
        return
    }
    if ($CreateConfig) { New-SampleConfig; return }
    if ($Update) { $Mode = 'update' }
    Write-Section "$($script:SCRIPT_NAME) v$($script:VERSION)"
    if ($DryRun) { Write-Warn "DRY RUN MODE" }

    Set-Content -Path $script:LOG_FILE -Value "=== $($script:SCRIPT_NAME) v$($script:VERSION) - $(Get-Date) ==="

    Import-ConfigFile $ConfigFile

    # CLI params override config
    if ($Image)         { $script:CFG.ImageName = $Image }
    if ($Port)          { $script:CFG.Port = $Port }
    if ($AcrUser)       { $script:CFG.AcrUser = $AcrUser }
    if ($AcrPass)       { $script:CFG.AcrPass = $AcrPass }
    if ($CorsOrigin)    { $script:CFG.CorsOrigin = $CorsOrigin }
    if ($Runtime)       { $script:CFG.Runtime = $Runtime }
    if ($ContainerType) { $script:CFG.ContainerType = $ContainerType }
    if ($script:CFG.Registry) { $script:REGISTRY_NAME = $script:CFG.Registry }

    # Pick default image based on container type hint
    $defaultImg = if ($ContainerType -eq 'windows' -or $script:CFG.ContainerType -eq 'windows' -or $Image -match 'windows') {
        $winTag = Get-WindowsLtscTag
        Write-Info "Detected Windows host build -> image tag: $winTag"
        if (-not [string]::IsNullOrWhiteSpace($BuildTag)) {
            "$($script:DEFAULT_IMAGE_WINDOWS):${BuildTag}-${winTag}"
        } else {
            "$($script:DEFAULT_IMAGE_WINDOWS):$winTag"
        }
    } else {
        $script:DEFAULT_IMAGE_LINUX
    }

    # Interactive prompts for missing values
    if ([string]::IsNullOrWhiteSpace($script:CFG.ImageName)) {
        $script:CFG.ImageName = Read-PromptOrDefault "Image name" $defaultImg
    }
    if (-not $ExportImage) {
        if ([string]::IsNullOrWhiteSpace($script:CFG.Port)) {
            $script:CFG.Port = Read-PromptOrDefault "Host port" $script:DEFAULT_PORT
        }
    }
    # ACR credentials not needed when loading from a local file
    $needsRegistry = [string]::IsNullOrWhiteSpace($LoadFromFile)
    if ($needsRegistry) {
        if ([string]::IsNullOrWhiteSpace($script:CFG.AcrUser)) {
            $script:CFG.AcrUser = Read-PromptOrDefault "ACR Username" ""
        }
        if ([string]::IsNullOrWhiteSpace($script:CFG.AcrPass)) {
            $script:CFG.AcrPass = Read-SecurePrompt "ACR Password"
        }
    }

    # Defaults
    if ([string]::IsNullOrWhiteSpace($script:CFG.Port)) { $script:CFG.Port = "$($script:DEFAULT_PORT)" }
    if ([string]::IsNullOrWhiteSpace($script:CFG.ImageName)) { $script:CFG.ImageName = $defaultImg }

    # Resolve runtime + container OS (must be after image name is known)
    Resolve-Runtime

    if (-not $ExportImage -and -not (Assert-Port $script:CFG.Port "Port")) { exit 1 }

    Write-Info "Configuration Summary:"
    Write-Info "  Mode:     $Mode"
    Write-Info "  Runtime:  $($script:RUNTIME)"
    Write-Info "  OS:       $($script:CONTAINER_OS)"
    Write-Info "  Image:    $($script:CFG.ImageName)"
    if ($ExportImage)                                    { Write-Info "  Export:   $(if ($ExportPath) { $ExportPath } else { '(auto)' })" }
    if (-not [string]::IsNullOrWhiteSpace($LoadFromFile)) { Write-Info "  Source:   $LoadFromFile (local file)" }
    if (-not $ExportImage)                               { Write-Info "  Port:     $($script:CFG.Port)" }
    Write-Info "  CORS:     $($script:CFG.CorsOrigin)"

    if (-not $DryRun -and $script:CAN_PROMPT -and -not $script:FORCE) {
        $confirm = Read-Host "Continue with deployment? (y/N)"
        if ($confirm -notin @('y','Y')) { Write-Info "Cancelled"; return }
    }

    try {
        Assert-Runtime

        if ($ExportImage) {
            # Export mode: pull from registry and save to tar
            Connect-Registry
            Get-Image
            Export-Image
            Write-Section "Export Completed"
            Write-Ok "Log file: $($script:LOG_FILE)"
            return
        } elseif (-not [string]::IsNullOrWhiteSpace($LoadFromFile)) {
            # Offline mode: load from local tar, skip registry
            Import-ImageFromFile $LoadFromFile
        } else {
            # Normal mode: pull from registry
            Connect-Registry
            Get-Image
        }

        Deploy-Application

        Write-Section "Deployment Completed Successfully"
        Write-Ok "SewerJS is now running ($($script:RUNTIME), $($script:CONTAINER_OS))"
        Write-Info "API endpoint: http://localhost:$($script:CFG.Port)"
        Write-Info "Log file: $($script:LOG_FILE)"
    }
    catch {
        Write-Err "Deployment failed: $_"
        Invoke-Cleanup
        throw
    }
}

Main
