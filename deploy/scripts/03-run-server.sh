#!/usr/bin/env bash
# ============================================================
# SmartHomeCare - Pasang & JALANKAN aplikasi LANGSUNG di server
#
#   sudo bash deploy/scripts/03-run-server.sh
#   sudo bash deploy/scripts/03-run-server.sh --skip-build   # pakai build lama
#
# Skrip ini DIJALANKAN DI SERVER (bukan push dari mesin dev).
# Mengasumsikan: apache2, PHP 8.3-FPM, Composer, Node, MySQL
# sudah terpasang manual (seperti yang kamu lakukan).
#
# Yang dilakukan:
#   1.  Cek & install Go (untuk WebSocket/chat) jika belum ada
#   2.  Buat backend/.env + portal/.env.production + cms-admin/.env.production
#   3.  composer install --no-dev + key:generate
#   4.  Buat database MySQL + user (kalau belum ada)
#   5.  migrate + seed (jika data kosong) + storage:link + cache
#   6.  Build Portal (Next.js) + CMS (Vite)
#   7.  Build binary WebSocket Go -> /opt/smarthomecare-ws/ws-service
#   8.  Pasang vhost Apache + unit systemd + start service
#   9.  Verifikasi (curl /health, /cms, status service)
# ============================================================
set -euo pipefail

LOG=/var/log/smarthomecare-run.log
DOMAIN=smarthomecare.citrasolusi.id
API_URL="https://${DOMAIN}"
SRV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKIP_BUILD=no
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=yes

[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root: sudo $0"; exit 1; }
cd "$SRV_ROOT"
[[ -d backend && -d portal && -d cms-admin ]] || { echo "Tidak di root repo SmartHomeCare: $SRV_ROOT"; exit 1; }

log() { echo "$*" | tee -a "$LOG"; }
section() { log ""; log "==> $*"; }

touch "$LOG"
log "=============================================================="
log "SmartHomeCare run-server dimulai: $(date)"
log "Repo: $SRV_ROOT | Domain: $DOMAIN"
log "=============================================================="

DB_NAME="smartHomeCare"
DB_USER="smartcare"
DB_PASS=""
ROOT_PW=""

# ------------------------------------------------------------------
# 0. Kredensial rahasia - dari deploy/env/.secrets.env (di-ignore git)
# ------------------------------------------------------------------
SECRETS_FILE="$SRV_ROOT/deploy/env/.secrets.env"
if [ ! -f "$SECRETS_FILE" ]; then
    log "SALAH: File secret tidak ditemukan: $SECRETS_FILE"
    log "  Buat dengan: cp deploy/env/.secrets.env.example deploy/env/.secrets.env"
    log "  lalu isi kredensial asli (file ini TIDAK di-commit ke git)."
    exit 1
fi
# shellcheck disable=SC1090
set -a; source "$SECRETS_FILE"; set +a
for KEY in GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET \
           MIDTRANS_CLIENT_KEY MIDTRANS_MERCHANT_ID MIDTRANS_SERVER_KEY \
           RESEND_API_KEY MAIL_FROM_ADDRESS LOCATIONIQ_KEY; do
    if [ -z "${!KEY:-}" ] || [ "${!KEY}" = "GANTI_DENGAN_${KEY}" ]; then
        log "SALAH: '${KEY}' belum diisi di ${SECRETS_FILE}"
        exit 1
    fi
done
log "  Secret dimuat dari ${SECRETS_FILE} (ok)"

# ------------------------------------------------------------------
# 0. Prasyarat wajib
# ------------------------------------------------------------------
section "Cek prasyarat"
for c in php composer node npm apache2ctl mysql; do
    command -v "$c" >/dev/null 2>&1 \
        && log "  [OK ] ${c}: $($c --version 2>/dev/null | head -1)" \
        || { log "  [SALAH] ${c} tidak ditemukan. Install dulu."; MISSING=1; }
done
PHP_FPM=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1 || true)
if [ -n "$PHP_FPM" ]; then log "  [OK ] PHP-FPM socket: $PHP_FPM"; else log "  [SALAH] socket php*-fpm.sock tidak ada. PHP-FPM belum jalan."; MISSING=1; fi

# ------------------------------------------------------------------
# 1. Go (WebSocket) - install jika belum ada
# ------------------------------------------------------------------
section "Go untuk WebSocket"
if command -v go >/dev/null 2>&1; then
    log "  Go sudah ada: $(go version)"
else
    log "  Install golang-go (distro)..."
    apt-get install -y golang-go >/dev/null
    log "  Go terinstall: $(go version)"
fi
GO_MAJOR=$(go version | sed -E 's/.*go([0-9]+)\..*/\1/')
GO_MINOR=$(go version | sed -E 's/.*go[0-9]+\.([0-9]+).*/\1/')
if [ "${GO_MAJOR:-0}" -lt 1 ] || { [ "${GO_MAJOR:-0}" -eq 1 ] && [ "${GO_MINOR:-0}" -lt 21 ]; }; then
    log "  WARNING: Go versi lama (<1.21). Build websocket mungkin gagal."
fi

# ------------------------------------------------------------------
# 2. Kredensial Database (buat DB + user jika belum ada)
# ------------------------------------------------------------------
section "Database MySQL"
if ! mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
    read -rsp "  Password root MySQL: " ROOT_PW; echo
fi
read -rp "  Username DB aplikasi [${DB_USER}]: " INP; DB_USER=${INP:-$DB_USER}
read -rsp "  Password DB aplikasi: " DB_PASS; echo
[ -n "$DB_PASS" ] || { log "  Password DB tidak boleh kosong."; exit 1; }

log "  Membuat DB '${DB_NAME}' + user '${DB_USER}' (abaikan jika sudah ada)..."
MYSQL=(mysql -u root)
[ -n "$ROOT_PW" ] && MYSQL+=(-p"$ROOT_PW")
"${MYSQL[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
log "  Database siap."

# ------------------------------------------------------------------
# 3. backend/.env (produksi) - kredensial asli
# ------------------------------------------------------------------
section "Env backend/.env"
BF="$SRV_ROOT/backend/.env"
cat > "$BF" <<EOF
APP_NAME=SmartHomeCare
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=${API_URL}
FRONTEND_URL=${API_URL}
APP_LOCALE=en
APP_FALLBACK_LOCALE=en
APP_FAKER_LOCALE=en_US
APP_MAINTENANCE_DRIVER=file
BCRYPT_ROUNDS=12
LOG_CHANNEL=stack
LOG_STACK=single
LOG_LEVEL=info
EOF
echo "GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}" >> "$BF"
echo "GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}" >> "$BF"
echo "GOOGLE_REDIRECT_URI=${API_URL}/auth/google/callback" >> "$BF"
cat >> "$BF" <<EOF
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}
QUEUE_CONNECTION=database
DB_QUEUE=wilayah
DB_QUEUE_RETRY_AFTER=7500
CACHE_STORE=database
FILESYSTEM_DISK=local
SESSION_DRIVER=database
SESSION_LIFETIME=120
SESSION_ENCRYPT=false
SESSION_PATH=/
SESSION_DOMAIN=.${DOMAIN}
SESSION_SECURE_COOKIE=true
SESSION_SAME_SITE=lax
SESSION_HTTP_ONLY=true
SANCTUM_STATEFUL_DOMAINS=localhost,localhost:3000,localhost:5173,localhost:8000,127.0.0.1,127.0.0.1:3000,127.0.0.1:5173,127.0.0.1:8000,${DOMAIN}
CORS_ALLOWED_ORIGINS=http://localhost:3000,http://localhost:5173,http://127.0.0.1:3000,http://127.0.0.1:5173,https://${DOMAIN}
CORS_ALLOWED_ORIGINS_PATTERNS=^https?://(localhost|127\.0\.0\.1)(:\d+)?$,^https?://([a-z0-9-]+\.)?${DOMAIN//./\.}$
WEBSOCKET_URL=wss://${DOMAIN}/ws
WEBSOCKET_HOST=127.0.0.1
WEBSOCKET_PORT=8088
BROADCAST_CONNECTION=log
REDIS_CLIENT=phpredis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379
MIDTRANS_CLIENT_KEY=${MIDTRANS_CLIENT_KEY}
MIDTRANS_MERCHANT_ID=${MIDTRANS_MERCHANT_ID}
MIDTRANS_SERVER_KEY=${MIDTRANS_SERVER_KEY}
MIDTRANS_IS_PRODUCTION=false
MIDTRANS_IS_SANITIZED=true
MIDTRANS_IS_3DS=true
FEE_MIDTRANS=4000
MIDTRANS_EXPIRY_DURATION=15
MIDTRANS_EXPIRY_UNIT=minutes
MIDTRANS_CALLBACK_URL=${API_URL}/api/midtrans/notification
MIDTRANS_NOTIFICATION_URL=${API_URL}/api/midtrans/notification
MIDTRANS_FINISH_URL=${API_URL}/payment/finish
MIDTRANS_UNFINISH_URL=${API_URL}/payment/unfinish
MIDTRANS_ERROR_URL=${API_URL}/payment/error
MIDTRANS_AUTO_SETTLEMENT=true
MAIL_MAILER=resend
RESEND_API_KEY=${RESEND_API_KEY}
MAIL_FROM_ADDRESS="${MAIL_FROM_ADDRESS}"
MAIL_FROM_NAME="\${APP_NAME}"
WILAYAH_PROVINCES_URL=https://www.emsifa.com/api-wilayah-indonesia/api/provinces.json
WILAYAH_REGENCIES_URL=https://www.emsifa.com/api-wilayah-indonesia/api/regencies/{id_provinsi}.json
WILAYAH_DISTRICTS_URL=https://www.emsifa.com/api-wilayah-indonesia/api/districts/{id_kota}.json
WILAYAH_VILLAGES_URL=https://www.emsifa.com/api-wilayah-indonesia/api/villages/{id_kecamatan}.json
LOCATIONIQ_KEY=${LOCATIONIQ_KEY}
EOF
chmod 600 "$BF"
log "  backend/.env ditulis. (GOOGLE_REDIRECT_URI=${API_URL}/auth/google/callback)"

# ------------------------------------------------------------------
# 4. Env portal + cms (production build)
# ------------------------------------------------------------------
section "Env Portal & CMS"
cat > "$SRV_ROOT/portal/.env.production" <<EOF
NEXT_PUBLIC_API_URL=${API_URL}
NEXT_PUBLIC_API_BASE_URL=${API_URL}
NEXT_PUBLIC_WS_URL=wss://${DOMAIN}/ws
NEXT_PUBLIC_GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
EOF
cat > "$SRV_ROOT/cms-admin/.env.production" <<EOF
VITE_API_BASE_URL=${API_URL}
VITE_URLDEV=${API_URL}/api
VITE_WS_URL=wss://${DOMAIN}/ws
EOF
log "  portal/.env.production & cms-admin/.env.production ditulis."

# ------------------------------------------------------------------
# 5. Backend: composer + APP_KEY + migrate + seed + storage
# ------------------------------------------------------------------
section "Backend Laravel"
cd "$SRV_ROOT/backend"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force
php artisan migrate --force

COUNT=$("${MYSQL[@]}" -N -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.users" 2>/dev/null || echo 0)
if [ "${COUNT:-0}" -eq 0 ]; then
    log "  Data kosong -> seed data awal..."
    php artisan db:seed --force
else
    log "  Data sudah ada (users=${COUNT}) -> seed dilewati."
fi
php artisan storage:link || true
php artisan config:cache
php artisan route:cache
php artisan view:cache
chown -R www-data:www-data "$SRV_ROOT/backend/storage" "$SRV_ROOT/backend/bootstrap/cache"
log "  Migrate + cache selesai."

# ------------------------------------------------------------------
# 6. Build Frontend
# ------------------------------------------------------------------
if [ "$SKIP_BUILD" = yes ]; then
    section "Build Frontend (SKIP - pakai build lama)"
else
    section "Build Portal (Next.js)"
    cd "$SRV_ROOT/portal"
    npm ci --omit=dev --no-audit --no-fund || npm install --omit=dev --no-audit --no-fund
    npm run build

    section "Build CMS Admin (Vite)"
    cd "$SRV_ROOT/cms-admin"
    npm ci --omit=dev --no-audit --no-fund || npm install --omit=dev --no-audit --no-fund
    npm run build
    log "  Build selesai: portal/.next dan cms-admin/dist."
fi

# ------------------------------------------------------------------
# 7. Build WebSocket Go
# ------------------------------------------------------------------
if [ "$SKIP_BUILD" = yes ] && [ -x /opt/smarthomecare-ws/ws-service ]; then
    section "WebSocket Go (SKIP - binary sudah ada)"
else
    section "Build WebSocket Go"
    mkdir -p /opt/smarthomecare-ws
    cd "$SRV_ROOT/backend/websocket-service"
    go build -o ws-service .
    mv -f ws-service /opt/smarthomecare-ws/ws-service
    chown -R www-data:www-data /opt/smarthomecare-ws
    log "  Binary -> /opt/smarthomecare-ws/ws-service"
fi

# ------------------------------------------------------------------
# 8. Apache vhost (SSL sudah aktif) + unit systemd
# ------------------------------------------------------------------
section "Apache vhost"
a2enmod rewrite alias proxy proxy_http proxy_fcgi proxy_wstunnel headers ssl
CONF="/etc/apache2/sites-available/smarthomecare-id.conf"
FULLCHAIN="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
if [ -f "$FULLCHAIN" ]; then
    cp -f "$SRV_ROOT/deploy/apache/smarthomecare-id.conf" "$CONF"
    sed -i "s|/run/php/php8.3-fpm.sock|${PHP_FPM}|" "$CONF"
    log "  Vhost lengkap (SSL) dipasang."
else
    log "  WARNING: ${FULLCHAIN} tidak ditemukan. Pasang vhost :80 dulu."
    awk '/<VirtualHost \*:443>/{skip=1} !skip{print} /<\/VirtualHost>/{if(skip)skip=0}' \
        "$SRV_ROOT/deploy/apache/smarthomecare-id.conf" > "$CONF"
fi
a2ensite smarthomecare-id >/dev/null 2>&1 || true
apache2ctl configtest
systemctl reload apache2
log "  Vhost aktif & Apache reloaded."

section "Unit systemd"
cp "$SRV_ROOT"/deploy/systemd/smarthomecare-*.service /etc/systemd/system/
systemctl daemon-reload
for svc in smarthomecare-portal smarthomecare-api-queue smarthomecare-websocket; do
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" || true
done
log "  Service sudah di-restart; status dicek di bagian verifikasi."

# ------------------------------------------------------------------
# 9. Verifikasi
# ------------------------------------------------------------------
section "Verifikasi"
sleep 5
"${MYSQL[@]}" -e "SHOW DATABASES LIKE '${DB_NAME}';" | sed "s/^/  DB: /"
echo "  Portal   : $(curl -sk -o /dev/null -w '%{http_code}' https://${DOMAIN}/)"
echo "  CMS      : $(curl -sk -o /dev/null -w '%{http_code}' https://${DOMAIN}/cms/)"
echo "  API      : $(curl -sk -o /dev/null -w '%{http_code}' https://${DOMAIN}/sanctum/csrf-cookie)"
echo "  WS health: $(curl -so /dev/null -w '%{http_code}' http://127.0.0.1:8088/health)"
for svc in smarthomecare-portal smarthomecare-api-queue smarthomecare-websocket; do
    systemctl is-active "$svc" >/dev/null 2>&1 \
        && echo "  systemd  : ${svc} ACTIVE" \
        || echo "  systemd  : ${svc} INACTIVE (cek: journalctl -u ${svc})"
done

section "SELESAI"
log "  Log: $LOG"
log "  Kredensial admin: cek seeder (admin@gmail.com / password dari seeder)"
log "  Catatan: pastikan Google Cloud Console punya redirect URI:"
log "    ${API_URL}/auth/google/callback"
log "  Service manual: systemctl restart smarthomecare-portal/api-queue/websocket; systemctl reload apache2"