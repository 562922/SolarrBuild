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

[CmdletBinding()]
param(
    [string]$TailscaleAuthKey = ""
)

$ErrorActionPreference = "Stop"

# ============================================================================
# CONSTANTS
# ============================================================================

$JellyfinPort  = 8096
$SeerrPort     = 5055
$QbitPort      = 8080
$ProwlarrPort  = 9696
$SonarrPort    = 8989
$RadarrPort    = 7878

$StackName = "media-stack"

# ============================================================================
# COLORS / OUTPUT
# ============================================================================

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Section {
    param([string]$Message)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host $Message -ForegroundColor DarkCyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""
}

# ============================================================================
# ADMIN CHECK
# ============================================================================

Write-Section "Checking Windows"

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)

$IsAdmin = $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $IsAdmin) {
    Write-Fail "This installer must be run as Administrator."
    Write-Host ""
    Write-Host "Right-click PowerShell and select 'Run as administrator'."
    exit 1
}

Write-OK "Running as Administrator."

# ============================================================================
# WINDOWS VERSION
# ============================================================================

$WindowsVersion = [System.Environment]::OSVersion.Version

Write-Info "Windows version: $WindowsVersion"

# ============================================================================
# POWERSHELL
# ============================================================================

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Fail "PowerShell 5.1 or newer is required."
    exit 1
}

Write-OK "PowerShell version supported."

# ============================================================================
# WINGET
# ============================================================================

Write-Section "Checking package manager"

$Winget = Get-Command winget -ErrorAction SilentlyContinue

if (-not $Winget) {
    Write-Fail "winget was not found."
    Write-Host ""
    Write-Host "Install/update 'App Installer' from the Microsoft Store and rerun."
    exit 1
}

Write-OK "winget available."

# ============================================================================
# DOCKER DESKTOP
# ============================================================================

Write-Section "Installing Docker Desktop"

$DockerCommand = Get-Command docker -ErrorAction SilentlyContinue

if (-not $DockerCommand) {

    Write-Info "Docker is not installed."
    Write-Info "Installing Docker Desktop..."

    winget install `
        --id Docker.DockerDesktop `
        --exact `
        --accept-source-agreements `
        --accept-package-agreements

    Write-OK "Docker Desktop installed."

} else {

    Write-OK "Docker CLI already installed."

}

# ============================================================================
# START DOCKER DESKTOP
# ============================================================================

Write-Section "Starting Docker Desktop"

$DockerExe = "$Env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

if (Test-Path $DockerExe) {

    Start-Process `
        -FilePath $DockerExe `
        -WindowStyle Hidden

} else {

    $DockerExe = "$Env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

    if (Test-Path $DockerExe) {
        Start-Process $DockerExe
    }

}

Write-Info "Waiting for Docker Desktop..."

$DockerReady = $false

for ($i = 0; $i -lt 90; $i++) {

    try {

        docker info *> $null

        if ($LASTEXITCODE -eq 0) {
            $DockerReady = $true
            break
        }

    } catch {}

    Start-Sleep -Seconds 2

}

if (-not $DockerReady) {

    Write-Fail "Docker Desktop did not become ready."
    Write-Host ""
    Write-Host "Open Docker Desktop, wait until it says it is running, then rerun."
    exit 1

}

Write-OK "Docker is running."

# ============================================================================
# DOCKER COMPOSE
# ============================================================================

try {

    docker compose version *> $null

    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose unavailable"
    }

} catch {

    Write-Fail "Docker Compose is unavailable."
    exit 1

}

Write-OK "Docker Compose available."

# ============================================================================
# TAILSCALE
# ============================================================================

Write-Section "Installing Tailscale"

$TailscaleCommand = Get-Command tailscale -ErrorAction SilentlyContinue

if (-not $TailscaleCommand) {

    Write-Info "Installing Tailscale..."

    winget install `
        --id Tailscale.Tailscale `
        --exact `
        --accept-source-agreements `
        --accept-package-agreements

    Write-OK "Tailscale installed."

} else {

    Write-OK "Tailscale already installed."

}

# ============================================================================
# INPUT
# ============================================================================

Write-Section "Server configuration"

Write-Host "The installer needs the following locations."
Write-Host ""

$MediaDirectory = Read-Host "Media directory"
$ConfigDirectory = Read-Host "Config directory"

if ([string]::IsNullOrWhiteSpace($MediaDirectory)) {
    Write-Fail "Media directory cannot be empty."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ConfigDirectory)) {
    Write-Fail "Config directory cannot be empty."
    exit 1
}

$MediaDirectory = [Environment]::ExpandEnvironmentVariables($MediaDirectory)
$ConfigDirectory = [Environment]::ExpandEnvironmentVariables($ConfigDirectory)

# Resolve paths
$MediaDirectory = [System.IO.Path]::GetFullPath($MediaDirectory)
$ConfigDirectory = [System.IO.Path]::GetFullPath($ConfigDirectory)

Write-Host ""

$AppUsername = Read-Host "Username for media applications"

if ([string]::IsNullOrWhiteSpace($AppUsername)) {
    Write-Fail "Username cannot be empty."
    exit 1
}

$PasswordSecure = Read-Host "Password for media applications" -AsSecureString

$PasswordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
    $PasswordSecure
)

try {
    $AppPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        $PasswordPointer
    )
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($PasswordPointer)
}

if ([string]::IsNullOrWhiteSpace($AppPassword)) {
    Write-Fail "Password cannot be empty."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($TailscaleAuthKey)) {

    Write-Host ""
    $TailscaleAuthKey = Read-Host `
        "Tailscale auth key (press Enter to skip)"

}

# ============================================================================
# CREATE DIRECTORIES
# ============================================================================

Write-Section "Creating directories"

$Directories = @(
    $MediaDirectory
    $ConfigDirectory

    "$MediaDirectory\movies"
    "$MediaDirectory\tv"
    "$MediaDirectory\music"

    "$MediaDirectory\downloads"
    "$MediaDirectory\downloads\complete"
    "$MediaDirectory\downloads\incomplete"

    "$ConfigDirectory\jellyfin"
    "$ConfigDirectory\seerr"
    "$ConfigDirectory\qbittorrent"
    "$ConfigDirectory\prowlarr"
    "$ConfigDirectory\sonarr"
    "$ConfigDirectory\radarr"
    "$ConfigDirectory\tailscale"
)

foreach ($Directory in $Directories) {

    if (-not (Test-Path $Directory)) {

        New-Item `
            -ItemType Directory `
            -Path $Directory `
            -Force | Out-Null

    }

}

Write-OK "Directory structure created."

# ============================================================================
# GENERATE API KEYS
# ============================================================================

Write-Section "Generating application API keys"

function New-RandomKey {

    $Bytes = New-Object byte[] 32

    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Bytes)

    return (
        [Convert]::ToHexString($Bytes)
    ).ToLower()

}

$SonarrApiKey   = New-RandomKey
$RadarrApiKey   = New-RandomKey
$ProwlarrApiKey = New-RandomKey
$SeerrApiKey    = New-RandomKey

Write-OK "API keys generated."

# ============================================================================
# ENVIRONMENT FILE
# ============================================================================

Write-Section "Creating environment"

$EnvFile = @"
TZ=America/Los_Angeles

MEDIA_DIR=$($MediaDirectory.Replace('\','/'))
CONFIG_DIR=$($ConfigDirectory.Replace('\','/'))

APP_USERNAME=$AppUsername
APP_PASSWORD=$AppPassword

SONARR_API_KEY=$SonarrApiKey
RADARR_API_KEY=$RadarrApiKey
PROWLARR_API_KEY=$ProwlarrApiKey
SEERR_API_KEY=$SeerrApiKey

TAILSCALE_AUTH_KEY=$TailscaleAuthKey
"@

$EnvPath = Join-Path $ConfigDirectory ".env"

Set-Content `
    -Path $EnvPath `
    -Value $EnvFile `
    -Encoding UTF8

Write-OK ".env created."

# ============================================================================
# SONARR CONFIG
# ============================================================================

Write-Section "Preparing Sonarr"

$SonarrConfig = @"
<Config>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <Port>8989</Port>
  <SslPort>9898</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>$SonarrApiKey</ApiKey>
  <AuthenticationMethod>None</AuthenticationMethod>
  <Branch>main</Branch>
  <UpdateMechanism>Docker</UpdateMechanism>
  <UpdateAutomatically>False</UpdateAutomatically>
  <InstanceName>Sonarr</InstanceName>
</Config>
"@

Set-Content `
    -Path "$ConfigDirectory\sonarr\config.xml" `
    -Value $SonarrConfig `
    -Encoding UTF8

# ============================================================================
# RADARR CONFIG
# ============================================================================

Write-Section "Preparing Radarr"

$RadarrConfig = @"
<Config>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <Port>7878</Port>
  <SslPort>9899</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>$RadarrApiKey</ApiKey>
  <AuthenticationMethod>None</AuthenticationMethod>
  <Branch>master</Branch>
  <UpdateMechanism>Docker</UpdateMechanism>
  <UpdateAutomatically>False</UpdateAutomatically>
  <InstanceName>Radarr</InstanceName>
</Config>
"@

Set-Content `
    -Path "$ConfigDirectory\radarr\config.xml" `
    -Value $RadarrConfig `
    -Encoding UTF8

# ============================================================================
# PROWLARR CONFIG
# ============================================================================

Write-Section "Preparing Prowlarr"

$ProwlarrConfig = @"
<Config>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <Port>9696</Port>
  <SslPort>6969</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>$ProwlarrApiKey</ApiKey>
  <AuthenticationMethod>None</AuthenticationMethod>
  <Branch>master</Branch>
  <UpdateMechanism>Docker</UpdateMechanism>
  <UpdateAutomatically>False</UpdateAutomatically>
  <InstanceName>Prowlarr</InstanceName>
</Config>
"@

Set-Content `
    -Path "$ConfigDirectory\prowlarr\config.xml" `
    -Value $ProwlarrConfig `
    -Encoding UTF8

# ============================================================================
# DOCKER COMPOSE
# ============================================================================

Write-Section "Creating Docker Compose"

$Compose = @'
services:

  # ==========================================================
  # JELLYFIN
  # ==========================================================

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

  # ==========================================================
  # SEERR
  # ==========================================================

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

  # ==========================================================
  # QBITTORRENT
  # ==========================================================

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

  # ==========================================================
  # PROWLARR
  # ==========================================================

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

  # ==========================================================
  # SONARR
  # ==========================================================

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

  # ==========================================================
  # RADARR
  # ==========================================================

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

networks:
  media:
    name: media
    driver: bridge
'@

$ComposePath = Join-Path $ConfigDirectory "compose.yaml"

Set-Content `
    -Path $ComposePath `
    -Value $Compose `
    -Encoding UTF8

Write-OK "compose.yaml created."

# ============================================================================
# VALIDATE COMPOSE
# ============================================================================

Write-Section "Validating Docker Compose"

Push-Location $ConfigDirectory

try {

    docker compose --env-file ".env" config *> $null

    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose validation failed."
    }

}
finally {

    Pop-Location

}

Write-OK "Docker Compose configuration is valid."

# ============================================================================
# PULL IMAGES
# ============================================================================

Write-Section "Downloading Docker images"

Push-Location $ConfigDirectory

try {

    docker compose --env-file ".env" pull

    if ($LASTEXITCODE -ne 0) {
        throw "Docker image download failed."
    }

}
finally {

    Pop-Location

}

Write-OK "Docker images downloaded."

# ============================================================================
# START STACK
# ============================================================================

Write-Section "Starting containers"

Push-Location $ConfigDirectory

try {

    docker compose --env-file ".env" up -d

    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose startup failed."
    }

}
finally {

    Pop-Location

}

Write-OK "Containers started."

# ============================================================================
# HTTP WAIT
# ============================================================================

function Wait-ForHttp {

    param(
        [string]$Name,
        [string]$Url,
        [int]$TimeoutSeconds = 120
    )

    Write-Info "Waiting for $Name..."

    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {

        try {

            $Response = Invoke-WebRequest `
                -Uri $Url `
                -UseBasicParsing `
                -TimeoutSec 3 `
                -ErrorAction Stop

            if ($Response.StatusCode -ge 200 -and
                $Response.StatusCode -lt 500) {

                Write-OK "$Name is responding."
                return $true

            }

        } catch {}

        Start-Sleep -Seconds 1

    }

    Write-Warn "$Name did not respond within $TimeoutSeconds seconds."

    return $false
}

# ============================================================================
# WAIT
# ============================================================================

Write-Section "Waiting for applications"

Wait-ForHttp `
    "Sonarr" `
    "http://localhost:$SonarrPort/ping" `
    120 | Out-Null

Wait-ForHttp `
    "Radarr" `
    "http://localhost:$RadarrPort/ping" `
    120 | Out-Null

Wait-ForHttp `
    "Prowlarr" `
    "http://localhost:$ProwlarrPort/ping" `
    120 | Out-Null

Wait-ForHttp `
    "qBittorrent" `
    "http://localhost:$QbitPort" `
    120 | Out-Null

Wait-ForHttp `
    "Jellyfin" `
    "http://localhost:$JellyfinPort/health" `
    120 | Out-Null

Wait-ForHttp `
    "Seerr" `
    "http://localhost:$SeerrPort" `
    120 | Out-Null

# ============================================================================
# REST HELPERS
# ============================================================================

function Invoke-ApiGet {

    param(
        [string]$Url,
        [string]$ApiKey
    )

    return Invoke-RestMethod `
        -Uri $Url `
        -Headers @{
            "X-Api-Key" = $ApiKey
        } `
        -Method Get

}

function Invoke-ApiPost {

    param(
        [string]$Url,
        [string]$ApiKey,
        [object]$Body
    )

    return Invoke-RestMethod `
        -Uri $Url `
        -Headers @{
            "X-Api-Key" = $ApiKey
        } `
        -ContentType "application/json" `
        -Method Post `
        -Body ($Body | ConvertTo-Json -Depth 20)

}

# ============================================================================
# SONARR ROOT FOLDER
# ============================================================================

Write-Section "Configuring Sonarr"

try {

    $SonarrRoots = Invoke-ApiGet `
        "http://localhost:$SonarrPort/api/v3/rootfolder" `
        $SonarrApiKey

    $ExistingTV = $SonarrRoots |
        Where-Object { $_.path -eq "/tv" }

    if (-not $ExistingTV) {

        Invoke-ApiPost `
            "http://localhost:$SonarrPort/api/v3/rootfolder" `
            $SonarrApiKey `
            @{
                path = "/tv"
            } | Out-Null

    }

    Write-OK "Sonarr TV root folder configured."

}
catch {

    Write-Warn "Could not configure Sonarr root folder."
}

# ============================================================================
# RADARR ROOT FOLDER
# ============================================================================

Write-Section "Configuring Radarr"

try {

    $RadarrRoots = Invoke-ApiGet `
        "http://localhost:$RadarrPort/api/v3/rootfolder" `
        $RadarrApiKey

    $ExistingMovies = $RadarrRoots |
        Where-Object { $_.path -eq "/movies" }

    if (-not $ExistingMovies) {

        Invoke-ApiPost `
            "http://localhost:$RadarrPort/api/v3/rootfolder" `
            $RadarrApiKey `
            @{
                path = "/movies"
            } | Out-Null

    }

    Write-OK "Radarr movie root folder configured."

}
catch {

    Write-Warn "Could not configure Radarr root folder."
}

# ============================================================================
# QBITTORRENT CONFIGURATION
# ============================================================================

Write-Section "Configuring qBittorrent"

$QbitCookieFile = Join-Path $env:TEMP "qbit-cookie-$([guid]::NewGuid()).txt"

$QbitLoggedIn = $false

# First try modern default credentials.
try {

    $LoginBody = "username=admin&password=adminadmin"

    $LoginResponse = Invoke-WebRequest `
        -Uri "http://localhost:$QbitPort/api/v2/auth/login" `
        -Method Post `
        -Body $LoginBody `
        -SessionVariable QbitSession `
        -UseBasicParsing `
        -ErrorAction Stop

    if ($LoginResponse.Content -eq "Ok.") {
        $QbitLoggedIn = $true
    }

}
catch {}

# Try extracting temporary password from container logs.
if (-not $QbitLoggedIn) {

    try {

        $Logs = docker logs qbittorrent 2>&1

        $PasswordLine = $Logs |
            Select-String -Pattern "temporary password" |
            Select-Object -Last 1

        if ($PasswordLine) {

            $TempPassword = (
                $PasswordLine.ToString() -split ":\s*"
            )[-1].Trim()

            if ($TempPassword) {

                $LoginResponse = Invoke-WebRequest `
                    -Uri "http://localhost:$QbitPort/api/v2/auth/login" `
                    -Method Post `
                    -Body @{
                        username = "admin"
                        password = $TempPassword
                    } `
                    -SessionVariable QbitSession `
                    -UseBasicParsing `
                    -ErrorAction Stop

                if ($LoginResponse.Content -eq "Ok.") {
                    $QbitLoggedIn = $true
                }

            }

        }

    }
    catch {}

}

if ($QbitLoggedIn) {

    try {

        $Preferences = @{
            web_ui_username = $AppUsername
            web_ui_password = $AppPassword

            save_path = "/downloads/complete/"
            temp_path_enabled = $true
            temp_path = "/downloads/incomplete/"

            use_subcategories = $true
        }

        $JsonPreferences = (
            $Preferences | ConvertTo-Json -Compress
        )

        Invoke-WebRequest `
            -Uri "http://localhost:$QbitPort/api/v2/app/setPreferences" `
            -Method Post `
            -WebSession $QbitSession `
            -Body @{
                json = $JsonPreferences
            } `
            -UseBasicParsing `
            -ErrorAction Stop | Out-Null

        Write-OK "qBittorrent configured."

    }
    catch {

        Write-Warn "qBittorrent logged in but preferences could not be changed."

    }

}
else {

    Write-Warn "Could not automatically log into qBittorrent."
    Write-Warn "The qBittorrent container is running."

}

# ============================================================================
# SONARR DOWNLOAD CLIENT
# ============================================================================

Write-Section "Connecting Sonarr to qBittorrent"

try {

    $ExistingClients = Invoke-ApiGet `
        "http://localhost:$SonarrPort/api/v3/downloadclient" `
        $SonarrApiKey

    $ExistingQbit = $ExistingClients |
        Where-Object {
            $_.implementation -eq "QBittorrent"
        }

    if (-not $ExistingQbit) {

        $SonarrQbit = @{
            enable = $true
            protocol = "torrent"
            priority = 1
            name = "qBittorrent"
            implementationName = "qBittorrent"
            implementation = "QBittorrent"
            configContract = "QBittorrentSettings"

            fields = @(
                @{
                    name = "host"
                    value = "qbittorrent"
                },
                @{
                    name = "port"
                    value = 8080
                },
                @{
                    name = "username"
                    value = $AppUsername
                },
                @{
                    name = "password"
                    value = $AppPassword
                },
                @{
                    name = "movieCategory"
                    value = "tv"
                },
                @{
                    name = "useSsl"
                    value = $false
                }
            )

        }

        Invoke-ApiPost `
            "http://localhost:$SonarrPort/api/v3/downloadclient" `
            $SonarrApiKey `
            $SonarrQbit | Out-Null

    }

    Write-OK "Sonarr -> qBittorrent configured."

}
catch {

    Write-Warn "Could not configure Sonarr -> qBittorrent."
}

# ============================================================================
# RADARR DOWNLOAD CLIENT
# ============================================================================

Write-Section "Connecting Radarr to qBittorrent"

try {

    $ExistingClients = Invoke-ApiGet `
        "http://localhost:$RadarrPort/api/v3/downloadclient" `
        $RadarrApiKey

    $ExistingQbit = $ExistingClients |
        Where-Object {
            $_.implementation -eq "QBittorrent"
        }

    if (-not $ExistingQbit) {

        $RadarrQbit = @{
            enable = $true
            protocol = "torrent"
            priority = 1
            name = "qBittorrent"
            implementationName = "qBittorrent"
            implementation = "QBittorrent"
            configContract = "QBittorrentSettings"

            fields = @(
                @{
                    name = "host"
                    value = "qbittorrent"
                },
                @{
                    name = "port"
                    value = 8080
                },
                @{
                    name = "username"
                    value = $AppUsername
                },
                @{
                    name = "password"
                    value = $AppPassword
                },
                @{
                    name = "movieCategory"
                    value = "radarr"
                },
                @{
                    name = "useSsl"
                    value = $false
                }
            )

        }

        Invoke-ApiPost `
            "http://localhost:$RadarrPort/api/v3/downloadclient" `
            $RadarrApiKey `
            $RadarrQbit | Out-Null

    }

    Write-OK "Radarr -> qBittorrent configured."

}
catch {

    Write-Warn "Could not configure Radarr -> qBittorrent."
}

# ============================================================================
# PROWLARR APPLICATIONS
# ============================================================================

Write-Section "Connecting Prowlarr to Sonarr and Radarr"

try {

    $ProwlarrApplications = Invoke-ApiGet `
        "http://localhost:$ProwlarrPort/api/v1/applications" `
        $ProwlarrApiKey

}
catch {

    $ProwlarrApplications = @()

}

# ============================================================================
# PROWLARR -> SONARR
# ============================================================================

if (
    -not (
        $ProwlarrApplications |
        Where-Object {
            $_.name -eq "Sonarr"
        }
    )
) {

    try {

        $ProwlarrSonarr = @{
            name = "Sonarr"

            implementation = "Sonarr"
            implementationName = "Sonarr"
            configContract = "SonarrSettings"

            fields = @(
                @{
                    name = "prowlarrUrl"
                    value = "http://prowlarr:9696"
                },
                @{
                    name = "baseUrl"
                    value = "http://sonarr:8989"
                },
                @{
                    name = "apiKey"
                    value = $SonarrApiKey
                }
            )

            syncLevel = "fullSync"
            tags = @()
        }

        Invoke-ApiPost `
            "http://localhost:$ProwlarrPort/api/v1/applications" `
            $ProwlarrApiKey `
            $ProwlarrSonarr | Out-Null

        Write-OK "Prowlarr -> Sonarr configured."

    }
    catch {

        Write-Warn "Could not configure Prowlarr -> Sonarr."

    }

}
else {

    Write-OK "Prowlarr -> Sonarr already exists."

}

# ============================================================================
# PROWLARR -> RADARR
# ============================================================================

if (
    -not (
        $ProwlarrApplications |
        Where-Object {
            $_.name -eq "Radarr"
        }
    )
) {

    try {

        $ProwlarrRadarr = @{
            name = "Radarr"

            implementation = "Radarr"
            implementationName = "Radarr"
            configContract = "RadarrSettings"

            fields = @(
                @{
                    name = "prowlarrUrl"
                    value = "http://prowlarr:9696"
                },
                @{
                    name = "baseUrl"
                    value = "http://radarr:7878"
                },
                @{
                    name = "apiKey"
                    value = $RadarrApiKey
                }
            )

            syncLevel = "fullSync"
            tags = @()
        }

        Invoke-ApiPost `
            "http://localhost:$ProwlarrPort/api/v1/applications" `
            $ProwlarrApiKey `
            $ProwlarrRadarr | Out-Null

        Write-OK "Prowlarr -> Radarr configured."

    }
    catch {

        Write-Warn "Could not configure Prowlarr -> Radarr."

    }

}
else {

    Write-OK "Prowlarr -> Radarr already exists."

}

# ============================================================================
# TAILSCALE
# ============================================================================

Write-Section "Configuring Tailscale"

$TailscalePath = Get-Command tailscale -ErrorAction SilentlyContinue

if ($TailscalePath) {

    if (-not [string]::IsNullOrWhiteSpace($TailscaleAuthKey)) {

        Write-Info "Authenticating Tailscale..."

        try {

            tailscale up `
                --authkey=$TailscaleAuthKey `
                --hostname="media-server" `
                --accept-dns=true

            Write-OK "Tailscale authenticated."

        }
        catch {

            Write-Warn "Tailscale authentication failed."
            Write-Warn "Run 'tailscale up' manually."

        }

    }
    else {

        Write-Warn "No Tailscale auth key supplied."

        Write-Host ""
        Write-Host "To authenticate:"
        Write-Host ""
        Write-Host "    tailscale up"
        Write-Host ""

    }

}
else {

    Write-Warn "Tailscale executable was not found."

}

# ============================================================================
# MANAGEMENT SCRIPTS
# ============================================================================

Write-Section "Creating management scripts"

$StartScript = @"
Set-Location "$ConfigDirectory"
docker compose --env-file ".env" up -d
"@

$StopScript = @"
Set-Location "$ConfigDirectory"
docker compose --env-file ".env" down
"@

$RestartScript = @"
Set-Location "$ConfigDirectory"
docker compose --env-file ".env" restart
"@

$UpdateScript = @"
Set-Location "$ConfigDirectory"
docker compose --env-file ".env" pull
docker compose --env-file ".env" up -d
docker image prune -f
"@

$StatusScript = @"
Set-Location "$ConfigDirectory"
docker compose --env-file ".env" ps
"@

$LogsScript = @"
Set-Location "$ConfigDirectory"
docker compose --env-file ".env" logs -f
"@

$BackupScript = @"
`$Backup = Join-Path "`$env:USERPROFILE\Desktop" ("media-stack-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))

New-Item -ItemType Directory -Path `$Backup -Force | Out-Null

Copy-Item `
    "$ConfigDirectory\*" `
    `$Backup `
    -Recurse `
    -Force

Write-Host ""
Write-Host "Backup created:"
Write-Host `$Backup
"@

Set-Content "$ConfigDirectory\start.ps1"   $StartScript
Set-Content "$ConfigDirectory\stop.ps1"    $StopScript
Set-Content "$ConfigDirectory\restart.ps1" $RestartScript
Set-Content "$ConfigDirectory\update.ps1"  $UpdateScript
Set-Content "$ConfigDirectory\status.ps1"  $StatusScript
Set-Content "$ConfigDirectory\logs.ps1"    $LogsScript
Set-Content "$ConfigDirectory\backup.ps1"  $BackupScript

Write-OK "Management scripts created."

# ============================================================================
# CREDENTIAL FILE
# ============================================================================

Write-Section "Saving credentials"

$Credentials = @"
============================================================
MEDIA SERVER CREDENTIALS
============================================================

Username:
$AppUsername

Password:
$AppPassword


============================================================
API KEYS
============================================================

Sonarr:
$SonarrApiKey

Radarr:
$RadarrApiKey

Prowlarr:
$ProwlarrApiKey

Seerr:
$SeerrApiKey


============================================================
SERVICES
============================================================

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


============================================================
MEDIA
============================================================

Movies:
$MediaDirectory\movies

TV:
$MediaDirectory\tv

Music:
$MediaDirectory\music

Downloads:
$MediaDirectory\downloads


============================================================
CONFIG
============================================================

$ConfigDirectory


============================================================
MANAGEMENT
============================================================

Start:
$ConfigDirectory\start.ps1

Stop:
$ConfigDirectory\stop.ps1

Restart:
$ConfigDirectory\restart.ps1

Update:
$ConfigDirectory\update.ps1

Status:
$ConfigDirectory\status.ps1

Logs:
$ConfigDirectory\logs.ps1

Backup:
$ConfigDirectory\backup.ps1
"@

$CredentialsPath = "$ConfigDirectory\credentials.txt"

Set-Content `
    -Path $CredentialsPath `
    -Value $Credentials `
    -Encoding UTF8

# Restrict credentials file to current user
try {

    $Acl = Get-Acl $CredentialsPath

    $Acl.SetAccessRuleProtection(
        $true,
        $false
    )

    $Rule = New-Object `
        System.Security.AccessControl.FileSystemAccessRule(
            $env:USERNAME,
            "FullControl",
            "Allow"
        )

    $Acl.SetAccessRule($Rule)

    Set-Acl `
        -Path $CredentialsPath `
        -AclObject $Acl

}
catch {

    Write-Warn "Could not restrict credentials.txt permissions."

}

Write-OK "Credentials saved."

# ============================================================================
# FINAL STATUS
# ============================================================================

Write-Section "INSTALLATION COMPLETE"

Write-Host "Services:"
Write-Host ""
Write-Host "  Jellyfin:    http://localhost:$JellyfinPort"
Write-Host "  Seerr:       http://localhost:$SeerrPort"
Write-Host "  qBittorrent: http://localhost:$QbitPort"
Write-Host "  Prowlarr:    http://localhost:$ProwlarrPort"
Write-Host "  Sonarr:      http://localhost:$SonarrPort"
Write-Host "  Radarr:      http://localhost:$RadarrPort"

Write-Host ""
Write-Host "Media:"
Write-Host ""
Write-Host "  Movies:      $MediaDirectory\movies"
Write-Host "  TV:          $MediaDirectory\tv"
Write-Host "  Music:       $MediaDirectory\music"
Write-Host "  Downloads:   $MediaDirectory\downloads"

Write-Host ""
Write-Host "Configuration:"
Write-Host ""
Write-Host "  $ConfigDirectory"

Write-Host ""
Write-Host "Credentials:"
Write-Host ""
Write-Host "  $CredentialsPath"

Write-Host ""
Write-Host "Management:"
Write-Host ""
Write-Host "  $ConfigDirectory\start.ps1"
Write-Host "  $ConfigDirectory\stop.ps1"
Write-Host "  $ConfigDirectory\restart.ps1"
Write-Host "  $ConfigDirectory\update.ps1"
Write-Host "  $ConfigDirectory\status.ps1"
Write-Host "  $ConfigDirectory\logs.ps1"
Write-Host "  $ConfigDirectory\backup.ps1"

Write-Host ""
Write-Host "Docker containers:" -ForegroundColor Cyan
Write-Host ""

Push-Location $ConfigDirectory

try {

    docker compose --env-file ".env" ps

}
finally {

    Pop-Location

}

# ============================================================================
# OPEN WEB INTERFACES
# ============================================================================

Write-Host ""
Write-Info "Opening Jellyfin and Seerr..."

Start-Process "http://localhost:$JellyfinPort"
Start-Process "http://localhost:$SeerrPort"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "               MEDIA SERVER READY" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

if ([string]::IsNullOrWhiteSpace($TailscaleAuthKey)) {

    Write-Warn "Tailscale still requires authentication."

    Write-Host ""
    Write-Host "Run:"
    Write-Host ""
    Write-Host "    tailscale up"
    Write-Host ""

}

Write-Host "Seerr may require its initial Jellyfin owner authentication."
Write-Host ""
Write-Host "After that, the stack is ready for use."
Write-Host ""
