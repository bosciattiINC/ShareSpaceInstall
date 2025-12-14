#!/bin/bash
# SharedSpace - Installation Script (DockerHub Edition)
#
# Usage:
#   curl -fsSL https://install.sharespace.cc/install.sh | sudo bash
#
# This script:
#   1. Installs Docker and Docker Compose (if needed)
#   2. Creates directory structure
#   3. Sets up docker-compose.yml with all services
#   4. Pulls and starts containers from DockerHub
#   5. Creates systemd service for auto-start
#   6. Configures mDNS (sharespace.local)
#
# License key is entered via the web UI after installation.

set -e

# Configuration
DOCKERHUB_IMAGE="yessir1232/sharespace:latest"

# Use the real user's home directory (not root's when running with sudo)
if [ -n "$SUDO_USER" ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    REAL_USER="$SUDO_USER"
else
    REAL_HOME="$HOME"
    REAL_USER="$(whoami)"
fi

INSTALL_DIR="$REAL_HOME/share-space"
DATA_DIR="$INSTALL_DIR/data"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check and install Docker
install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker is already installed"
        docker --version
    else
        log_info "Installing Docker..."

        # Install prerequisites
        apt-get update
        apt-get install -y \
            apt-transport-https \
            ca-certificates \
            curl \
            gnupg \
            lsb-release

        # Add Docker's official GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        # Set up stable repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
            tee /etc/apt/sources.list.d/docker.list > /dev/null

        # Install Docker Engine
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        # Start and enable Docker
        systemctl start docker
        systemctl enable docker

        # Add the real user to docker group
        if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
            usermod -aG docker "$REAL_USER"
            log_info "Added $REAL_USER to docker group (logout/login required for non-sudo docker access)"
        fi

        log_success "Docker installed successfully"
    fi

    # Ensure docker compose is available
    if ! docker compose version &> /dev/null; then
        log_info "Installing Docker Compose plugin..."
        apt-get install -y docker-compose-plugin
    fi
}

# Create directory structure
create_directories() {
    log_info "Creating installation directories..."

    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR"
    mkdir -p "$DATA_DIR/signal-cli"

    # Set ownership to real user
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        chown -R "$REAL_USER:$REAL_USER" "$INSTALL_DIR"
    fi

    log_success "Directories created at $INSTALL_DIR"
}

# Detect Docker API version
detect_docker_api_version() {
    # Get the Docker API version from the daemon
    DOCKER_API_VERSION=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || echo "1.41")
    log_info "Detected Docker API version: $DOCKER_API_VERSION"
}

# Create docker-compose.yml
create_docker_compose() {
    log_info "Creating docker-compose.yml..."

    # Detect Docker API version for Watchtower compatibility
    detect_docker_api_version

    cat > "$INSTALL_DIR/docker-compose.yml" << EOF
services:
  # Signal CLI REST API - Messaging service
  signal-api:
    image: bbernhard/signal-cli-rest-api:latest
    container_name: signal-api
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - ./data/signal-cli:/home/.local/share/signal-cli
    environment:
      - MODE=normal
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8080/v1/about || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    networks:
      - sharespace-network

  # Main SharedSpace Application
  sharespace-app:
    image: ${DOCKERHUB_IMAGE}
    container_name: sharespace
    restart: unless-stopped
    depends_on:
      signal-api:
        condition: service_healthy
    environment:
      - SIGNAL_API_BASE=http://signal-api:8080
      - EXTERNAL_PORT=80
    ports:
      - "80:5000"
    volumes:
      - ./data:/app/data
    networks:
      - sharespace-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  # Watchtower - Automatic container updates (checks every 3 minutes)
  # NOTE: Watchtower is NOT on sharespace-network because it only needs Docker socket access.
  # Being on the same network as containers it updates can cause disconnection issues.
  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    network_mode: none
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=180
      - WATCHTOWER_INCLUDE_STOPPED=false
      - WATCHTOWER_LABEL_ENABLE=true
      - DOCKER_API_VERSION=${DOCKER_API_VERSION}

  # mDNS - Local network discovery (sharespace.local)
  mdns:
    image: flungo/avahi
    container_name: sharespace-mdns
    restart: unless-stopped
    network_mode: host
    environment:
      - SERVER_HOST_NAME=sharespace
    healthcheck:
      test: ["CMD-SHELL", "pgrep avahi-daemon > /dev/null"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

  # Autoheal - Automatically restart unhealthy containers
  autoheal:
    image: willfarrell/autoheal
    container_name: autoheal
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - AUTOHEAL_CONTAINER_LABEL=all

networks:
  sharespace-network:
    driver: bridge
EOF

    log_success "docker-compose.yml created"
}

# Pull and start containers
start_application() {
    log_info "Pulling Docker images..."

    cd "$INSTALL_DIR"
    docker compose pull

    log_info "Starting application..."
    docker compose up -d

    # Wait for containers to start
    log_info "Waiting for services to start..."
    sleep 10

    # Check if main app is running
    if docker compose ps | grep -q "sharespace.*running\|sharespace.*Up"; then
        log_success "Application started successfully!"
    else
        log_warn "Application may still be starting. Check status with:"
        echo "  docker compose -f $INSTALL_DIR/docker-compose.yml ps"
        echo "  docker logs sharespace"
    fi
}

# Create systemd service for auto-start
create_systemd_service() {
    log_info "Creating systemd service for auto-start..."

    cat > /etc/systemd/system/sharespace.service << EOF
[Unit]
Description=SharedSpace Chore Management
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sharespace.service

    log_success "Systemd service created and enabled"
}

# Generate installation ID
save_installation_info() {
    log_info "Saving installation information..."

    # Generate installation ID
    INSTALLATION_ID=$(cat /etc/machine-id 2>/dev/null || uuidgen || hostname | md5sum | cut -d' ' -f1)
    echo "$INSTALLATION_ID" > "$DATA_DIR/installation_id"

    # Set ownership
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        chown "$REAL_USER:$REAL_USER" "$DATA_DIR/installation_id"
    fi

    log_success "Installation info saved"
}

# Print completion message
print_completion() {
    local IP=$(hostname -I | awk '{print $1}')

    echo ""
    echo "=============================================="
    echo -e "${GREEN}Installation Complete!${NC}"
    echo "=============================================="
    echo ""
    echo "Access the application at:"
    echo -e "  ${GREEN}http://${IP}${NC}"
    echo -e "  ${GREEN}http://sharespace.local${NC}"
    echo ""
    echo "Useful commands:"
    echo "  View logs:        docker logs -f sharespace"
    echo "  View all logs:    docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
    echo "  Restart:          docker compose -f $INSTALL_DIR/docker-compose.yml restart"
    echo "  Stop:             docker compose -f $INSTALL_DIR/docker-compose.yml down"
    echo "  Start:            docker compose -f $INSTALL_DIR/docker-compose.yml up -d"
    echo ""
    echo "Data directory: $DATA_DIR"
    echo ""
    echo -e "${YELLOW}NEXT STEPS:${NC}"
    echo "  1. Open the web interface at one of the URLs above"
    echo "  2. Enter your license key"
    echo "  3. Complete the initial setup wizard"
    echo "  4. Link your Signal group for automated messaging"
    echo ""
    echo "Updates are automatic via Watchtower (checks every 3 minutes)"
    echo ""
}

# Main installation flow
main() {
    echo ""
    echo "=============================================="
    echo "SharedSpace - Installer"
    echo "=============================================="
    echo ""

    check_root
    install_docker
    create_directories
    create_docker_compose
    save_installation_info
    start_application
    create_systemd_service

    print_completion
}

# Run main
main "$@"
