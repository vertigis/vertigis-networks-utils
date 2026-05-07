# SewerJS Service Deployment (Windows)

## System Requirements

- min. **Windows Server 2022** (or Windows 10/11 with Hyper-V enabled)
- **Docker Engine** (Windows containers)

## Prerequisites

> You will need your **ACR Username** and **ACR Password** → ask Petr Diviš.

---

## Install Docker Engine

> ⚠️ **The server will restart automatically after installation!**

Open **PowerShell as Administrator** and run:

```powershell
cd C:\app\sewerjs

Invoke-WebRequest -UseBasicParsing `
  "https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1" `
  -OutFile install-docker-ce.ps1

.\install-docker-ce.ps1
```

The installation will complete automatically after restarting (a PowerShell window will appear).

Open **PowerShell as Administrator** again and test installation:

```powershell
cd C:\app\sewerjs
docker version
```

Result (example):

```
Client:
 Version:           29.3.0
 API version:       1.54
 Go version:        go1.25.7
 Git commit:        5927d80
 Built:             Thu Mar  5 14:28:30 2026
 OS/Arch:           windows/amd64
 Context:           default

Server: Docker Engine - Community
 Engine:
  Version:          29.3.0
  API version:      1.47 (minimum version 1.24)
  Go version:       go1.25.7
  Git commit:       9a15c61
  Built:            Thu Mar  5 14:28:38 2026
  OS/Arch:          windows/amd64
  Experimental:     false
```

---

## 1. Create deployment script

Create a file:

```
C:\app\sewerjs\sewerjs_windows.ps1
```

Paste the **entire PowerShell script content** from the repository file `scripts/sewerjs_windows.ps1`.

---

## 2. Run deployment script

Execute:

```powershell
.\sewerjs_windows.ps1 -Runtime docker -ContainerType windows
```

The script will ask for the deployment parameters.

### Recommended values

When prompted:

| Question        | Recommended input                              |
| --------------- | ---------------------------------------------- |
| Image name      | press Enter (default: `networks/sewerjs-windows:latest`) |
| Host port       | press Enter (default: `3000`)                  |
| ACR Username    | Enter your username                            |
| ACR Password    | Enter your password                            |

### Example output

```
PS C:\app\sewerjs> .\sewerjs_windows.ps1 -Runtime docker -ContainerType windows
2026-04-29 10:00:00
=== SewerJS Deployment v1.0 ===
2026-04-29 10:00:00 [WARN] Config file not found: sewerjs-deployment.conf
2026-04-29 10:00:00 [i]    Windows containers: using Docker context 'windows-docker'
2026-04-29 10:00:00 [OK]   Runtime: docker | Container OS: windows
Enter Image name (default: networks/sewerjs-windows:latest):
Enter Host port (default: 3000):
Enter ACR Username (default: ):  petrdivis
Enter ACR Password: ********
2026-04-29 10:00:05 [i]    Configuration Summary:
2026-04-29 10:00:05 [i]      Mode:     new
2026-04-29 10:00:05 [i]      Runtime:  docker
2026-04-29 10:00:05 [i]      OS:       windows
2026-04-29 10:00:05 [i]      Image:    networks/sewerjs-windows:latest
2026-04-29 10:00:05 [i]      Port:     3000
2026-04-29 10:00:05 [i]      CORS:
Continue with deployment? (y/N): y
```

Finally confirm and wait for the deployment to complete.

Done — the SewerJS Service is now running.

Test in browser on the server: **http://localhost:3000/api-docs**

---

## Change deployment

If you want to change parameters such as port, image, etc., use the following command:

```powershell
.\sewerjs_windows.ps1 -Update -Runtime docker -ContainerType windows
```

---

## Semi-Manual Procedure (if the script cannot download the image)

### 1. Export the image (on a machine with registry access)

Run the deployment script with `-ExportImage` on a machine that can reach the registry
(e.g. your development machine or an existing deployment server):

```powershell
cd C:\app\sewerjs
.\sewerjs_windows.ps1 -ExportImage -Runtime docker -ContainerType windows
```

The script will ask for ACR credentials, pull the image and save it as a `.tar` file
(e.g. `sewerjs-windows_ltsc2022.tar`) in the current directory.

Alternatively, you can export manually:

```powershell
cd C:\app\sewerjs
docker save -o sewerjs-windows_ltsc2022.tar vertigisnetworks.azurecr.io/networks/sewerjs-windows:ltsc2022
```

### 2. Copy the tar file to the target machine

Copy the `.tar` file to the same directory on the target server, e.g. `C:\app\sewerjs`.

### 3. Copy the deployment script to the target machine

Make sure `sewerjs_windows.ps1` is also present at `C:\app\sewerjs` on the target machine
(see [1. Create deployment script](#1-create-deployment-script) above).

### 4. Load the image and deploy

On the target machine, run:

```powershell
cd C:\app\sewerjs
.\sewerjs_windows.ps1 -Runtime docker -ContainerType windows -LoadFromFile .\sewerjs-windows_ltsc2022.tar
```

The script loads the image from the tar file (no registry access needed) and deploys
the container exactly like the standard procedure.

**Recommended values when prompted:**

| Question    | Recommended input                              |
| ----------- | ---------------------------------------------- |
| Image name  | press Enter (default)                          |
| Host port   | press Enter (default: `3000`)                  |

---

## Configure a Reverse Proxy and URL Rewrite in IIS

The SewerJS API runs on port 3000 and has no built-in URL prefix — all routes are at root level:

| Route | Description |
| ----- | ----------- |
| `GET /` | Health check |
| `POST /api/validate` | XML validation |
| `GET /api/plausibilityRuleCheck` | Plausibility rule check |
| `GET /api/nodeCheckPlausibilityRule` | Node plausibility check |
| `GET /api-docs` | Swagger UI |

Because there is no path prefix in the app itself, a **path-based reverse proxy rule** is needed to isolate SewerJS traffic from other applications running on the same IIS site.
The recommended approach is to expose the service under a sub-path (e.g. `/sewer/`), which IIS strips before forwarding to port 3000.

```
https://<server>/sewer/api/plausibilityRuleCheck?...
        ↓  IIS strips /sewer/
http://localhost:3000/api/plausibilityRuleCheck?...
```

### Prerequisites

- [Application Request Routing](https://www.iis.net/downloads/microsoft/application-request-routing)
- [URL Rewrite](https://www.iis.net/downloads/microsoft/url-rewrite)

### Configuration

1. Open **IIS Manager**
2. At the **server** level, open **Application Request Routing** → **Server Proxy Settings** → enable **Enable proxy** → Apply
3. Select the relevant **site**
4. Open **URL Rewrite**
5. **Add Rule → Reverse Proxy**

| Field | Value |
| ----- | ----- |
| Inbound rule — Pattern | `^sewer/(.*)` |
| Inbound rule — Rewrite URL | `http://localhost:3000/{R:1}` |

> **Note:** The captured group `{R:1}` contains everything **after** `/sewer/`, so the prefix is stripped before the request reaches the Node app. Leave **Stop processing of subsequent rules** checked.

This routes all traffic:

| Browser URL | Forwarded to |
| ----------- | ------------ |
| `https://<server>/sewer/` | `http://localhost:3000/` |
| `https://<server>/sewer/api/validate` | `http://localhost:3000/api/validate` |
| `https://<server>/sewer/api/plausibilityRuleCheck` | `http://localhost:3000/api/plausibilityRuleCheck` |
| `https://<server>/sewer/api-docs` | `http://localhost:3000/api-docs` |

Test in browser: **https://\<server\>/sewer/api-docs**

---

## Troubleshooting

Check browser developer tools (F12 → Network tab).

### Service live logs

```powershell
docker logs -f sewerjs-service
```

### Container status

```powershell
docker ps -a --filter "name=sewerjs-service"
```

### Restart service

```powershell
docker restart sewerjs-service
```

### Full redeploy

```powershell
docker rm -f sewerjs-service
.\sewerjs_windows.ps1 -Runtime docker -ContainerType windows
```
