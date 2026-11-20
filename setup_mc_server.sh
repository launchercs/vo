#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
log(){ printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn(){ printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
die(){ printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }
trap 'rc=$?; echo; die "نصب در خط $(caller 0 | awk '\''{print $1}'\'') با کد $rc متوقف شد. پیام خطای بالا را بررسی کنید."' ERR

command -v apt-get >/dev/null 2>&1 || die 'این نصب‌کننده برای Ubuntu/Debian و GitHub Codespaces آماده شده است.'
command -v sudo >/dev/null 2>&1 || die 'sudo در محیط پیدا نشد.'

SERVER_DIR="${SERVER_DIR:-$HOME/minecraft-server}"
mkdir -p "$SERVER_DIR"

printf '\nMinecraft Server setup (Codespaces)\n'
printf 'نوع سرور را انتخاب کنید:\n  1) Vanilla (بدون پلاگین)\n  2) Paper (پشتیبانی از پلاگین)\n'
read -r -p 'انتخاب [1/2] (پیش‌فرض 1): ' SERVER_TYPE
SERVER_TYPE="${SERVER_TYPE:-1}"
[[ "$SERVER_TYPE" == 1 || "$SERVER_TYPE" == 2 ]] || die 'انتخاب نامعتبر است؛ فقط 1 یا 2 وارد کنید.'

MANIFEST_URL='https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
log 'دریافت فهرست رسمی نسخه‌های Minecraft از Mojang...'
curl --fail --location --silent --show-error --retry 3 --retry-delay 2 "$MANIFEST_URL" -o /tmp/mc-version-manifest.json
LATEST_RELEASE="$(python3 -c 'import json; print(json.load(open("/tmp/mc-version-manifest.json"))["latest"]["release"])')"
LATEST_SNAPSHOT="$(python3 -c 'import json; print(json.load(open("/tmp/mc-version-manifest.json"))["latest"]["snapshot"])')"
printf 'آخرین نسخه پایدار: %s\nآخرین Snapshot: %s\n' "$LATEST_RELEASE" "$LATEST_SNAPSHOT"
read -r -p "نسخه Minecraft را وارد کنید (خالی = آخرین نسخه پایدار $LATEST_RELEASE): " MC_VERSION
MC_VERSION="${MC_VERSION:-$LATEST_RELEASE}"

if [[ "$SERVER_TYPE" == 2 ]]; then
  read -r -p 'نسخه Paper را وارد کنید (باید با نسخه Minecraft یکی باشد؛ خالی = همان نسخه): ' PAPER_VERSION
  PAPER_VERSION="${PAPER_VERSION:-$MC_VERSION}"
  MC_VERSION="$PAPER_VERSION"
fi

read -r -p 'حداکثر RAM جاوا بر حسب GB (مثلاً 2 یا 4) [2]: ' RAM_GB
RAM_GB="${RAM_GB:-2}"
[[ "$RAM_GB" =~ ^[1-9][0-9]*$ ]] || die 'RAM باید یک عدد صحیح مثبت باشد.'
read -r -p 'حداکثر تعداد بازیکنان [10]: ' MAX_PLAYERS
MAX_PLAYERS="${MAX_PLAYERS:-10}"
[[ "$MAX_PLAYERS" =~ ^[1-9][0-9]*$ ]] || die 'تعداد بازیکنان باید یک عدد صحیح مثبت باشد.'
read -r -p 'فاصله دید (view-distance) [8]: ' VIEW_DISTANCE
VIEW_DISTANCE="${VIEW_DISTANCE:-8}"
[[ "$VIEW_DISTANCE" =~ ^[1-9][0-9]*$ ]] || die 'فاصله دید باید عددی بین 1 تا 32 باشد.'
(( VIEW_DISTANCE <= 32 )) || die 'فاصله دید حداکثر 32 است.'

log "بررسی نسخه $MC_VERSION و نسخه Java موردنیاز..."
VERSION_URL="$(python3 - "$MC_VERSION" <<'PY'
import json,sys
m=json.load(open('/tmp/mc-version-manifest.json'))
for v in m['versions']:
    if v['id']==sys.argv[1]:
        print(v['url']); break
else:
    raise SystemExit('نسخه در فهرست رسمی Mojang پیدا نشد: '+sys.argv[1])
PY
)"
curl --fail --location --silent --show-error --retry 3 "$VERSION_URL" -o /tmp/mc-version-meta.json
JAVA_MAJOR="$(python3 -c 'import json; d=json.load(open("/tmp/mc-version-meta.json")); print(d.get("javaVersion",{}).get("majorVersion",21))')"
[[ "$JAVA_MAJOR" =~ ^[0-9]+$ ]] || die 'نسخه Java از اطلاعات نسخه قابل تشخیص نیست.'
log "نسخه Java موردنیاز: $JAVA_MAJOR"

log 'به‌روزرسانی بسته‌ها و نصب وابستگی‌ها...'
sudo apt-get update
sudo apt-get install -y ca-certificates curl jq python3 tar gzip
JAVA_PACKAGE="openjdk-${JAVA_MAJOR}-jre-headless"
if ! apt-cache show "$JAVA_PACKAGE" >/dev/null 2>&1; then
  JAVA_PACKAGE="openjdk-${JAVA_MAJOR}-jdk-headless"
fi
apt-cache show "$JAVA_PACKAGE" >/dev/null 2>&1 || die "بسته $JAVA_PACKAGE در مخازن سیستم موجود نیست. نسخه Ubuntu/Codespaces یا مخازن Java را بررسی کنید."
sudo apt-get install -y "$JAVA_PACKAGE"
JAVA_BIN="$(command -v java)" || die 'پس از نصب، دستور java پیدا نشد.'
INSTALLED_JAVA="$($JAVA_BIN -version 2>&1 | head -n 1)"
log "Java نصب‌شده: $INSTALLED_JAVA"

cd "$SERVER_DIR"
if [[ -e server.jar ]]; then
  BACKUP_OLD="server.jar.before-setup.$(date +%Y%m%d-%H%M%S)"
  warn "server.jar قبلی به $BACKUP_OLD منتقل می‌شود."
  mv server.jar "$BACKUP_OLD"
fi

if [[ "$SERVER_TYPE" == 1 ]]; then
  SERVER_JAR_URL="$(python3 -c 'import json; print(json.load(open("/tmp/mc-version-meta.json"))["downloads"]["server"]["url"])')"
  log "دانلود Vanilla Minecraft $MC_VERSION..."
  curl --fail --location --silent --show-error --retry 3 --retry-all-errors "$SERVER_JAR_URL" -o server.jar
else
  PAPER_API="https://api.papermc.io/v2/projects/paper/versions/$MC_VERSION"
  log "دریافت آخرین Build رسمی Paper برای $MC_VERSION..."
  curl --fail --location --silent --show-error --retry 3 "$PAPER_API" -o /tmp/paper-version.json || die "نسخه $MC_VERSION در Paper موجود نیست یا API در دسترس نیست."
  PAPER_BUILD="$(python3 -c 'import json; d=json.load(open("/tmp/paper-version.json")); print(d["builds"][-1])')"
  PAPER_JAR="$(curl --fail --location --silent --show-error "https://api.papermc.io/v2/projects/paper/versions/$MC_VERSION/builds/$PAPER_BUILD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["downloads"]["application"]["name"])')"
  curl --fail --location --silent --show-error --retry 3 --retry-all-errors "https://api.papermc.io/v2/projects/paper/versions/$MC_VERSION/builds/$PAPER_BUILD/downloads/$PAPER_JAR" -o server.jar
fi
[[ -s server.jar ]] || die 'فایل server.jar دانلود نشد یا خالی است.'
file_size="$(stat -c%s server.jar)"
(( file_size > 1000000 )) || die 'حجم server.jar غیرعادی است؛ دانلود احتمالاً ناقص یا نامعتبر است.'

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
[[ -s "$SERVER_JAR" ]] || { echo "server.jar پیدا نشد؛ setup را دوباره اجرا کنید." >&2; exit 1; }
java -Xms1G -Xmx"${RAM_GB}G" -jar "$SERVER_JAR" nogui
START

cat > start_auto.sh <<'AUTO'
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"
source ./server.env
while true; do
  echo "[$(date -Is)] اجرای سرور..."
  set +e
  ./start.sh
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    echo 'سرور با خروج عادی متوقف شد؛ Restart انجام نمی‌شود.'
    break
  fi
  echo "سرور با کد $status متوقف شد؛ ${RESTART_DELAY_SECONDS}s دیگر تلاش می‌شود. برای توقف کامل Ctrl+C بزنید."
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
((${#WORLDS[@]} > 0)) || { echo 'هیچ پوشه دنیایی پیدا نشد.' >&2; exit 1; }
tar -czf "$TMP" "${WORLDS[@]}"
mv "$TMP" "$FINAL"
find "$BACKUP_DIR" -type f -name 'world-*.tar.gz' -mtime "+$KEEP_DAYS" -delete
echo "Backup ساخته شد: $FINAL"
BACKUP

cat > install_backup_cron.sh <<'CRON'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
SCRIPT="$(pwd)/backup.sh"
HOURS="${1:-6}"
[[ "$HOURS" =~ ^([1-9]|1[0-9]|2[0-3])$ ]] || { echo 'فاصله باید عددی بین 1 تا 23 ساعت باشد.' >&2; exit 1; }
command -v crontab >/dev/null 2>&1 || { echo 'crontab نصب نیست؛ cron را نصب کنید یا backup.sh را دستی اجرا کنید.' >&2; exit 1; }
( crontab -l 2>/dev/null | grep -vF "$SCRIPT" || true; echo "0 */$HOURS * * * cd '$PWD' && '$SCRIPT' >> '$HOME/minecraft-backup.log' 2>&1" ) | crontab -
echo "بکاپ هر $HOURS ساعت زمان‌بندی شد."
CRON

cat > plugins.txt <<'PLUGINS'
# فقط URL مستقیم فایل .jar پلاگین‌های مورد اعتماد را در هر خط وارد کنید.
# این قابلیت فقط برای Paper فعال است. پس از ویرایش، ./install_plugins.sh را اجرا کنید.
PLUGINS
cat > install_plugins.sh <<'PLUG'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
[[ -f server.jar ]] || { echo 'ابتدا سرور را نصب کنید.' >&2; exit 1; }
[[ -f server-type.txt && "$(cat server-type.txt)" == paper ]] || { echo 'نصب پلاگین فقط برای سرور Paper فعال است.' >&2; exit 1; }
mkdir -p plugins
while IFS= read -r url || [[ -n "$url" ]]; do
  [[ -z "$url" || "$url" =~ ^[[:space:]]*# ]] && continue
  [[ "$url" =~ ^https:// ]] || { echo "URL ناامن یا نامعتبر رد شد: $url" >&2; continue; }
  name="$(basename "${url%%\?*}")"
  [[ "$name" == *.jar ]] || { echo "فقط لینک مستقیم .jar پذیرفته می‌شود: $url" >&2; continue; }
  echo "دریافت $name ..."
  curl --fail --location --silent --show-error --retry 2 "$url" -o "plugins/$name.tmp"
  [[ -s "plugins/$name.tmp" ]] || { rm -f "plugins/$name.tmp"; echo "دانلود ناموفق: $name" >&2; continue; }
  mv "plugins/$name.tmp" "plugins/$name"
done < plugins.txt
echo 'پایان نصب پلاگین‌ها. سرور را Restart کنید.'
PLUG

cat > start_tunnel.sh <<'TUNNEL'
#!/usr/bin/env bash
set -Eeuo pipefail
if ! command -v playit >/dev/null 2>&1; then
  echo 'Playit نصب نیست. نصب‌کننده را دوباره اجرا کنید یا راهنمای فارسی را ببینید.' >&2
  exit 1
fi
echo 'Playit Agent در حال اجراست. برای توقف Ctrl+C را بزنید.'
exec playit
TUNNEL

chmod +x start.sh start_auto.sh backup.sh install_backup_cron.sh install_plugins.sh start_tunnel.sh

read -r -p 'Playit.gg را نصب کنم؟ [Y/n]: ' INSTALL_PLAYIT
if [[ ! "$INSTALL_PLAYIT" =~ ^[Nn]$ ]]; then
  log 'نصب Playit از مخزن رسمی...'
  curl --fail --location --silent --show-error --retry 3 https://playit-cloud.github.io/ppa/key.gpg -o /tmp/playit-key.gpg
  sudo gpg --dearmor --yes -o /usr/share/keyrings/playit-archive-keyring.gpg /tmp/playit-key.gpg
  echo 'deb [signed-by=/usr/share/keyrings/playit-archive-keyring.gpg] https://playit-cloud.github.io/ppa/data ./' | sudo tee /etc/apt/sources.list.d/playit-cloud.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y playit
else
  warn 'نصب Playit رد شد؛ می‌توانید بعداً طبق README نصب کنید.'
fi

if [[ "$SERVER_TYPE" == 2 ]]; then
  read -r -p 'آیا می‌خواهید اکنون لینک پلاگین‌ها را وارد کنید؟ [y/N]: ' ADD_PLUGINS
  if [[ "$ADD_PLUGINS" =~ ^[Yy]$ ]]; then
    echo 'لینک مستقیم فایل‌های jar را در plugins.txt قرار دهید و سپس ./install_plugins.sh را اجرا کنید.'
  fi
fi

cat > eula.txt <<'EULA'
# برای اجرای سرور باید EULA رسمی Minecraft را بخوانید و بپذیرید.
# اگر موافق هستید، مقدار زیر را دستی به eula=true تغییر دهید.
eula=false
EULA

log 'نصب اولیه کامل شد.'
printf '\nبرای شروع:\n  cd %q\n  nano eula.txt   # فقط پس از مطالعه و پذیرش EULA مقدار را true کنید\n  ./start_auto.sh # اجرای سرور با Restart پس از Crash\n' "$SERVER_DIR"
printf 'برای تونل: ./start_tunnel.sh\nبرای بکاپ دستی: ./backup.sh\nبرای زمان‌بندی بکاپ: ./install_backup_cron.sh 6\n'
printf 'برای Paper: فایل plugins.txt را ویرایش کنید و ./install_plugins.sh را اجرا کنید.\n'
