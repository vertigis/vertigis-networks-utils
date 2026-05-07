# networks-utils
This repo contains code for scripts, workflows, etc. that can be used with VertiGIS Networks. These might be installation scripts for additional functionality or docker images, or ...

## Contents

### DXF Export Service (`DXF Deployment/`)

Contains the deployment script for setting up the VertiGIS Networks DXF Export service on a Linux host.

**`dxfexport_linux.sh`** — Bash deployment script (v2.2) that handles:

- **Multiple deployment modes**: new installation, update, and dry-run
- **Docker setup**: installs Docker from the Ubuntu official repository if not already present
- **PostgreSQL setup**: installs and configures PostgreSQL (via pgdg) or connects to an existing instance
- **Container deployment**: pulls the `dxf-export` image from the VertiGIS Azure Container Registry (`vertigisapps.azurecr.io`) and starts the service containers
- **Configuration file support**: reads settings from `dxf-deployment.conf`
- **Parameter validation, logging, cleanup, and rollback**

Usage:

```bash
./dxfexport_linux.sh [--mode new|update|dry-run] [--config <file>] [OPTIONS]
```

---

### Job Management Feature Services (`JobManagement/`)

Contains the Python utility for provisioning and maintaining the Job Management hosted feature services in an ArcGIS Enterprise/Portal environment.

**`job_service_creator.py`** — Python script that:

- Creates the Job Management hosted feature service and all required portal items (role, group, folder)
- Detects and handles existing services — including schema updates and replacement of non-hosted services with hosted equivalents
- Optionally sets up job history tracking layers
- Prompts interactively for any missing connection parameters (portal URL, username, password)
- Supports non-interactive use by passing all arguments via the command line

Usage:

```bash
python3 job_service_creator.py --help
python3 job_service_creator.py --host <portal-url> --username <user> --password <pass>
```

Older script versions are archived under `JobManagement/OlderVersions/`.


---


### Sewer Services (`Sewer/`)

Contains deployment scripts and documentation for the VertiGIS Networks Sewer services (`sewer` and `sewercc` containers).

| Script | Platform | Description |
|--------|----------|-------------|
| `sewer_linux.sh` | Linux | Bash deployment script for Docker/Podman |
| `sewer_windows.ps1` | Windows | PowerShell deployment script for Docker/Podman |

Two services are covered:

- **SewerManagement** (`networks/sewer`, port 5050) — Import/Export API
- **Condition Classification** (`networks/sewercc`, port 8080) — Condition rating API

Both scripts handle:

- Auto-detection of Docker or Podman runtime
- New installation and update modes (`--update` / `-Update`)
- Configuration file support (`sewer-deployment.conf`, `sewercc-deployment.conf`)
- Registry login, image pull, container start, and health check with TCP fallback
- Dry-run mode for previewing actions without making changes

Usage:

```bash

# Linux
./sewer_linux.sh --service sewer --acr-user <USER> --acr-pass <PASS>
./sewer_linux.sh --service sewercc --update

# Windows
.\sewer_windows.ps1 -Service sewer -AcrUser <USER> -AcrPass <PASS>
.\sewer_windows.ps1 -Service sewercc -Update
```

See [`Sewer/Deployment-Linux.md`](Sewer/Sewer/Deployment-Linux.md) and [`Sewer/Deployment-Windows.md`](Sewer/Sewer/Deployment-Windows.md) for full configuration reference.

---

### SewerJS (`Sewer/SewerJS/`)

Contains deployment scripts and documentation for the SewerJS service — a Node.js API for ISYBAU XML validation and plausibility checks (`sewerjs` container).

| Script | Platform | Description |
|--------|----------|----|
| `sewerjs_linux.sh` | Linux | Bash deployment script (v1.1) for Docker/Podman |
| `sewerjs_windows.ps1` | Windows | PowerShell deployment script (v1.0) for Docker/Podman |

One service is covered:

- **SewerJS** (`networks/sewerjs`, port 3000) — ISYBAU XML validation and plausibility rule check API

Both scripts handle:

- Auto-detection of Docker or Podman runtime
- New installation and update modes (`--update` / `-Update`)
- Configuration file support (`sewerjs-deployment.conf`)
- Registry login, image pull, container start, and health check with TCP fallback
- Dry-run mode for previewing actions without making changes
- Docker Engine auto-installation on Ubuntu (Linux script)

Additional Windows-only features:

- `-ExportImage` — pull and save the image to a `.tar` file for offline transfer
- `-LoadFromFile` — deploy from a local `.tar` file without registry access
- `-BuildTag` — select a specific build; LTSC tag is resolved automatically from the host OS

Usage:

```bash
# Linux
./sewerjs_linux.sh --acr-user <USER> --acr-pass <PASS>
./sewerjs_linux.sh --update
```

```powershell
# Windows (Linux container via Podman)
.\sewerjs_windows.ps1 -AcrUser <USER> -AcrPass <PASS>

# Windows (Windows container via Docker Engine)
.\sewerjs_windows.ps1 -Runtime docker -ContainerType windows

# Offline deployment from tar
.\sewerjs_windows.ps1 -Runtime docker -ContainerType windows -LoadFromFile .\sewerjs-windows_ltsc2022.tar
```

See [`SewerJS/SewerJS Deployment (Linux).md`](Sewer/SewerJS/SewerJS%20Deployment%20(Linux).md) and [`SewerJS/SewerJS Deployment (Windows).md`](Sewer/SewerJS/SewerJS%20Deployment%20(Windows).md) for full configuration reference including nginx / IIS reverse proxy setup.
