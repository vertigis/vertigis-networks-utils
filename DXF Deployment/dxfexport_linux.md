# Deploy VertiGIS DXF Export Backend API on Linux

This guide documents how to deploy the **VertiGIS DXF Export Backend API** using Docker containers on an Ubuntu Linux host, using the `dxfexport_linux.sh` deployment script. It reflects a tested end-to-end run (including a local test with a throwaway PostgreSQL container) and the script's actual supported options as of v2.2.

## Prerequisites

| Category         | Tool       | Version     |
| ----------------- | ---------- | ----------- |
| Operating System  | Ubuntu     | 22.04+ LTS  |
| Containerization  | Docker     | 28.0.1+     |
| Database          | PostgreSQL | 17.x        |
| Source Control    | Git        | 2.34.1+     |

- A user account with `sudo` privileges.
- A static IP address on the server (ideally bound to its MAC address via DHCP reservation).
- Firewall (server and network) rules allowing inbound/outbound traffic on ports `5000` and `5001` (the DXF Export API endpoints).
- Database host, port, user, password, and database name.
- Azure Container Registry (ACR) username and password, unless deploying from Docker Hub with `--dockerhub`.

> Docker doesn't need to be installed beforehand. `dxfexport_linux.sh` detects a missing installation and installs it automatically via Docker's official Ubuntu repository. If you'd rather install it yourself first, follow the [official Docker Engine installation guide](https://docs.docker.com/engine/install/). PostgreSQL is handled the same way: the script can use an existing instance, offer to install PostgreSQL on the host, or deploy PostgreSQL as its own container.

---

## Deployment Steps

### 1. Download the Script and Grant Execute Permissions

```bash
curl -LO https://raw.githubusercontent.com/vertigis/vertigis-networks-utils/refs/heads/main/DXF%20Deployment/dxfexport_linux.sh
chmod +x dxfexport_linux.sh
```

### 2. Create a Configuration File (recommended)

Instead of answering the script's interactive prompts every time, create a `dxf-deployment.conf` file in the same directory. This lets the script run non-interactively and makes the deployment repeatable/auditable.

Generate a template, then edit it with your values:

```bash
./dxfexport_linux.sh --create-config
```

Alternatively, write the file directly:

```bash
cat << EOF > dxf-deployment.conf
DB_HOST="localhost"
DB_PORT="5432"
DB_USER="postgres"
DB_PASS="postgres"
DB_NAME="testdb"
IMAGE_NAME="networks/dxf-export:1.5.0"
PORT1="5000"
PORT2="5001"
ACR_USER="<your-acr-username>"
ACR_PASS="<your-acr-password>"
USE_EXISTING_POSTGRES=true
DEPLOY_FROM_DOCKERHUB=false
EOF
```

Any value left blank will be prompted for interactively when the script runs (unless `FORCE=yes` is set, see the options table below).

> dxf-deployment.conf` contains plaintext database and registry credentials. Restrict its permissions (`chmod 600 dxf-deployment.conf`) and avoid committing it to source control.

### 3. Optional - Stand Up a Local/Test PostgreSQL Instance

For local testing or evaluation (for example, on a [Multipass](https://multipass.run/) VM), you can quickly spin up a disposable PostgreSQL container with Docker Compose instead of pointing at a production database:

```bash
cat << EOF > compose.yaml
services:
  postgres:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: testdb
    ports:
      - "5432:5432"
EOF

docker compose up -d
```

This matches the `DB_HOST=localhost` / `DB_USER=postgres` / `DB_PASS=postgres` / `DB_NAME=testdb` values used in the sample config above. In production, point the `DB_*` values at your real PostgreSQL instance instead, and skip this step.

### 4. Run the Deployment Script

```bash
./dxfexport_linux.sh
```

The script will: 
1. load `dxf-deployment.conf` and prompt for any missing values
2. validate parameters and check that ports `5000`/`5001` are free
3. install/verify Docker
4. check PostgreSQL connectivity (using the existing instance, offering to install PostgreSQL on the host, or deploying a PostgreSQL container)
5. log in to the container registry and pull the image
6. write a `.env` file with the runtime configuration 
7. and start the `dxf-export-service` container, waiting for its health check to pass

A full log of the run is written to `/tmp/dxf-deployment-<timestamp>.log`.

---

## Useful Script Options

| Flag / Env Var          | Purpose                                                              |
| ------------------------ | --------------------------------------------------------------------- |
| `-d`, `--dry-run`        | Show what the script would do without making changes                |
| `-c`, `--config FILE`    | Use a specific config file (default: `dxf-deployment.conf`)          |
| `-u`, `--update`         | Update an existing deployment (removes and recreates the containers) |
| `--existing-postgres` / `--new-postgres` | Use an existing PostgreSQL instance (default) or deploy one as a container |
| `--dockerhub`            | Pull the image from Docker Hub instead of Azure Container Registry    |
| `--db-host / --db-port / --db-user / --db-pass / --db-name` | Database connection parameters                   |
| `--image`                | Container image name (registry-qualified or not)                     |
| `--port1 / --port2`      | Host ports for the two application endpoints (defaults: 5000/5001)    |
| `--acr-user / --acr-pass`| Azure Container Registry credentials                                  |
| `--create-config`        | Generate a sample `dxf-deployment.conf` and exit                      |
| `FORCE=yes`               | Env var that skips all interactive prompts, for CI/automated use, e.g. `FORCE=yes ./dxfexport_linux.sh -c dxf-deployment.conf` |

Run `./dxfexport_linux.sh --help` at any time for the full list.

## Configuration & Maintenance

Every deployment or `--update` run does a `docker rm` followed by `docker run`, which discards the container's writable layer. Any change made *inside* a running container (editing `supervisord.conf` by hand, copying in a certificate with `docker cp`, patching a connection string with a shell) is lost the next time the script runs. For a fix to survive updates, it needs to be part of the container's definition: an environment variable, a mounted file, or an image change.

### Database Connection String

Don't edit the connection string inside the container. The script already handles this correctly: it writes `DBConnection` into `.env` and starts the container with `--env-file .env`. A corrected value just needs to go into `dxf-deployment.conf` (or be passed via `--db-host`/`--db-user`/etc.) before the next deploy or update.

### CA Certificate Bundle

If the container needs to trust a custom or internal CA (for example, to reach an internal PostgreSQL or ACR endpoint over TLS), mount the combined CA bundle read-only instead of copying it into the container:

```bash
docker run -d \
  --name dxf-export-service \
  --env-file .env \
  -v /path/on/host/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro \
  -p 5000:5000 -p 5001:5001 \
  vertigisapps.azurecr.io/networks/dxf-export:1.5.0
```

`dxfexport_linux.sh` doesn't yet have a built-in flag for this mount, so add the `-v` line above by hand each time you run or update the container. The mounted file must be the **combined** bundle (system CAs plus your custom CA) described below. Mounting only the custom CA will cause the container to stop trusting the public CAs it needs for ACR pulls and other outbound TLS.

> **Known issue:** the current health check (`curl -f http://localhost:5000`) is an HTTP probe. A TCP-based probe is planned as a separate fix and isn't covered here.

### Updating an Existing Deployment

Update `dxf-deployment.conf` (or your flags) with the new image, corrected `DBConnection`, or other config change, then re-run with `--update`:

```bash
./dxfexport_linux.sh --update -c dxf-deployment.conf
```

This removes and recreates the `dxf-export-service` (and, if applicable, `dxf-postgres`) container. If you're mounting a CA bundle manually, re-add the `-v` mount each time, or wrap `dxfexport_linux.sh` in your own script so it isn't forgotten.

### Certificate Renewal

**Proxy TLS certificate** (if a reverse proxy such as `dxf-proxy` terminates TLS in front of the service): replace the PFX with the newly issued one, export it to `fullchain.pem` / `privkey.pem`, then restart the proxy container so it picks up the new files:

```bash
docker restart dxf-proxy
```

Track the certificate's `notAfter` date and renew before it lapses.

**CA bundle, after a base image update:** a new base image ships its own updated public CAs. Rebuild the combined bundle from the *current* base image's system CA store, not an old snapshot, so you don't override new public CAs with stale ones:

```bash
# Extract the current system CA bundle from the (updated) base image
docker run --rm vertigisapps.azurecr.io/networks/dxf-export:1.5.0 \
  cat /etc/ssl/certs/ca-certificates.crt > system-ca-bundle.crt

# Append your custom/internal CA and use the result as the mounted bundle
cat system-ca-bundle.crt your-custom-ca.pem > ca-certificates.crt
```

Use the resulting `ca-certificates.crt` as the file mounted in the `docker run`/`--update` step above.

---

## Verifying the Deployment

The deployment is successful when the application container shows status **Up** and **(healthy)**, its health checks pass, its endpoints are reachable on `5000`/`5001`, and no errors appear in its logs.

```bash
docker ps
```

Expected output includes a line similar to:

```text
CONTAINER ID   IMAGE                                        STATUS                    PORTS                                             NAMES
6fa333220fb0   vertigisapps.azurecr.io/networks/dxf-export   Up 2 minutes (healthy)    0.0.0.0:5000->5000/tcp, 0.0.0.0:5001->5001/tcp   dxf-export-service
```

Check the logs for startup errors, database connection failures, or unhandled exceptions:

```bash
docker logs dxf-export-service
```

**If something looks wrong:**

| Symptom                                          | Likely Cause / Fix                                                                                   |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| "Missing required parameters"                     | Required config values are blank while `FORCE=yes` is set. Populate them in the config file or as flags. |
| "Port X is already in use"                         | Another process (or a previous deployment) is bound to `5000`/`5001`/`5432`. Stop it or choose different ports. |
| Database connection test fails                     | Verify `DB_HOST`/`DB_PORT`/`DB_USER`/`DB_PASS`/`DB_NAME` and that the database is reachable (firewall, `pg_hba.conf`, security groups). |
| ACR login fails                                    | Confirm ACR credentials, or pass `--dockerhub` if the image is published publicly.                     |
| Container is "unhealthy"                           | Check `docker logs dxf-export-service`. The health check calls `http://localhost:5000` inside the container; a non-2xx response or startup crash will fail it. |

---

## Cleaning Up (Test/Evaluation Environments)

If you used the optional Docker Compose PostgreSQL instance from Step 3 for local testing, tear it down when finished:

```bash
docker compose down -v
```

To remove the deployed container entirely:

```bash
docker rm -f dxf-export-service
```
