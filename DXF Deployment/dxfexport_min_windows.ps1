docker rm -f dxf-export-service 2>$null

# Parameter abfragen
$EnvFile       = Read-Host ".env file path [.env]"
if (-not $EnvFile) { $EnvFile = ".env" }

$SqlitePath    = Read-Host "SQLite file path [C:\app\SQLite\export.db]"
if (-not $SqlitePath) { $SqlitePath = "C:\app\SQLite\export.db" }

$SqliteHostDir = Read-Host "SQLite host path [C:\app\dxfexport\dxf-data]"
if (-not $SqliteHostDir) { $SqliteHostDir = "C:\app\dxfexport\dxf-data" }

$Port1         = Read-Host "External Port 1 [5000]"
if (-not $Port1) { $Port1 = 5000 }

$Port2         = Read-Host "External Port 2 [5001]"
if (-not $Port2) { $Port2 = 5001 }

$Image         = Read-Host "Docker Image [vertigisapps.azurecr.io/networks/dxf-export-windows:1.4.0]"
if (-not $Image) { $Image = "vertigisapps.azurecr.io/networks/dxf-export-windows:1.4.0" }

# .env Datei erzeugen
@"
DOTNET_ENVIRONMENT=Production
DBConnection=Data Source=$SqlitePath
DBProvider=SQLite
FilePath=C:\app\DXFExports

Logging__LogLevel__Default=Information
Logging__LogLevel__Microsoft=Warning

# Path to the .db file inside the container
SQLITE_DB_PATH=C:\app\SQLite\export.db
# Host directory that will be bind-mounted to persist the SQLite file
SQLITE_HOST_DIR=./dxf-data

ASPNETCORE_URLS=http://+:5000;http://+:5001
"@ | Set-Content -Path $EnvFile -Encoding ASCII

$containerDir = Split-Path -Path $SqlitePath -Parent

# Docker starten
docker run -d `
  --name dxf-export-service `
  --restart unless-stopped `
  --env-file $EnvFile `
  -p ${Port1}:5000 `
  -p ${Port2}:5001 `
  -v "${SqliteHostDir}:${containerDir}" `
  $Image

