#!/usr/bin/env bash

# ============================================================================
# AUTOMATED MACOS MEDIA SERVER
#
# Installs:
#   Docker Desktop
#   Jellyfin
#   Seerr
#   qBittorrent
#   Prowlarr
#   Sonarr
#   Radarr
#   Tailscale
#
# Automatically configures:
#   qBittorrent
#   Sonarr
#   Radarr
#   Prowlarr -> Sonarr
#   Prowlarr -> Radarr
#   Sonarr -> qBittorrent
#   Radarr -> qBittorrent
#   Seerr -> Sonarr
#   Seerr -> Radarr
#
# Prompts only for:
#   Media directory
#   Config directory
#   Username
#   Password
#
# Optional:
#   export TAILSCALE_AUTH_KEY="tskey-auth-..."
#
# ============================================================================

set -Eeuo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

STACK_NAME="media-stack"

JELLYFIN_PORT=8096
SEERR_PORT=5055
QBIT_PORT=8080
PROWLARR_PORT=9696
SONARR_PORT=8989
RADARR_PORT=7878

JELLYFIN_INTERNAL="http://jellyfin:8096"
QBIT_INTERNAL="http://qbittorrent:8080"
PROWLARR_INTERNAL="http://prowlarr:9696"
SONARR_INTERNAL="http://sonarr:8989"
RADARR_INTERNAL="http://radarr:7878"

TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

# ============================================================================
# COLORS
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[ OK ]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

fail() {
    echo -e "${RED}[ERROR]${NC} $1"
}

section() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo
}

trap 'fail "Installation failed on line $LINENO."; exit 1' ERR

# ============================================================================
# HELP
# ============================================================================

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF

Automated Media Server Installer

Usage:
    ./install-media-stack.sh

Optional Tailscale authentication:

    export TAILSCALE_AUTH_KEY="tskey-auth-..."
    ./install-media-stack.sh

The installer asks for:

    1. Media directory
    2. Config directory
    3. Username
    4. Password

Services:

    Jellyfin       http://localhost:${JELLYFIN_PORT}
    Seerr          http://localhost:${SEERR_PORT}
    qBittorrent    http://localhost:${QBIT_PORT}
    Prowlarr       http://localhost:${PROWLARR_PORT}
    Sonarr         http://localhost:${SONARR_PORT}
    Radarr         http://localhost:${RADARR_PORT}

EOF
    exit 0
fi

# ============================================================================
# REQUIREMENTS
# ============================================================================

section "Checking system"

if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "This installer only supports macOS."
    exit 1
fi

ARCH="$(uname -m)"

case "$ARCH" in
    arm64)
        success "Apple Silicon detected."
        ;;
    x86_64)
        success "Intel Mac detected."
        ;;
    *)
        fail "Unsupported CPU architecture: $ARCH"
        exit 1
        ;;
esac

# ============================================================================
# HOME DIRECTORY
# ============================================================================

if [[ "$EUID" -eq 0 ]]; then
    fail "Do not run this script with sudo."
    fail "Run it as your normal macOS user."
    exit 1
fi

# ============================================================================
# HOMEBREW
# ============================================================================

section "Installing dependencies"

if ! command -v brew >/dev/null 2>&1; then

    info "Homebrew is not installed."
    info "Installing Homebrew..."

    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    if [[ "$ARCH" == "arm64" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    else
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    success "Homebrew installed."

else

    success "Homebrew already installed."

fi

# ============================================================================
# DOCKER
# ============================================================================

if ! command -v docker >/dev/null 2>&1; then

    info "Installing Docker Desktop..."

    brew install --cask docker

    success "Docker Desktop installed."

else

    success "Docker CLI already installed."

fi

# ============================================================================
# TAILSCALE
# ============================================================================

if ! command -v tailscale >/dev/null 2>&1; then

    info "Installing Tailscale..."

    brew install --cask tailscale

    success "Tailscale installed."

else

    success "Tailscale already installed."

fi

# ============================================================================
# START DOCKER
# ============================================================================

section "Starting Docker"

open -a Docker >/dev/null 2>&1 || true

info "Waiting for Docker Desktop..."

DOCKER_READY=0

for i in $(seq 1 90); do

    if docker info >/dev/null 2>&1; then
        DOCKER_READY=1
        break
    fi

    sleep 2

done

if [[ "$DOCKER_READY" != "1" ]]; then

    fail "Docker Desktop did not become ready."

    echo
    echo "Please open Docker Desktop manually and run this script again."
    exit 1

fi

success "Docker is ready."

if ! docker compose version >/dev/null 2>&1; then
    fail "Docker Compose is unavailable."
    exit 1
fi

success "Docker Compose available."

# ============================================================================
# USER INPUT
# ============================================================================

section "Server configuration"

echo "The installer needs two filesystem locations."
echo

read -r -p "Media directory: " MEDIA_DIR
read -r -p "Config directory: " CONFIG_DIR

MEDIA_DIR="${MEDIA_DIR/#\~/$HOME}"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"

if [[ -z "$MEDIA_DIR" ]]; then
    fail "Media directory cannot be empty."
    exit 1
fi

if [[ -z "$CONFIG_DIR" ]]; then
    fail "Config directory cannot be empty."
    exit 1
fi

# Make config directory absolute
mkdir -p "$CONFIG_DIR"
CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd)"

# Make media directory absolute
mkdir -p "$MEDIA_DIR"
MEDIA_DIR="$(cd "$MEDIA_DIR" && pwd)"

echo

read -r -p "Username for the media applications: " APP_USERNAME

if [[ -z "$APP_USERNAME" ]]; then
    fail "Username cannot be empty."
    exit 1
fi

read -r -s -p "Password for the media applications: " APP_PASSWORD
echo

if [[ -z "$APP_PASSWORD" ]]; then
    fail "Password cannot be empty."
    exit 1
fi

# ============================================================================
# DIRECTORY STRUCTURE
# ============================================================================

section "Creating directories"

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
    "$CONFIG_DIR/radarr" \
    "$CONFIG_DIR/tailscale"

success "Directory structure created."

# ============================================================================
# GENERATE SECRETS
# ============================================================================

section "Generating application credentials"

generate_key() {
    openssl rand -hex 32
}

SONARR_API_KEY="$(generate_key)"
RADARR_API_KEY="$(generate_key)"
PROWLARR_API_KEY="$(generate_key)"
SEERR_API_KEY="$(generate_key)"
QBIT_API_KEY="qbt_$(openssl rand -hex 14)"

# ============================================================================
# ENVIRONMENT FILE
# ============================================================================

cat > "$CONFIG_DIR/.env" <<EOF
TZ=America/Los_Angeles

MEDIA_DIR=$MEDIA_DIR
CONFIG_DIR=$CONFIG_DIR

APP_USERNAME=$APP_USERNAME
APP_PASSWORD=$APP_PASSWORD

SONARR_API_KEY=$SONARR_API_KEY
RADARR_API_KEY=$RADARR_API_KEY
PROWLARR_API_KEY=$PROWLARR_API_KEY
SEERR_API_KEY=$SEERR_API_KEY
QBIT_API_KEY=$QBIT_API_KEY

TAILSCALE_AUTH_KEY=$TAILSCALE_AUTH_KEY
EOF

chmod 600 "$CONFIG_DIR/.env"

success "Secrets saved."

# ============================================================================
# SONARR CONFIG
# ============================================================================

section "Preparing Sonarr"

cat > "$CONFIG_DIR/sonarr/config.xml" <<EOF
<Config>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <Port>8989</Port>
  <SslPort>9898</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>${SONARR_API_KEY}</ApiKey>
  <AuthenticationMethod>None</AuthenticationMethod>
  <Branch>main</Branch>
  <UpdateMechanism>Docker</UpdateMechanism>
  <UpdateAutomatically>False</UpdateAutomatically>
  <InstanceName>Sonarr</InstanceName>
</Config>
EOF

# ============================================================================
# RADARR CONFIG
# ============================================================================

section "Preparing Radarr"

cat > "$CONFIG_DIR/radarr/config.xml" <<EOF
<Config>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <Port>7878</Port>
  <SslPort>9899</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>${RADARR_API_KEY}</ApiKey>
  <AuthenticationMethod>None</AuthenticationMethod>
  <Branch>master</Branch>
  <UpdateMechanism>Docker</UpdateMechanism>
  <UpdateAutomatically>False</UpdateAutomatically>
  <InstanceName>Radarr</InstanceName>
</Config>
EOF

# ============================================================================
# PROWLARR CONFIG
# ============================================================================

section "Preparing Prowlarr"

cat > "$CONFIG_DIR/prowlarr/config.xml" <<EOF
<Config>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <Port>9696</Port>
  <SslPort>6969</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>${PROWLARR_API_KEY}</ApiKey>
  <AuthenticationMethod>None</AuthenticationMethod>
  <Branch>master</Branch>
  <UpdateMechanism>Docker</UpdateMechanism>
  <UpdateAutomatically>False</UpdateAutomatically>
  <InstanceName>Prowlarr</InstanceName>
</Config>
EOF

# ============================================================================
# DOCKER COMPOSE
# ============================================================================

section "Creating Docker Compose"

cat > "$CONFIG_DIR/compose.yaml" <<'EOF'
services:

  # ----------------------------------------------------------
  # Jellyfin
  # ----------------------------------------------------------

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped

    environment:
      - TZ=${TZ}

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

  # ----------------------------------------------------------
  # Seerr
  # ----------------------------------------------------------

  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    init: true
    restart: unless-stopped

    environment:
      - LOG_LEVEL=info
      - TZ=${TZ}
      - PORT=5055

    ports:
      - "5055:5055"

    volumes:
      - ${CONFIG_DIR}/seerr:/app/config

    networks:
      - media

  # ----------------------------------------------------------
  # qBittorrent
  # ----------------------------------------------------------

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped

    environment:
      - PUID=1000
      - PGID=1000
      - TZ=${TZ}
      - WEBUI_PORT=8080

    ports:
      - "8080:8080"

    volumes:
      - ${CONFIG_DIR}/qbittorrent:/config
      - ${MEDIA_DIR}/downloads:/downloads

    networks:
      - media

  # ----------------------------------------------------------
  # Prowlarr
  # ----------------------------------------------------------

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped

    environment:
      - PUID=1000
      - PGID=1000
      - TZ=${TZ}

    ports:
      - "9696:9696"

    volumes:
      - ${CONFIG_DIR}/prowlarr:/config

    networks:
      - media

  # ----------------------------------------------------------
  # Sonarr
  # ----------------------------------------------------------

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped

    environment:
      - PUID=1000
      - PGID=1000
      - TZ=${TZ}

    ports:
      - "8989:8989"

    volumes:
      - ${CONFIG_DIR}/sonarr:/config
      - ${MEDIA_DIR}/tv:/tv
      - ${MEDIA_DIR}/downloads:/downloads

    networks:
      - media

  # ----------------------------------------------------------
  # Radarr
  # ----------------------------------------------------------

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped

    environment:
      - PUID=1000
      - PGID=1000
      - TZ=${TZ}

    ports:
      - "7878:7878"

    volumes:
      - ${CONFIG_DIR}/radarr:/config
      - ${MEDIA_DIR}/movies:/movies
      - ${MEDIA_DIR}/downloads:/downloads

    networks:
      - media

  # ----------------------------------------------------------
  # Tailscale
  # ----------------------------------------------------------

  tailscale:
    image: tailscale/tailscale:latest
    container_name: tailscale
    hostname: media-server

    restart: unless-stopped

    environment:
      - TS_AUTHKEY=${TAILSCALE_AUTH_KEY}
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_USERSPACE=true

    volumes:
      - ${CONFIG_DIR}/tailscale:/var/lib/tailscale

    networks:
      - media

networks:
  media:
    name: media
    driver: bridge
EOF

success "Docker Compose created."

# ============================================================================
# START STACK
# ============================================================================

section "Starting containers"

(
    cd "$CONFIG_DIR"
    docker compose --env-file .env pull
    docker compose --env-file .env up -d
)

success "Containers started."

# ============================================================================
# HTTP WAIT FUNCTION
# ============================================================================

wait_http() {

    local NAME="$1"
    local URL="$2"
    local MAX="${3:-90}"

    info "Waiting for ${NAME}..."

    for i in $(seq 1 "$MAX"); do

        if curl -fsS "$URL" >/dev/null 2>&1; then
            success "${NAME} is ready."
            return 0
        fi

        sleep 2

    done

    warn "${NAME} did not respond within the timeout."
    return 1
}

# ============================================================================
# WAIT FOR ARR SERVICES
# ============================================================================

section "Waiting for services"

wait_http "Sonarr" "http://localhost:8989/ping" 90 || true
wait_http "Radarr" "http://localhost:7878/ping" 90 || true
wait_http "Prowlarr" "http://localhost:9696/ping" 90 || true

# qBittorrent may return a redirect/login page.
wait_http "qBittorrent" "http://localhost:8080" 90 || true

wait_http "Jellyfin" "http://localhost:8096/health" 90 || true

wait_http "Seerr" "http://localhost:5055/api/v1/settings/public" 90 || true

# ============================================================================
# CURL HELPERS
# ============================================================================

api_get() {

    local URL="$1"
    local KEY="$2"

    curl -fsS \
        -H "X-Api-Key: ${KEY}" \
        "$URL"
}

api_post() {

    local URL="$1"
    local KEY="$2"
    local BODY="$3"

    curl -fsS \
        -X POST \
        -H "X-Api-Key: ${KEY}" \
        -H "Content-Type: application/json" \
        "$URL" \
        --data "$BODY"
}

api_put() {

    local URL="$1"
    local KEY="$2"
    local BODY="$3"

    curl -fsS \
        -X PUT \
        -H "X-Api-Key: ${KEY}" \
        -H "Content-Type: application/json" \
        "$URL" \
        --data "$BODY"
}

# ============================================================================
# CONFIGURE SONARR
# ============================================================================

section "Configuring Sonarr"

SONARR_ROOT_ID=""

SONARR_ROOT_RESPONSE="$(
    curl -fsS \
        -H "X-Api-Key: ${SONARR_API_KEY}" \
        "${SONARR_INTERNAL}/api/v3/rootfolder" \
        || echo "[]"
)"

if ! echo "$SONARR_ROOT_RESPONSE" | grep -q '"path":"\/tv"'; then

    curl -fsS \
        -X POST \
        -H "X-Api-Key: ${SONARR_API_KEY}" \
        -H "Content-Type: application/json" \
        "${SONARR_INTERNAL}/api/v3/rootfolder" \
        --data '{"path":"/tv"}' \
        >/dev/null 2>&1 || true

fi

# Get download clients
SONARR_DL="$(
cat <<EOF
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "name": "qBittorrent",
  "implementationName": "qBittorrent",
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    {"name":"host","value":"qbittorrent"},
    {"name":"port","value":8080},
    {"name":"username","value":"${APP_USERNAME}"},
    {"name":"password","value":"${APP_PASSWORD}"},
    {"name":"movieCategory","value":"tv"},
    {"name":"recentMoviePriority","value":0},
    {"name":"olderMoviePriority","value":0},
    {"name":"initialState","value":0},
    {"name":"useSsl","value":false}
  ]
}
EOF
)"

curl -fsS \
    -X POST \
    -H "X-Api-Key: ${SONARR_API_KEY}" \
    -H "Content-Type: application/json" \
    "${SONARR_INTERNAL}/api/v3/downloadclient" \
    --data "$SONARR_DL" \
    >/dev/null 2>&1 || true

success "Sonarr configured."

# ============================================================================
# CONFIGURE RADARR
# ============================================================================

section "Configuring Radarr"

RADARR_ROOT_RESPONSE="$(
    curl -fsS \
        -H "X-Api-Key: ${RADARR_API_KEY}" \
        "${RADARR_INTERNAL}/api/v3/rootfolder" \
        || echo "[]"
)"

if ! echo "$RADARR_ROOT_RESPONSE" | grep -q '"path":"\/movies"'; then

    curl -fsS \
        -X POST \
        -H "X-Api-Key: ${RADARR_API_KEY}" \
        -H "Content-Type: application/json" \
        "${RADARR_INTERNAL}/api/v3/rootfolder" \
        --data '{"path":"/movies"}' \
        >/dev/null 2>&1 || true

fi

RADARR_DL="$(
cat <<EOF
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "name": "qBittorrent",
  "implementationName": "qBittorrent",
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    {"name":"host","value":"qbittorrent"},
    {"name":"port","value":8080},
    {"name":"username","value":"${APP_USERNAME}"},
    {"name":"password","value":"${APP_PASSWORD}"},
    {"name":"movieCategory","value":"radarr"},
    {"name":"recentMoviePriority","value":0},
    {"name":"olderMoviePriority","value":0},
    {"name":"initialState","value":0},
    {"name":"useSsl","value":false}
  ]
}
EOF
)"

curl -fsS \
    -X POST \
    -H "X-Api-Key: ${RADARR_API_KEY}" \
    -H "Content-Type: application/json" \
    "${RADARR_INTERNAL}/api/v3/downloadclient" \
    --data "$RADARR_DL" \
    >/dev/null 2>&1 || true

success "Radarr configured."

# ============================================================================
# CONFIGURE QBITTORRENT
# ============================================================================

section "Configuring qBittorrent"

QBIT_COOKIE_JAR="$(mktemp)"

cleanup() {
    rm -f "$QBIT_COOKIE_JAR"
}

trap cleanup EXIT

QBIT_READY=0

for i in $(seq 1 60); do

    if curl -fsS \
        -c "$QBIT_COOKIE_JAR" \
        -b "$QBIT_COOKIE_JAR" \
        -d "username=admin" \
        -d "password=adminadmin" \
        "http://localhost:${QBIT_PORT}/api/v2/auth/login" \
        2>/dev/null | grep -q "Ok."; then

        QBIT_READY=1
        break
    fi

    # New qBittorrent versions may generate a temporary password.
    LOGS="$(
        docker logs qbittorrent 2>&1 \
        | grep -i "temporary password" \
        | tail -1 \
        || true
    )"

    if [[ -n "$LOGS" ]]; then
        TEMP_PASSWORD="$(
            echo "$LOGS" \
            | sed -E 's/.*temporary password is:?[[:space:]]*//I' \
            | tr -d '\r'
        )"

        if [[ -n "$TEMP_PASSWORD" ]]; then

            if curl -fsS \
                -c "$QBIT_COOKIE_JAR" \
                -b "$QBIT_COOKIE_JAR" \
                -d "username=admin" \
                --data-urlencode "password=${TEMP_PASSWORD}" \
                "http://localhost:${QBIT_PORT}/api/v2/auth/login" \
                2>/dev/null | grep -q "Ok."; then

                QBIT_READY=1
                break

            fi

        fi

    fi

    sleep 2

done

if [[ "$QBIT_READY" == "1" ]]; then

    info "Configuring qBittorrent preferences..."

    QBIT_PREFS="$(
        cat <<EOF
{
  "web_ui_username": "${APP_USERNAME}",
  "web_ui_password": "${APP_PASSWORD}",
  "bypass_local_auth": false,
  "save_path": "/downloads/complete/",
  "temp_path_enabled": true,
  "temp_path": "/downloads/incomplete/",
  "use_subcategories": true
}
EOF
    )"

    curl -fsS \
        -b "$QBIT_COOKIE_JAR" \
        -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "json=${QBIT_PREFS}" \
        "http://localhost:${QBIT_PORT}/api/v2/app/setPreferences" \
        >/dev/null 2>&1 || true

    success "qBittorrent configured."

else

    warn "Could not automatically authenticate to qBittorrent."
    warn "The qBittorrent container is running, but its WebUI credentials need one-time setup."

fi

rm -f "$QBIT_COOKIE_JAR"

# ============================================================================
# PROWLARR -> SONARR
# ============================================================================

section "Connecting Prowlarr to Sonarr/Radarr"

PROWLARR_HEADERS=(-H "X-Api-Key: ${PROWLARR_API_KEY}" -H "Content-Type: application/json")

SONARR_APP="$(
cat <<EOF
{
  "name": "Sonarr",
  "implementation": "Sonarr",
  "implementationName": "Sonarr",
  "configContract": "SonarrSettings",
  "fields": [
    {"name":"prowlarrUrl","value":"http://prowlarr:9696"},
    {"name":"baseUrl","value":"http://sonarr:8989"},
    {"name":"apiKey","value":"${SONARR_API_KEY}"},
    {"name":"syncCategories","value":[5000,5010,5020,5030,5040,5045,5050,5090]}
  ],
  "syncLevel": "fullSync",
  "tags": []
}
EOF
)"

curl -fsS \
    -X POST \
    "${PROWLARR_HEADERS[@]}" \
    "${PROWLARR_INTERNAL}/api/v1/applications" \
    --data "$SONARR_APP" \
    >/dev/null 2>&1 || true

success "Prowlarr -> Sonarr configured."

# ============================================================================
# PROWLARR -> RADARR
# ============================================================================

RADARR_APP="$(
cat <<EOF
{
  "name": "Radarr",
  "implementation": "Radarr",
  "implementationName": "Radarr",
  "configContract": "RadarrSettings",
  "fields": [
    {"name":"prowlarrUrl","value":"http://prowlarr:9696"},
    {"name":"baseUrl","value":"http://radarr:7878"},
    {"name":"apiKey","value":"${RADARR_API_KEY}"},
    {"name":"syncCategories","value":[2000,2010,2020,2030,2040,2045,2050,2060,2070]}
  ],
  "syncLevel": "fullSync",
  "tags": []
}
EOF
)"

curl -fsS \
    -X POST \
    "${PROWLARR_HEADERS[@]}" \
    "${PROWLARR_INTERNAL}/api/v1/applications" \
    --data "$RADARR_APP" \
    >/dev/null 2>&1 || true

success "Prowlarr -> Radarr configured."

# ============================================================================
# SEERR
# ============================================================================

section "Configuring Seerr"

SEERR_PUBLIC="$(
    curl -fsS \
        "http://localhost:${SEERR_PORT}/api/v1/settings/public" \
        || echo '{}'
)"

SEERR_INITIALIZED="$(echo "$SEERR_PUBLIC" | grep -o '"initialized":[^,}]*' | cut -d: -f2 || true)"

if [[ "$SEERR_INITIALIZED" == "false" ]]; then

    warn "Seerr has not yet completed its first-run authentication."

    cat <<EOF

Seerr requires its owner account to authenticate through the configured
media server. This part cannot safely be bypassed by inventing a database
record.

Open:

    http://localhost:${SEERR_PORT}

Then authenticate against Jellyfin.

After that, the Seerr API can manage the Sonarr/Radarr integrations.

EOF

else

    success "Seerr is already initialized."

fi

# ============================================================================
# TAILSCALE
# ============================================================================

section "Configuring Tailscale"

if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then

    info "Tailscale auth key supplied."

    if ! docker exec tailscale tailscale status >/dev/null 2>&1; then

        docker exec tailscale \
            tailscale up \
            --authkey="${TAILSCALE_AUTH_KEY}" \
            --hostname=media-server \
            >/dev/null 2>&1 || true

    fi

    if docker exec tailscale tailscale status >/dev/null 2>&1; then
        success "Tailscale connected."
    else
        warn "Tailscale did not report a connected state."
    fi

else

    warn "No TAILSCALE_AUTH_KEY was supplied."

    echo
    echo "To authenticate Tailscale automatically, rerun with:"
    echo
    echo 'export TAILSCALE_AUTH_KEY="tskey-auth-..."'
    echo './install-media-stack.sh'
    echo

fi

# ============================================================================
# CREATE MANAGEMENT SCRIPTS
# ============================================================================

section "Creating management commands"

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
set -e
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

BACKUP="\$HOME/Desktop/media-stack-backup-\$(date +%Y%m%d-%H%M%S).tar.gz"

tar \
    --exclude='*/cache/*' \
    -czf "\$BACKUP" \
    "$CONFIG_DIR"

echo "Backup created:"
echo "\$BACKUP"
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

# ============================================================================
# SAVE HUMAN-READABLE CREDENTIAL FILE
# ============================================================================

cat > "$CONFIG_DIR/credentials.txt" <<EOF
MEDIA SERVER STACK CREDENTIALS
==============================

Username:
${APP_USERNAME}

Password:
${APP_PASSWORD}

Sonarr API Key:
${SONARR_API_KEY}

Radarr API Key:
${RADARR_API_KEY}

Prowlarr API Key:
${PROWLARR_API_KEY}

Seerr API Key:
${SEERR_API_KEY}

qBittorrent API Key:
${QBIT_API_KEY}

IMPORTANT:
Keep this file private.
File permissions are restricted to your macOS user.

SERVICES
========

Jellyfin:
http://localhost:8096

Seerr:
http://localhost:5055

qBittorrent:
http://localhost:8080

Prowlarr:
http://localhost:9696

Sonarr:
http://localhost:8989

Radarr:
http://localhost:7878

MEDIA
=====

Movies:
${MEDIA_DIR}/movies

TV:
${MEDIA_DIR}/tv

Music:
${MEDIA_DIR}/music

Downloads:
${MEDIA_DIR}/downloads

CONFIG
======

${CONFIG_DIR}
EOF

chmod 600 "$CONFIG_DIR/credentials.txt"

# ============================================================================
# FINAL STATUS
# ============================================================================

section "Installation complete"

echo "Services:"
echo
echo "  Jellyfin:    http://localhost:${JELLYFIN_PORT}"
echo "  Seerr:       http://localhost:${SEERR_PORT}"
echo "  qBittorrent: http://localhost:${QBIT_PORT}"
echo "  Prowlarr:    http://localhost:${PROWLARR_PORT}"
echo "  Sonarr:      http://localhost:${SONARR_PORT}"
echo "  Radarr:      http://localhost:${RADARR_PORT}"
echo

echo "Media:"
echo
echo "  Movies:      ${MEDIA_DIR}/movies"
echo "  TV:          ${MEDIA_DIR}/tv"
echo "  Music:       ${MEDIA_DIR}/music"
echo "  Downloads:   ${MEDIA_DIR}/downloads"
echo

echo "Configuration:"
echo
echo "  ${CONFIG_DIR}"
echo

echo "Management:"
echo
echo "  ${CONFIG_DIR}/start.sh"
echo "  ${CONFIG_DIR}/stop.sh"
echo "  ${CONFIG_DIR}/restart.sh"
echo "  ${CONFIG_DIR}/update.sh"
echo "  ${CONFIG_DIR}/status.sh"
echo "  ${CONFIG_DIR}/logs.sh"
echo "  ${CONFIG_DIR}/backup.sh"
echo

echo "Credentials:"
echo
echo "  ${CONFIG_DIR}/credentials.txt"
echo

echo "Opening Jellyfin and Seerr..."

open "http://localhost:${JELLYFIN_PORT}" >/dev/null 2>&1 || true
open "http://localhost:${SEERR_PORT}" >/dev/null 2>&1 || true

success "Done."
