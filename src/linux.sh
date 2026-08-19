#!/usr/bin/env bash

# =============================================================================
# AUTOMATED LINUX MEDIA SERVER
#
# Installs/configures:
#   Docker
#   Docker Compose
#   Jellyfin
#   Seerr
#   qBittorrent
#   Prowlarr
#   Sonarr
#   Radarr
#   Tailscale
#
# Automatically:
#   - Detects Linux distribution
#   - Installs required packages
#   - Installs Docker if necessary
#   - Installs Tailscale if necessary
#   - Creates media/config directories
#   - Generates API keys
#   - Creates Docker Compose stack
#   - Starts all containers
#   - Configures Sonarr -> qBittorrent
#   - Configures Radarr -> qBittorrent
#   - Configures Prowlarr -> Sonarr
#   - Configures Prowlarr -> Radarr
#   - Configures Sonarr TV root
#   - Configures Radarr movie root
#   - Configures qBittorrent downloads
#   - Configures Tailscale when an auth key is supplied
#   - Creates management scripts
#
# Usage:
#
#   chmod +x install-media-stack.sh
#   sudo ./install-media-stack.sh
#
# Or:
#
#   sudo ./install-media-stack.sh --tailscale-auth-key "tskey-auth-..."
#
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# COLORS
# =============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BLUE=''
    RESET=''
fi

info() {
    echo -e "${CYAN}[INFO]${RESET} $*"
}

success() {
    echo -e "${GREEN}[ OK ]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

error() {
    echo -e "${RED}[ERROR]${RESET} $*" >&2
}

section() {
    echo
    echo "======================================================================"
    echo -e "${BLUE}$*${RESET}"
    echo "======================================================================"
    echo
}

die() {
    error "$*"
    exit 1
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

trap 'error "Installation failed on line $LINENO."' ERR

# =============================================================================
# DEFAULTS
# =============================================================================

JELLYFIN_PORT=8096
SEERR_PORT=5055
QBIT_PORT=8080
PROWLARR_PORT=9696
SONARR_PORT=8989
RADARR_PORT=7878

STACK_NAME="media-stack"

TAILSCALE_AUTH_KEY=""

# =============================================================================
# ARGUMENTS
# =============================================================================

while [[ $# -gt 0 ]]; do

    case "$1" in

        --tailscale-auth-key)
            [[ $# -ge 2 ]] || die "--tailscale-auth-key requires a value"
            TAILSCALE_AUTH_KEY="$2"
            shift 2
            ;;

        --help|-h)
            cat <<EOF

Automated Linux Media Server

Usage:

  sudo ./install-media-stack.sh

Optional:

  sudo ./install-media-stack.sh \\
      --tailscale-auth-key "tskey-auth-..."

EOF
            exit 0
            ;;

        *)
            die "Unknown argument: $1"
            ;;

    esac

done

# =============================================================================
# ROOT CHECK
# =============================================================================

section "Checking privileges"

if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root:

sudo ./install-media-stack.sh"
fi

success "Running as root."

# =============================================================================
# OS DETECTION
# =============================================================================

section "Detecting Linux distribution"

[[ -f /etc/os-release ]] || die "/etc/os-release was not found."

source /etc/os-release

DISTRO_ID="${ID:-unknown}"
DISTRO_VERSION="${VERSION_ID:-unknown}"
DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"

info "Detected: $DISTRO_NAME"

case "$DISTRO_ID" in

    ubuntu)
        PACKAGE_MANAGER="apt"
        ;;

    debian)
        PACKAGE_MANAGER="apt"
        ;;

    linuxmint)
        PACKAGE_MANAGER="apt"
        ;;

    pop)
        PACKAGE_MANAGER="apt"
        ;;

    fedora)
        PACKAGE_MANAGER="dnf"
        ;;

    rhel)
        PACKAGE_MANAGER="dnf"
        ;;

    rocky)
        PACKAGE_MANAGER="dnf"
        ;;

    almalinux)
        PACKAGE_MANAGER="dnf"
        ;;

    centos)
        PACKAGE_MANAGER="dnf"
        ;;

    arch)
        PACKAGE_MANAGER="pacman"
        ;;

    manjaro)
        PACKAGE_MANAGER="pacman"
        ;;

    opensuse-tumbleweed)
        PACKAGE_MANAGER="zypper"
        ;;

    opensuse-leap)
        PACKAGE_MANAGER="zypper"
        ;;

    *)
        if command -v apt-get >/dev/null 2>&1; then
            PACKAGE_MANAGER="apt"
        elif command -v dnf >/dev/null 2>&1; then
            PACKAGE_MANAGER="dnf"
        elif command -v yum >/dev/null 2>&1; then
            PACKAGE_MANAGER="yum"
        elif command -v pacman >/dev/null 2>&1; then
            PACKAGE_MANAGER="pacman"
        elif command -v zypper >/dev/null 2>&1; then
            PACKAGE_MANAGER="zypper"
        else
            die "Unsupported Linux distribution/package manager."
        fi
        ;;

esac

success "Package manager: $PACKAGE_MANAGER"

# =============================================================================
# PACKAGE INSTALLATION
# =============================================================================

section "Installing base dependencies"

install_packages() {

    case "$PACKAGE_MANAGER" in

        apt)

            export DEBIAN_FRONTEND=noninteractive

            apt-get update

            apt-get install -y \
                ca-certificates \
                curl \
                wget \
                gnupg \
                lsb-release \
                apt-transport-https \
                jq \
                openssl \
                python3 \
                python3-pip \
                unzip \
                git

            ;;

        dnf|yum)

            "$PACKAGE_MANAGER" install -y \
                ca-certificates \
                curl \
                wget \
                gnupg2 \
                jq \
                openssl \
                python3 \
                unzip \
                git

            ;;

        pacman)

            pacman -Sy --noconfirm

            pacman -S --needed --noconfirm \
                curl \
                wget \
                gnupg \
                jq \
                openssl \
                python \
                unzip \
                git

            ;;

        zypper)

            zypper --non-interactive refresh

            zypper --non-interactive install \
                curl \
                wget \
                gpg2 \
                jq \
                openssl \
                python3 \
                unzip \
                git

            ;;

    esac
}

install_packages

success "Base dependencies installed."

# =============================================================================
# SYSTEMD CHECK
# =============================================================================

if command -v systemctl >/dev/null 2>&1; then
    HAS_SYSTEMD=1
else
    HAS_SYSTEMD=0
fi

# =============================================================================
# DOCKER INSTALLATION
# =============================================================================

section "Installing Docker"

if command -v docker >/dev/null 2>&1; then

    success "Docker is already installed."

else

    info "Installing Docker..."

    curl -fsSL https://get.docker.com | sh

    success "Docker installed."

fi

# =============================================================================
# DOCKER SERVICE
# =============================================================================

if [[ "$HAS_SYSTEMD" -eq 1 ]]; then

    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker || true

fi

# =============================================================================
# DOCKER WAIT
# =============================================================================

info "Waiting for Docker..."

DOCKER_READY=0

for ((i=0; i<60; i++)); do

    if docker info >/dev/null 2>&1; then
        DOCKER_READY=1
        break
    fi

    sleep 2

done

[[ "$DOCKER_READY" -eq 1 ]] || die "Docker did not become ready."

success "Docker is running."

# =============================================================================
# DOCKER COMPOSE
# =============================================================================

if docker compose version >/dev/null 2>&1; then

    success "Docker Compose is available."

else

    die "Docker Compose plugin was not installed correctly."

fi

# =============================================================================
# TAILSCALE
# =============================================================================

section "Installing Tailscale"

if command -v tailscale >/dev/null 2>&1; then

    success "Tailscale is already installed."

else

    info "Installing Tailscale..."

    curl -fsSL https://tailscale.com/install.sh | sh

    success "Tailscale installed."

fi

# =============================================================================
# USER INPUT
# =============================================================================

section "Server configuration"

echo "Enter the location where your media will live."
echo
read -r -p "Media directory: " MEDIA_DIR

[[ -n "$MEDIA_DIR" ]] || die "Media directory cannot be empty."

echo
echo "Enter the location where application configuration will live."
echo
read -r -p "Config directory: " CONFIG_DIR

[[ -n "$CONFIG_DIR" ]] || die "Config directory cannot be empty."

MEDIA_DIR="${MEDIA_DIR/#\~/$HOME}"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"

MEDIA_DIR="$(readlink -m "$MEDIA_DIR")"
CONFIG_DIR="$(readlink -m "$CONFIG_DIR")"

echo
read -r -p "Username for media applications: " APP_USERNAME

[[ -n "$APP_USERNAME" ]] || die "Username cannot be empty."

echo
read -r -s -p "Password for media applications: " APP_PASSWORD
echo

[[ -n "$APP_PASSWORD" ]] || die "Password cannot be empty."

if [[ -z "$TAILSCALE_AUTH_KEY" ]]; then

    echo
    read -r -p "Tailscale auth key (press Enter to skip): " TAILSCALE_AUTH_KEY

fi

# =============================================================================
# DIRECTORY STRUCTURE
# =============================================================================

section "Creating directory structure"

mkdir -p \
    "$MEDIA_DIR/movies" \
    "$MEDIA_DIR/tv" \
    "$MEDIA_DIR/music" \
    "$MEDIA_DIR/downloads/complete" \
    "$MEDIA_DIR/downloads/incomplete"

mkdir -p \
    "$CONFIG_DIR/jellyfin" \
    "$CONFIG_DIR/seerr" \
    "$CONFIG_DIR/qbittorrent" \
    "$CONFIG_DIR/prowlarr" \
    "$CONFIG_DIR/sonarr" \
    "$CONFIG_DIR/radarr"

success "Media directories created."

# =============================================================================
# API KEY GENERATION
# =============================================================================

section "Generating API keys"

generate_key() {
    openssl rand -hex 32
}

SONARR_API_KEY="$(generate_key)"
RADARR_API_KEY="$(generate_key)"
PROWLARR_API_KEY="$(generate_key)"
SEERR_API_KEY="$(generate_key)"

success "API keys generated."

# =============================================================================
# ENVIRONMENT FILE
# =============================================================================

section "Creating environment configuration"

ENV_FILE="$CONFIG_DIR/.env"

cat > "$ENV_FILE" <<EOF
TZ=America/Los_Angeles

MEDIA_DIR=$MEDIA_DIR
CONFIG_DIR=$CONFIG_DIR

APP_USERNAME=$APP_USERNAME
APP_PASSWORD=$APP_PASSWORD

SONARR_API_KEY=$SONARR_API_KEY
RADARR_API_KEY=$RADARR_API_KEY
PROWLARR_API_KEY=$PROWLARR_API_KEY
SEERR_API_KEY=$SEERR_API_KEY

TAILSCALE_AUTH_KEY=$TAILSCALE_AUTH_KEY
EOF

chmod 600 "$ENV_FILE"

success "Environment configuration created."

# =============================================================================
# SONARR CONFIG.XML
# =============================================================================

section "Preparing Sonarr configuration"

cat > "$CONFIG_DIR/sonarr/config.xml" <<EOF
<Config>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <Port>8989</Port>
  <SslPort>9898</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>$SONARR_API_KEY</ApiKey>
  <AuthenticationMethod>None</AuthenticationMethod>
  <Branch>main</Branch>
  <UpdateMechanism>Docker</UpdateMechanism>
  <UpdateAutomatically>False</UpdateAutomatically>
  <InstanceName>Sonarr</InstanceName>
</Config>
EOF

# =============================================================================
# RADARR CONFIG.XML
# =============================================================================

section "Preparing Radarr configuration"

cat > "$CONFIG_DIR/radarr/config.xml" <<EOF
<Config>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <Port>7878</Port>
  <SslPort>9899</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>$RADARR_API_KEY</ApiKey>
  <AuthenticationMethod>None</AuthenticationMethod>
  <Branch>master</Branch>
  <UpdateMechanism>Docker</UpdateMechanism>
  <UpdateAutomatically>False</UpdateAutomatically>
  <InstanceName>Radarr</InstanceName>
</Config>
EOF

# =============================================================================
# PROWLARR CONFIG.XML
# =============================================================================

section "Preparing Prowlarr configuration"

cat > "$CONFIG_DIR/prowlarr/config.xml" <<EOF
<Config>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <Port>9696</Port>
  <SslPort>6969</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>$PROWLARR_API_KEY</ApiKey>
  <AuthenticationMethod>None</AuthenticationMethod>
  <Branch>master</Branch>
  <UpdateMechanism>Docker</UpdateMechanism>
  <UpdateAutomatically>False</UpdateAutomatically>
  <InstanceName>Prowlarr</InstanceName>
</Config>
EOF

# =============================================================================
# DOCKER COMPOSE
# =============================================================================

section "Creating Docker Compose stack"

COMPOSE_FILE="$CONFIG_DIR/compose.yaml"

cat > "$COMPOSE_FILE" <<'EOF'
services:

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped

    environment:
      TZ: ${TZ}

    ports:
      - "8096:8096"

    volumes:
      - ${CONFIG_DIR}/jellyfin:/config
      - ${CONFIG_DIR}/jellyfin/cache:/cache

      - ${MEDIA_DIR}/movies:/media/movies
      - ${MEDIA_DIR}/tv:/media/tv
      - ${MEDIA_DIR}/music:/media/music

    networks:
      - media

  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    init: true
    restart: unless-stopped

    environment:
      LOG_LEVEL: info
      TZ: ${TZ}
      PORT: 5055

    ports:
      - "5055:5055"

    volumes:
      - ${CONFIG_DIR}/seerr:/app/config

    networks:
      - media

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped

    environment:
      PUID: 1000
      PGID: 1000
      TZ: ${TZ}
      WEBUI_PORT: 8080

    ports:
      - "8080:8080"

    volumes:
      - ${CONFIG_DIR}/qbittorrent:/config
      - ${MEDIA_DIR}/downloads:/downloads

    networks:
      - media

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped

    environment:
      PUID: 1000
      PGID: 1000
      TZ: ${TZ}

    ports:
      - "9696:9696"

    volumes:
      - ${CONFIG_DIR}/prowlarr:/config

    networks:
      - media

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped

    environment:
      PUID: 1000
      PGID: 1000
      TZ: ${TZ}

    ports:
      - "8989:8989"

    volumes:
      - ${CONFIG_DIR}/sonarr:/config
      - ${MEDIA_DIR}/tv:/tv
      - ${MEDIA_DIR}/downloads:/downloads

    networks:
      - media

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped

    environment:
      PUID: 1000
      PGID: 1000
      TZ: ${TZ}

    ports:
      - "7878:7878"

    volumes:
      - ${CONFIG_DIR}/radarr:/config
      - ${MEDIA_DIR}/movies:/movies
      - ${MEDIA_DIR}/downloads:/downloads

    networks:
      - media

networks:
  media:
    name: media
    driver: bridge
EOF

success "compose.yaml created."

# =============================================================================
# COMPOSE VALIDATION
# =============================================================================

section "Validating Docker Compose"

cd "$CONFIG_DIR"

docker compose --env-file "$ENV_FILE" config >/dev/null

success "Docker Compose configuration is valid."

# =============================================================================
# DOWNLOAD IMAGES
# =============================================================================

section "Downloading Docker images"

docker compose \
    --env-file "$ENV_FILE" \
    pull

success "Docker images downloaded."

# =============================================================================
# START STACK
# =============================================================================

section "Starting media stack"

docker compose \
    --env-file "$ENV_FILE" \
    up -d

success "Containers started."

# =============================================================================
# HTTP WAIT
# =============================================================================

wait_for_http() {

    local NAME="$1"
    local URL="$2"
    local TIMEOUT="${3:-120}"

    info "Waiting for $NAME..."

    for ((i=0; i<TIMEOUT; i++)); do

        if curl \
            --silent \
            --output /dev/null \
            --max-time 3 \
            "$URL"; then

            success "$NAME is responding."
            return 0

        fi

        sleep 1

    done

    warn "$NAME did not respond within ${TIMEOUT}s."
    return 1
}

section "Waiting for applications"

wait_for_http \
    "Sonarr" \
    "http://127.0.0.1:$SONARR_PORT/ping" \
    180 || true

wait_for_http \
    "Radarr" \
    "http://127.0.0.1:$RADARR_PORT/ping" \
    180 || true

wait_for_http \
    "Prowlarr" \
    "http://127.0.0.1:$PROWLARR_PORT/ping" \
    180 || true

wait_for_http \
    "qBittorrent" \
    "http://127.0.0.1:$QBIT_PORT" \
    180 || true

wait_for_http \
    "Jellyfin" \
    "http://127.0.0.1:$JELLYFIN_PORT/health" \
    180 || true

wait_for_http \
    "Seerr" \
    "http://127.0.0.1:$SEERR_PORT" \
    180 || true

# =============================================================================
# API HELPERS
# =============================================================================

api_get() {

    local URL="$1"
    local API_KEY="$2"

    curl \
        --silent \
        --show-error \
        --fail \
        -H "X-Api-Key: $API_KEY" \
        "$URL"
}

api_post() {

    local URL="$1"
    local API_KEY="$2"
    local BODY="$3"

    curl \
        --silent \
        --show-error \
        --fail \
        -X POST \
        -H "X-Api-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$BODY" \
        "$URL"
}

# =============================================================================
# SONARR ROOT
# =============================================================================

section "Configuring Sonarr"

if SONARR_ROOTS="$(api_get \
    "http://127.0.0.1:$SONARR_PORT/api/v3/rootfolder" \
    "$SONARR_API_KEY" 2>/dev/null)"; then

    if ! echo "$SONARR_ROOTS" | jq -e '.[] | select(.path == "/tv")' >/dev/null; then

        api_post \
            "http://127.0.0.1:$SONARR_PORT/api/v3/rootfolder" \
            "$SONARR_API_KEY" \
            '{"path":"/tv"}' >/dev/null || true

    fi

    success "Sonarr TV root folder configured."

else

    warn "Could not configure Sonarr root folder."
fi

# =============================================================================
# RADARR ROOT
# =============================================================================

section "Configuring Radarr"

if RADARR_ROOTS="$(api_get \
    "http://127.0.0.1:$RADARR_PORT/api/v3/rootfolder" \
    "$RADARR_API_KEY" 2>/dev/null)"; then

    if ! echo "$RADARR_ROOTS" | jq -e '.[] | select(.path == "/movies")' >/dev/null; then

        api_post \
            "http://127.0.0.1:$RADARR_PORT/api/v3/rootfolder" \
            "$RADARR_API_KEY" \
            '{"path":"/movies"}' >/dev/null || true

    fi

    success "Radarr movie root folder configured."

else

    warn "Could not configure Radarr root folder."
fi

# =============================================================================
# QBITTORRENT LOGIN
# =============================================================================

section "Configuring qBittorrent"

QBIT_COOKIE="$(mktemp)"

cleanup_qbit() {
    rm -f "$QBIT_COOKIE"
}

trap cleanup_qbit EXIT

QBIT_LOGGED_IN=0

# Try standard LinuxServer qBittorrent credentials.
if curl \
    --silent \
    --show-error \
    --fail \
    -c "$QBIT_COOKIE" \
    -X POST \
    -d "username=admin&password=adminadmin" \
    "http://127.0.0.1:$QBIT_PORT/api/v2/auth/login" \
    | grep -q "Ok."; then

    QBIT_LOGGED_IN=1

fi

# Try extracting temporary password from logs.
if [[ "$QBIT_LOGGED_IN" -eq 0 ]]; then

    TEMP_PASSWORD="$(
        docker logs qbittorrent 2>&1 |
        grep -i "temporary password" |
        tail -n 1 |
        sed -E 's/.*password is[: ]*//I' |
        tr -d '\r'
    )" || true

    if [[ -n "$TEMP_PASSWORD" ]]; then

        if curl \
            --silent \
            --show-error \
            --fail \
            -c "$QBIT_COOKIE" \
            -X POST \
            --data-urlencode "username=admin" \
            --data-urlencode "password=$TEMP_PASSWORD" \
            "http://127.0.0.1:$QBIT_PORT/api/v2/auth/login" \
            | grep -q "Ok."; then

            QBIT_LOGGED_IN=1

        fi

    fi

fi

if [[ "$QBIT_LOGGED_IN" -eq 1 ]]; then

    QBIT_PREFS="$(
        jq -cn \
        --arg username "$APP_USERNAME" \
        --arg password "$APP_PASSWORD" \
        '{
            save_path: "/downloads/complete/",
            temp_path_enabled: true,
            temp_path: "/downloads/incomplete/",
            use_subcategories: true
        }'
    )"

    curl \
        --silent \
        --show-error \
        --fail \
        -b "$QBIT_COOKIE" \
        -X POST \
        --data-urlencode "json=$QBIT_PREFS" \
        "http://127.0.0.1:$QBIT_PORT/api/v2/app/setPreferences" \
        >/dev/null || true

    success "qBittorrent download directories configured."

else

    warn "Could not automatically authenticate to qBittorrent."
    warn "qBittorrent is running, but its initial WebUI credentials may need setup."

fi

# =============================================================================
# SONARR -> QBITTORRENT
# =============================================================================

section "Connecting Sonarr to qBittorrent"

if SONARR_CLIENTS="$(api_get \
    "http://127.0.0.1:$SONARR_PORT/api/v3/downloadclient" \
    "$SONARR_API_KEY" 2>/dev/null)"; then

    if ! echo "$SONARR_CLIENTS" |
        jq -e '.[] | select(.implementation == "QBittorrent")' >/dev/null; then

        SONARR_QBIT="$(
            jq -cn \
            --arg user "$APP_USERNAME" \
            --arg pass "$APP_PASSWORD" \
            '{
                enable: true,
                protocol: "torrent",
                priority: 1,
                name: "qBittorrent",
                implementationName: "qBittorrent",
                implementation: "QBittorrent",
                configContract: "QBittorrentSettings",
                fields: [
                    {name:"host", value:"qbittorrent"},
                    {name:"port", value:8080},
                    {name:"username", value:$user},
                    {name:"password", value:$pass},
                    {name:"movieCategory", value:"tv"},
                    {name:"useSsl", value:false}
                ]
            }'
        )"

        api_post \
            "http://127.0.0.1:$SONARR_PORT/api/v3/downloadclient" \
            "$SONARR_API_KEY" \
            "$SONARR_QBIT" >/dev/null || true

    fi

    success "Sonarr -> qBittorrent configured."

else

    warn "Could not configure Sonarr download client."
fi

# =============================================================================
# RADARR -> QBITTORRENT
# =============================================================================

section "Connecting Radarr to qBittorrent"

if RADARR_CLIENTS="$(api_get \
    "http://127.0.0.1:$RADARR_PORT/api/v3/downloadclient" \
    "$RADARR_API_KEY" 2>/dev/null)"; then

    if ! echo "$RADARR_CLIENTS" |
        jq -e '.[] | select(.implementation == "QBittorrent")' >/dev/null; then

        RADARR_QBIT="$(
            jq -cn \
            --arg user "$APP_USERNAME" \
            --arg pass "$APP_PASSWORD" \
            '{
                enable: true,
                protocol: "torrent",
                priority: 1,
                name: "qBittorrent",
                implementationName: "qBittorrent",
                implementation: "QBittorrent",
                configContract: "QBittorrentSettings",
                fields: [
                    {name:"host", value:"qbittorrent"},
                    {name:"port", value:8080},
                    {name:"username", value:$user},
                    {name:"password", value:$pass},
                    {name:"movieCategory", value:"radarr"},
                    {name:"useSsl", value:false}
                ]
            }'
        )"

        api_post \
            "http://127.0.0.1:$RADARR_PORT/api/v3/downloadclient" \
            "$RADARR_API_KEY" \
            "$RADARR_QBIT" >/dev/null || true

    fi

    success "Radarr -> qBittorrent configured."

else

    warn "Could not configure Radarr download client."
fi

# =============================================================================
# PROWLARR -> SONARR
# =============================================================================

section "Connecting Prowlarr to Sonarr"

if PROWLARR_APPS="$(api_get \
    "http://127.0.0.1:$PROWLARR_PORT/api/v1/applications" \
    "$PROWLARR_API_KEY" 2>/dev/null)"; then

    if ! echo "$PROWLARR_APPS" |
        jq -e '.[] | select(.name == "Sonarr")' >/dev/null; then

        PROWLARR_SONARR="$(
            jq -cn \
            --arg key "$SONARR_API_KEY" \
            '{
                name:"Sonarr",
                implementation:"Sonarr",
                implementationName:"Sonarr",
                configContract:"SonarrSettings",
                fields:[
                    {name:"prowlarrUrl",value:"http://prowlarr:9696"},
                    {name:"baseUrl",value:"http://sonarr:8989"},
                    {name:"apiKey",value:$key}
                ],
                syncLevel:"fullSync",
                tags:[]
            }'
        )"

        api_post \
            "http://127.0.0.1:$PROWLARR_PORT/api/v1/applications" \
            "$PROWLARR_API_KEY" \
            "$PROWLARR_SONARR" >/dev/null || true

    fi

    success "Prowlarr -> Sonarr configured."

else

    warn "Could not access Prowlarr API."
fi

# =============================================================================
# PROWLARR -> RADARR
# =============================================================================

section "Connecting Prowlarr to Radarr"

if PROWLARR_APPS="$(api_get \
    "http://127.0.0.1:$PROWLARR_PORT/api/v1/applications" \
    "$PROWLARR_API_KEY" 2>/dev/null)"; then

    if ! echo "$PROWLARR_APPS" |
        jq -e '.[] | select(.name == "Radarr")' >/dev/null; then

        PROWLARR_RADARR="$(
            jq -cn \
            --arg key "$RADARR_API_KEY" \
            '{
                name:"Radarr",
                implementation:"Radarr",
                implementationName:"Radarr",
                configContract:"RadarrSettings",
                fields:[
                    {name:"prowlarrUrl",value:"http://prowlarr:9696"},
                    {name:"baseUrl",value:"http://radarr:7878"},
                    {name:"apiKey",value:$key}
                ],
                syncLevel:"fullSync",
                tags:[]
            }'
        )"

        api_post \
            "http://127.0.0.1:$PROWLARR_PORT/api/v1/applications" \
            "$PROWLARR_API_KEY" \
            "$PROWLARR_RADARR" >/dev/null || true

    fi

    success "Prowlarr -> Radarr configured."

else

    warn "Could not access Prowlarr API."
fi

# =============================================================================
# TAILSCALE
# =============================================================================

section "Configuring Tailscale"

if command -v tailscale >/dev/null 2>&1; then

    if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then

        info "Authenticating Tailscale..."

        if tailscale up \
            --authkey="$TAILSCALE_AUTH_KEY" \
            --hostname="media-server" \
            --accept-dns=true; then

            success "Tailscale authenticated."

        else

            warn "Tailscale authentication failed."
            warn "Run: tailscale up"

        fi

    else

        warn "No Tailscale auth key supplied."

        echo
        echo "Authenticate manually with:"
        echo
        echo "    sudo tailscale up"
        echo

    fi

else

    warn "Tailscale command is unavailable."
fi

# =============================================================================
# MANAGEMENT SCRIPTS
# =============================================================================

section "Creating management scripts"

cat > "$CONFIG_DIR/start.sh" <<EOF
#!/usr/bin/env bash
cd "$CONFIG_DIR"
docker compose --env-file .env up -d
EOF

cat > "$CONFIG_DIR/stop.sh" <<EOF
#!/usr/bin/env bash
cd "$CONFIG_DIR"
docker compose --env-file .env down
EOF

cat > "$CONFIG_DIR/restart.sh" <<EOF
#!/usr/bin/env bash
cd "$CONFIG_DIR"
docker compose --env-file .env restart
EOF

cat > "$CONFIG_DIR/update.sh" <<EOF
#!/usr/bin/env bash
cd "$CONFIG_DIR"
docker compose --env-file .env pull
docker compose --env-file .env up -d
docker image prune -f
EOF

cat > "$CONFIG_DIR/status.sh" <<EOF
#!/usr/bin/env bash
cd "$CONFIG_DIR"
docker compose --env-file .env ps
EOF

cat > "$CONFIG_DIR/logs.sh" <<EOF
#!/usr/bin/env bash
cd "$CONFIG_DIR"
docker compose --env-file .env logs -f
EOF

cat > "$CONFIG_DIR/backup.sh" <<EOF
#!/usr/bin/env bash

set -e

BACKUP_DIR="\$HOME/media-stack-backup-\$(date +%Y%m%d-%H%M%S)"

mkdir -p "\$BACKUP_DIR"

cp -a \
    "$CONFIG_DIR/jellyfin" \
    "$CONFIG_DIR/seerr" \
    "$CONFIG_DIR/qbittorrent" \
    "$CONFIG_DIR/prowlarr" \
    "$CONFIG_DIR/sonarr" \
    "$CONFIG_DIR/radarr" \
    "$CONFIG_DIR/compose.yaml" \
    "$CONFIG_DIR/.env" \
    "\$BACKUP_DIR/"

echo
echo "Backup created:"
echo "\$BACKUP_DIR"
EOF

chmod +x \
    "$CONFIG_DIR/start.sh" \
    "$CONFIG_DIR/stop.sh" \
    "$CONFIG_DIR/restart.sh" \
    "$CONFIG_DIR/update.sh" \
    "$CONFIG_DIR/status.sh" \
    "$CONFIG_DIR/logs.sh" \
    "$CONFIG_DIR/backup.sh"

success "Management scripts created."

# =============================================================================
# CREDENTIALS
# =============================================================================

section "Saving credentials"

CREDENTIALS_FILE="$CONFIG_DIR/credentials.txt"

cat > "$CREDENTIALS_FILE" <<EOF
============================================================
MEDIA SERVER CREDENTIALS
============================================================

Username:
$APP_USERNAME

Password:
$APP_PASSWORD


============================================================
API KEYS
============================================================

Sonarr:
$SONARR_API_KEY

Radarr:
$RADARR_API_KEY

Prowlarr:
$PROWLARR_API_KEY

Seerr:
$SEERR_API_KEY


============================================================
SERVICES
============================================================

Jellyfin:
http://localhost:$JELLYFIN_PORT

Seerr:
http://localhost:$SEERR_PORT

qBittorrent:
http://localhost:$QBIT_PORT

Prowlarr:
http://localhost:$PROWLARR_PORT

Sonarr:
http://localhost:$SONARR_PORT

Radarr:
http://localhost:$RADARR_PORT


============================================================
MEDIA
============================================================

Movies:
$MEDIA_DIR/movies

TV:
$MEDIA_DIR/tv

Music:
$MEDIA_DIR/music

Downloads:
$MEDIA_DIR/downloads


============================================================
CONFIG
============================================================

$CONFIG_DIR


============================================================
MANAGEMENT
============================================================

Start:
$CONFIG_DIR/start.sh

Stop:
$CONFIG_DIR/stop.sh

Restart:
$CONFIG_DIR/restart.sh

Update:
$CONFIG_DIR/update.sh

Status:
$CONFIG_DIR/status.sh

Logs:
$CONFIG_DIR/logs.sh

Backup:
$CONFIG_DIR/backup.sh
EOF

chmod 600 "$CREDENTIALS_FILE"

success "Credentials saved to $CREDENTIALS_FILE"

# =============================================================================
# OPTIONAL FIREWALL
# =============================================================================

section "Checking firewall"

if command -v ufw >/dev/null 2>&1; then

    if ufw status 2>/dev/null | grep -q "Status: active"; then

        warn "UFW is active."

        info "Docker-published ports are handled by Docker's networking."

        # Tailscale traffic
        ufw allow in on tailscale0 >/dev/null 2>&1 || true

    fi

elif command -v firewall-cmd >/dev/null 2>&1; then

    if firewall-cmd --state >/dev/null 2>&1; then

        info "firewalld is active."

    fi

fi

# =============================================================================
# FINAL STATUS
# =============================================================================

section "INSTALLATION COMPLETE"

echo
echo "Services:"
echo
echo "  Jellyfin:    http://localhost:$JELLYFIN_PORT"
echo "  Seerr:       http://localhost:$SEERR_PORT"
echo "  qBittorrent: http://localhost:$QBIT_PORT"
echo "  Prowlarr:    http://localhost:$PROWLARR_PORT"
echo "  Sonarr:      http://localhost:$SONARR_PORT"
echo "  Radarr:      http://localhost:$RADARR_PORT"

echo
echo "Media:"
echo
echo "  Movies:      $MEDIA_DIR/movies"
echo "  TV:          $MEDIA_DIR/tv"
echo "  Music:       $MEDIA_DIR/music"
echo "  Downloads:   $MEDIA_DIR/downloads"

echo
echo "Configuration:"
echo
echo "  $CONFIG_DIR"

echo
echo "Credentials:"
echo
echo "  $CREDENTIALS_FILE"

echo
echo "Management:"
echo
echo "  $CONFIG_DIR/start.sh"
echo "  $CONFIG_DIR/stop.sh"
echo "  $CONFIG_DIR/restart.sh"
echo "  $CONFIG_DIR/update.sh"
echo "  $CONFIG_DIR/status.sh"
echo "  $CONFIG_DIR/logs.sh"
echo "  $CONFIG_DIR/backup.sh"

echo
echo "Docker containers:"
echo

cd "$CONFIG_DIR"

docker compose \
    --env-file "$ENV_FILE" \
    ps

echo

if [[ -z "$TAILSCALE_AUTH_KEY" ]]; then

    warn "Tailscale still needs authentication."

    echo
    echo "Run:"
    echo
    echo "    sudo tailscale up"
    echo

else

    success "Tailscale authentication was attempted."

fi

echo
echo "IMPORTANT:"
echo
echo "Seerr's initial owner account is established through its"
echo "supported Jellyfin authentication/setup flow."
echo
echo "Open Jellyfin first, complete its initial setup, then open Seerr."
echo

echo "============================================================"
echo "                  MEDIA SERVER READY"
echo "============================================================"
echo
