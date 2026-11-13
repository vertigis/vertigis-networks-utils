# Consolidated Sewer Backend

The consolidated Sewer backend runs Sewer Management, Condition
Classification, its worker, and SewerJS in one container behind an nginx
gateway. The gateway listens on port `8080`; the internal service ports are
not exposed.

| Backend | Public routes | Purpose |
| --- | --- | --- |
| Sewer Management API | `/api/Sewer`, `/api/Token`, `/swagger` | Import/export logging and token validation |
| Condition Classification | `/ConditionClassification` | Classification jobs and status |
| SewerJS | `/api`, `/api-docs`, `/videos`, `/thumbnails` | XML validation, plausibility checks, video and thumbnail processing |

Use the [Linux deployment guide](./Deployment-Linux.md) or
[Windows deployment guide](./Deployment-Windows.md) for the installer scripts,
configuration options, and platform-specific requirements.

## Run with Docker

Create an `.env` file beside the command you run. Set `CORS_ORIGIN` to the
origin of your Networks web application; add Azure Storage settings only if
media conversion and thumbnails need blob storage.

```dotenv
ASPNETCORE_ENVIRONMENT=Production
NODE_ENV=production
CORS_ORIGIN=https://networks.example.com
MEDIA_ROOT=/app/media
XSD_PATH=/app/sewerjs/schemas/schema.xsd
```

Pull a released image and run it with persistent volumes for media and
management import logs:

```bash
docker login vertigisapps.azurecr.io
docker pull vertigisapps.azurecr.io/networks/sewer:<version>

docker volume create sewer-media
docker volume create sewer-import-logs

docker run --detach \
  --name sewer \
  --restart unless-stopped \
  --publish 8080:8080 \
  --env-file .env \
  --mount type=volume,source=sewer-media,target=/app/media \
  --mount type=volume,source=sewer-import-logs,target=/app/sewer-management/ImportLogs \
  vertigisapps.azurecr.io/networks/sewer:<version>
```

The image runs as a non-root user. Named volumes avoid host-directory
permission differences and preserve generated media and import logs when the
container is replaced.

## Windows Image

Windows Server 2022 hosts can use the Windows container image:

```powershell
docker login vertigisapps.azurecr.io
docker pull vertigisapps.azurecr.io/networks/sewer-windows:<version>-ltsc2022

docker volume create sewer-media
docker volume create sewer-import-logs

docker run --detach `
  --name sewer `
  --restart unless-stopped `
  --publish 8080:8080 `
  --env-file .env `
  --mount type=volume,source=sewer-media,target=C:\app\media `
  --mount type=volume,source=sewer-import-logs,target=C:\app\sewer-management\ImportLogs `
  vertigisapps.azurecr.io/networks/sewer-windows:<version>-ltsc2022
```

The Windows host and image must use matching Windows Server versions. For
installation details, see the [Windows deployment guide](./Deployment-Windows.md).

## Health and Logs

The gateway health endpoint checks nginx and ingress:

```bash
curl --fail http://127.0.0.1:8080/health
docker exec sewer supervisorctl -c /etc/supervisor/conf.d/sewer.conf status
docker logs --follow sewer
```

## Media Storage

Media storage is configured at runtime; do not put storage credentials or SAS
URLs in frontend configuration. The backend supports these authentication
options:

| Authentication | Environment variables |
| --- | --- |
| Managed identity | `AZURE_STORAGE_ACCOUNT`, `AZURE_CLIENT_ID` |
| Service principal | `AZURE_STORAGE_ACCOUNT`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` |
| Storage connection string | `AZURE_STORAGE_CONNECTION_STRING` |
| Container SAS URLs | `AZURE_STORAGE_CONTAINER_SAS_URL`, `AZURE_STORAGE_READ_SAS_URL` |

The identity or service principal requires the Storage Blob Data Contributor
and Storage Blob Delegator roles on the storage account. Optional settings:

| Variable | Purpose |
| --- | --- |
| `AZURE_STORAGE_CONTAINER` | Container for source media |
| `AZURE_STORAGE_OUTPUT_CONTAINER` | Container for converted videos and thumbnails; defaults to the source container |
| `AZURE_BLOB_SAS_TTL_MINUTES` | Lifetime of generated read links; defaults to `60` |

Without storage settings, media conversion and thumbnail endpoints report that
Azure Blob Storage is not configured. HTTPS video streaming routes remain
available for externally hosted videos.

The classification API and worker share a SQLite database inside the
container. Keep it on the container's local filesystem; Azure Files does not
provide the SQLite locking behavior it requires.

## Authentication and API Routes

SewerJS validation and media endpoints accept a bearer token or `x-api-key`.
For example:

```bash
curl --fail \
  -H "Authorization: Bearer $SEWER_TOKEN" \
  "$SEWER_BASE_URL/api/mp4-status?videoUrl=https%3A%2F%2Fexample.test%2Fvideo.mp4"
```

The management API validates `AuthToken` in its request body against the
provided `WebMapUrl`. Main routes include:

```text
POST /api/Token/validatetoken
POST /api/Sewer/logImportData
POST /api/Sewer/logExportData
POST /ConditionClassification/Classify
GET  /ConditionClassification/status/<jobId>
POST /api/validate
POST /api/plausibilityRuleCheck
POST /api/nodeCheckPlausibilityRule
POST /api/mp4
GET  /api/mp4-status
POST /api/thumbnail
GET  /api/media-url?blob=<name>
```

MP4 conversion can return `202` while a job is queued; poll the returned status
URL for completion.
