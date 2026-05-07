#!/usr/bin/env bash

# ============================================================
# SewerJS - Deployment Script (Linux)
# ============================================================
#   - Multiple deployment modes (new/update/dry-run)
#   - Container runtime: Docker or Podman (auto-detected)
#   - Configuration file support
#   - Parameter validation and error handling
#   - Proper cleanup and rollback mechanisms
#   - Enhanced security and logging
#   - Docker installation: use Ubuntu official Docker repo when Docker missing
# Version: 1.1
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# Global variables for cleanup tracking
TEMP_FILES=()
CREATED_CONTAINERS=()
CLEANUP_NEEDED=false

# ------------------------------
# Configuration and Constants
# ------------------------------
SCRIPT_NAME="SewerJS Deployment"
VERSION="1.1"
CONFIG_FILE="sewerjs-deployment.conf"
LOG_FILE="/tmp/sewerjs-deployment-$(date +%Y%m%d-%H%M%S).log"

# Default Parameters
REGISTRY_NAME="vertigisnetworks.azurecr.io"
DEFAULT_IMAGE="networks/sewerjs:latest"
DEFAULT_PORT=3000
CONTAINER_NAME="sewerjs-service"

# Operation modes
MODE=""
DRY_RUN=false
DEPLOY_FROM_DOCKERHUB=false
UPDATE_MODE=false

# Runtime (docker or podman, resolved in resolve_runtime)
RUNTIME=""

# Configuration variables
IMAGE_NAME=""
PORT=""
ACR_USER=""
ACR_PASS=""
CORS_ORIGIN=""

# Non-interactive CI mode: set FORCE=yes to skip confirmations
FORCE=${FORCE:-no}

# ------------------------------
# Colors and logging
# ------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Reset

function log_and_print() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

function print_section() {
    log_and_print "\n${BLUE}=== $1 ===${NC}"
}

function print_success() {
    log_and_print "${GREEN}[OK] $1${NC}"
}

function print_info() {
    log_and_print "${YELLOW}[i] $1${NC}"
}

function print_error() {
    log_and_print "${RED}[ERR] $1${NC}"
}

function print_warning() {
    log_and_print "${YELLOW}[WARN] $1${NC}"
}

function print_dry_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_and_print "${BLUE}[DRY RUN] Would execute: $1${NC}"
    fi
}

# ------------------------------
# Cleanup and Error Handling
# ------------------------------
function cleanup_temp_files() {
    for temp_file in "${TEMP_FILES[@]}"; do
        if [[ -f "$temp_file" ]]; then
            rm -f "$temp_file" || true
        fi
    done
}

function rollback_containers() {
    print_info "Rolling back containers..."
    for container in "${CREATED_CONTAINERS[@]}"; do
        if $RUNTIME ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            print_info "Removing container: $container"
            if [[ "$DRY_RUN" != "true" ]]; then
                $RUNTIME rm -f "$container" >/dev/null 2>&1 || true
            else
                print_dry_run "$RUNTIME rm -f $container"
            fi
        fi
    done
}

function cleanup_and_exit() {
    local exit_code=${1:-1}
    CLEANUP_NEEDED=true
    print_error "Deployment failed or interrupted. Performing cleanup..."
    rollback_containers
    cleanup_temp_files
    print_error "Deployment failed. Check log file: $LOG_FILE"
    exit $exit_code
}

trap 'cleanup_and_exit $?' ERR
trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM
trap cleanup_temp_files EXIT

# ------------------------------
# Help and Usage
# ------------------------------
function show_help() {
    cat << EOF
$SCRIPT_NAME v$VERSION

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -d, --dry-run           Run in dry-run mode (show what would be done)
    -c, --config FILE       Use configuration file (default: $CONFIG_FILE)
    -m, --mode MODE         Deployment mode: new|update (default: new)
    -u, --update            Update existing deployment
    -r, --runtime RT        Container runtime: docker|podman (default: auto-detect)
    --dockerhub             Pull image from Docker Hub instead of ACR
    --image IMAGE           Container image name (can include registry)
    --port PORT             Host port for API (default: $DEFAULT_PORT)
    --cors ORIGINS          Comma-separated CORS origins
    --acr-user USER         Azure Container Registry username
    --acr-pass PASS         Azure Container Registry password
    --create-config         Create a sample configuration file and exit

Environment:
    FORCE=yes               Skip interactive confirmation (CI usage)

EXAMPLES:
    $0 --dry-run
    $0 --runtime podman --image networks/sewerjs:latest
    FORCE=yes $0 --image networks/sewerjs:1.0.0-12345 --port 3000
    $0 --update --image networks/sewerjs:latest
EOF
}

# ------------------------------
# Configuration Management
# ------------------------------
function load_config_file() {
    local config_file="$1"
    if [[ -f "$config_file" ]]; then
        print_info "Loading configuration from: $config_file"
        while IFS='=' read -r key value; do
            [[ $key =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            key=$(echo "$key" | xargs)
            value=$(echo "${value:-}" | sed 's/^\s*"//' | sed 's/"\s*$//' | xargs)
            case "$key" in
                IMAGE_NAME) IMAGE_NAME="$value" ;;
                PORT) PORT="$value" ;;
                ACR_USER) ACR_USER="$value" ;;
                ACR_PASS) ACR_PASS="$value" ;;
                CORS_ORIGIN) CORS_ORIGIN="$value" ;;
                DEPLOY_FROM_DOCKERHUB) DEPLOY_FROM_DOCKERHUB="$value" ;;
                REGISTRY) REGISTRY_NAME="$value" ;;
                RUNTIME) [[ -z "$RUNTIME" ]] && RUNTIME="$value" ;;
                CONTAINER_TYPE) : ;;
            esac
        done < "$config_file"
        print_success "Configuration loaded successfully"
    else
        print_warning "Configuration file not found: $config_file"
    fi
}

function create_sample_config() {
    cat > "$CONFIG_FILE" << EOF
# SewerJS Deployment Configuration
IMAGE_NAME=$DEFAULT_IMAGE
PORT=$DEFAULT_PORT
ACR_USER=your_acr_username
ACR_PASS=your_acr_password
CORS_ORIGIN=http://localhost:3001,https://dev002-networks.apps.vertigisstudio.com
DEPLOY_FROM_DOCKERHUB=false
EOF
    print_success "Sample configuration created: $CONFIG_FILE"
}

# ------------------------------
# Port & Utility checks
# ------------------------------
function port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -ltn "sport = :$port" | grep -q LISTEN || return $?
        return 0
    elif command -v netstat &>/dev/null; then
        netstat -tuln | grep -q ":$port " && return 0 || return 1
    elif command -v lsof &>/dev/null; then
        lsof -iTCP -sTCP:LISTEN -P -n | grep -q ":$port" && return 0 || return 1
    else
        return 2
    fi
}

function validate_port() {
    local port="$1"
    local port_name="$2"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        print_error "Invalid $port_name: $port (must be 1-65535)"
        return 1
    fi
    if port_in_use "$port"; then
        print_error "$port_name $port is already in use"
        return 1
    fi
    return 0
}

# ------------------------------
# Runtime detection
# ------------------------------
function resolve_runtime() {
    local has_docker=false
    local has_podman=false
    command -v docker &>/dev/null && has_docker=true
    command -v podman &>/dev/null && has_podman=true

    if [[ -n "$RUNTIME" ]]; then
        # User explicitly chose a runtime
        if [[ "$RUNTIME" == "docker" && "$has_docker" != "true" ]]; then
            print_error "Docker is not installed."; exit 1
        fi
        if [[ "$RUNTIME" == "podman" && "$has_podman" != "true" ]]; then
            print_error "Podman is not installed."; exit 1
        fi
    elif [[ "$has_podman" == "true" ]]; then
        RUNTIME="podman"
    elif [[ "$has_docker" == "true" ]]; then
        RUNTIME="docker"
    else
        print_error "No container runtime found. Install docker or podman."
        exit 1
    fi
    print_success "Using container runtime: $RUNTIME"
}

# ------------------------------
# Docker / Podman
# ------------------------------
function install_docker_on_ubuntu() {
    print_section "Installing Docker Engine on Ubuntu (official repo)"
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg lsb-release

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.gpg > /dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if ! getent group docker > /dev/null; then
        sudo groupadd docker
    fi
    sudo usermod -aG docker $USER || true

    sudo systemctl daemon-reload || true
    sudo systemctl enable --now docker || true

    print_success "Docker installed and started"
}

function detect_os() {
    if command -v apt-get >/dev/null; then
        PACKAGE_MANAGER="apt-get"
        INSTALL_CMD="sudo apt-get install -y"
        UPDATE_CMD="sudo apt-get update -y"
    elif command -v yum >/dev/null; then
        PACKAGE_MANAGER="yum"
        INSTALL_CMD="sudo yum install -y"
        UPDATE_CMD="sudo yum update -y"
    elif command -v brew >/dev/null; then
        PACKAGE_MANAGER="brew"
        INSTALL_CMD="brew install"
        UPDATE_CMD="brew update"
    else
        PACKAGE_MANAGER=""
    fi
    print_info "Detected package manager: ${PACKAGE_MANAGER:-none}"
}

function check_docker() {
    print_section "Checking Container Runtime: $RUNTIME"
    if [[ "$RUNTIME" == "podman" ]]; then
        print_success "Podman found: $(podman --version)"
        if ! podman info >/dev/null 2>&1; then
            print_error "Podman is not running. Start the podman machine/service."
            exit 1
        fi
        return
    fi

    # Docker path
    if command -v docker &>/dev/null; then
        print_success "Docker is already installed: $(docker --version)"
    else
        print_info "Docker not found"
        detect_os
        if [[ "$PACKAGE_MANAGER" == "apt-get" ]]; then
            install_docker_on_ubuntu
        elif [[ -n "$PACKAGE_MANAGER" ]]; then
            print_info "Attempting to install Docker via package manager: $PACKAGE_MANAGER"
            $UPDATE_CMD
            $INSTALL_CMD docker.io || $INSTALL_CMD docker || true
            if [[ "$PACKAGE_MANAGER" != "brew" ]]; then
                sudo systemctl enable --now docker || true
            fi
        else
            print_error "Docker is required but could not be installed automatically. Please install Docker and re-run."
            exit 1
        fi
    fi

    if ! docker info >/dev/null 2>&1; then
        print_error "Docker daemon is not running. Please start Docker service."
        exit 1
    fi
}
# ------------------------------
# Registry operations
# ------------------------------
function login_to_registry() {
    print_section "Container Registry Authentication"
    if [[ "$DEPLOY_FROM_DOCKERHUB" == "true" ]]; then
        print_info "Using Docker Hub - public images do not require login"
        return 0
    fi

    if command -v az &>/dev/null; then
        print_info "Attempting Azure CLI login..."
        if [[ "$DRY_RUN" == "true" ]]; then
            print_dry_run "az acr login --name $(echo $REGISTRY_NAME | cut -d'.' -f1)"
            return 0
        fi
        if az acr login --name "$(echo $REGISTRY_NAME | cut -d'.' -f1)" >/dev/null 2>&1; then
            print_success "Logged in to ACR using Azure CLI"
            return 0
        else
            print_warning "Azure CLI login failed, falling back to manual login"
        fi
    fi

    print_info "Using manual ACR login"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_dry_run "$RUNTIME login $REGISTRY_NAME -u [ACR_USER]"
        return 0
    fi

    if echo "$ACR_PASS" | $RUNTIME login "$REGISTRY_NAME" -u "$ACR_USER" --password-stdin; then
        print_success "Logged in to ACR successfully via $RUNTIME"
    else
        print_error "Failed to login to ACR. Please check credentials."
        exit 1
    fi
}

function pull_image() {
    print_section "Pulling Container Image"
    local full_image_name

    if [[ "$IMAGE_NAME" == "$REGISTRY_NAME"* ]]; then
        full_image_name="$IMAGE_NAME"
    else
        if [[ "$DEPLOY_FROM_DOCKERHUB" == "true" ]]; then
            full_image_name="$IMAGE_NAME"
        else
            full_image_name="$REGISTRY_NAME/$IMAGE_NAME"
        fi
    fi

    print_info "Pulling image: $full_image_name (via $RUNTIME)"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_dry_run "$RUNTIME pull $full_image_name"
        return 0
    fi

    if $RUNTIME pull "$full_image_name"; then
        print_success "Image pulled successfully: $full_image_name"
    else
        print_error "Failed to pull image: $full_image_name"
        exit 1
    fi
}

# ------------------------------
# Application container
# ------------------------------
function wait_for_container_health() {
    local max_attempts=12
    local wait_secs=5
    print_info "Waiting for container to be ready (up to $((max_attempts * wait_secs))s)..."
    for i in $(seq 1 $max_attempts); do
        # 1. Check container is still running
        local state
        state=$($RUNTIME inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
        if [[ "$state" != "running" ]]; then
            print_error "Container is not running (state: $state). Logs:"
            $RUNTIME logs --tail 50 "$CONTAINER_NAME" 2>/dev/null || true
            return 1
        fi

        # 2. Check built-in health status (only meaningful if HEALTHCHECK is defined in image)
        local health_status
        health_status=$($RUNTIME inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
        if [[ "$health_status" == "healthy" ]]; then
            print_success "Container is healthy and ready"
            return 0
        elif [[ "$health_status" == "unhealthy" ]]; then
            print_error "Container health check failed. Logs:"
            $RUNTIME logs --tail 50 "$CONTAINER_NAME" 2>/dev/null || true
            return 1
        fi

        # 3. Fall back to TCP port check (works even without curl in image)
        if timeout 2 bash -c "cat < /dev/null > /dev/tcp/localhost/$PORT" 2>/dev/null; then
            print_success "Container is ready (port $PORT is open)"
            return 0
        fi

        print_info "Waiting for port $PORT to open... ($i/$max_attempts)"
        sleep $wait_secs
    done

    print_error "Container did not become ready after $((max_attempts * wait_secs))s. Logs:"
    $RUNTIME logs --tail 50 "$CONTAINER_NAME" 2>/dev/null || true
    return 1
}

function deploy_application() {
    print_section "Deploying SewerJS Application"
    local full_image_name

    if [[ -n "$IMAGE_NAME" && "$IMAGE_NAME" == "$REGISTRY_NAME"* ]]; then
        full_image_name="$IMAGE_NAME"
    else
        if [[ -n "$IMAGE_NAME" && "$DEPLOY_FROM_DOCKERHUB" == "true" ]]; then
            full_image_name="$IMAGE_NAME"
        else
            full_image_name="$REGISTRY_NAME/${IMAGE_NAME:-$DEFAULT_IMAGE}"
        fi
    fi

    print_info "Will run image: $full_image_name"

    if $RUNTIME ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        if [[ "$MODE" == "update" ]]; then
            print_info "Removing existing container for update: $CONTAINER_NAME"
            if [[ "$DRY_RUN" != "true" ]]; then
                $RUNTIME rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
            else
                print_dry_run "$RUNTIME rm -f $CONTAINER_NAME"
            fi
        else
            print_warning "Container already exists: $CONTAINER_NAME. Use --update to replace it."
            return 0
        fi
    fi

    print_info "Starting SewerJS container..."

    local env_args=""
    if [[ -n "$CORS_ORIGIN" ]]; then
        env_args="-e CORS_ORIGIN=$CORS_ORIGIN"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        print_dry_run "$RUNTIME run -d --name $CONTAINER_NAME $env_args -p $PORT:3000 $full_image_name"
        return 0
    fi

    local run_cmd="$RUNTIME run -d \
        --name $CONTAINER_NAME \
        --restart unless-stopped \
        -p $PORT:3000 \
        --health-cmd='curl -sf http://localhost:3000/ || nc -z localhost 3000 || exit 1' \
        --health-interval=30s \
        --health-timeout=10s \
        --health-retries=3"

    # Resource limits (may not work in podman rootless without cgroup v2)
    if [[ "$RUNTIME" == "docker" ]]; then
        run_cmd="$run_cmd --memory=512m --cpus=0.5"
    fi

    if [[ -n "$CORS_ORIGIN" ]]; then
        run_cmd="$run_cmd -e CORS_ORIGIN=$CORS_ORIGIN"
    fi

    run_cmd="$run_cmd $full_image_name"

    if eval "$run_cmd"; then
        CREATED_CONTAINERS+=("$CONTAINER_NAME")
        print_info "Container process started, checking readiness..."
        if wait_for_container_health; then
            print_success "SewerJS container started successfully"
            print_info "Container status:"
            $RUNTIME ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        else
            print_error "Container started but is not ready. Deployment failed."
            exit 1
        fi
    else
        print_error "Failed to start SewerJS container"
        exit 1
    fi
}

# ------------------------------
# Argument parsing
# ------------------------------
function parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--dry-run)
                DRY_RUN=true
                print_info "Dry-run mode enabled"
                shift
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -m|--mode)
                MODE="$2"
                shift 2
                ;;
            -u|--update)
                UPDATE_MODE=true
                MODE="update"
                shift
                ;;
            --dockerhub)
                DEPLOY_FROM_DOCKERHUB=true
                shift
                ;;
            -r|--runtime)
                RUNTIME="$2"
                shift 2
                ;;
            --image)
                IMAGE_NAME="$2"
                shift 2
                ;;
            --port)
                PORT="$2"
                shift 2
                ;;
            --cors)
                CORS_ORIGIN="$2"
                shift 2
                ;;
            --acr-user)
                ACR_USER="$2"
                shift 2
                ;;
            --acr-pass)
                ACR_PASS="$2"
                shift 2
                ;;
            --create-config)
                create_sample_config
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [[ -z "$MODE" ]]; then
        if [[ "$UPDATE_MODE" == "true" ]]; then
            MODE="update"
        else
            MODE="new"
        fi
    fi
}

function validate_required_params() {
    local missing_params=()
    if [[ "$DEPLOY_FROM_DOCKERHUB" != "true" ]]; then
        [[ -z "$ACR_USER" ]] && missing_params+=("ACR Username")
        [[ -z "$ACR_PASS" ]] && missing_params+=("ACR Password")
    fi
    if [[ ${#missing_params[@]} -gt 0 ]]; then
        print_error "Missing required parameters:"
        for param in "${missing_params[@]}"; do
            print_error "  - $param"
        done
        return 1
    fi
    return 0
}

# ------------------------------
# Main
# ------------------------------
function main() {
    print_section "$SCRIPT_NAME v$VERSION"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warning "DRY RUN MODE - No actual changes will be made"
    fi

    echo "=== $SCRIPT_NAME v$VERSION - $(date) ===" > "$LOG_FILE"
    echo "User: $(whoami)" >> "$LOG_FILE" || true
    echo "Mode: $MODE" >> "$LOG_FILE"
    echo "Dry Run: $DRY_RUN" >> "$LOG_FILE"
    echo "================================" >> "$LOG_FILE"

    load_config_file "$CONFIG_FILE"

    # Collect missing params interactively
    if [[ -t 0 && "$FORCE" != "yes" ]]; then
        if [[ -z "$IMAGE_NAME" ]]; then
            read -p "Enter Image Name (default: $DEFAULT_IMAGE): " IMAGE_NAME
            IMAGE_NAME=${IMAGE_NAME:-$DEFAULT_IMAGE}
        fi
        if [[ -z "$PORT" ]]; then
            read -p "Enter host port (default: $DEFAULT_PORT): " PORT
            PORT=${PORT:-$DEFAULT_PORT}
        fi
        if [[ -z "$CORS_ORIGIN" ]]; then
            read -p "Enter CORS origins (comma-separated, or leave empty): " CORS_ORIGIN
        fi
        if [[ "$DEPLOY_FROM_DOCKERHUB" != "true" ]]; then
            if [[ -z "$ACR_USER" ]]; then
                read -p "Enter ACR Username: " ACR_USER
            fi
            if [[ -z "$ACR_PASS" ]]; then
                read -s -p "Enter ACR Password: " ACR_PASS
                echo ""
            fi
        fi
    else
        print_info "Non-interactive or FORCE mode; skipping interactive prompts"
    fi

    # Apply defaults
    PORT=${PORT:-$DEFAULT_PORT}
    IMAGE_NAME=${IMAGE_NAME:-$DEFAULT_IMAGE}

    if ! validate_required_params; then
        print_error "Parameter validation failed"
        exit 1
    fi

    if ! validate_port "$PORT" "Port"; then
        exit 1
    fi

    print_info "Configuration Summary:"
    print_info "  Runtime: $RUNTIME"
    print_info "  Mode: $MODE"
    print_info "  Image: $IMAGE_NAME"
    print_info "  Port: $PORT"
    print_info "  CORS Origins: ${CORS_ORIGIN:-<not set>}"
    print_info "  Deploy from Docker Hub: $DEPLOY_FROM_DOCKERHUB"

    if [[ "$DRY_RUN" != "true" && "$FORCE" != "yes" && -t 0 ]]; then
        read -p "Continue with deployment? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            print_info "Deployment cancelled by user"
            exit 0
        fi
    fi

    resolve_runtime
    check_docker
    login_to_registry
    pull_image
    deploy_application

    CLEANUP_NEEDED=false

    print_section "Deployment Completed Successfully"
    print_success "SewerJS is now running (via $RUNTIME)"
    print_info "API endpoint: http://localhost:$PORT"
    print_info "Log file: $LOG_FILE"
}

# Start
parse_arguments "$@"
main
