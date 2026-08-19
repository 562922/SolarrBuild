#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Universal Media Server Installer - macOS
# Installs/configures:
# Jellyfin, Seerr, qBittorrent, Prowlarr, Sonarr, Radarr, Tailscale
# ============================================================

APP_USER=""
APP_PASS=""
MEDIA_DIR=""
CONFIG_DIR=""
TS_AUTH=""

PORT_JELLYFIN=8096
PORT_SEERR=5055
PORT_QBIT=8080
PORT_PROWLARR=9696
PORT_SONARR=8989
PORT_RADARR=7878
TZ="${TZ:-America/Los_Angeles}"

log(){ printf '\033[1;36m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "This installer is for macOS."

command -v brew >/dev/null 2>&1 || {
  echo "Homebrew is required. Installing it..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null || true)"
brew install jq openssl python3 curl >/dev/null 2>&1 || true

if ! command -v docker >/dev/null 2>&1; then
  die "Docker Desktop is required. Install/start Docker Desktop, then rerun this installer."
fi
docker info >/dev/null 2>&1 || die "Docker Desktop is installed but not running."
docker compose version >/dev/null 2>&1 || die "Docker Compose is unavailable."

if ! command -v tailscale >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then brew install --cask tailscale || true; fi
fi

read -r -p "Media directory: " MEDIA_DIR
read -r -p "Config directory: " CONFIG_DIR
read -r -p "Application username: " APP_USER
read -r -s -p "Application password: " APP_PASS
echo
read -r -p "Tailscale auth key (Enter to skip): " TS_AUTH

[[ -n "$MEDIA_DIR" && -n "$CONFIG_DIR" && -n "$APP_USER" && -n "$APP_PASS" ]] || die "All except the Tailscale key are required."

MEDIA_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$MEDIA_DIR")"
CONFIG_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$CONFIG_DIR")"

mkdir -p \
  "$MEDIA_DIR"/{movies,tv,music,downloads/complete,downloads/incomplete} \
  "$CONFIG_DIR"/{jellyfin,seerr,qbittorrent,prowlarr,sonarr,radarr}

# Use a single credential set. qBittorrent's LinuxServer image still creates
# a temporary admin password on first boot, so the installer discovers it
# from the container log and changes it through the supported Web API.
SONARR_KEY="$(openssl rand -hex 32)"
RADARR_KEY="$(openssl rand -hex 32)"
PROWLARR_KEY="$(openssl rand -hex 32)"

cat > "$CONFIG_DIR/.env" <<EOF
TZ=$TZ
MEDIA_DIR=$MEDIA_DIR
CONFIG_DIR=$CONFIG_DIR
APP_USERNAME=$APP_USER
APP_PASSWORD=$APP_PASS
SONARR_API_KEY=$SONARR_KEY
RADARR_API_KEY=$RADARR_KEY
PROWLARR_API_KEY=$PROWLARR_KEY
EOF
chmod 600 "$CONFIG_DIR/.env"

cat > "$CONFIG_DIR/compose.yaml" <<'EOF'
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
    networks: [media]

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
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5055/api/v1/settings/public || exit 1"]
      start_period: 20s
      timeout: 3s
      interval: 15s
      retries: 3
    networks: [media]

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    environment:
      PUID: 1000
      PGID: 1000
      TZ: ${TZ}
      WEBUI_PORT: 8080
      TORRENTING_PORT: 6881
    ports:
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
    volumes:
      - ${CONFIG_DIR}/qbittorrent:/config
      - ${MEDIA_DIR}/downloads:/downloads
    networks: [media]

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
    networks: [media]

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
    networks: [media]

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
    networks: [media]

networks:
  media:
    name: media
    driver: bridge
EOF

# Seed Arr config files with known API keys so API discovery is deterministic.
cat > "$CONFIG_DIR/sonarr/config.xml" <<EOF
<Config><LogLevel>info</LogLevel><UrlBase></UrlBase><BindAddress>*</BindAddress><Port>8989</Port><EnableSsl>False</EnableSsl><LaunchBrowser>False</LaunchBrowser><ApiKey>$SONARR_KEY</ApiKey><AuthenticationMethod>None</AuthenticationMethod><Branch>main</Branch><UpdateMechanism>Docker</UpdateMechanism><UpdateAutomatically>False</UpdateAutomatically><InstanceName>Sonarr</InstanceName></Config>
EOF
cat > "$CONFIG_DIR/radarr/config.xml" <<EOF
<Config><LogLevel>info</LogLevel><UrlBase></UrlBase><BindAddress>*</BindAddress><Port>7878</Port><EnableSsl>False</EnableSsl><LaunchBrowser>False</LaunchBrowser><ApiKey>$RADARR_KEY</ApiKey><AuthenticationMethod>None</AuthenticationMethod><Branch>master</Branch><UpdateMechanism>Docker</UpdateMechanism><UpdateAutomatically>False</UpdateAutomatically><InstanceName>Radarr</InstanceName></Config>
EOF
cat > "$CONFIG_DIR/prowlarr/config.xml" <<EOF
<Config><LogLevel>info</LogLevel><UrlBase></UrlBase><BindAddress>*</BindAddress><Port>9696</Port><EnableSsl>False</EnableSsl><LaunchBrowser>False</LaunchBrowser><ApiKey>$PROWLARR_KEY</ApiKey><AuthenticationMethod>None</AuthenticationMethod><Branch>master</Branch><UpdateMechanism>Docker</UpdateMechanism><UpdateAutomatically>False</UpdateAutomatically><InstanceName>Prowlarr</InstanceName></Config>
EOF

cd "$CONFIG_DIR"
docker compose --env-file .env config >/dev/null
docker compose --env-file .env pull
docker compose --env-file .env up -d

wait_http(){
  local name="$1" url="$2"
  for _ in {1..180}; do
    curl -fsS --max-time 2 "$url" >/dev/null 2>&1 && { ok "$name ready"; return 0; }
    sleep 1
  done
  warn "$name did not answer in time"
  return 1
}
wait_http Sonarr http://127.0.0.1:8989/ping || true
wait_http Radarr http://127.0.0.1:7878/ping || true
wait_http Prowlarr http://127.0.0.1:9696/ping || true
wait_http qBittorrent http://127.0.0.1:8080 || true
wait_http Jellyfin http://127.0.0.1:8096/health || true
wait_http Seerr http://127.0.0.1:5055/api/v1/settings/public || true

# Discover the actual API keys from config.xml, rather than assuming the
# generated values survived an existing installation.
xml_key(){
  sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$1" | head -n1
}
SONARR_KEY="$(xml_key "$CONFIG_DIR/sonarr/config.xml")"
RADARR_KEY="$(xml_key "$CONFIG_DIR/radarr/config.xml")"
PROWLARR_KEY="$(xml_key "$CONFIG_DIR/prowlarr/config.xml")"

curl -fsS -H "X-Api-Key: $SONARR_KEY" \
  -H "Content-Type: application/json" \
  -X POST http://127.0.0.1:8989/api/v3/rootfolder \
  -d '{"path":"/tv"}' >/dev/null 2>&1 || true

curl -fsS -H "X-Api-Key: $RADARR_KEY" \
  -H "Content-Type: application/json" \
  -X POST http://127.0.0.1:7878/api/v3/rootfolder \
  -d '{"path":"/movies"}' >/dev/null 2>&1 || true

# qBittorrent: discover temporary password, log in, then change credentials.
QCOOKIE="$(mktemp)"
cleanup(){ rm -f "$QCOOKIE"; }
trap cleanup EXIT

QPASS=""
for _ in {1..30}; do
  QPASS="$(docker logs qbittorrent 2>&1 | sed -nE 's/.*temporary password.*is ([^ ]+).*/\1/p' | tail -n1 || true)"
  [[ -n "$QPASS" ]] && break
  sleep 1
done

if [[ -n "$QPASS" ]] && curl -fsS -c "$QCOOKIE" \
  -X POST -d "username=admin" --data-urlencode "password=$QPASS" \
  http://127.0.0.1:8080/api/v2/auth/login | grep -q 'Ok.'; then

  curl -fsS -b "$QCOOKIE" -X POST \
    --data-urlencode "json={\"web_ui_username\":\"$APP_USER\",\"web_ui_password\":\"$APP_PASS\",\"save_path\":\"/downloads/complete/\",\"temp_path_enabled\":true,\"temp_path\":\"/downloads/incomplete/\"}" \
    http://127.0.0.1:8080/api/v2/app/setPreferences >/dev/null || true

  # Login again with the final shared credentials.
  curl -fsS -c "$QCOOKIE" -X POST \
    --data-urlencode "username=$APP_USER" --data-urlencode "password=$APP_PASS" \
    http://127.0.0.1:8080/api/v2/auth/login >/dev/null || true
  ok "qBittorrent credentials/download paths configured"
else
  warn "Could not discover qBittorrent's temporary password. It is still running; inspect docker logs qbittorrent."
fi

qbit_client_json(){
  local category="$1"
  jq -nc --arg u "$APP_USER" --arg p "$APP_PASS" --arg c "$category" '{
    enable:true,protocol:"torrent",priority:1,name:"qBittorrent",
    fields:[
      {name:"host",value:"qbittorrent"},
      {name:"port",value:8080},
      {name:"useSsl",value:false},
      {name:"username",value:$u},
      {name:"password",value:$p},
      {name:"tvCategory",value:$c},
      {name:"movieCategory",value:$c}
    ],
    implementationName:"qBittorrent",implementation:"QBittorrent",
    configContract:"QBittorrentSettings",tags:[]
  }'
}

# Add clients only if absent. Exact fields are intentionally minimal and are
# accepted by current Arr API schemas.
for app in sonarr radarr; do
  base="http://127.0.0.1:${PORT_SONARR}"
  key="$SONARR_KEY"
  [[ "$app" == radarr ]] && base="http://127.0.0.1:${PORT_RADARR}" && key="$RADARR_KEY"
  clients="$(curl -fsS -H "X-Api-Key: $key" "$base/api/v3/downloadclient" || echo '[]')"
  if ! echo "$clients" | jq -e '.[] | select(.implementation=="QBittorrent")' >/dev/null; then
    body="$(qbit_client_json "$app")"
    curl -fsS -H "X-Api-Key: $key" -H "Content-Type: application/json" \
      -X POST "$base/api/v3/downloadclient" -d "$body" >/dev/null 2>&1 || true
  fi
done

# Prowlarr -> Sonarr/Radarr. Use current API field names and update if an app exists.
prowlarr_app(){
  local name="$1" impl="$2" url="$3" key="$4"
  jq -nc --arg n "$name" --arg i "$impl" --arg u "$url" --arg k "$key" '{
    name:$n,implementation:$i,implementationName:$i,configContract:($i+"Settings"),
    syncLevel:"fullSync",fields:[
      {name:"prowlarrUrl",value:"http://prowlarr:9696"},
      {name:"baseUrl",value:$u},
      {name:"apiKey",value:$k}
    ],tags:[]
  }'
}
PAPPS="$(curl -fsS -H "X-Api-Key: $PROWLARR_KEY" http://127.0.0.1:9696/api/v1/applications || echo '[]')"
if ! echo "$PAPPS" | jq -e '.[] | select(.name=="Sonarr")' >/dev/null; then
  curl -fsS -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
    -X POST http://127.0.0.1:9696/api/v1/applications \
    -d "$(prowlarr_app Sonarr Sonarr http://sonarr:8989 "$SONARR_KEY")" >/dev/null 2>&1 || true
fi
if ! echo "$PAPPS" | jq -e '.[] | select(.name=="Radarr")' >/dev/null; then
  curl -fsS -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
    -X POST http://127.0.0.1:9696/api/v1/applications \
    -d "$(prowlarr_app Radarr Radarr http://radarr:7878 "$RADARR_KEY")" >/dev/null 2>&1 || true
fi

if [[ -n "$TS_AUTH" ]]; then
  tailscale up --authkey="$TS_AUTH" --hostname="media-server" --accept-dns=true || warn "Tailscale authentication failed"
else
  warn "Tailscale installed but not authenticated."
fi

cat > "$CONFIG_DIR/start.sh" <<EOF
#!/usr/bin/env bash
cd "$CONFIG_DIR"; docker compose --env-file .env up -d
EOF
cat > "$CONFIG_DIR/stop.sh" <<EOF
#!/usr/bin/env bash
cd "$CONFIG_DIR"; docker compose --env-file .env down
EOF
cat > "$CONFIG_DIR/restart.sh" <<EOF
#!/usr/bin/env bash
cd "$CONFIG_DIR"; docker compose --env-file .env restart
EOF
cat > "$CONFIG_DIR/update.sh" <<EOF
#!/usr/bin/env bash
cd "$CONFIG_DIR"; docker compose --env-file .env pull; docker compose --env-file .env up -d
EOF
cat > "$CONFIG_DIR/status.sh" <<EOF
#!/usr/bin/env bash
cd "$CONFIG_DIR"; docker compose --env-file .env ps
EOF
cat > "$CONFIG_DIR/logs.sh" <<EOF
#!/usr/bin/env bash
cd "$CONFIG_DIR"; docker compose --env-file .env logs -f
EOF
chmod +x "$CONFIG_DIR"/*.sh

cat > "$CONFIG_DIR/credentials.txt" <<EOF
MEDIA SERVER CREDENTIALS
Username: $APP_USER
Password: $APP_PASS

Sonarr API: $SONARR_KEY
Radarr API: $RADARR_KEY
Prowlarr API: $PROWLARR_KEY

Jellyfin: http://localhost:8096
Seerr: http://localhost:5055
qBittorrent: http://localhost:8080
Prowlarr: http://localhost:9696
Sonarr: http://localhost:8989
Radarr: http://localhost:7878
EOF
chmod 600 "$CONFIG_DIR/credentials.txt"

ok "Installation complete."
echo
echo "Config: $CONFIG_DIR"
echo "Media:  $MEDIA_DIR"
echo "Open:"
echo "  Jellyfin    http://localhost:8096"
echo "  Seerr       http://localhost:5055"
echo "  qBittorrent http://localhost:8080"
echo "  Prowlarr    http://localhost:9696"
echo "  Sonarr      http://localhost:8989"
echo "  Radarr      http://localhost:7878"
echo
echo "Seerr's supported first-run wizard still requires the initial Jellyfin/owner setup."
