# Sewer Services Deployment (Linux)

## Overview

This document describes deployment of the Sewer services as Docker/Podman containers on Linux.

| Service | Container Name | Image | Port | Description |
|---------|---------------|-------|------|-------------|
| SewerManagement | `sewer-service` | `networks/sewer` | 5050 | Import/Export API |
| Condition Classification | `sewercc-service` | `networks/sewercc` | 8080 | Condition rating API |

## Prerequisites

- Docker or Podman installed
- Access to `vertigisnetworks.azurecr.io` container registry
- Network access to target port (5050 or 8080)

## Quick Start

```bash
# Deploy SewerManagement
./sewer_linux.sh --service sewer --acr-user <USER> --acr-pass <PASS>

# Deploy Condition Classification
./sewer_linux.sh --service sewercc --acr-user <USER> --acr-pass <PASS>
```

## Configuration File

Create a config file to avoid passing credentials on each deploy:

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

**sewercc-deployment.conf:**
```ini
IMAGE_NAME=networks/sewercc:latest
PORT=8080
ACR_USER=your_username
ACR_PASS=your_password
CORS_ORIGIN=
REGISTRY=vertigisnetworks.azurecr.io
RUNTIME=docker
CONTAINER_TYPE=linux
```

## Deployment Modes

### New Deployment
```bash
./sewer_linux.sh --service sewer
```

### Update Existing
```bash
./sewer_linux.sh --service sewer --update
```

### Dry Run
```bash
./sewer_linux.sh --service sewercc --dry-run
```

### Specific Image Version
```bash
./sewer_linux.sh --service sewer --image networks/sewer:1.0.1-12345
```

## Environment Variables

Both services support configuration via environment variables passed at container runtime:

| Variable | Description | Example |
|----------|-------------|---------|
| `CORS_ORIGIN` | Allowed CORS origins | `http://localhost:3001` |
| `ASPNETCORE_ENVIRONMENT` | ASP.NET environment | `Production` |
| `ConnectionStrings__JobService` | SQLite DB path (CC only) | `Data Source=/data/job.db` |
| `FeatureServer__URL` | Feature service URL (CC only) | `https://...` |
| `FeatureServer__Token` | Feature service token (CC only) | `<token>` |

## Health Checks

Both containers include built-in health checks:
- **Interval:** 30s
- **Timeout:** 10s
- **Retries:** 3
- **Start period:** 15s

The deployment script additionally performs TCP port probing as a fallback.

## Volumes (Condition Classification)

The CC service uses SQLite for job tracking. Mount a volume for persistence:

```bash
docker run -d --name sewercc-service \
  -p 8080:8080 \
  -v /opt/sewercc/data:/data \
  vertigisnetworks.azurecr.io/networks/sewercc:latest
```

## Troubleshooting

### View Logs
```bash
docker logs -f sewer-service
docker logs -f sewercc-service
```

### Check Health
```bash
docker inspect --format '{{.State.Health.Status}}' sewer-service
```

### Manual Health Probe
```bash
curl -f http://localhost:5050/swagger/index.html
curl -f http://localhost:8080/swagger/index.html
```

## CI/CD Non-Interactive Mode
```bash
FORCE=yes ./sewer_linux.sh --service sewer --config /etc/sewer/sewer-deployment.conf
```
