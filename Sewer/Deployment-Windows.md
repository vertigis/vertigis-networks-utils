# Sewer Backend Deployment (Windows)

## Overview

Since version 2.0 the Sewer backend is one container with all services behind
an nginx gateway on port `8080`. [`sewer_windows.ps1`](./sewer_windows.ps1)
deploys it on a Windows host, either as

- a **Windows container** (Docker Engine on Windows Server 2022), or
- a **Linux container** (Docker Desktop or Podman on Windows 10/11).

| Container | Container name | Image | Port |
|-----------|----------------|-------|------|
| Windows | `sewer` | `vertigisapps.azurecr.io/networks/sewer-windows:<version>-ltsc2022` | 8080 |
| Linux | `sewer` | `vertigisapps.azurecr.io/networks/sewer:<version>` | 8080 |

The image includes the Sewer Management API, Condition Classification API and
worker, and SewerJS.

## Prerequisites

- PowerShell 5.1 or later
- **Windows container:** Windows Server 2022 (build 20348) with Docker Engine.
  A Windows container must match the Windows Server version of the host; the
  image is built for `ltsc2022`.
- **Linux container:** Docker Desktop (Linux containers) or Podman
- Credentials for `vertigisapps.azurecr.io`, or an image loaded with `docker load`
- The origin of the web application for `CORS_ORIGIN`

## Quick Start

Create `sewer.env` in the directory you run the script from. For a Windows
container:

```dotenv
ASPNETCORE_ENVIRONMENT=Production
NODE_ENV=production
CORS_ORIGIN=https://networks.example.com
MEDIA_ROOT=C:\app\media
XSD_PATH=C:\app\sewerjs\schemas\schema.xsd
```

For a Linux container use `/app/media` and `/app/sewerjs/schemas/schema.xsd`.
Add the media storage settings (`AZURE_STORAGE_*`) if needed. Do not set `PORT`.

```powershell
# Install version 2.2.0 (asks for the registry credentials)
.\sewer_windows.ps1 -Version 2.2.0

# Update to a newer version
.\sewer_windows.ps1 -Version 2.2.1 -Update

# Without registry access: load the image first
docker load -i sewer-windows-2.2.0-ltsc2022.tar
.\sewer_windows.ps1 -Version 2.2.0 -NoPull

# Linux container on Windows 10/11
.\sewer_windows.ps1 -Version 2.2.0 -ContainerType linux

# Non-interactive
$env:FORCE = 'yes'; .\sewer_windows.ps1 -ConfigFile C:\sewer\sewer-consolidated-deployment.conf
```

The script:

1. picks the container OS (Windows on Windows Server, Linux otherwise) and the
   image tag; for a Windows container the tag suffix comes from the host build
   (`20348` → `ltsc2022`),
2. checks that Docker runs the matching container OS,
3. logs in to the registry (or uses the existing login when no credentials are given),
4. pulls the image (`-NoPull` uses a local image),
5. creates the volumes `sewer-media` and `sewer-import-logs` if they do not exist,
6. starts the container with `--restart unless-stopped`, `sewer.env` and the volumes,
7. waits until all five services are `RUNNING`.

With `-Update` the existing container is removed first; the volumes stay.

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Version` | Image version (consolidated) | asked |
| `-EnvFile` | Environment file for the container | `sewer.env` if present |
| `-Image` | Full image name, overrides `-Version` | |
| `-Port` | Host port | 8080 |
| `-CorsOrigin` | CORS origins, overrides `CORS_ORIGIN` of the env file | |
| `-AcrUser`, `-AcrPass` | Registry credentials | asked / existing login |
| `-Runtime` | `docker` or `podman` | `docker` for Windows containers, otherwise auto-detect |
| `-ContainerType` | `linux` or `windows` | `windows` on Windows Server |
| `-Update` | Replace an existing container | off |
| `-NoPull` | Use an image already on the host | off |
| `-ConfigFile` | Configuration file | `sewer-consolidated-deployment.conf` |
| `-DryRun` | Show the commands only | off |

`$env:FORCE = 'yes'` skips all prompts.

## Configuration File

[`sewer-consolidated-deployment.conf`](./sewer-consolidated-deployment.conf)
is the template. The script looks for it in the current directory and next to
the script. Parameters win over the file.

```ini
VERSION=2.2.0
PORT=8080
REGISTRY=vertigisapps.azurecr.io
ACR_USER=
ACR_PASS=
CORS_ORIGIN=
ENV_FILE=C:\sewer\sewer.env
RUNTIME=docker
CONTAINER_TYPE=windows
MEDIA_VOLUME=sewer-media
LOGS_VOLUME=sewer-import-logs
```

## Checks

```powershell
curl.exe --fail http://localhost:8080/health
docker exec sewer powershell -File C:\app\start-services.ps1 -Status   # Windows container
docker exec sewer supervisorctl -c /etc/supervisor/conf.d/sewer.conf status   # Linux container
docker logs --follow sewer
```

## Windows Containers

- Process isolation needs the same Windows Server version on the host and in
  the image. On another version the script stops before pulling.
- The services run as `ContainerUser`; named volumes need no extra permissions.
- The first start takes up to a minute. The script waits up to 3 minutes.
- If Docker Desktop is installed next to Docker Engine, the script uses the
  `windows-docker` context for Windows containers.
