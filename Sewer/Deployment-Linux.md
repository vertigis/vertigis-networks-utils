# Sewer Backend Deployment (Linux)

## Overview

Since version 2.0 the Sewer backend is one container: the Sewer Management API,
the Condition Classification API and worker, and SewerJS run behind an nginx
gateway on port `8080`. [`sewer_linux.sh`](./sewer_linux.sh)
deploys it with Docker or Podman.

| Container name | Image | Port |
|----------------|-------|------|
| `sewer` | `vertigisapps.azurecr.io/networks/sewer:<version>` | 8080 |

The image itself is described in the [consolidated README](https://dev.azure.com/vertigis/Utilities/_git/Sewer?path=/consolidated/README.md).

## Prerequisites

- Docker or Podman
- Credentials for `vertigisapps.azurecr.io`, or an image loaded with `docker load`
- The origin of the web application for `CORS_ORIGIN`
- A reverse proxy that terminates TLS in front of port 8080

## Quick Start

Create `sewer.env` in the directory you run the script from:

```dotenv
ASPNETCORE_ENVIRONMENT=Production
NODE_ENV=production
CORS_ORIGIN=https://networks.example.com
MEDIA_ROOT=/app/media
XSD_PATH=/app/sewerjs/schemas/schema.xsd
```

Add the media storage settings (`AZURE_STORAGE_*`) if needed; see the Media
Storage section in the [consolidated README](https://dev.azure.com/vertigis/Utilities/_git/Sewer?path=/consolidated/README.md).
Do not set `PORT`.

```bash
# Install version 2.2.0 (asks for the registry credentials)
./sewer_linux.sh --version 2.2.0

# Update to a newer version
./sewer_linux.sh --version 2.2.1 --update

# Without registry access: load the image first
docker load -i sewer-2.2.0.tar
./sewer_linux.sh --version 2.2.0 --no-pull

# Non-interactive
FORCE=yes ./sewer_linux.sh --config /etc/sewer/sewer-consolidated-deployment.conf
```

The script:

1. logs in to the registry (or uses the existing login when no credentials are given),
2. pulls the image (`--no-pull` uses a local image),
3. creates the volumes `sewer-media` (`/app/media`) and `sewer-import-logs`
   (`/app/sewer-management/ImportLogs`) if they do not exist,
4. starts the container with `--restart unless-stopped`, `sewer.env` and the volumes,
5. waits until all five supervised processes are `RUNNING`.

With `--update` the existing container is removed first; the volumes stay.

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-v`, `--version` | Image version (consolidated) | asked |
| `-e`, `--env-file` | Environment file for the container | `sewer.env` if present |
| `--image` | Full image name, overrides `--version` | |
| `--port` | Host port | 8080 |
| `--cors` | CORS origins, overrides `CORS_ORIGIN` of the env file | |
| `--acr-user`, `--acr-pass` | Registry credentials | asked / existing login |
| `-r`, `--runtime` | `docker` or `podman` | auto-detect (Podman first) |
| `-u`, `--update` | Replace an existing container | off |
| `--no-pull` | Use an image already on the host | off |
| `-c`, `--config` | Configuration file | `sewer-consolidated-deployment.conf` |
| `-d`, `--dry-run` | Show the commands only | off |

`FORCE=yes` skips all prompts.

## Configuration File

[`sewer-consolidated-deployment.conf`](./sewer-consolidated-deployment.conf)
is the template. The script looks for it in the current directory and next to
the script. Command line options win over the file.

```ini
VERSION=2.2.0
PORT=8080
REGISTRY=vertigisapps.azurecr.io
ACR_USER=
ACR_PASS=
CORS_ORIGIN=
ENV_FILE=/etc/sewer/sewer.env
RUNTIME=docker
MEDIA_VOLUME=sewer-media
LOGS_VOLUME=sewer-import-logs
```

## Checks

```bash
curl --fail http://127.0.0.1:8080/health
docker exec sewer supervisorctl -c /etc/supervisor/conf.d/sewer.conf status
docker logs --follow sewer
```

With Podman the image health check is only evaluated when systemd timers are
available; the script therefore checks the supervised processes directly.
