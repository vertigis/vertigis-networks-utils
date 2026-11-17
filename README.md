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


### Sewer Backend (`Sewer/`)

Contains deployment scripts and documentation for the consolidated VertiGIS
Networks Sewer backend. Sewer Management, Condition Classification and its
worker, and SewerJS run in one container behind an nginx gateway on port 8080.

| Script | Platform | Description |
|--------|----------|-------------|
| `sewer_linux.sh` | Linux | Bash deployment script for Docker/Podman |
| `sewer_windows.ps1` | Windows | PowerShell deployment script for Docker/Podman and Linux/Windows containers |

The consolidated `networks/sewer` image includes:

- **Sewer Management API** — import/export logging and token validation
- **Condition Classification API and worker** — classification jobs and status
- **SewerJS** — ISYBAU XML validation, plausibility checks, and media processing

Both scripts support new deployments, updates, configuration files, registry
authentication, readiness checks, and dry-run mode. The Linux installer also
supports using a locally loaded image with `--no-pull`.

Linux usage:

```bash
./Sewer/sewer_linux.sh --version <VERSION>
./Sewer/sewer_linux.sh --version <VERSION> --update
```

Windows usage:

```powershell
.\Sewer\sewer_windows.ps1 -Version <VERSION>
.\Sewer\sewer_windows.ps1 -Version <VERSION> -Update
```

See the [consolidated Sewer README](Sewer/README.md), [Linux deployment
guide](Sewer/Deployment-Linux.md), and [Windows deployment
guide](Sewer/Deployment-Windows.md) for configuration, API, and platform
details. The shared configuration template is
[`sewer-consolidated-deployment.conf`](Sewer/sewer-consolidated-deployment.conf).
