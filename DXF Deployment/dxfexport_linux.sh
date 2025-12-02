#!/usr/bin/env bash

# ============================================================
# DXF Export - Deployment Script
# ============================================================
#   - Multiple deployment modes (new/update/dry-run)
#   - Configuration file support
#   - Parameter validation and error handling
#   - Proper cleanup and rollback mechanisms
#   - Support for existing PostgreSQL or new container deployment
#   - Enhanced security and logging
#   - Docker installation: use Ubuntu official Docker repo when Docker missing
#   - PostgreSQL installation: if missing, install using apt and pgdg script
# Version: 1.0
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
SCRIPT_NAME="DXF Export Deployment"
VERSION="2.2"
CONFIG_FILE="dxf-deployment.conf"
LOG_FILE="/tmp/dxf-deployment-$(date +%Y%m%d-%H%M%S).log"

# Default Parameters
REGISTRY_NAME="vertigisapps.azurecr.io"
DEFAULT_IMAGE="networks/dxf-export:1.2.0"
DEFAULT_PORT1=5000
DEFAULT_PORT2=5001
CONTAINER_NAME="dxf-export-service"
POSTGRES_CONTAINER_NAME="dxf-postgres"

# Operation modes
MODE=""
DRY_RUN=false
USE_EXISTING_POSTGRES=true
DEPLOY_FROM_DOCKERHUB=false
UPDATE_MODE=false

# Configuration variables
DB_HOST=""
DB_PORT="5432"
DB_USER=""
DB_PASS=""
DB_NAME=""
IMAGE_NAME=""
PORT1=""
PORT2=""
ACR_USER=""
ACR_PASS=""

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
    log_and_print "${GREEN}[✔] $1${NC}"
}

function print_info() {
    log_and_print "${YELLOW}[i] $1${NC}"
}

function print_error() {
    log_and_print "${RED}[✘] $1${NC}"
}

function print_warning() {
    log_and_print "${YELLOW}[⚠] $1${NC}"
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
    print_info "Cleaning up temporary files..."
    for temp_file in "${TEMP_FILES[@]}"; do
        if [[ -f "$temp_file" ]]; then
            rm -f "$temp_file" || true
            print_info "Removed temp file: $temp_file"
        fi
    done

    if [[ "$CLEANUP_NEEDED" == "true" && -f ".env" ]]; then
        rm -f ".env" || true
        print_info "Removed .env file"
    fi
}

function rollback_containers() {
    print_info "Rolling back containers..."
    for container in "${CREATED_CONTAINERS[@]}"; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            print_info "Removing container: $container"
            if [[ "$DRY_RUN" != "true" ]]; then
                docker rm -f "$container" >/dev/null 2>&1 || true
            else
                print_dry_run "docker rm -f $container"
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

# traps: ERR -> cleanup_and_exit with exit code, INT and TERM too
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
    --existing-postgres     Use existing PostgreSQL instance (default)
    --new-postgres          Deploy new PostgreSQL container
    --dockerhub             Pull image from Docker Hub instead of ACR
    --db-host HOST          Database host
    --db-port PORT          Database port (default: 5432)
    --db-user USER          Database username
    --db-pass PASS          Database password
    --db-name NAME          Database name
    --image IMAGE           Docker image name (can include registry)
    --port1 PORT            Host port for API 1 (default: $DEFAULT_PORT1)
    --port2 PORT            Host port for API 2 (default: $DEFAULT_PORT2)
    --acr-user USER         Azure Container Registry username
    --acr-pass PASS         Azure Container Registry password
    --create-config         Create a sample configuration file and exit

Environment:
    FORCE=yes               Skip interactive confirmation (CI usage)

EXAMPLES:
    $0 --dry-run
    FORCE=yes $0 --db-host localhost --db-user dxf_user --db-pass s3cr3t --db-name dxfdb --new-postgres
EOF
}

# ------------------------------
# Configuration Management
# ------------------------------
function load_config_file() {
    local config_file="$1"
    if [[ -f "$config_file" ]]; then
        print_info "Loading configuration from: $config_file"
        # Source the config file safely -- allow KEY=VALUE lines
        while IFS='=' read -r key value; do
            [[ $key =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            # Trim whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "${value:-}" | sed 's/^\s*"//' | sed 's/"\s*$//' | xargs)
            case "$key" in
                DB_HOST) DB_HOST="$value" ;;
                DB_PORT) DB_PORT="$value" ;;
                DB_USER) DB_USER="$value" ;;
                DB_PASS) DB_PASS="$value" ;;
                DB_NAME) DB_NAME="$value" ;;
                IMAGE_NAME) IMAGE_NAME="$value" ;;
                PORT1) PORT1="$value" ;;
                PORT2) PORT2="$value" ;;
                ACR_USER) ACR_USER="$value" ;;
                ACR_PASS) ACR_PASS="$value" ;;
                USE_EXISTING_POSTGRES) USE_EXISTING_POSTGRES="$value" ;;
                DEPLOY_FROM_DOCKERHUB) DEPLOY_FROM_DOCKERHUB="$value" ;;
            esac
        done < "$config_file"
        print_success "Configuration loaded successfully"
    else
        print_warning "Configuration file not found: $config_file"
    fi
}

function create_sample_config() {
    cat > "$CONFIG_FILE" << EOF
# DXF Export Deployment Configuration
DB_HOST=localhost
DB_PORT=5432
DB_USER=dxf_user
DB_PASS=secure_password
DB_NAME=dxf_database
IMAGE_NAME=$DEFAULT_IMAGE
PORT1=$DEFAULT_PORT1
PORT2=$DEFAULT_PORT2
ACR_USER=your_acr_username
ACR_PASS=your_acr_password
USE_EXISTING_POSTGRES=true
DEPLOY_FROM_DOCKERHUB=false
EOF
    print_success "Sample configuration created: $CONFIG_FILE"
}

# ------------------------------
# Port & Utility checks
# ------------------------------
function port_in_use() {
    local port=$1
    # prefer ss, fallback to netstat, lsof
    if command -v ss &>/dev/null; then
        ss -ltn "sport = :$port" | grep -q LISTEN || return $?
        return 0
    elif command -v netstat &>/dev/null; then
        netstat -tuln | grep -q ":$port " && return 0 || return 1
    elif command -v lsof &>/dev/null; then
        lsof -iTCP -sTCP:LISTEN -P -n | grep -q ":$port" && return 0 || return 1
    else
        # cannot determine
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
        # port_in_use returns 0 when listening
        if [[ $? -eq 0 ]]; then
            print_error "$port_name $port is already in use"
            return 1
        fi
    fi
    return 0
}

# ------------------------------
# Database connection test (uses .pgpass-compatible temp file)
# ------------------------------
function test_database_connection() {
    print_info "Testing database connection..."
    if [[ "$DRY_RUN" == "true" ]]; then
        print_dry_run "Test connection to $DB_HOST:$DB_PORT as $DB_USER"
        return 0
    fi

    if ! command -v psql &>/dev/null; then
        print_warning "psql client not found. Attempting to install the client..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -y && sudo apt-get install -y postgresql-client || true
        elif command -v yum &>/dev/null; then
            sudo yum install -y postgresql || true
        fi
    fi

    local pgpass_file
    pgpass_file=$(mktemp)
    TEMP_FILES+=("$pgpass_file")
    chmod 600 "$pgpass_file"
    # pgpass format: hostname:port:database:username:password
    echo "${DB_HOST}:${DB_PORT}:${DB_NAME}:${DB_USER}:${DB_PASS}" > "$pgpass_file"

    if PGPASSFILE="$pgpass_file" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
        print_success "Database connection successful"
        return 0
    else
        print_warning "Failed to connect to database. Please check credentials and connectivity."
        return 1
    fi
}

# ------------------------------
# Docker & OS detection
# ------------------------------
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
        print_warning "Unsupported package manager. Will not attempt to install packages automatically."
        PACKAGE_MANAGER=""
    fi
    print_info "Detected package manager: ${PACKAGE_MANAGER:-none}"
}

# ------------------------------
# Install Docker using Ubuntu's official repo when missing
# ------------------------------
function install_docker_on_ubuntu() {
    print_section "Installing Docker Engine on Ubuntu (official repo)"
    # Based on Docker's official install steps
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg lsb-release

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.gpg > /dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # configure daemon
    cat <<EOF | sudo tee /etc/docker/daemon.json > /dev/null
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m" },
  "storage-driver": "overlay2"
}
EOF

    if ! getent group docker > /dev/null; then
        sudo groupadd docker
    fi
    sudo usermod -aG docker $USER || true

    sudo systemctl daemon-reload || true
    sudo systemctl enable --now docker || true

    print_success "Docker installed and started"
}

function check_docker() {
    print_section "Checking Docker Installation"
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
        if [[ "$PACKAGE_MANAGER" != "brew" && -n "$PACKAGE_MANAGER" ]]; then
            print_info "Try: sudo systemctl start docker"
        fi
        exit 1
    fi
}

# ------------------------------
# PostgreSQL support
# ------------------------------
# Install PostgreSQL on server (with pgdg script for Ubuntu)
function install_postgres_on_server() {
    print_section "Installing PostgreSQL on server"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_dry_run "$UPDATE_CMD && $INSTALL_CMD postgresql postgresql-contrib"
        return 0
    fi

    detect_os
    if [[ "$PACKAGE_MANAGER" == "apt-get" ]]; then
        print_info "Installing PostgreSQL via apt and PGDG script (Ubuntu/Debian)"
        sudo apt-get update -y
        sudo apt-get install -y postgresql postgresql-contrib postgresql-common wget
        # Attempt to add PostgreSQL apt repo (script may fail on some systems; ignore errors)
        sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh >/dev/null 2>&1 || true
        sudo systemctl enable --now postgresql || true
        print_success "PostgreSQL installed and started on server"
    elif [[ -n "$PACKAGE_MANAGER" ]]; then
        $UPDATE_CMD
        $INSTALL_CMD postgresql postgresql-contrib || true
        if [[ "$PACKAGE_MANAGER" != "brew" ]]; then
            sudo systemctl enable --now postgresql || true
        fi
        print_success "PostgreSQL installed and started on server"
    else
        print_error "Cannot install PostgreSQL automatically on this OS. Please install manually."
        exit 1
    fi
}

function check_postgresql() {
    print_section "Checking PostgreSQL"
    if [[ "$USE_EXISTING_POSTGRES" == "true" ]]; then
        print_info "Using existing PostgreSQL instance"
        if [[ -n "$DB_HOST" && -n "$DB_USER" && -n "$DB_PASS" && -n "$DB_NAME" ]]; then
            if ! test_database_connection; then
                print_warning "Failed to connect to provided PostgreSQL instance."
                if [[ "$FORCE" == "yes" ]]; then
                    print_error "Non-interactive mode (FORCE=yes) and DB connection failed. Exiting."
                    exit 1
                fi
                echo ""
                echo "Choose an option to proceed:"
                echo "  1) Install PostgreSQL on this server (requires sudo)"
                echo "  2) Create PostgreSQL as a Docker container on this host"
                echo "  3) Exit deployment"
                read -p "Enter choice [1-3]: " choice
                case "$choice" in
                    1)
                        install_postgres_on_server
                        DB_HOST=${DB_HOST:-localhost}
                        sleep 5
                        if ! test_database_connection; then
                            print_error "PostgreSQL installed but connection still failing. Please verify credentials and access."
                            exit 1
                        fi
                        ;;
                    2)
                        print_info "Will deploy PostgreSQL container instead of using existing instance."
                        USE_EXISTING_POSTGRES=false
                        ;;
                    3)
                        print_error "Exiting due to PostgreSQL connectivity failure."
                        exit 1
                        ;;
                    *)
                        print_error "Invalid choice. Exiting."
                        exit 1
                        ;;
                esac
            fi
        else
            print_warning "Cannot test database connection - credentials not provided yet"
        fi
    else
        print_info "Will deploy PostgreSQL as a container"
        if docker ps -a --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER_NAME}$"; then
            print_warning "PostgreSQL container already exists: $POSTGRES_CONTAINER_NAME"
        fi
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
        print_dry_run "docker login $REGISTRY_NAME -u [ACR_USER]"
        return 0
    fi

    if echo "$ACR_PASS" | docker login "$REGISTRY_NAME" -u "$ACR_USER" --password-stdin; then
        print_success "Logged in to ACR successfully"
    else
        print_error "Failed to login to ACR. Please check credentials."
        exit 1
    fi
}

function pull_image() {
    print_section "Pulling Container Image"
    local full_image_name

    # Always prepend registry unless IMAGE_NAME already includes the registry
    if [[ "$IMAGE_NAME" == "$REGISTRY_NAME"* ]]; then
        full_image_name="$IMAGE_NAME"
    else
        if [[ "$DEPLOY_FROM_DOCKERHUB" == "true" ]]; then
            full_image_name="$IMAGE_NAME"
        else
            full_image_name="$REGISTRY_NAME/$IMAGE_NAME"
        fi
    fi

    print_info "Pulling image: $full_image_name"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_dry_run "docker pull $full_image_name"
        return 0
    fi

    if docker pull "$full_image_name"; then
        print_success "Image pulled successfully: $full_image_name"
    else
        print_error "Failed to pull image: $full_image_name"
        exit 1
    fi
}

# ------------------------------
# Environment Configuration
# ------------------------------
function create_env_file() {
    print_section "Creating Environment Configuration"
    local env_file=".env"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_dry_run "Create $env_file with database configuration"
        return 0
    fi

    print_info "Creating secure .env file..."
    cat > "$env_file" <<EOF
# DXF Export Service Configuration
# Generated on $(date)

DOTNET_ENVIRONMENT=Production
DBProvider=Postgres
DBConnection=Host=$DB_HOST;Port=$DB_PORT;Username=$DB_USER;Password=$DB_PASS;Database=$DB_NAME;

Logging__LogLevel__Default=Information
Logging__LogLevel__Microsoft=Warning

ASPNETCORE_URLS=http://+:5000;http://+:5001
EOF
    chmod 600 "$env_file"
    print_success "Environment file created with secure permissions"
}

# ------------------------------
# PostgreSQL container
# ------------------------------
function deploy_postgres_container() {
    print_section "Deploying PostgreSQL Container"
    if [[ "$USE_EXISTING_POSTGRES" == "true" ]]; then
        print_info "Skipping PostgreSQL deployment - using existing instance"
        return 0
    fi

    print_info "Deploying PostgreSQL container: $POSTGRES_CONTAINER_NAME"
    if docker ps -a --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER_NAME}$"; then
        if [[ "$MODE" == "update" ]]; then
            print_info "Removing existing PostgreSQL container for update"
            if [[ "$DRY_RUN" != "true" ]]; then
                docker rm -f "$POSTGRES_CONTAINER_NAME" >/dev/null 2>&1 || true
            else
                print_dry_run "docker rm -f $POSTGRES_CONTAINER_NAME"
            fi
        else
            print_warning "PostgreSQL container already exists. Use --update to replace it."
            return 0
        fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        print_dry_run "docker run -d --name $POSTGRES_CONTAINER_NAME -e POSTGRES_DB=$DB_NAME -e POSTGRES_USER=$DB_USER -p $DB_PORT:5432 postgres:15"
        return 0
    fi

    if docker run -d \
        --name "$POSTGRES_CONTAINER_NAME" \
        --restart unless-stopped \
        -e POSTGRES_DB="$DB_NAME" \
        -e POSTGRES_USER="$DB_USER" \
        -e POSTGRES_PASSWORD="$DB_PASS" \
        -p "$DB_PORT:5432" \
        -v "${POSTGRES_CONTAINER_NAME}_data:/var/lib/postgresql/data" \
        postgres:15; then

        CREATED_CONTAINERS+=("$POSTGRES_CONTAINER_NAME")
        print_success "PostgreSQL container deployed successfully"
        print_info "Waiting for PostgreSQL to be ready..."
        sleep 10
        test_database_connection || true
    else
        print_error "Failed to deploy PostgreSQL container"
        exit 1
    fi
}

# ------------------------------
# Application container
# ------------------------------
function wait_for_container_health() {
    print_info "Waiting for container to be healthy..."
    for i in {1..5}; do
        local health_status
        health_status=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
        case "$health_status" in
            "healthy")
                print_success "Container is healthy and ready"
                return 0
                ;;
            "unhealthy")
                print_error "Container health check failed"
                docker logs --tail 40 "$CONTAINER_NAME" || true
                exit 1
                ;;
            "starting"|"unknown")
                print_info "Health check in progress... ($i/5)"
                sleep 5
                ;;
        esac
    done
    print_warning "Health check timeout - container may still be starting"
    print_info "Check container logs: docker logs $CONTAINER_NAME"
}

function deploy_application() {
    print_section "Deploying DXF Export Application"
    local full_image_name

    # Use same robust logic as pull_image(): always prepend registry unless image starts with registry
    if [[ -n "$IMAGE_NAME" && "$IMAGE_NAME" == "$REGISTRY_NAME"* ]]; then
        full_image_name="$IMAGE_NAME"
    else
        if [[ -n "$IMAGE_NAME" && "$DEPLOY_FROM_DOCKERHUB" == "true" ]]; then
            full_image_name="$IMAGE_NAME"
        else
            full_image_name="$REGISTRY_NAME/${IMAGE_NAME:-$DEFAULT_IMAGE}"
        fi
    fi

    # Ensure we show what image we're about to run
    print_info "Will run image: $full_image_name"

    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        if [[ "$MODE" == "update" ]]; then
            print_info "Removing existing container for update: $CONTAINER_NAME"
            if [[ "$DRY_RUN" != "true" ]]; then
                docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
            else
                print_dry_run "docker rm -f $CONTAINER_NAME"
            fi
        else
            print_warning "Container already exists: $CONTAINER_NAME. Use --update to replace it."
            return 0
        fi
    fi

    print_info "Starting DXF Export Service container..."
    if [[ "$DRY_RUN" == "true" ]]; then
        print_dry_run "docker run -d --name $CONTAINER_NAME --env-file .env -p $PORT1:5000 -p $PORT2:5001 $full_image_name"
        return 0
    fi

    if docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --memory="1g" \
        --cpus="1.0" \
        --env-file .env \
        -p "$PORT1:5000" \
        -p "$PORT2:5001" \
        --health-cmd="curl -f http://localhost:5000 || exit 1" \
        --health-interval=30s \
        --health-timeout=10s \
        --health-retries=3 \
        "$full_image_name"; then

        CREATED_CONTAINERS+=("$CONTAINER_NAME")
        print_success "DXF Export Service container started successfully"
        wait_for_container_health || true
        print_info "Container status:"
        docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    else
        print_error "Failed to start DXF Export Service container"
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
            --existing-postgres)
                USE_EXISTING_POSTGRES=true
                shift
                ;;
            --new-postgres)
                USE_EXISTING_POSTGRES=false
                shift
                ;;
            --dockerhub)
                DEPLOY_FROM_DOCKERHUB=true
                shift
                ;;
            --db-host)
                DB_HOST="$2"
                shift 2
                ;;
            --db-port)
                DB_PORT="$2"
                shift 2
                ;;
            --db-user)
                DB_USER="$2"
                shift 2
                ;;
            --db-pass)
                DB_PASS="$2"
                shift 2
                ;;
            --db-name)
                DB_NAME="$2"
                shift 2
                ;;
            --image)
                IMAGE_NAME="$2"
                shift 2
                ;;
            --port1)
                PORT1="$2"
                shift 2
                ;;
            --port2)
                PORT2="$2"
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

    # Set default mode
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
    [[ -z "$DB_HOST" ]] && missing_params+=("Database Host")
    [[ -z "$DB_USER" ]] && missing_params+=("Database User")
    [[ -z "$DB_PASS" ]] && missing_params+=("Database Password")
    [[ -z "$DB_NAME" ]] && missing_params+=("Database Name")
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

    # Collect missing params interactively (only if not in FORCE=yes and running in tty)
    if [[ -t 0 && "$FORCE" != "yes" ]]; then
        # prompt only for missing ones
        if [[ -z "$DB_HOST" ]]; then
            read -p "Enter Database Host: " DB_HOST
        fi
        if [[ -z "$DB_PORT" ]]; then
            read -p "Enter Database Port (default: 5432): " input_port
            DB_PORT=${input_port:-5432}
        fi
        if [[ -z "$DB_USER" ]]; then
            read -p "Enter Database Username: " DB_USER
        fi
        if [[ -z "$DB_PASS" ]]; then
            read -s -p "Enter Database Password: " DB_PASS
            echo ""
        fi
        if [[ -z "$DB_NAME" ]]; then
            read -p "Enter Database Name: " DB_NAME
        fi
        if [[ -z "$IMAGE_NAME" ]]; then
            read -p "Enter Image Name (default: $DEFAULT_IMAGE): " IMAGE_NAME
            IMAGE_NAME=${IMAGE_NAME:-$DEFAULT_IMAGE}
        fi
        if [[ -z "$PORT1" ]]; then
            read -p "Enter host port for API 1 (default: $DEFAULT_PORT1): " PORT1
            PORT1=${PORT1:-$DEFAULT_PORT1}
        fi
        if [[ -z "$PORT2" ]]; then
            read -p "Enter host port for API 2 (default: $DEFAULT_PORT2): " PORT2
            PORT2=${PORT2:-$DEFAULT_PORT2}
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

    if ! validate_required_params; then
        print_error "Parameter validation failed"
        exit 1
    fi

    if ! validate_port "$PORT1" "Port 1" || ! validate_port "$PORT2" "Port 2"; then
        exit 1
    fi

    if [[ "$USE_EXISTING_POSTGRES" != "true" ]]; then
        if ! validate_port "$DB_PORT" "Database Port"; then
            exit 1
        fi
    fi

    print_info "Configuration Summary:"
    print_info "  Mode: $MODE"
    print_info "  Database: $DB_HOST:$DB_PORT ($DB_NAME)"
    print_info "  Image: ${IMAGE_NAME:-$DEFAULT_IMAGE}"
    print_info "  Ports: $PORT1, $PORT2"
    print_info "  Use existing PostgreSQL: $USE_EXISTING_POSTGRES"
    print_info "  Deploy from Docker Hub: $DEPLOY_FROM_DOCKERHUB"

    if [[ "$DRY_RUN" != "true" && "$FORCE" != "yes" && -t 0 ]]; then
        read -p "Continue with deployment? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            print_info "Deployment cancelled by user"
            exit 0
        fi
    fi

    check_docker
    check_postgresql

    if [[ "$USE_EXISTING_POSTGRES" != "true" ]]; then
        deploy_postgres_container
    fi

    login_to_registry
    pull_image
    create_env_file
    deploy_application

    CLEANUP_NEEDED=false

    print_section "Deployment Continued Successfully"
    print_success "DXF Export Service is now running"
    print_info "API endpoints:"
    print_info "  - http://localhost:$PORT1"
    print_info "  - http://localhost:$PORT2"
    print_info "Log file: $LOG_FILE"
    if [[ "$USE_EXISTING_POSTGRES" != "true" ]]; then
        print_info "PostgreSQL container: $POSTGRES_CONTAINER_NAME"
    fi
}

# Start
parse_arguments "$@"
main
