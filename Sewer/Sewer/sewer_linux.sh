#!/usr/bin/env bash

# ============================================================
# Sewer Services - Deployment Script (Linux)
# ============================================================
#   Deploys SewerManagement or ConditionClassification containers.
#   - Auto-detects Docker or Podman
#   - Configuration file support
#   - Health check with TCP fallback
#   - Supports update/new modes
# Version: 1.0
# ============================================================

set -euo pipefail
IFS=$'\n\t'

TEMP_FILES=()
CREATED_CONTAINERS=()

SCRIPT_NAME="Sewer Deployment"
VERSION="1.0"
LOG_FILE="/tmp/sewer-deployment-$(date +%Y%m%d-%H%M%S).log"

# Defaults
REGISTRY_NAME="vertigisnetworks.azurecr.io"
DEFAULT_PORT=""
CONTAINER_NAME=""
DEFAULT_IMAGE=""
CONFIG_FILE=""

# State
MODE="new"
DRY_RUN=false
RUNTIME=""
IMAGE_NAME=""
PORT=""
ACR_USER=""
ACR_PASS=""
CORS_ORIGIN=""
SERVICE=""
FORCE=${FORCE:-no}

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log_and_print() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
print_section()  { log_and_print "\n${BLUE}=== $1 ===${NC}"; }
print_success()  { log_and_print "${GREEN}[OK] $1${NC}"; }
print_info()     { log_and_print "${YELLOW}[i] $1${NC}"; }
print_error()    { log_and_print "${RED}[ERR] $1${NC}"; }
print_warning()  { log_and_print "${YELLOW}[WARN] $1${NC}"; }

cleanup_and_exit() {
    local exit_code=${1:-1}
    print_error "Deployment failed. Check log: $LOG_FILE"
    for c in "${CREATED_CONTAINERS[@]}"; do
        $RUNTIME rm -f "$c" >/dev/null 2>&1 || true
    done
    exit $exit_code
}
trap 'cleanup_and_exit $?' ERR
trap 'cleanup_and_exit 130' INT

# ============================================================
show_help() {
    cat << EOF
$SCRIPT_NAME v$VERSION

USAGE:
    $0 --service <sewer|sewercc> [OPTIONS]

SERVICES:
    sewer       SewerManagement API (port 5050)
    sewercc     Condition Classification API (port 8080)

OPTIONS:
    -s, --service NAME      Service to deploy (required)
    -h, --help              Show help
    -d, --dry-run           Show what would be done
    -c, --config FILE       Configuration file
    -u, --update            Update existing deployment
    -r, --runtime RT        docker|podman (default: auto-detect)
    --image IMAGE           Container image
    --port PORT             Host port
    --cors ORIGINS          CORS origins
    --acr-user USER         ACR username
    --acr-pass PASS         ACR password

EXAMPLES:
    $0 --service sewer
    $0 --service sewercc --update
    $0 --service sewer --runtime podman --port 5050
    FORCE=yes $0 --service sewercc --image networks/sewercc:1.0.0-123
EOF
}

# ============================================================
resolve_service() {
    case "$SERVICE" in
        sewer|sewermanagement)
            CONTAINER_NAME="sewer-service"
            DEFAULT_IMAGE="networks/sewer:latest"
            DEFAULT_PORT=5050
            CONFIG_FILE="${CONFIG_FILE:-sewer-deployment.conf}"
            ;;
        sewercc|conditionclassification|cc)
            CONTAINER_NAME="sewercc-service"
            DEFAULT_IMAGE="networks/sewercc:latest"
            DEFAULT_PORT=8080
            CONFIG_FILE="${CONFIG_FILE:-sewercc-deployment.conf}"
            ;;
        *)
            print_error "Unknown service: $SERVICE. Use 'sewer' or 'sewercc'."
            exit 1
            ;;
    esac
}

# ============================================================
load_config() {
    local cf="$1"
    [[ ! -f "$cf" ]] && { print_warning "Config not found: $cf"; return; }
    print_info "Loading config: $cf"
    while IFS='=' read -r key value; do
        [[ $key =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "${value:-}" | sed 's/^\s*"//;s/"\s*$//' | xargs)
        case "$key" in
            IMAGE_NAME)  IMAGE_NAME="$value" ;;
            PORT)        PORT="$value" ;;
            ACR_USER)    ACR_USER="$value" ;;
            ACR_PASS)    ACR_PASS="$value" ;;
            CORS_ORIGIN) CORS_ORIGIN="$value" ;;
            REGISTRY)    REGISTRY_NAME="$value" ;;
            RUNTIME)     [[ -z "$RUNTIME" ]] && RUNTIME="$value" ;;
        esac
    done < "$cf"
    print_success "Configuration loaded"
}

# ============================================================
resolve_runtime() {
    local has_docker=false has_podman=false
    command -v docker &>/dev/null && has_docker=true
    command -v podman &>/dev/null && has_podman=true

    if [[ -n "$RUNTIME" ]]; then
        :
    elif $has_podman && $has_docker; then
        RUNTIME="podman"
        print_info "Auto-detected: both available, using podman"
    elif $has_podman; then
        RUNTIME="podman"
    elif $has_docker; then
        RUNTIME="docker"
    else
        print_error "No container runtime found. Install docker or podman."
        exit 1
    fi

    if [[ "$RUNTIME" == "docker" ]] && ! $has_docker; then
        print_error "Docker not installed"; exit 1
    fi
    if [[ "$RUNTIME" == "podman" ]] && ! $has_podman; then
        print_error "Podman not installed"; exit 1
    fi

    # Verify daemon
    if ! $RUNTIME info &>/dev/null; then
        print_error "$RUNTIME daemon is not running"; exit 1
    fi
    print_success "Runtime: $RUNTIME"
}

# ============================================================
validate_port() {
    local p="$1"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
        print_error "Invalid port: $p"; return 1
    fi
    if command -v ss &>/dev/null; then
        if ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then
            print_error "Port $p already in use"; return 1
        fi
    fi
    return 0
}

# ============================================================
login_registry() {
    print_section "Registry Authentication"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY] $RUNTIME login $REGISTRY_NAME -u $ACR_USER"; return
    fi
    echo "$ACR_PASS" | $RUNTIME login "$REGISTRY_NAME" -u "$ACR_USER" --password-stdin
    if [[ $? -eq 0 ]]; then
        print_success "Logged in to $REGISTRY_NAME"
    else
        print_error "Login failed"; exit 1
    fi
}

# ============================================================
pull_image() {
    print_section "Pulling Image"
    local img="$IMAGE_NAME"
    [[ "$img" != "$REGISTRY_NAME"* ]] && img="$REGISTRY_NAME/$img"
    print_info "Pulling: $img"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY] $RUNTIME pull $img"; return
    fi
    $RUNTIME pull "$img"
    print_success "Image pulled: $img"
}

# ============================================================
wait_container_health() {
    local max_attempts=12
    local wait_secs=5
    local port="${PORT:-$DEFAULT_PORT}"
    print_info "Waiting for container readiness (up to $((max_attempts * wait_secs))s)..."

    for ((i=1; i<=max_attempts; i++)); do
        # Check still running
        local state
        state=$($RUNTIME inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
        if [[ "$state" != "running" ]]; then
            print_error "Container not running (state: $state). Logs:"
            $RUNTIME logs --tail 50 "$CONTAINER_NAME" 2>&1 || true
            return 1
        fi

        # Docker/Podman HEALTHCHECK
        local health
        health=$($RUNTIME inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
        if [[ "$health" == "healthy" ]]; then
            print_success "Container is healthy"
            return 0
        fi
        if [[ "$health" == "unhealthy" ]]; then
            print_error "Container unhealthy. Logs:"
            $RUNTIME logs --tail 50 "$CONTAINER_NAME" 2>&1 || true
            return 1
        fi

        # TCP fallback
        if (echo >/dev/tcp/localhost/"$port") 2>/dev/null; then
            print_success "Container ready (port $port open)"
            return 0
        fi

        local label="${health:-no healthcheck}"
        print_info "Waiting... ($i/$max_attempts) port not open, health: $label"
        sleep $wait_secs
    done

    print_error "Container not ready after $((max_attempts * wait_secs))s. Logs:"
    $RUNTIME logs --tail 50 "$CONTAINER_NAME" 2>&1 || true
    return 1
}

# ============================================================
deploy() {
    print_section "Deploying $CONTAINER_NAME"
    local img="$IMAGE_NAME"
    [[ "$img" != "$REGISTRY_NAME"* ]] && img="$REGISTRY_NAME/$img"
    local port="${PORT:-$DEFAULT_PORT}"

    # Check existing
    if $RUNTIME ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        if [[ "$MODE" == "update" ]]; then
            print_info "Removing existing container for update"
            [[ "$DRY_RUN" != "true" ]] && $RUNTIME rm -f "$CONTAINER_NAME" >/dev/null
        else
            print_warning "Container already exists. Use --update to replace."
            $RUNTIME logs --tail 10 "$CONTAINER_NAME" 2>&1 || true
            return
        fi
    fi

    local env_args=()
    [[ -n "$CORS_ORIGIN" ]] && env_args+=("-e" "CORS_ORIGIN=$CORS_ORIGIN")

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY] $RUNTIME run -d --name $CONTAINER_NAME -p $port:$port ${env_args[*]} $img"
        return
    fi

    # Determine internal port from image (SewerManagement=5050, CC=8080)
    local internal_port="$DEFAULT_PORT"

    $RUNTIME run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p "${port}:${internal_port}" \
        --health-cmd "curl -f http://localhost:${internal_port}/ || exit 1" \
        --health-interval 30s \
        --health-timeout 10s \
        --health-retries 3 \
        --health-start-period 15s \
        "${env_args[@]}" \
        "$img"

    CREATED_CONTAINERS+=("$CONTAINER_NAME")
    print_info "Container started, checking health..."

    if wait_container_health; then
        print_success "$CONTAINER_NAME deployed successfully"
        $RUNTIME ps --filter "name=$CONTAINER_NAME"
    else
        print_error "Deployment failed - container not ready"
        exit 1
    fi
}

# ============================================================
# MAIN
# ============================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--service)   SERVICE="$2"; shift 2 ;;
            -h|--help)      show_help; exit 0 ;;
            -d|--dry-run)   DRY_RUN=true; shift ;;
            -c|--config)    CONFIG_FILE="$2"; shift 2 ;;
            -u|--update)    MODE="update"; shift ;;
            -r|--runtime)   RUNTIME="$2"; shift 2 ;;
            --image)        IMAGE_NAME="$2"; shift 2 ;;
            --port)         PORT="$2"; shift 2 ;;
            --cors)         CORS_ORIGIN="$2"; shift 2 ;;
            --acr-user)     ACR_USER="$2"; shift 2 ;;
            --acr-pass)     ACR_PASS="$2"; shift 2 ;;
            *)              print_error "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done
}

main() {
    parse_args "$@"

    if [[ -z "$SERVICE" ]]; then
        print_error "Service not specified. Use --service <sewer|sewercc>"
        show_help
        exit 1
    fi

    resolve_service
    load_config "$CONFIG_FILE"

    # Apply defaults
    [[ -z "$IMAGE_NAME" ]] && IMAGE_NAME="$DEFAULT_IMAGE"
    [[ -z "$PORT" ]] && PORT="$DEFAULT_PORT"

    print_section "$SCRIPT_NAME v$VERSION — $SERVICE"
    [[ "$DRY_RUN" == "true" ]] && print_warning "DRY RUN MODE"

    resolve_runtime
    validate_port "$PORT" || exit 1

    print_info "Configuration:"
    print_info "  Service:   $SERVICE"
    print_info "  Mode:      $MODE"
    print_info "  Runtime:   $RUNTIME"
    print_info "  Image:     $IMAGE_NAME"
    print_info "  Port:      $PORT"
    print_info "  CORS:      ${CORS_ORIGIN:-<none>}"

    if [[ "$FORCE" != "yes" && "$DRY_RUN" != "true" ]]; then
        read -rp "Continue? (y/N) " confirm
        [[ "$confirm" != [yY] ]] && { print_info "Cancelled"; exit 0; }
    fi

    login_registry
    pull_image
    deploy

    print_section "Deployment Complete"
    print_success "$CONTAINER_NAME running on port $PORT"
    print_info "Log: $LOG_FILE"
}

main "$@"
