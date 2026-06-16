# DXF Export - Deployment Script (Windows PowerShell 5.1 compatible)
# Version: 2.4 (PS5)
# - Fixed HTML-encodes (&, >)
# - Removed special unicode glyphs in logging
# - Proper quoting for docker health-cmd (no parser conflicts)
# - OS detection compatible with PS5
# - No PS7-only operators (e.g., || as parser token)
# - Safe strings & here-strings

[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$DryRun,
    [string]$ConfigFile = "dxf-deployment.conf",
    [ValidateSet("new", "update")]
    [string]$Mode = "new",
    [switch]$Update,
    [ValidateSet("postgres", "sqlite", "")]
    [string]$DbType = "",
    [switch]$ExistingPostgres,
    [switch]$NewPostgres,
    [string]$DbHost = "",
    [string]$DbPort = "5432",
    [string]$DbUser = "",
    [string]$DbPass = "",
    [string]$DbName = "",
    [string]$SqlitePath = "",
    [string]$SqliteHostDir = "",
    [switch]$DockerHub,
    [string]$Image = "",
    [string]$Port1 = "",
    [string]$Port2 = "",
    [string]$AcrUser = "",
    [string]$AcrPass = "",
    [switch]$CreateConfig
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Globals
$script:SCRIPT_NAME = "DXF Export Deployment"
$script:VERSION = "2.4"
$script:LOG_FILE = Join-Path $env:TEMP ("dxf-deployment-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# Defaults
$script:REGISTRY_NAME = "vertigisapps.azurecr.io"
$script:DEFAULT_IMAGE = "networks/dxf-export-windows:1.5.0"
$script:DEFAULT_PORT1 = 5000
$script:DEFAULT_PORT2 = 5001
$script:CONTAINER_NAME = "dxf-export-service"
$script:POSTGRES_CONTAINER_NAME = "dxf-postgres"

# State
$script:USE_EXISTING_POSTGRES = $true
$script:DEPLOY_FROM_DOCKERHUB = $false
$script:CLEANUP_NEEDED = $false
$script:TEMP_FILES = @()
$script:CREATED_CONTAINERS = @()

# Non-interactive mode (CI)
$script:FORCE = $env:FORCE -eq "yes"
$script:CAN_PROMPT = (-not $script:FORCE) -and ($Host.Name -ne 'ServerRemoteHost') -and (-not [Console]::IsInputRedirected)

# ------------------------------
# Helpers for PS5 OS detection
# ------------------------------
function Test-IsWindows { return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) }
function Test-IsLinux {
    try {
        return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix)
    } catch { return $false }
}

# ------------------------------
# Colors & Logging
# ------------------------------
function Write-ColorOutput {
    param(
        [string]$Message,
        [ValidateSet('Black','DarkBlue','DarkGreen','DarkCyan','DarkRed','DarkMagenta','DarkYellow','Gray','DarkGray','Blue','Green','Cyan','Red','Magenta','Yellow','White')]
        [string]$ForegroundColor = "White"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp $Message"
    Write-Host $logMessage -ForegroundColor $ForegroundColor
    Add-Content -Path $script:LOG_FILE -Value $logMessage
}
function Log-Section { param([string]$Message) Write-ColorOutput "`n=== $Message ===" -ForegroundColor Cyan }
function Log-Success { param([string]$Message) Write-ColorOutput "[OK] $Message" -ForegroundColor Green }
function Log-Info    { param([string]$Message) Write-ColorOutput "[i] $Message" -ForegroundColor Yellow }
function Log-Warning { param([string]$Message) Write-ColorOutput "[WARN] $Message" -ForegroundColor Yellow }
function Log-Error   { param([string]$Message) Write-ColorOutput "[ERR] $Message" -ForegroundColor Red }
function Log-DryRun  { param([string]$Message) if ($DryRun) { Write-ColorOutput "[DRY RUN] Would execute: $Message" -ForegroundColor Blue } }

# ------------------------------
# External command wrapper
# ------------------------------
function Run-External {
    param(
        [Parameter(Mandatory)] [string]$Exe,
        [string[]]$Args = @(),
        [switch]$IgnoreFailure
    )
    if ($DryRun) {
        Log-DryRun "$Exe $($Args -join ' ')"
        return 0
    }
    & $Exe @Args
    $code = $LASTEXITCODE
    if (($code -ne 0) -and (-not $IgnoreFailure)) {
        throw "$Exe exited with code $code"
    }
    return $code
}

# ------------------------------
# Help
# ------------------------------
function Show-Help {
    $scriptName = Split-Path -Leaf $PSCommandPath
    Write-Host @"
$($script:SCRIPT_NAME) v$($script:VERSION)

USAGE:
    .\${scriptName} [OPTIONS]

OPTIONS:
    -Help                   Show this help message
    -DryRun                 Run in dry-run mode (show what would be done)
    -ConfigFile FILE        Use configuration file (default: dxf-deployment.conf)
    -Mode MODE              Deployment mode: new|update (default: new)
    -Update                 Update existing deployment

DATABASE TYPE:
    -DbType TYPE            Database backend: postgres|sqlite

POSTGRESQL OPTIONS:
    -ExistingPostgres       Use existing PostgreSQL instance (default)
    -NewPostgres            Deploy new PostgreSQL container
    -DbHost HOST            Database host
    -DbPort PORT            Database port (default: 5432)
    -DbUser USER            Database username
    -DbPass PASS            Database password
    -DbName NAME            Database name

SQLITE OPTIONS:
    -SqlitePath PATH        Path to SQLite .db file inside container
                            (default: /app/SQLite/export.db)
    -SqliteHostDir DIR      Host directory to persist SQLite database
                            (default: ./dxf-data)

CONTAINER / REGISTRY:
    -DockerHub              Pull image from Docker Hub instead of ACR
    -Image IMAGE            Docker image name
    -Port1 PORT             Host port for API 1 (default: 5000)
    -Port2 PORT             Host port for API 2 (default: 5001)
    -AcrUser USER           Azure Container Registry username
    -AcrPass PASS           Azure Container Registry password
    -CreateConfig           Create sample configuration file and exit

ENVIRONMENT:
    `\$env:FORCE="yes"       Skip interactive confirmation (CI usage)
"@
}

# ------------------------------
# Cleanup
# ------------------------------
function Remove-TempFiles {
    Log-Info "Cleaning up temporary files..."
    foreach ($tempFile in $script:TEMP_FILES) {
        if (Test-Path $tempFile) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            Log-Info "Removed temp file: $tempFile"
        }
    }
    if ($script:CLEANUP_NEEDED -and (Test-Path ".env")) {
        Remove-Item -Path ".env" -Force -ErrorAction SilentlyContinue
        Log-Info "Removed .env file"
    }
}
function Remove-CreatedContainers {
    Log-Info "Rolling back containers..."
    foreach ($container in $script:CREATED_CONTAINERS) {
        $exists = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $container }
        if ($exists) {
            Log-Info "Removing container: $container"
            if (-not $DryRun) {
                docker rm -f $container 2>$null | Out-Null
            } else {
                Log-DryRun "docker rm -f $container"
            }
        }
    }
}
function Invoke-Cleanup {
    param([int]$ExitCode = 1)
    $script:CLEANUP_NEEDED = $true
    Log-Error "Deployment failed or interrupted. Performing cleanup..."
    Remove-CreatedContainers
    Remove-TempFiles
    Log-Error "Deployment failed. Check log file: $script:LOG_FILE"
    exit $ExitCode
}
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Remove-TempFiles }

# ------------------------------
# Config Management
# ------------------------------
function Import-ConfigFile {
    param([string]$Path)
    if (Test-Path $Path) {
        Log-Info "Loading configuration from: $Path"
        Get-Content $Path | ForEach-Object {
            if ($_ -match '^\s*#' -or [string]::IsNullOrWhiteSpace($_)) { return }
            if ($_ -match '^([^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim().Trim('"').Trim("'")
                switch ($key) {
                    "DB_TYPE"               { $script:DbType = $value }
                    "DB_HOST"               { $script:DbHost = $value }
                    "DB_PORT"               { $script:DbPort = $value }
                    "DB_USER"               { $script:DbUser = $value }
                    "DB_PASS"               { $script:DbPass = $value }
                    "DB_NAME"               { $script:DbName = $value }
                    "SQLITE_DB_PATH"        { $script:SqlitePath = $value }
                    "SQLITE_HOST_DIR"       { $script:SqliteHostDir = $value }
                    "IMAGE_NAME"            { $script:Image = $value }
                    "PORT1"                 { $script:Port1 = $value }
                    "PORT2"                 { $script:Port2 = $value }
                    "ACR_USER"              { $script:AcrUser = $value }
                    "ACR_PASS"              { $script:AcrPass = $value }
                    "USE_EXISTING_POSTGRES" { $script:USE_EXISTING_POSTGRES = ($value -eq "true") }
                    "DEPLOY_FROM_DOCKERHUB" { $script:DEPLOY_FROM_DOCKERHUB = ($value -eq "true") }
                }
            }
        }
        Log-Success "Configuration loaded successfully"
    } else {
        Log-Warning "Configuration file not found: $Path"
    }
}
function New-SampleConfig {
    $configContent = @"
# DXF Export Deployment Configuration
# Database type: postgres | sqlite
DB_TYPE=postgres

# --- PostgreSQL settings (used when DB_TYPE=postgres) ---
DB_HOST=localhost
DB_PORT=5432
DB_USER=dxf_user
DB_PASS=secure_password
DB_NAME=dxf_database
USE_EXISTING_POSTGRES=true

# --- SQLite settings (used when DB_TYPE=sqlite) ---
# Path to the .db file inside the container
SQLITE_DB_PATH=C:\app\SQLite\export.db
# Host directory that will be bind-mounted to persist the SQLite file
SQLITE_HOST_DIR=./dxf-data

# --- Common settings ---
IMAGE_NAME=$($script:DEFAULT_IMAGE)
PORT1=$($script:DEFAULT_PORT1)
PORT2=$($script:DEFAULT_PORT2)
ACR_USER=your_acr_username
ACR_PASS=your_acr_password
DEPLOY_FROM_DOCKERHUB=false
"@
    Set-Content -Path $ConfigFile -Value $configContent
    Log-Success "Sample configuration created: $ConfigFile"
}

# ------------------------------
# Validation
# ------------------------------
function Test-PortAvailable {
    param([int]$Port)

    $connections = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if ($connections) {
        return $false
    }

    $udp = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
    if ($udp) {
        return $false
    }

    return $true
}
function Test-PortValid {
    param([string]$Port, [string]$PortName)
    if (-not ($Port -match '^\d+$') -or [int]$Port -lt 1 -or [int]$Port -gt 65535) {
        Log-Error ("Invalid {0}: {1} (must be 1-65535)" -f $PortName, $Port)
        return $false
    }
    if (-not (Test-PortAvailable $Port)) {
        Log-Error ("{0} {1} is already in use" -f $PortName, $Port)
        return $false
    }
    return $true
}

# ------------------------------
# Docker
# ------------------------------
function Test-DockerInstalled {
    if (Get-Command docker -ErrorAction SilentlyContinue) { return $true } else { return $false }
}
function Install-DockerOnWindows {
    Log-Section "Installing Docker Desktop for Windows"
    if ($DryRun) { Log-DryRun "Download and install Docker Desktop" ; return }
    $dockerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
    $installerPath = Join-Path $env:TEMP "DockerDesktopInstaller.exe"
    Log-Info "Downloading Docker Desktop..."
    try {
        Invoke-WebRequest -Uri $dockerUrl -OutFile $installerPath
        Log-Info "Starting Docker Desktop installation (requires admin rights)..."
        Start-Process -FilePath $installerPath -ArgumentList "install","--quiet" -Wait -Verb RunAs
        Log-Success "Docker Desktop installed. Please restart your computer and run this script again."
        exit 0
    } catch {
        Log-Error "Failed to install Docker Desktop: $_"
        exit 1
    }
}
function Install-DockerOnLinux {
    Log-Section "Installing Docker Engine"
    if ($DryRun) { Log-DryRun "Install Docker via package manager" ; return }
    if (Get-Command apt-get -ErrorAction SilentlyContinue) {
        Log-Info "Installing Docker using apt..."
        Run-External -Exe "sudo" -Args @("apt-get","update","-y")
        Run-External -Exe "sudo" -Args @("apt-get","install","-y","docker.io")
        Run-External -Exe "sudo" -Args @("systemctl","enable","--now","docker")
    } elseif (Get-Command yum -ErrorAction SilentlyContinue) {
        Log-Info "Installing Docker using yum..."
        Run-External -Exe "sudo" -Args @("yum","install","-y","docker")
        Run-External -Exe "sudo" -Args @("systemctl","enable","--now","docker")
    } else {
        Log-Error "Unsupported Linux distribution for automatic Docker installation"
        exit 1
    }
}
function Test-Docker {
    Log-Section "Checking Docker Installation"
    if (Test-DockerInstalled) {
        $dockerVersion = docker --version
        Log-Success "Docker is installed: $dockerVersion"
    } else {
        Log-Info "Docker not found. Installing..."
        if (Test-IsWindows) {
            Install-DockerOnWindows
        } elseif (Test-IsLinux) {
            Install-DockerOnLinux
        } else {
            Log-Error "Unsupported operating system for automatic Docker installation"
            exit 1
        }
    }
    try {
        docker info 2>$null | Out-Null
        Log-Success "Docker daemon is running"
    } catch {
        Log-Error "Docker daemon is not running. Please start Docker and try again."
        exit 1
    }
}

# ------------------------------
# PostgreSQL
# ------------------------------
function Test-PostgreSQLConnection {
    Log-Info "Testing database connection..."
    if ($DryRun) { Log-DryRun "Test connection to ${DbHost}:${DbPort} as $DbUser" ; return $true }

    $psqlConn = "postgresql://${DbUser}:${DbPass}@${DbHost}:${DbPort}/${DbName}"
    $args = @("run","--rm","postgres:15","psql",$psqlConn,"-c","SELECT 1;")
    $code = Run-External -Exe "docker" -Args $args -IgnoreFailure
    if ($code -eq 0) {
        Log-Success "Database connection successful"
        return $true
    } else {
        Log-Warning "Database connection test failed"
        return $false
    }
}
function Deploy-PostgresContainer {
    Log-Section "Deploying PostgreSQL Container"
    if ($script:USE_EXISTING_POSTGRES) {
        Log-Info "Skipping PostgreSQL deployment - using existing instance"
        return
    }
    Log-Info "Deploying PostgreSQL container: $script:POSTGRES_CONTAINER_NAME"
    $exists = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $script:POSTGRES_CONTAINER_NAME }
    if ($exists) {
        if ($Mode -eq "update") {
            Log-Info "Removing existing PostgreSQL container for update"
            if (-not $DryRun) { docker rm -f $script:POSTGRES_CONTAINER_NAME 2>$null | Out-Null } else { Log-DryRun "docker rm -f $script:POSTGRES_CONTAINER_NAME" }
        } else {
            Log-Warning "PostgreSQL container already exists. Use -Update to replace it."
            return
        }
    }
    if ($DryRun) {
        Log-DryRun ("docker run -d --name {0} --restart unless-stopped -e POSTGRES_DB={1} -e POSTGRES_USER={2} -e POSTGRES_PASSWORD=**** -p {3}:5432 -v {0}_data:/var/lib/postgresql/data postgres:15" -f $script:POSTGRES_CONTAINER_NAME, $DbName, $DbUser, $DbPort)
        return
    }
    try {
        $args = @(
            "run","-d",
            "--name",$script:POSTGRES_CONTAINER_NAME,
            "--restart","unless-stopped",
            "-e","POSTGRES_DB=$DbName",
            "-e","POSTGRES_USER=$DbUser",
            "-e","POSTGRES_PASSWORD=$DbPass",
            "-p","${DbPort}:5432",
            "-v","${script:POSTGRES_CONTAINER_NAME}_data:/var/lib/postgresql/data",
            "postgres:15"
        )
        Run-External -Exe "docker" -Args $args | Out-Null
        $script:CREATED_CONTAINERS += $script:POSTGRES_CONTAINER_NAME
        Log-Success "PostgreSQL container deployed successfully"
        Log-Info "Waiting for PostgreSQL to be ready..."
        Start-Sleep -Seconds 10
        Test-PostgreSQLConnection | Out-Null
    } catch {
        Log-Error "Failed to deploy PostgreSQL container: $_"
        Invoke-Cleanup
    }
}

# ------------------------------
# SQLite
# ------------------------------
function Initialize-SqliteDefaults {
    if ([string]::IsNullOrEmpty($script:SqlitePath))    { $script:SqlitePath = "C:\app\SQLite\export.db" }
    if ([string]::IsNullOrEmpty($script:SqliteHostDir)) { $script:SqliteHostDir = "C:\dxf-data" }
}
function Test-SqliteParams {
    Initialize-SqliteDefaults
    Log-Info "SQLite database path (container): $script:SqlitePath"
    Log-Info "SQLite data directory (host): $script:SqliteHostDir"
    if ($DryRun) { Log-DryRun "mkdir -p $script:SqliteHostDir" ; return $true }
    if (-not (Test-Path -LiteralPath $script:SqliteHostDir)) {
        Log-Info "Creating SQLite host data directory: $script:SqliteHostDir"
        try { New-Item -ItemType Directory -Path $script:SqliteHostDir -Force | Out-Null } catch {
            Log-Error "Could not create SQLite host directory: $_"
            return $false
        }
    }
    try {
        $testFile = Join-Path $script:SqliteHostDir "test.tmp"
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item $testFile -Force
        Log-Success "SQLite configuration validated"
        return $true
    } catch {
        Log-Error "SQLite host directory is not writable: $script:SqliteHostDir"
        return $false
    }
}

# ------------------------------
# Registry
# ------------------------------
function Connect-Registry {
    Log-Section "Container Registry Authentication"
    if ($script:DEPLOY_FROM_DOCKERHUB) {
        Log-Info "Using Docker Hub - public images may not require login"
        return
    }
    if (Get-Command az -ErrorAction SilentlyContinue) {
        Log-Info "Attempting Azure CLI login..."
        if ($DryRun) { Log-DryRun ("az acr login --name {0}" -f ($script:REGISTRY_NAME.Split('.')[0])) ; return }
        try {
            $registryShortName = $script:REGISTRY_NAME.Split('.')[0]
            az acr login --name $registryShortName 2>$null
            Log-Success "Logged in to ACR using Azure CLI"
            return
        } catch {
            Log-Warning "Azure CLI login failed, falling back to manual login"
        }
    }
    Log-Info "Using manual ACR login"
    if ($DryRun) { Log-DryRun "echo ***** | docker login $script:REGISTRY_NAME -u [ACR_USER] --password-stdin" ; return }
try {
    $pass = $script:AcrPass
    if ([string]::IsNullOrEmpty($pass)) { throw "ACR password not provided." }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "docker"
    $psi.Arguments = "login $($script:REGISTRY_NAME) -u $($script:AcrUser) --password-stdin"
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.WriteLine($pass)
    $p.StandardInput.Close()
    $p.WaitForExit()

    if ($p.ExitCode -ne 0) { throw $p.StandardError.ReadToEnd() }
    Log-Success "Logged in to ACR successfully"
} catch {
    Log-Error "Failed to login to ACR: $_"
    Invoke-Cleanup
}
}
function Get-FullImageName {
    if ($script:Image -like "$($script:REGISTRY_NAME)*") { return $script:Image }
    elseif ($script:DEPLOY_FROM_DOCKERHUB) { return $script:Image }
    else { return "$($script:REGISTRY_NAME)/$($script:Image)" }
}
function Get-DockerImage {
    Log-Section "Pulling Container Image"
    $fullImageName = Get-FullImageName
    Log-Info "Pulling image: $fullImageName"
    try {
        Run-External -Exe "docker" -Args @("pull",$fullImageName) | Out-Null
        Log-Success "Image pulled successfully: $fullImageName"
    } catch {
        Log-Error "Failed to pull image: $_"
        Invoke-Cleanup
    }
}

# ------------------------------
# Environment File
# ------------------------------
function New-EnvFile {
    Log-Section "Creating Environment Configuration"
    $envFile = ".env"
    if ($DryRun) { Log-DryRun "Create $envFile with $DbType database configuration" ; return }
    Log-Info "Creating .env file..."
    try {
        if ($DbType -eq "sqlite") {
$envContent = @"
# DXF Export Service Configuration
# Generated on $(Get-Date)
# Database backend: SQLite

DOTNET_ENVIRONMENT=Production
DBConnection=Data Source=$($script:SqlitePath)
DBProvider=SQLite
FilePath=C:\app\DXFExports

Logging__LogLevel__Default=Debug
Logging__LogLevel__Microsoft=Debug

ASPNETCORE_URLS=http://+:5000;http://+:5001
"@
        } else {
$envContent = @"
# DXF Export Service Configuration
# Generated on $(Get-Date)
# Database backend: PostgreSQL

DOTNET_ENVIRONMENT=Production
DBConnection=Host=$DbHost;Port=$DbPort;Username=$DbUser;Password=$DbPass;Database=$DbName;
DBProvider=PostgreSQL

Logging__LogLevel__Default=Information
Logging__LogLevel__Microsoft=Warning

ASPNETCORE_URLS=http://+:5000;http://+:5001
"@
        }
        Set-Content -Path $envFile -Value $envContent -Encoding UTF8
        Log-Success "Environment file created"
    } catch {
        Log-Error "Failed to create environment file: $_"
        Invoke-Cleanup
    }
}

# ------------------------------
# Application Deployment
# ------------------------------
function Deploy-Application {
    Log-Section "Deploying DXF Export Application"
    $fullImageName = Get-FullImageName
    Log-Info "Will run image: $fullImageName"

    $exists = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $script:CONTAINER_NAME }
    if ($exists) {
        if ($Mode -eq "update") {
            Log-Info "Removing existing container for update: $script:CONTAINER_NAME"
            if (-not $DryRun) { docker rm -f $script:CONTAINER_NAME 2>$null | Out-Null } else { Log-DryRun "docker rm -f $script:CONTAINER_NAME" }
        } else {
            Log-Warning "Container already exists: $script:CONTAINER_NAME. Use -Update to replace it."
            return
        }
    }

    Log-Info "Starting DXF Export Service container..."
    $volumeArgs = @()
    if ($DbType -eq "sqlite") {
        $containerDir = Split-Path -Parent $script:SqlitePath
        $resolved = Resolve-Path -LiteralPath $script:SqliteHostDir -ErrorAction SilentlyContinue
        $absHostDir = if ($resolved) { $resolved.Path } else { (Get-Location).Path }
        $volumeArgs += "-v", ("{0}:{1}" -f $absHostDir, $containerDir)
        Log-Info ("Bind-mounting SQLite data: {0} -> {1}" -f $absHostDir, $containerDir)
    }

    # Health check argument as a single, safely-quoted token (so PS5 parser won't see ||)
    $healthCmd = '--health-cmd=curl -f http://localhost:5000 || exit 1'

    if ($DryRun) {
        $volStr = if ($volumeArgs) { " " + ($volumeArgs -join " ") } else { "" }
        Log-DryRun ("docker run -d --name {0} --restart unless-stopped --memory=1g --cpus=1.0 --env-file .env -p {1}:5000 -p {2}:5001 {3} --health-interval=30s --health-timeout=10s --health-retries=3 {4}" -f $script:CONTAINER_NAME, $Port1, $Port2, ($volumeArgs -join ' '), $fullImageName)
        return
    }

    try {
        $dockerArgs = @(
            "run","-d",
            "--name",$script:CONTAINER_NAME,
            "--restart","unless-stopped",
            "--memory=1g",
            "--cpus=1.0",
            "--env-file",".env",
            "-p","${Port1}:5000",
            "-p","${Port2}:5001"
        )
        if ($volumeArgs) { $dockerArgs += $volumeArgs }
        $dockerArgs += @(
            $healthCmd,
            "--health-interval=30s",
            "--health-timeout=10s",
            "--health-retries=3",
            $fullImageName
        )
        Run-External -Exe "docker" -Args $dockerArgs | Out-Null
        $script:CREATED_CONTAINERS += $script:CONTAINER_NAME
        Log-Success "DXF Export Service container started successfully"
        Log-Info "Waiting for container to be healthy..."
        Start-Sleep -Seconds 5
        Log-Info "Container status:"
        docker ps --filter "name=$script:CONTAINER_NAME" --format "table {{.Names}}`t{{.Status}}`t{{.Ports}}"
    } catch {
        Log-Error "Failed to start DXF Export Service container: $_"
        Invoke-Cleanup
    }
}

# ------------------------------
# Interactive Prompts
# ------------------------------
function Request-MissingParams {
    if ([string]::IsNullOrEmpty($DbType)) {
        Write-Host ""
        Write-Host "Select database backend:"
        Write-Host "  1) PostgreSQL"
        Write-Host "  2) SQLite"
        do {
            $choice = Read-Host "Enter choice [1-2]"
            switch ($choice) {
                "1" { $script:DbType = "postgres"; break }
                "2" { $script:DbType = "sqlite"; break }
                default { Write-Host "Please enter 1 or 2." }
            }
        } while ($DbType -eq "")
    }
    Log-Info "Database backend selected: $DbType"

    if ($DbType -eq "sqlite") {
        Log-Info "SQLite backend - no database server credentials required."
        if ([string]::IsNullOrEmpty($script:SqlitePath)) {
            $input = Read-Host "Enter SQLite .db file path inside container (default: C:\app\SQLite\export.db)"
            $script:SqlitePath = if ($input) { $input } else { "C:\app\SQLite\export.db" }
        }
        if ([string]::IsNullOrEmpty($script:SqliteHostDir)) {
            $input = Read-Host "Enter host directory to persist SQLite file (default: ./dxf-data)"
            $script:SqliteHostDir = if ($input) { $input } else { "./dxf-data" }
        }
    } else {
        if ([string]::IsNullOrEmpty($DbHost)) { $script:DbHost = Read-Host "Enter Database Host" }
        if ([string]::IsNullOrEmpty($DbPort)) {
            $input = Read-Host "Enter Database Port (default: 5432)"
            $script:DbPort = if ($input) { $input } else { "5432" }
        }
        if ([string]::IsNullOrEmpty($DbUser)) { $script:DbUser = Read-Host "Enter Database Username" }
        if ([string]::IsNullOrEmpty($DbPass)) {
            $securePass = Read-Host "Enter Database Password" -AsSecureString
            $script:DbPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
            )
        }
        if ([string]::IsNullOrEmpty($DbName)) { $script:DbName = Read-Host "Enter Database Name" }
    }

    if ([string]::IsNullOrEmpty($script:Image)) {
        $input = Read-Host "Enter Image Name (default: $($script:DEFAULT_IMAGE))"
        $script:Image = if ($input) { $input } else { $script:DEFAULT_IMAGE }
    }
    if ([string]::IsNullOrEmpty($Port1)) {
        $input = Read-Host "Enter host port for API 1 (default: $($script:DEFAULT_PORT1))"
        $script:Port1 = if ($input) { $input } else { "$script:DEFAULT_PORT1" }
    }
    if ([string]::IsNullOrEmpty($Port2)) {
        $input = Read-Host "Enter host port for API 2 (default: $($script:DEFAULT_PORT2))"
        $script:Port2 = if ($input) { $input } else { "$script:DEFAULT_PORT2" }
    }
    if (-not $script:DEPLOY_FROM_DOCKERHUB) {
        if ([string]::IsNullOrEmpty($AcrUser)) { $script:AcrUser = Read-Host "Enter ACR Username" }
        if ([string]::IsNullOrEmpty($AcrPass)) {
            $securePass = Read-Host "Enter ACR Password" -AsSecureString
            $script:AcrPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
            )
        }
    }
}
function Test-RequiredParams {
    $missingParams = @()
    if ($DbType -eq "postgres") {
        if ([string]::IsNullOrEmpty($DbHost)) { $missingParams += "Database Host (-DbHost)" }
        if ([string]::IsNullOrEmpty($DbUser)) { $missingParams += "Database User (-DbUser)" }
        if ([string]::IsNullOrEmpty($DbPass)) { $missingParams += "Database Password (-DbPass)" }
        if ([string]::IsNullOrEmpty($DbName)) { $missingParams += "Database Name (-DbName)" }
    }
    if (-not $script:DEPLOY_FROM_DOCKERHUB) {
        if ([string]::IsNullOrEmpty($AcrUser)) { $missingParams += "ACR Username (-AcrUser)" }
        if ([string]::IsNullOrEmpty($AcrPass)) { $missingParams += "ACR Password (-AcrPass)" }
    }
    if ($missingParams.Count -gt 0) {
        Log-Error "Missing required parameters:"
        foreach ($param in $missingParams) { Log-Error "  - $param" }
        return $false
    }
    return $true
}

# ------------------------------
# Main
# ------------------------------
function Main {
    try {
        if ($Help) { Show-Help ; exit 0 }
        if ($CreateConfig) { New-SampleConfig ; exit 0 }

        Log-Section ("{0} v{1}" -f $script:SCRIPT_NAME, $script:VERSION)
        if ($DryRun) { Log-Warning "DRY RUN MODE - No actual changes will be made" }

        "=== $($script:SCRIPT_NAME) v$($script:VERSION) - $(Get-Date) ===" | Out-File $script:LOG_FILE -Encoding UTF8
        "User: $env:USERNAME" | Add-Content $script:LOG_FILE
        "Mode: $Mode" | Add-Content $script:LOG_FILE
        "Dry Run: $DryRun" | Add-Content $script:LOG_FILE
        "================================" | Add-Content $script:LOG_FILE

        if ($Update) { $Mode = "update" }
        if ($ExistingPostgres) { $script:USE_EXISTING_POSTGRES = $true }
        if ($NewPostgres)      { $script:USE_EXISTING_POSTGRES = $false }
        if ($DockerHub)        { $script:DEPLOY_FROM_DOCKERHUB = $true }

        Import-ConfigFile -Path $ConfigFile

        if ($PSBoundParameters.ContainsKey('DbType'))        { $script:DbType = $DbType }
        if ($PSBoundParameters.ContainsKey('DbHost'))        { $script:DbHost = $DbHost }
        if ($PSBoundParameters.ContainsKey('DbPort'))        { $script:DbPort = $DbPort }
        if ($PSBoundParameters.ContainsKey('DbUser'))        { $script:DbUser = $DbUser }
        if ($PSBoundParameters.ContainsKey('DbPass'))        { $script:DbPass = $DbPass }
        if ($PSBoundParameters.ContainsKey('DbName'))        { $script:DbName = $DbName }
        if ($PSBoundParameters.ContainsKey('SqlitePath'))    { $script:SqlitePath = $SqlitePath }
        if ($PSBoundParameters.ContainsKey('SqliteHostDir')) { $script:SqliteHostDir = $SqliteHostDir }
        if ($PSBoundParameters.ContainsKey('Image'))         { $script:Image = $Image }
        if ($PSBoundParameters.ContainsKey('Port1'))         { $script:Port1 = $Port1 }
        if ($PSBoundParameters.ContainsKey('Port2'))         { $script:Port2 = $Port2 }
        if ($PSBoundParameters.ContainsKey('AcrUser'))       { $script:AcrUser = $AcrUser }
        if ($PSBoundParameters.ContainsKey('AcrPass'))       { $script:AcrPass = $AcrPass }

        if ($script:CAN_PROMPT) {
            Request-MissingParams
        } else {
            Log-Info "Non-interactive or FORCE mode; skipping interactive prompts"
            if ([string]::IsNullOrEmpty($DbType)) { $script:DbType = "postgres" }
        }

        if (-not (Test-RequiredParams)) {
            Log-Error "Parameter validation failed"
            exit 1
        }

        if ([string]::IsNullOrEmpty($Port1))        { $script:Port1 = "$script:DEFAULT_PORT1" }
        if ([string]::IsNullOrEmpty($Port2))        { $script:Port2 = "$script:DEFAULT_PORT2" }
        if ([string]::IsNullOrEmpty($script:Image)) { $script:Image = $script:DEFAULT_IMAGE }

        if (-not (Test-PortValid $Port1 "Port 1")) { exit 1 }
        if (-not (Test-PortValid $Port2 "Port 2")) { exit 1 }
        if ($DbType -eq "postgres" -and -not $script:USE_EXISTING_POSTGRES) {
            if (-not (Test-PortValid $DbPort "Database Port")) { exit 1 }
        }

        Log-Info "Configuration Summary:"
        Log-Info "  Mode:        $Mode"
        Log-Info "  DB Type:     $DbType"
        if ($DbType -eq "sqlite") {
            Log-Info "  SQLite host dir:  $($script:SqliteHostDir)"
            Log-Info "  SQLite container: $($script:SqlitePath)"
        } else {
            Log-Info "  Database:    ${DbHost}:${DbPort} ($DbName)"
            Log-Info "  Use existing PostgreSQL: $script:USE_EXISTING_POSTGRES"
        }
        Log-Info "  Image:       $script:Image"
        Log-Info "  Ports:       $Port1, $Port2"
        Log-Info "  Deploy from Docker Hub: $script:DEPLOY_FROM_DOCKERHUB"

        if (-not $DryRun -and $script:CAN_PROMPT) {
            $confirm = Read-Host "Continue with deployment? (y/N)"
            if ($confirm -notin @('y','Y')) {
                Log-Info "Deployment cancelled by user"
                exit 0
            }
        }

        Test-Docker

        if ($DbType -eq "sqlite") {
            if (-not (Test-SqliteParams)) { Log-Error "SQLite parameter validation failed" ; exit 1 }
        } else {
            if (-not $script:USE_EXISTING_POSTGRES) {
                Deploy-PostgresContainer
            } else {
                Test-PostgreSQLConnection | Out-Null
            }
        }

        Connect-Registry
        Get-DockerImage
        New-EnvFile
        Deploy-Application

        $script:CLEANUP_NEEDED = $false
        Log-Section "Deployment Completed Successfully"
        Log-Success "DXF Export Service is now running"
        Log-Info "API endpoints:"
        Log-Info "  - http://localhost:$Port1"
        Log-Info "  - http://localhost:$Port2"
        Log-Info "Log file: $script:LOG_FILE"

        if ($DbType -eq "sqlite") {
            $dbFile = Split-Path -Leaf $script:SqlitePath
            Log-Info ("SQLite database: {0}" -f (Join-Path $script:SqliteHostDir $dbFile))
            $rp = Resolve-Path $script:SqliteHostDir -ErrorAction SilentlyContinue
            if ($rp) { Log-Info ("  (persisted on host at: {0})" -f $rp.Path) }
        } elseif (-not $script:USE_EXISTING_POSTGRES) {
            Log-Info "PostgreSQL container: $script:POSTGRES_CONTAINER_NAME"
        }

    } catch {
        Log-Error "An error occurred: $_"
        Invoke-Cleanup
    }
}

Main

