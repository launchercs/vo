#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
log(){ printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn(){ printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
die(){ printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }
trap 'rc=$?; echo; die "Setup failed with exit code $rc. Check the error above."' ERR

command -v apt-get >/dev/null 2>&1 || die 'This installer requires Ubuntu/Debian or GitHub Codespaces.'
command -v sudo >/dev/null 2>&1 || die 'sudo was not found in this environment.'

SERVER_DIR="${SERVER_DIR:-$HOME/minecraft-server}"
mkdir -p "$SERVER_DIR"

printf '\nMinecraft Server setup (Codespaces)\n'
printf 'Select server type:\n  1) Vanilla (no plugins)\n  2) Paper (plugin support)\n'
read -r -p 'Choose [1/2] (default 1): ' SERVER_TYPE
SERVER_TYPE="${SERVER_TYPE:-1}"
[[ "$SERVER_TYPE" == 1 || "$SERVER_TYPE" == 2 ]] || die 'Invalid choice. Enter 1 or 2.'

MANIFEST_URL='https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
log 'Fetching the official Minecraft version manifest from Mojang...'
curl --fail --location --silent --show-error --retry 3 --retry-delay 2 "$MANIFEST_URL" -o /tmp/mc-version-manifest.json
LATEST_RELEASE="$(python3 -c 'import json; print(json.load(open("/tmp/mc-version-manifest.json"))["latest"]["release"])')"
LATEST_SNAPSHOT="$(python3 -c 'import json; print(json.load(open("/tmp/mc-version-manifest.json"))["latest"]["snapshot"])')"
printf 'Latest release: %s\nLatest snapshot: %s\n' "$LATEST_RELEASE" "$LATEST_SNAPSHOT"
read -r -p "Enter Minecraft version (blank = latest release $LATEST_RELEASE): " MC_VERSION
MC_VERSION="${MC_VERSION:-$LATEST_RELEASE}"

if [[ "$SERVER_TYPE" == 2 ]]; then
  read -r -p 'Enter Paper version (must match Minecraft version; blank = same version): ' PAPER_VERSION
  PAPER_VERSION="${PAPER_VERSION:-$MC_VERSION}"
  MC_VERSION="$PAPER_VERSION"
fi

read -r -p 'Maximum Java RAM in GB (e.g. 2 or 4) [2]: ' RAM_GB
RAM_GB="${RAM_GB:-2}"
[[ "$RAM_GB" =~ ^[1-9][0-9]*$ ]] || die 'RAM must be a positive integer.'
read -r -p 'Maximum players [10]: ' MAX_PLAYERS
MAX_PLAYERS="${MAX_PLAYERS:-10}"
[[ "$MAX_PLAYERS" =~ ^[1-9][0-9]*$ ]] || die 'Player count must be a positive integer.'
read -r -p 'View distance [8]: ' VIEW_DISTANCE
VIEW_DISTANCE="${VIEW_DISTANCE:-8}"
[[ "$VIEW_DISTANCE" =~ ^[1-9][0-9]*$ ]] || die 'View distance must be between 1 and 32.'
(( VIEW_DISTANCE <= 32 )) || die 'View distance cannot exceed 32.'

log "Checking Minecraft $MC_VERSION and its required Java version..."
VERSION_URL="$(python3 - "$MC_VERSION" <<'PY'
import json,sys
m=json.load(open('/tmp/mc-version-manifest.json'))
for v in m['versions']:
    if v['id']==sys.argv[1]:
        print(v['url']); break
else:
    raise SystemExit('Version not found in the official Mojang manifest: '+sys.argv[1])
PY
)"
curl --fail --location --silent --show-error --retry 3 "$VERSION_URL" -o /tmp/mc-version-meta.json
JAVA_MAJOR="$(python3 -c 'import json; d=json.load(open("/tmp/mc-version-meta.json")); print(d.get("javaVersion",{}).get("majorVersion",21))')"
[[ "$JAVA_MAJOR" =~ ^[0-9]+$ ]] || die 'Could not determine the required Java version from version metadata.'
log "Required Java version: $JAVA_MAJOR"

log 'Updating packages and installing dependencies...'
sudo apt-get update
sudo apt-get install -y ca-certificates curl jq python3 tar gzip
JAVA_PACKAGE="openjdk-${JAVA_MAJOR}-jre-headless"
if ! apt-cache show "$JAVA_PACKAGE" >/dev/null 2>&1; then
  JAVA_PACKAGE="openjdk-${JAVA_MAJOR}-jdk-headless"
fi
apt-cache show "$JAVA_PACKAGE" >/dev/null 2>&1 || die "Package $JAVA_PACKAGE is unavailable. Check the Ubuntu/Codespaces image and Java repositories."
sudo apt-get install -y "$JAVA_PACKAGE"
JAVA_BIN="$(command -v java)" || die 'Java executable was not found after installation.'
INSTALLED_JAVA="$($JAVA_BIN -version 2>&1 | head -n 1)"
log "Installed Java: $INSTALLED_JAVA"

cd "$SERVER_DIR"
if [[ -e server.jar ]]; then
  BACKUP_OLD="server.jar.before-setup.$(date +%Y%m%d-%H%M%S)"
  warn "Existing server.jar will be moved to $BACKUP_OLD."
  mv server.jar "$BACKUP_OLD"
fi

if [[ "$SERVER_TYPE" == 1 ]]; then
  SERVER_JAR_URL="$(python3 -c 'import json; print(json.load(open("/tmp/mc-version-meta.json"))["downloads"]["server"]["url"])')"
  log "Downloading Vanilla Minecraft $MC_VERSION..."
  curl --fail --location --silent --show-error --retry 3 --retry-all-errors "$SERVER_JAR_URL" -o server.jar
else
  PAPER_API="https://api.papermc.io/v2/projects/paper/versions/$MC_VERSION"
  log "Fetching the latest official Paper build for $MC_VERSION..."
  curl --fail --location --silent --show-error --retry 3 "$PAPER_API" -o /tmp/paper-version.json || die "Paper version $MC_VERSION is unavailable or the Paper API cannot be reached."
  PAPER_BUILD="$(python3 -c 'import json; d=json.load(open("/tmp/paper-version.json")); print(d["builds"][-1])')"
  PAPER_JAR="$(curl --fail --location --silent --show-error "https://api.papermc.io/v2/projects/paper/versions/$MC_VERSION/builds/$PAPER_BUILD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["downloads"]["application"]["name"])')"
  curl --fail --location --silent --show-error --retry 3 --retry-all-errors "https://api.papermc.io/v2/projects/paper/versions/$MC_VERSION/builds/$PAPER_BUILD/downloads/$PAPER_JAR" -o server.jar
fi
[[ -s server.jar ]] || die 'server.jar download failed or the file is empty.'
file_size="$(stat -c%s server.jar)"
(( file_size > 1000000 )) || die 'server.jar has an unexpected size; the download may be incomplete or invalid.'

cat > server.properties <<PROPS
server-port=25565
max-players=$MAX_PLAYERS
view-distance=$VIEW_DISTANCE
simulation-distance=$VIEW_DISTANCE
gamemode=survival
difficulty=normal
pvp=true
spawn-protection=16
online-mode=true
white-list=false
enable-command-block=false
motd=Welcome to Minecraft Server!
PROPS

printf '%s\n' "$([[ \"$SERVER_TYPE\" == 2 ]] && echo paper || echo vanilla)" > server-type.txt

cat > server.env <<ENV
SERVER_JAR=server.jar
RAM_GB=$RAM_GB
BACKUP_KEEP_DAYS=7
BACKUP_INTERVAL_HOURS=6
RESTART_DELAY_SECONDS=10
ENV

cat > start.sh <<'START'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
source ./server.env
[[ -s "$SERVER_JAR" ]] || { echo "server.jar not found. Run the setup script again." >&2; exit 1; }
java -Xms1G -Xmx"${RAM_GB}G" -jar "$SERVER_JAR" nogui
START

cat > start_auto.sh <<'AUTO'
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"
source ./server.env
while true; do
  echo "[$(date -Is)] Starting server..."
  set +e
  ./start.sh
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    echo 'Server stopped normally. Automatic restart will not run.'
    break
  fi
  echo "Server exited with code $status. Retrying in ${RESTART_DELAY_SECONDS}s. Press Ctrl+C to stop the restart loop."
  sleep "$RESTART_DELAY_SECONDS"
done
AUTO

cat > backup.sh <<'BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
BACKUP_DIR="${BACKUP_DIR:-$HOME/minecraft-backups}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-7}"
mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$BACKUP_DIR/world-$STAMP.tar.gz.tmp"
FINAL="$BACKUP_DIR/world-$STAMP.tar.gz"
WORLDS=()
for d in world world_nether world_the_end; do [[ -d "$d" ]] && WORLDS+=("$d"); done
((${#WORLDS[@]} > 0)) || { echo 'No Minecraft world folders were found.' >&2; exit 1; }
tar -czf "$TMP" "${WORLDS[@]}"
mv "$TMP" "$FINAL"
find "$BACKUP_DIR" -type f -name 'world-*.tar.gz' -mtime "+$KEEP_DAYS" -delete
echo "Backup created: $FINAL"
BACKUP

cat > install_backup_cron.sh <<'CRON'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
SCRIPT="$(pwd)/backup.sh"
HOURS="${1:-6}"
[[ "$HOURS" =~ ^([1-9]|1[0-9]|2[0-3])$ ]] || { echo 'Interval must be between 1 and 23 hours.' >&2; exit 1; }
command -v crontab >/dev/null 2>&1 || { echo 'crontab is not installed. Install cron or run backup.sh manually.' >&2; exit 1; }
( crontab -l 2>/dev/null | grep -vF "$SCRIPT" || true; echo "0 */$HOURS * * * cd '$PWD' && '$SCRIPT' >> '$HOME/minecraft-backup.log' 2>&1" ) | crontab -
echo "Backup scheduled every $HOURS hours."
CRON

cat > plugins.txt <<'PLUGINS'
# Add one trusted direct plugin .jar URL per line.
# Paper only. After editing, run ./install_plugins.sh.
PLUGINS
cat > install_plugins.sh <<'PLUG'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
[[ -f server.jar ]] || { echo 'Install the server first.' >&2; exit 1; }
[[ -f server-type.txt && "$(cat server-type.txt)" == paper ]] || { echo 'Plugin installation is available for Paper servers only.' >&2; exit 1; }
mkdir -p plugins
while IFS= read -r url || [[ -n "$url" ]]; do
  [[ -z "$url" || "$url" =~ ^[[:space:]]*# ]] && continue
  [[ "$url" =~ ^https:// ]] || { echo "Rejected unsafe or invalid URL: $url" >&2; continue; }
  name="$(basename "${url%%\?*}")"
  [[ "$name" == *.jar ]] || { echo "Only direct .jar download URLs are accepted: $url" >&2; continue; }
  echo "Downloading $name ..."
  curl --fail --location --silent --show-error --retry 2 "$url" -o "plugins/$name.tmp"
  [[ -s "plugins/$name.tmp" ]] || { rm -f "plugins/$name.tmp"; echo "Download failed: $name" >&2; continue; }
  mv "plugins/$name.tmp" "plugins/$name"
done < plugins.txt
echo 'Plugin installation finished. Restart the server.'
PLUG

cat > start_tunnel.sh <<'TUNNEL'
#!/usr/bin/env bash
set -Eeuo pipefail
if ! command -v playit >/dev/null 2>&1; then
  echo 'Playit is not installed. Re-run the installer or follow the README instructions.' >&2
  exit 1
fi
echo 'Playit Agent is running. Press Ctrl+C to stop.'
exec playit
TUNNEL

chmod +x start.sh start_auto.sh backup.sh install_backup_cron.sh install_plugins.sh start_tunnel.sh

read -r -p 'Install Playit.gg? [Y/n]: ' INSTALL_PLAYIT
if [[ ! "$INSTALL_PLAYIT" =~ ^[Nn]$ ]]; then
  log 'Installing Playit from the official repository...'
  curl --fail --location --silent --show-error --retry 3 https://playit-cloud.github.io/ppa/key.gpg -o /tmp/playit-key.gpg
  sudo gpg --dearmor --yes -o /usr/share/keyrings/playit-archive-keyring.gpg /tmp/playit-key.gpg
  echo 'deb [signed-by=/usr/share/keyrings/playit-archive-keyring.gpg] https://playit-cloud.github.io/ppa/data ./' | sudo tee /etc/apt/sources.list.d/playit-cloud.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y playit
else
  warn 'Playit installation skipped. You can install it later using the README instructions.'
fi

if [[ "$SERVER_TYPE" == 2 ]]; then
  read -r -p 'Would you like to add plugin URLs now? [y/N]: ' ADD_PLUGINS
  if [[ "$ADD_PLUGINS" =~ ^[Yy]$ ]]; then
    echo 'Add direct .jar URLs to plugins.txt, then run ./install_plugins.sh.'
  fi
fi

cat > eula.txt <<'EULA'
# Read and accept the official Minecraft EULA before starting the server.
# If you agree, manually change the value below to eula=true.
eula=false
EULA

log 'Initial setup completed.'
printf '\nTo start:\n  cd %q\n  nano eula.txt   # Set to true only after reading and accepting the EULA\n  ./start_auto.sh # Start server and restart after a crash\n' "$SERVER_DIR"
printf 'Tunnel: ./start_tunnel.sh\nManual backup: ./backup.sh\nSchedule backups: ./install_backup_cron.sh 6\n'
printf 'For Paper: edit plugins.txt and run ./install_plugins.sh.\n'
