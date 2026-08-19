#requires -Version 5.1
<#
===============================================================================
 AUTOMATED WINDOWS MEDIA SERVER

 Installs:
   - Docker Desktop
   - Jellyfin
   - Seerr
   - qBittorrent
   - Prowlarr
   - Sonarr
   - Radarr
   - Tailscale

 Automatically configures:
   - Persistent Docker Compose stack
   - Media directories
   - Download directories
   - Sonarr API key
   - Radarr API key
   - Prowlarr API key
   - Sonarr -> qBittorrent
   - Radarr -> qBittorrent
   - Prowlarr -> Sonarr
   - Prowlarr -> Radarr
   - Sonarr TV root folder
   - Radarr movie root folder
   - qBittorrent download directories
   - Tailscale

 Prompts:
   - Media directory
   - Config directory
   - Username
   - Password
   - Optional Tailscale auth key

 NOTE:
   Seerr's owner initialization/authentication is intentionally not
   performed by modifying its database. The installer starts Seerr and
   opens its setup page. After Jellyfin authentication, the supported
   Seerr APIs can be used for further automation.

 Run:
   Set-ExecutionPolicy -Scope Process Bypass
   .\install-media-stack.ps1

 Optional:
   .\install-media-stack.ps1 -TailscaleAuthKey "tskey-auth-..."
===============================================================================
#>

$ErrorActionPreference = "Stop"

function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function OK($m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Die($m){ Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die "Run PowerShell as Administrator."
}

$TZ = "America/Los_Angeles"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Info "Installing Docker Desktop..."
        winget install --id Docker.DockerDesktop --exact --accept-package-agreements --accept-source-agreements
    } else {
        Die "Docker Desktop is required. Install Docker Desktop with WSL2 and rerun."
    }
}

if (-not (Get-Command tailscale -ErrorAction SilentlyContinue) -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    Info "Installing Tailscale..."
    winget install --id Tailscale.Tailscale --exact --accept-package-agreements --accept-source-agreements
}

$dockerOk = $false
for($i=0;$i -lt 60;$i++){
    try { docker info | Out-Null; $dockerOk=$true; break } catch { Start-Sleep 2 }
}
if(-not $dockerOk){ Die "Docker Desktop is not running. Start it and rerun." }

docker compose version | Out-Null

$MEDIA_DIR = Read-Host "Media directory"
$CONFIG_DIR = Read-Host "Config directory"
$APP_USER = Read-Host "Application username"
$sec = Read-Host "Application password" -AsSecureString
$APP_PASS = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
$TS_AUTH = Read-Host "Tailscale auth key (Enter to skip)"

if([string]::IsNullOrWhiteSpace($MEDIA_DIR) -or [string]::IsNullOrWhiteSpace($CONFIG_DIR) -or [string]::IsNullOrWhiteSpace($APP_USER) -or [string]::IsNullOrWhiteSpace($APP_PASS)){
    Die "Media, config, username and password are required."
}

$MEDIA_DIR = [IO.Path]::GetFullPath($MEDIA_DIR)
$CONFIG_DIR = [IO.Path]::GetFullPath($CONFIG_DIR)

$dirs = @(
 "$MEDIA_DIR\movies","$MEDIA_DIR\tv","$MEDIA_DIR\music",
 "$MEDIA_DIR\downloads\complete","$MEDIA_DIR\downloads\incomplete",
 "$CONFIG_DIR\jellyfin","$CONFIG_DIR\seerr","$CONFIG_DIR\qbittorrent",
 "$CONFIG_DIR\prowlarr","$CONFIG_DIR\sonarr","$CONFIG_DIR\radarr"
)
$dirs | ForEach-Object { New-Item -ItemType Directory -Force -Path $_ | Out-Null }

function New-Key { -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) }) }
$SONARR_KEY = New-Key
$RADARR_KEY = New-Key
$PROWLARR_KEY = New-Key

@"
TZ=$TZ
MEDIA_DIR=$($MEDIA_DIR -replace '\\','/')
CONFIG_DIR=$($CONFIG_DIR -replace '\\','/')
APP_USERNAME=$APP_USER
APP_PASSWORD=$APP_PASS
SONARR_API_KEY=$SONARR_KEY
RADARR_API_KEY=$RADARR_KEY
PROWLARR_API_KEY=$PROWLARR_KEY
"@ | Set-Content -Encoding UTF8 "$CONFIG_DIR\.env"

@'
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
'@ | Set-Content -Encoding UTF8 "$CONFIG_DIR\compose.yaml"

$sonarrXml = "<Config><LogLevel>info</LogLevel><UrlBase></UrlBase><BindAddress>*</BindAddress><Port>8989</Port><EnableSsl>False</EnableSsl><LaunchBrowser>False</LaunchBrowser><ApiKey>$SONARR_KEY</ApiKey><AuthenticationMethod>None</AuthenticationMethod><Branch>main</Branch><UpdateMechanism>Docker</UpdateMechanism><UpdateAutomatically>False</UpdateAutomatically><InstanceName>Sonarr</InstanceName></Config>"
$radarrXml = "<Config><LogLevel>info</LogLevel><UrlBase></UrlBase><BindAddress>*</BindAddress><Port>7878</Port><EnableSsl>False</EnableSsl><LaunchBrowser>False</LaunchBrowser><ApiKey>$RADARR_KEY</ApiKey><AuthenticationMethod>None</AuthenticationMethod><Branch>master</Branch><UpdateMechanism>Docker</UpdateMechanism><UpdateAutomatically>False</UpdateAutomatically><InstanceName>Radarr</InstanceName></Config>"
$prowlarrXml = "<Config><LogLevel>info</LogLevel><UrlBase></UrlBase><BindAddress>*</BindAddress><Port>9696</Port><EnableSsl>False</EnableSsl><LaunchBrowser>False</LaunchBrowser><ApiKey>$PROWLARR_KEY</ApiKey><AuthenticationMethod>None</AuthenticationMethod><Branch>master</Branch><UpdateMechanism>Docker</UpdateMechanism><UpdateAutomatically>False</UpdateAutomatically><InstanceName>Prowlarr</InstanceName></Config>"
$sonarrXml | Set-Content -Encoding UTF8 "$CONFIG_DIR\sonarr\config.xml"
$radarrXml | Set-Content -Encoding UTF8 "$CONFIG_DIR\radarr\config.xml"
$prowlarrXml | Set-Content -Encoding UTF8 "$CONFIG_DIR\prowlarr\config.xml"

Push-Location $CONFIG_DIR
docker compose --env-file .env config | Out-Null
docker compose --env-file .env pull
docker compose --env-file .env up -d
Pop-Location

function Wait-Http($name,$url){
    for($i=0;$i -lt 180;$i++){
        try { Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 2 | Out-Null; OK "$name ready"; return }
        catch { Start-Sleep 1 }
    }
    Warn "$name did not answer in time"
}
Wait-Http "Sonarr" "http://127.0.0.1:8989/ping"
Wait-Http "Radarr" "http://127.0.0.1:7878/ping"
Wait-Http "Prowlarr" "http://127.0.0.1:9696/ping"
Wait-Http "qBittorrent" "http://127.0.0.1:8080"
Wait-Http "Jellyfin" "http://127.0.0.1:8096/health"
Wait-Http "Seerr" "http://127.0.0.1:5055/api/v1/settings/public"

function Invoke-JsonApi($Method,$Uri,$Key,$Body=$null){
    $headers=@{"X-Api-Key"=$Key}
    if($null -eq $Body){ return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 10)
}

# Root folders
try { Invoke-JsonApi POST "http://127.0.0.1:8989/api/v3/rootfolder" $SONARR_KEY @{path="/tv"} | Out-Null } catch {}
try { Invoke-JsonApi POST "http://127.0.0.1:7878/api/v3/rootfolder" $RADARR_KEY @{path="/movies"} | Out-Null } catch {}

# qBittorrent temporary password discovery and credential update.
$logs = docker logs qbittorrent 2>&1
$qpass = ($logs | Select-String -Pattern "temporary password.*is ([^ ]+)" | Select-Object -Last 1).Matches.Groups[1].Value
if($qpass){
    try {
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $form = @{username="admin";password=$qpass}
        Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8080/api/v2/auth/login" -Method Post -Body $form -WebSession $session | Out-Null
        $prefs = @{
            web_ui_username=$APP_USER
            web_ui_password=$APP_PASS
            save_path="/downloads/complete/"
            temp_path_enabled=$true
            temp_path="/downloads/incomplete/"
        } | ConvertTo-Json -Compress
        Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8080/api/v2/app/setPreferences" -Method Post -Body @{json=$prefs} -WebSession $session | Out-Null
        OK "qBittorrent credentials/download paths configured"
    } catch { Warn "qBittorrent API configuration failed: $($_.Exception.Message)" }
} else { Warn "Could not discover qBittorrent temporary password." }

function QbitClient($category){
    return @{
        enable=$true; protocol="torrent"; priority=1; name="qBittorrent"
        fields=@(
          @{name="host";value="qbittorrent"},
          @{name="port";value=8080},
          @{name="useSsl";value=$false},
          @{name="username";value=$APP_USER},
          @{name="password";value=$APP_PASS},
          @{name="tvCategory";value=$category},
          @{name="movieCategory";value=$category}
        )
        implementationName="qBittorrent"; implementation="QBittorrent"; configContract="QBittorrentSettings"; tags=@()
    }
}

foreach($x in @(
    @{name="Sonarr";base="http://127.0.0.1:8989";key=$SONARR_KEY;cat="sonarr"},
    @{name="Radarr";base="http://127.0.0.1:7878";key=$RADARR_KEY;cat="radarr"}
)){
    try {
        $clients=Invoke-JsonApi GET "$($x.base)/api/v3/downloadclient" $x.key
        if(-not ($clients | Where-Object implementation -eq "QBittorrent")){
            Invoke-JsonApi POST "$($x.base)/api/v3/downloadclient" $x.key (QbitClient $x.cat) | Out-Null
        }
    } catch { Warn "$($x.name) qBittorrent configuration failed: $($_.Exception.Message)" }
}

function ProwlarrApp($name,$url,$key){
    return @{
      name=$name; implementation=$name; implementationName=$name
      configContract="${name}Settings"; syncLevel="fullSync"; tags=@()
      fields=@(
        @{name="prowlarrUrl";value="http://prowlarr:9696"},
        @{name="baseUrl";value=$url},
        @{name="apiKey";value=$key}
      )
    }
}
try {
    $apps=Invoke-JsonApi GET "http://127.0.0.1:9696/api/v1/applications" $PROWLARR_KEY
    if(-not ($apps | Where-Object name -eq "Sonarr")){ Invoke-JsonApi POST "http://127.0.0.1:9696/api/v1/applications" $PROWLARR_KEY (ProwlarrApp "Sonarr" "http://sonarr:8989" $SONARR_KEY) | Out-Null }
    if(-not ($apps | Where-Object name -eq "Radarr")){ Invoke-JsonApi POST "http://127.0.0.1:9696/api/v1/applications" $PROWLARR_KEY (ProwlarrApp "Radarr" "http://radarr:7878" $RADARR_KEY) | Out-Null }
} catch { Warn "Prowlarr application configuration failed: $($_.Exception.Message)" }

if($TS_AUTH -and (Get-Command tailscale -ErrorAction SilentlyContinue)){
    try { tailscale up --authkey=$TS_AUTH --hostname=media-server --accept-dns=true; OK "Tailscale authenticated" }
    catch { Warn "Tailscale authentication failed" }
} elseif(Get-Command tailscale -ErrorAction SilentlyContinue) {
    Warn "Tailscale installed but not authenticated."
}

@"
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
"@ | Set-Content -Encoding UTF8 "$CONFIG_DIR\credentials.txt"

@"
Set-Location "$CONFIG_DIR"
docker compose --env-file .env up -d
"@ | Set-Content "$CONFIG_DIR\start.ps1"

@"
Set-Location "$CONFIG_DIR"
docker compose --env-file .env down
"@ | Set-Content "$CONFIG_DIR\stop.ps1"

@"
Set-Location "$CONFIG_DIR"
docker compose --env-file .env restart
"@ | Set-Content "$CONFIG_DIR\restart.ps1"

@"
Set-Location "$CONFIG_DIR"
docker compose --env-file .env pull
docker compose --env-file .env up -d
"@ | Set-Content "$CONFIG_DIR\update.ps1"

@"
Set-Location "$CONFIG_DIR"
docker compose --env-file .env ps
"@ | Set-Content "$CONFIG_DIR\status.ps1"

OK "Installation complete."
Write-Host ""
Write-Host "Config: $CONFIG_DIR"
Write-Host "Media:  $MEDIA_DIR"
Write-Host "Open:"
Write-Host "  Jellyfin    http://localhost:8096"
Write-Host "  Seerr       http://localhost:5055"
Write-Host "  qBittorrent http://localhost:8080"
Write-Host "  Prowlarr    http://localhost:9696"
Write-Host "  Sonarr      http://localhost:8989"
Write-Host "  Radarr      http://localhost:7878"
Write-Host ""
Write-Host "Seerr's supported first-run wizard still requires the initial Jellyfin/owner setup."
