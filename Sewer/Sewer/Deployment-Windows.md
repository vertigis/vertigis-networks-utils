# Sewer Services Deployment (Windows)

## Overview

This document describes deployment of the Sewer services as Docker/Podman containers on Windows.

| Service | Container Name | Image (Linux) | Image (Windows) | Port |
|---------|---------------|---------------|-----------------|------|
| SewerManagement | `sewer-service` | `networks/sewer` | `networks/sewer-windows` | 5050 |
| Condition Classification | `sewercc-service` | `networks/sewercc` | `networks/sewercc-windows` | 8080 |

## Prerequisites

- **Linux containers:** Docker Desktop or Podman (rootful mode for Windows 10)
- **Windows containers:** Docker Engine (Windows Server) or Docker Desktop (Windows containers mode)
- Access to `vertigisnetworks.azurecr.io`
- PowerShell 5.1+

## Quick Start

```powershell
# Deploy SewerManagement (Linux container)
.\sewer_windows.ps1 -Service sewer -AcrUser <USER> -AcrPass <PASS>

# Deploy Condition Classification (Linux container)
.\sewer_windows.ps1 -Service sewercc -AcrUser <USER> -AcrPass <PASS>

# Deploy Windows container
.\sewer_windows.ps1 -Service sewer -Runtime docker -ContainerType windows
```

## Configuration File

Place config files in the `scripts/` directory:

**sewer-deployment.conf:**
```ini
IMAGE_NAME=networks/sewer:latest
PORT=5050
ACR_USER=your_username
ACR_PASS=your_password
CORS_ORIGIN=
REGISTRY=vertigisnetworks.azurecr.io
RUNTIME=docker
CONTAINER_TYPE=linux
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Service` | `sewer` or `sewercc` | (required) |
| `-Update` | Update existing container | off |
| `-Runtime` | `docker` or `podman` | auto-detect |
| `-ContainerType` | `linux` or `windows` | auto-detect |
| `-Image` | Full image name | from config |
| `-Port` | Host port | 5050/8080 |
| `-DryRun` | Preview actions only | off |

## Windows Containers

Windows containers use process isolation and require:
- Docker Engine with Windows containers enabled
- Matching OS build between host and image (e.g., both LTSC 2022 / build 20348)

The script auto-detects and validates OS build compatibility.

### Windows Container Health Check

Windows containers use `curl.exe` for health checking (available since Windows Server 2019):
```
curl.exe -f http://localhost:<port>/
```

### Startup Timing

Windows containers take longer to start (60-120s). The script uses:
- **36 attempts × 5s = 180s** timeout (vs 12×5s for Linux)
- `--health-start-period 90s` so Docker doesn't count startup failures

## Environment Variables

Pass configuration at runtime via `-e` flags or Container App settings:

| Variable | Service | Description |
|----------|---------|-------------|
| `CORS_ORIGIN` | Both | Comma-separated CORS origins |
| `ConnectionStrings__JobService` | CC | SQLite connection string |
| `FeatureServer__URL` | CC | Feature service endpoint |
| `FeatureServer__Token` | CC | Authentication token |
| `FeatureServer__GdbVersion` | CC | Geodatabase version |
| `FeatureServer__Contract` | CC | Contract GUID |
| `AuxiliaryData__ClassificationCodes__ServiceURL` | CC | Code classes service |
| `AuxiliaryData__BoundaryConditions__ServiceURL` | CC | Boundary conditions service |

## Volumes

### Condition Classification (SQLite persistence)
```powershell
# Linux container
docker run -d --name sewercc-service -p 8080:8080 -v sewercc-data:/data vertigisnetworks.azurecr.io/networks/sewercc:latest

# Windows container
docker run -d --name sewercc-service -p 8080:8080 -v sewercc-data:C:\data vertigisnetworks.azurecr.io/networks/sewercc-windows:latest
```

## Podman on Windows 10

For Linux containers on Windows 10 via Podman:
1. Podman must run in **rootful** mode for proper port binding
2. Run `podman machine set --rootful` then `podman machine start`
3. Verify: `podman info --format '{{.Host.Security.Rootless}}'` should be `false`

## Troubleshooting

### View Logs
```powershell
docker logs -f sewer-service
docker logs -f sewercc-service
```

### Container Not Becoming Ready
- Check `docker inspect --format "{{.State.Health.Status}}" <name>`
- For Windows containers, wait up to 3 minutes before diagnosing
- Verify port isn't already in use: `Get-NetTCPConnection -LocalPort 5050`

### Docker Context Issues
If both Podman and Docker are installed, the script auto-detects the `windows-docker` context for Windows containers. Force with `-Runtime docker`.
