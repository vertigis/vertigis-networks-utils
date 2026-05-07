# SewerJS Service Deployment (Linux)

## System Requirements

- **Ubuntu 22.04 LTS** or newer (or any Debian/RHEL-based distro with Docker/Podman)
- **Docker Engine** or **Podman** — installed automatically on Ubuntu if missing

## Prerequisites

> You will need your **ACR Username** and **ACR Password** → ask Petr Diviš.

### Optional prerequisites

- Create the working directory:

  ```bash
  sudo mkdir -p /opt/sewerjs
  sudo chown $USER:$USER /opt/sewerjs
  ```

  > ⚠️ *If you choose a different directory, adjust it in all subsequent commands.*

---

## Install Docker Engine

On **Ubuntu**, the deployment script installs Docker automatically if it is not present.

On other distributions, install Docker or Podman manually before running the script.

To verify Docker is running:

```bash
docker version
```

Result (example):

```
Client: Docker Engine - Community
 Version:           27.3.1
 API version:       1.47
 Go version:        go1.22.7
 OS/Arch:           linux/amd64

Server: Docker Engine - Community
 Engine:
  Version:          27.3.1
  API version:      1.47 (minimum version 1.24)
  OS/Arch:          linux/amd64
```

---

## 1. Create deployment script

Create a file:

```
/opt/sewerjs/sewerjs_linux.sh
```

Paste the **entire shell script content** from the repository file `scripts/sewerjs_linux.sh`.

Make it executable:

```bash
chmod +x /opt/sewerjs/sewerjs_linux.sh
```

---

## 2. Create config file

`/opt/sewerjs/sewerjs-deployment.conf`

With content:

```
# SewerJS Deployment Configuration
# IMAGE_NAME - use sewerjs:latest for Linux
IMAGE_NAME=networks/sewerjs:latest
PORT=3000
ACR_USER=
ACR_PASS=
CORS_ORIGIN=http://localhost:3001,https://dev002-networks.apps.vertigisstudio.com
REGISTRY=vertigisnetworks.azurecr.io
RUNTIME=docker
```

---

## 3. Run deployment script

Execute:

```bash
cd /opt/sewerjs
./sewerjs_linux.sh --config sewerjs-deployment.conf
```

### Recommended values

When prompted:

| Question     | Recommended input                              |
| ------------ | ---------------------------------------------- |
| Image name   | press Enter (default: `networks/sewerjs:latest`) |
| Host port    | press Enter (default: `3000`)                  |
| ACR Username | Enter your username                            |
| ACR Password | Enter your password                            |

### Example output

```
2026-04-29 10:00:00
=== SewerJS Deployment v1.1 ===
2026-04-29 10:00:00 [i] Loading configuration from: sewerjs-deployment.conf
2026-04-29 10:00:00 [OK] Configuration loaded successfully
2026-04-29 10:00:00 [i] Configuration Summary:
2026-04-29 10:00:00 [i]   Runtime: docker
2026-04-29 10:00:00 [i]   Mode: new
2026-04-29 10:00:00 [i]   Image: networks/sewerjs:latest
2026-04-29 10:00:00 [i]   Port: 3000
2026-04-29 10:00:00 [i]   CORS Origins: http://localhost:3001,...
2026-04-29 10:00:00 [i]   Deploy from Docker Hub: false
Continue with deployment? (y/N): y
2026-04-29 10:00:00 [OK] Using container runtime: docker
...
=== Deployment Completed Successfully ===
2026-04-29 10:00:30 [OK] SewerJS is now running (via docker)
2026-04-29 10:00:30 [i] API endpoint: http://localhost:3000
```

Finally confirm and wait for the deployment to complete.

Done — the SewerJS Service is now running.

Test in browser on the server: **http://localhost:3000/api-docs**

---

## Change deployment

If you want to change parameters such as port, image, etc., use the following command:

```bash
./sewerjs_linux.sh --update --config sewerjs-deployment.conf
```

---

## Semi-Manual Procedure (if the script cannot download the image)

### 1. Export the image (on a machine with registry access)

Log in to ACR and pull + save the image:

```bash
echo "$ACR_PASS" | docker login vertigisnetworks.azurecr.io -u "$ACR_USER" --password-stdin
docker pull vertigisnetworks.azurecr.io/networks/sewerjs:latest
docker save -o sewerjs_linux.tar vertigisnetworks.azurecr.io/networks/sewerjs:latest
```

### 2. Copy the tar file to the target machine

Copy `sewerjs_linux.tar` to `/opt/sewerjs/` on the target server (e.g. via `scp` or USB).

### 3. Load the image and deploy on the target machine

```bash
cd /opt/sewerjs
docker load -i sewerjs_linux.tar
./sewerjs_linux.sh --config sewerjs-deployment.conf
```

When prompted for ACR credentials, press Enter — the image is already loaded locally and no registry access is needed.

---

## Configure a Reverse Proxy in nginx

The SewerJS API runs on port 3000 with no built-in URL prefix. All routes are at root level:

| Route | Description |
| ----- | ----------- |
| `GET /` | Health check |
| `POST /api/validate` | XML validation |
| `GET /api/plausibilityRuleCheck` | Plausibility rule check |
| `GET /api/nodeCheckPlausibilityRule` | Node plausibility check |
| `GET /api-docs` | Swagger UI |

Because there is no path prefix in the app itself, a **path-based reverse proxy rule** is needed.
The recommended approach is to expose the service under `/sewer/`, which nginx strips before forwarding to port 3000:

```
https://<server>/sewer/api/plausibilityRuleCheck?...
        ↓  nginx strips /sewer/
http://localhost:3000/api/plausibilityRuleCheck?...
```

### Prerequisites

- nginx installed (`sudo apt-get install -y nginx`)

### Configuration

Add the following `location` block to your nginx site configuration
(e.g. `/etc/nginx/sites-available/default` or a dedicated site file):

```nginx
location /sewer/ {
    proxy_pass         http://localhost:3000/;
    proxy_http_version 1.1;
    proxy_set_header   Host              $host;
    proxy_set_header   X-Real-IP         $remote_addr;
    proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto $scheme;
}
```

> **Note:** The trailing slash on `proxy_pass http://localhost:3000/` is what causes nginx to strip the `/sewer/` prefix before forwarding the request to the Node app.

Reload nginx:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

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

```bash
docker logs -f sewerjs-service
```

### Container status

```bash
docker ps -a --filter "name=sewerjs-service"
```

### Restart service

```bash
docker restart sewerjs-service
```

### Full redeploy

```bash
docker rm -f sewerjs-service
./sewerjs_linux.sh --config sewerjs-deployment.conf
```
