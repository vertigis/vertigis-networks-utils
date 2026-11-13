#!/usr/bin/env bash

# ============================================================
# Sewer Backend - Deployment Script (Linux)
# ============================================================
#   Deploys the consolidated Sewer backend (all services in one
#   container, port 8080, image networks/sewer).
#   Auto-detects Docker or Podman, reads a configuration file,
#   supports new/update/dry-run and a pre-loaded image (--no-pull).
# Version: 2.0
# ============================================================

set -euo pipefail
IFS=$'\n\t'

CREATED_CONTAINERS=()

SCRIPT_NAME="Sewer Deployment"
VERSION="2.0"
LOG_FILE="/tmp/sewer-deployment-$(date +%Y%m%d-%H%M%S).log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER_NAME="sewer"
INTERNAL_PORT=8080
CONFIG_FILE="sewer-consolidated-deployment.conf"

# State (command line values win over the config file)
MODE="new"
DRY_RUN=false
NO_PULL=false
RUNTIME=""
REGISTRY_NAME=""
IMAGE_NAME=""
IMAGE_VERSION=""
PORT=""
ACR_USER=""
ACR_PASS=""
CORS_ORIGIN=""
ENV_FILE=""
MEDIA_VOLUME="sewer-media"
LOGS_VOLUME="sewer-import-logs"
FORCE=${FORCE:-no}
IMAGE=""

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
    exit "$exit_code"
}
trap 'cleanup_and_exit $?' ERR
trap 'cleanup_and_exit 130' INT

# ============================================================
show_help() {
    cat << EOF
$SCRIPT_NAME v$VERSION

Deploys the consolidated Sewer backend (container "sewer", port 8080).

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -v, --version VERSION   Image version, for example 2.2.0
    -e, --env-file FILE     Environment file for the container
                            (default: sewer.env if it exists)
    -h, --help              Show help
    -d, --dry-run           Show what would be done
    -c, --config FILE       Configuration file
                            (default: sewer-consolidated-deployment.conf)
    -u, --update            Replace an existing container
    -r, --runtime RT        docker|podman (default: auto-detect)
    --image IMAGE           Full image name (overrides --version)
    --port PORT             Host port (default: 8080)
    --cors ORIGINS          CORS origins
    --acr-user USER         Registry user name
    --acr-pass PASS         Registry password
    --no-pull               Use an image that is already on the host
                            (for example loaded with docker load)

EXAMPLES:
    $0 --version 2.2.0
    $0 --version 2.2.1 --update
    $0 --version 2.2.0 --env-file /etc/sewer/sewer.env --port 8080
    docker load -i sewer-2.2.0.tar && $0 --version 2.2.0 --no-pull
    FORCE=yes $0 --config /etc/sewer/sewer-consolidated-deployment.conf
EOF
}

# ============================================================
load_config() {
    local cf="$1"
    if [[ ! -f "$cf" && "$cf" != /* && -f "$SCRIPT_DIR/$cf" ]]; then
        cf="$SCRIPT_DIR/$cf"
    fi
    if [[ ! -f "$cf" ]]; then
        print_info "No config file ($cf), using parameters and defaults"
        return
    fi
    print_info "Loading config: $cf"
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ $key =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "${value:-}" | sed 's/^\s*"//;s/"\s*$//' | xargs)
        [[ -z "$value" ]] && continue
        case "$key" in
            IMAGE_NAME)   [[ -z "$IMAGE_NAME" ]] && IMAGE_NAME="$value" ;;
            VERSION)      [[ -z "$IMAGE_VERSION" ]] && IMAGE_VERSION="$value" ;;
            PORT)         [[ -z "$PORT" ]] && PORT="$value" ;;
            ACR_USER)     [[ -z "$ACR_USER" ]] && ACR_USER="$value" ;;
            ACR_PASS)     [[ -z "$ACR_PASS" ]] && ACR_PASS="$value" ;;
            CORS_ORIGIN)  [[ -z "$CORS_ORIGIN" ]] && CORS_ORIGIN="$value" ;;
            REGISTRY)     [[ -z "$REGISTRY_NAME" ]] && REGISTRY_NAME="$value" ;;
            RUNTIME)      [[ -z "$RUNTIME" ]] && RUNTIME="$value" ;;
            ENV_FILE)     [[ -z "$ENV_FILE" ]] && ENV_FILE="$value" ;;
            MEDIA_VOLUME) MEDIA_VOLUME="$value" ;;
            LOGS_VOLUME)  LOGS_VOLUME="$value" ;;
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

    if [[ "$DRY_RUN" != "true" ]] && ! $RUNTIME info &>/dev/null; then
        print_error "$RUNTIME daemon is not running"; exit 1
    fi
    print_success "Runtime: $RUNTIME"
}

# ============================================================
resolve_image() {
    local img="$IMAGE_NAME"
    if [[ -z "$img" ]]; then
        if [[ -z "$IMAGE_VERSION" && "$FORCE" != "yes" && -t 0 ]]; then
            read -rp "Version to deploy (for example 2.2.0): " IMAGE_VERSION
        fi
        if [[ -z "$IMAGE_VERSION" ]]; then
            print_error "No version given. Use --version <x.y.z> or --image."
            exit 1
        fi
        img="networks/sewer:$IMAGE_VERSION"
    fi
    # Add the registry unless the name already starts with a registry host.
    local first="${img%%/*}"
    if [[ "$img" != */* || ( "$first" != *.* && "$first" != *:* ) ]]; then
        img="$REGISTRY_NAME/$img"
    fi
    IMAGE="$img"
}

# ============================================================
validate_port() {
    local p="$1"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
        print_error "Invalid port: $p"; return 1
    fi
    return 0
}

port_in_use() {
    command -v ss &>/dev/null && ss -ltn "sport = :$1" 2>/dev/null | grep -q LISTEN
}

# ============================================================
login_registry() {
    print_section "Registry Authentication"
    if [[ "$NO_PULL" == "true" ]]; then
        print_info "Skipped (--no-pull)"; return
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY] $RUNTIME login $REGISTRY_NAME"; return
    fi
    if [[ -z "$ACR_USER" || -z "$ACR_PASS" ]]; then
        print_info "No credentials given, using the existing login for $REGISTRY_NAME"
        return
    fi
    if echo "$ACR_PASS" | $RUNTIME login "$REGISTRY_NAME" -u "$ACR_USER" --password-stdin; then
        print_success "Logged in to $REGISTRY_NAME"
    else
        print_error "Login failed"; exit 1
    fi
}

# ============================================================
pull_image() {
    print_section "Image"
    if [[ "$NO_PULL" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY] use local image $IMAGE"; return
        fi
        if ! $RUNTIME image inspect "$IMAGE" >/dev/null 2>&1; then
            print_error "Image not found on this host: $IMAGE"; exit 1
        fi
        print_success "Using local image $IMAGE"
        return
    fi
    print_info "Pulling: $IMAGE"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY] $RUNTIME pull $IMAGE"; return
    fi
    $RUNTIME pull "$IMAGE"
    print_success "Image pulled: $IMAGE"
}

# ============================================================
# Ready when every supervised service runs; works also where the runtime
# does not evaluate the image health check (Podman without systemd).
services_ready() {
    local out
    out=$($RUNTIME exec "$CONTAINER_NAME" supervisorctl -c /etc/supervisor/conf.d/sewer.conf status 2>&1) || return 1
    [[ $(grep -c RUNNING <<< "$out") -ge 5 ]] || return 1
    grep -qv RUNNING <<< "$out" && return 1
    while IFS= read -r line; do print_info "  $line"; done <<< "$out"
    return 0
}

wait_container_ready() {
    local max_attempts=24
    local wait_secs=5
    print_info "Waiting for container readiness (up to $((max_attempts * wait_secs))s)..."

    for ((i=1; i<=max_attempts; i++)); do
        local state
        state=$($RUNTIME inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
        if [[ "$state" != "running" ]]; then
            print_error "Container not running (state: $state). Logs:"
            $RUNTIME logs --tail 50 "$CONTAINER_NAME" 2>&1 || true
            return 1
        fi
        if services_ready; then
            print_success "All services are running"
            return 0
        fi
        print_info "Waiting... ($i/$max_attempts) services are starting"
        sleep $wait_secs
    done

    print_error "Container not ready after $((max_attempts * wait_secs))s. Logs:"
    $RUNTIME logs --tail 50 "$CONTAINER_NAME" 2>&1 || true
    return 1
}

# ============================================================
deploy() {
    print_section "Deploying $CONTAINER_NAME"

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

    if [[ "$DRY_RUN" != "true" ]] && port_in_use "$PORT"; then
        print_error "Port $PORT already in use"; exit 1
    fi

    # Named volumes keep media and import logs across updates.
    for volume in "$MEDIA_VOLUME" "$LOGS_VOLUME"; do
        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY] $RUNTIME volume create $volume"
        elif ! $RUNTIME volume inspect "$volume" >/dev/null 2>&1; then
            $RUNTIME volume create "$volume" >/dev/null
            print_success "Created volume $volume"
        fi
    done

    # The image has its own health check and runs as a non-root user.
    local run_args=(run -d --name "$CONTAINER_NAME" --restart unless-stopped -p "${PORT}:${INTERNAL_PORT}")
    [[ -n "$ENV_FILE" ]] && run_args+=(--env-file "$ENV_FILE")
    [[ -n "$CORS_ORIGIN" ]] && run_args+=(-e "CORS_ORIGIN=$CORS_ORIGIN")
    run_args+=(
        --mount "type=volume,source=$MEDIA_VOLUME,target=/app/media"
        --mount "type=volume,source=$LOGS_VOLUME,target=/app/sewer-management/ImportLogs"
        "$IMAGE"
    )

    if [[ "$DRY_RUN" == "true" ]]; then
        local IFS=' '
        print_info "[DRY] $RUNTIME ${run_args[*]}"
        return
    fi

    $RUNTIME "${run_args[@]}" >/dev/null
    CREATED_CONTAINERS+=("$CONTAINER_NAME")
    print_info "Container started, checking readiness..."

    if wait_container_ready; then
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
            -v|--version)   IMAGE_VERSION="$2"; shift 2 ;;
            -e|--env-file)  ENV_FILE="$2"; shift 2 ;;
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
            --no-pull)      NO_PULL=true; shift ;;
            *)              print_error "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done
}

main() {
    parse_args "$@"

    print_section "$SCRIPT_NAME v$VERSION"
    [[ "$DRY_RUN" == "true" ]] && print_warning "DRY RUN MODE"
    load_config "$CONFIG_FILE"

    REGISTRY_NAME="${REGISTRY_NAME:-vertigisapps.azurecr.io}"
    PORT="${PORT:-8080}"
    if [[ -z "$ENV_FILE" && -f sewer.env ]]; then
        ENV_FILE="sewer.env"
    fi
    if [[ -n "$ENV_FILE" ]]; then
        [[ -f "$ENV_FILE" ]] || { print_error "Environment file not found: $ENV_FILE"; exit 1; }
        ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"
    fi

    validate_port "$PORT" || exit 1
    resolve_runtime
    resolve_image

    if [[ "$NO_PULL" != "true" && "$DRY_RUN" != "true" && "$FORCE" != "yes" && -t 0 && -z "$ACR_USER" ]]; then
        read -rp "Registry user name for $REGISTRY_NAME (empty: use existing login): " ACR_USER
        [[ -n "$ACR_USER" && -z "$ACR_PASS" ]] && { read -rsp "Registry password: " ACR_PASS; echo; }
    fi

    print_info "Configuration:"
    print_info "  Mode:      $MODE"
    print_info "  Runtime:   $RUNTIME"
    print_info "  Image:     $IMAGE"
    print_info "  Port:      $PORT"
    print_info "  CORS:      ${CORS_ORIGIN:-<none>}"
    print_info "  Env file:  ${ENV_FILE:-<none>}"
    print_info "  Volumes:   $MEDIA_VOLUME, $LOGS_VOLUME"
    if [[ -z "$ENV_FILE" && -z "$CORS_ORIGIN" ]]; then
        print_warning "Neither an environment file nor CORS origins are set. The web application cannot call the backend until CORS_ORIGIN is set."
    fi

    if [[ "$FORCE" != "yes" && "$DRY_RUN" != "true" ]]; then
        read -rp "Continue? (y/N) " confirm
        [[ "$confirm" != [yY] ]] && { print_info "Cancelled"; exit 0; }
    fi

    login_registry
    pull_image
    deploy

    print_section "Deployment Complete"
    print_success "$CONTAINER_NAME listens on port $PORT"
    print_info "Log: $LOG_FILE"
}

main "$@"
