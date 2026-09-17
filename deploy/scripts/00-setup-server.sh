#!/usr/bin/env bash
# ============================================================
# SmartHomeCare - Setup Server (AMAN untuk server bersama / share host)
#
#   sudo bash deploy/scripts/00-setup-server.sh
#   sudo bash deploy/scripts/00-setup-server.sh --yes         # jawab 'y' otomatis
#   sudo bash deploy/scripts/00-setup-server.sh --enable-ssl  # aktifkan SSL vhost (stlh certbot)
#
# Prinsip "TIDAK mengganggu repo/aplikasi lain di server":
#   - TIDAK menjalankan `apt upgrade` (hanya `apt update`, non-destruktif)
#   - TIDAK menonaktifkan / memodifikasi situs Apache milik aplikasi lain
#     (000-default, vhost lain, dsb. dibiarkan utuh)
#   - Setiap komponen global dicek dulu: kalau sudah ada, DILEWATI
#   - Komponen yang bersifat opsional (certbot, Go, Node) diminta konfirmasi
#   - Node.js global memberi warning: mengganti paket nodejs sistem
#   - Semua berkas aplikasi masuk ke /var/www/html/smarthomecare (diri sendiri)
#   - Vhost Apache & unit systemd hanya untuk nama "smarthomecare-*"
#   - MySQL HANYA membuat database + user baru, tidak menyentuh DB lain
#   - Semua aktivitas dicatat ke /var/log/smarthomecare-setup.log
# ============================================================
set -euo pipefail

LOG=/var/log/smarthomecare-setup.log
DOMAIN=smarthomecare.citrasolusi.id
WEBROOT=/var/www/html/smarthomecare
CONF_REPO=deploy/apache/smarthomecare-id.conf
CONF_DST=/etc/apache2/sites-available/smarthomecare-id.conf
CERTS_DIR=/etc/letsencrypt/live/${DOMAIN}
AUTO=no

[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root: sudo bash $0"; exit 1; }
[[ "${1:-}" == "--yes" ]] && AUTO=yes

log()      { echo "$*" | tee -a "$LOG"; }
section()  { log ""; log "==> $*"; }
have()     { command -v "$1" >/dev/null 2>&1; }

ask() { # $1=pertanyaan; return 0 jika lanjut (ya)
    [[ "$AUTO" == yes ]] && { log "  (auto-ya)"; return 0; }
    local ans
    read -rp "$1 [y/N] " ans
    [[ "${ans,,}" == "y" ]]
}

# ------------------------------------------------------------------
# Mode --enable-ssl : pasang ulang conf vhost LENGKAP (dgn :443)
# Jalankan SETELAH certbot menerbitkan sertifikat.
# ------------------------------------------------------------------
if [[ "${1:-}" == "--enable-ssl" ]]; then
    echo "==> Memasang vhost lengkap (SSL) untuk ${DOMAIN}..." | tee -a "$LOG"
    cp -f "$CONF_REPO" "$CONF_DST"
    a2ensite smarthomecare-id >/dev/null 2>&1 || true
    systemctl reload apache2
    echo "==> SSL vhost aktif. Verifikasi: curl -I https://${DOMAIN}" | tee -a "$LOG"
    exit 0
fi

touch "$LOG"
log "=============================================================="
log "SmartHomeCare setup dimulai: $(date)"
log "=============================================================="

# ------------------------------------------------------------------
# 1. Preflight - laporkan apa yang sudah ada / akan diinstall
# ------------------------------------------------------------------
section "Preflight - cek komponen yang sudah terpasang"
for c in apache2 php8.3-fpm composer node npm certbot go mysql; do
    if have "$c"; then
        ver=$($c --version 2>/dev/null | head -1)
        log "  [OK ] ${c}: ${ver:-ada}"
    else
        log "  [ - ] ${c}: belum terpasang"
    fi
done

# ------------------------------------------------------------------
# 2. apt update saja (TANPA upgrade - aman utk aplikasi lain)
# ------------------------------------------------------------------
section "apt update (tanpa upgrade, non-destruktif)"
apt update -y

# ------------------------------------------------------------------
# 3. Apache2 + modul (additive: menambah modul, tidak ubah vhost org)
# ------------------------------------------------------------------
if ! have apache2; then
    if ask "Apache2 belum ada. Install?"; then
        apt install -y apache2
    fi
fi
log "Menambah modul Apache (idempoten, tidak mengubah vhost lain)..."
a2enmod rewrite alias proxy proxy_http proxy_fcgi proxy_wstunnel headers ssl

# ------------------------------------------------------------------
# 4. PHP 8.3-FPM (coexist dengan versi PHP lain, socket terpisah)
# ------------------------------------------------------------------
if have php8.3-fpm; then
    log "php8.3-fpm sudah ada - dilewati."
elif ask "Install PHP 8.3-FPM + ekstensi (coexist dgn versi lain)?"; then
    apt install -y software-properties-common
    add-apt-repository -y ppa:ondrej/php || true
    apt update -y
    apt install -y php8.3-fpm php8.3-mysql php8.3-mbstring php8.3-xml \
        php8.3-curl php8.3-gd php8.3-zip php8.3-bcmath php8.3-intl php8.3-redis
else
    log "WARNING: php8.3-fpm dilewati. Laravel di /api TIDAK akan berjalan."
fi

# ------------------------------------------------------------------
# 5. Composer (file tunggal di /usr/local/bin - tidak mengusik)
# ------------------------------------------------------------------
if have composer; then
    log "Composer sudah ada - dilewati."
elif ask "Install Composer?"; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

# ------------------------------------------------------------------
# 6. Node.js 20 (PENTING: mengganti paket nodejs global sistem)
# ------------------------------------------------------------------
NEED_NODE=1
if have node; then
    NODE_MAJOR=$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')
    if [ "${NODE_MAJOR:-0}" -ge 18 ] && have npm; then
        log "Node ${NODE_MAJOR} + npm sudah ada - dilewati (dipakai service portal)."
        NEED_NODE=0
    fi
fi
if [ "$NEED_NODE" = 1 ]; then
    log "WARNING: instalasi via nodesource MENGGANTI nodejs global sistem -"
    log "         aplikasi lain yang bergantung versi node tertentu bisa terpengaruh."
    if ask "Install Node.js 20 GLOBAL (diperlukan portal 'next start')?"; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt install -y nodejs
    else
        log "SKIP nodejs. Pastikan node >=18 global tersedia utk service smarthomecare-portal."
    fi
fi

# ------------------------------------------------------------------
# 7. certbot (opsional - SSL bisa dikelola infra yang sudah ada)
# ------------------------------------------------------------------
if have certbot; then
    log "certbot sudah ada - dilewati."
elif ask "Install certbot + modul apache (opsional, utk SSL)?"; then
    apt install -y certbot python3-certbot-apache
fi

# ------------------------------------------------------------------
# 8. Go (opsional - hanya diperlukan utk WebSocket/chat)
# ------------------------------------------------------------------
if have go; then
    log "Go sudah ada - dilewati."
elif ask "Install Go (distro, opsional - utk WebSocket)?"; then
    apt install -y golang-go
fi

# ------------------------------------------------------------------
# 9. Direktori aplikasi (khusus milik SmartHomeCare)
# ------------------------------------------------------------------
section "Struktur direktori khusus aplikasi"
mkdir -p "$WEBROOT"/{api,cms,portal}
mkdir -p /opt/smarthomecare-ws
chown -R www-data:www-data "$WEBROOT"
log "  $WEBROOT/{api,cms,portal} dan /opt/smarthomecare-ws siap."

# ------------------------------------------------------------------
# 10. Vhost Apache - hanya utk nama ini, TIDAK menyentuh vhost lain
# ------------------------------------------------------------------
section "Vhost Apache (hanya smarthomecare-*)"
mkdir -p /etc/apache2/sites-available
if [ -f "$CERTS_DIR"/fullchain.pem ]; then
    cp -f "$CONF_REPO" "$CONF_DST"
    log "Sertifikat SSL ditemukan - vhost lengkap dipasang."
    a2ensite smarthomecare-id >/dev/null
    systemctl reload apache2
else
    # Belum ada sertifikat -> pasang versi :80 saja supaya reload tidak gagal
    # dan vhost aplikasi lain tidak terganggu. Blok :443 di-aktifkan kembali
    # lewat `--enable-ssl` setelah certbot.
    log "Sertifikat SSL belum ada - vhost :80 dipasang (ssl:443 dinonaktifkan sementara)."
    awk '/<VirtualHost \*:443>/{skip=1} !skip{print} /<\/VirtualHost>/{if(skip)skip=0}' \
        "$CONF_REPO" > "$CONF_DST"
    a2ensite smarthomecare-id >/dev/null
    systemctl reload apache2
    log "  Vhost :80 aktif. Vhost/vhost lain di server TIDAK diubah."
fi

# ------------------------------------------------------------------
# 11. MySQL - HANYA membuat database + user baru (tidak menyentuh DB lain)
# ------------------------------------------------------------------
section "Database MySQL (buat DB + user baru saja)"
if have mysql; then
    read -rsp "Password root MySQL: " MYSQL_ROOT_PW; echo
    read -rp "Username DB aplikasi [smartcare]: " DB_USER
    DB_USER=${DB_USER:-smartcare}
    read -rsp "Password DB aplikasi: " APP_DB_PASSWORD; echo
    log "Membuat DB 'smartHomeCare' + user '${DB_USER}' (mengabaikan jika sudah ada)..."
    mysql -u root -p"$MYSQL_ROOT_PW" <<SQL
CREATE DATABASE IF NOT EXISTS smartHomeCare CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${APP_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON smartHomeCare.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    log "  Database smartHomeCare siap (user: ${DB_USER}). DB lain tidak tersentuh."
else
    log "WARNING: mysql CLI tidak ditemukan. Buat database manual:"
    log "  CREATE DATABASE smartHomeCare CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    log "  CREATE USER 'smartcare'@'localhost' IDENTIFIED BY '<password>';"
    log "  GRANT ALL PRIVILEGES ON smartHomeCare.* TO 'smartcare'@'localhost';"
fi

# ------------------------------------------------------------------
# 12. Unit systemd - hanya unit milik aplikasi (enable tidak = start)
# ------------------------------------------------------------------
section "Unit systemd"
cp deploy/systemd/smarthomecare-*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable smarthomecare-portal smarthomecare-api-queue smarthomecare-websocket
log "  3 unit smarthomecare-*.service di-enable (mulai otomatis saat file app tersedia)."

# ------------------------------------------------------------------
# 13. Selesai
# ------------------------------------------------------------------
section "SETUP SELESAI - langkah berikutnya"
log "  1. Arahkan DNS ${DOMAIN} -> IP server"
log "  2. jalankan: certbot --apache -d ${DOMAIN}"
log "  3. aktifkan vhost SSL: sudo bash deploy/scripts/00-setup-server.sh --enable-ssl"
log "  4. isi kredensial di deploy/env/*.production, lalu: deploy/scripts/01-build.sh"
log "  5. deploy: SERVER=user@ip bash deploy/scripts/02-deploy.sh"
log "Catatan lengkap: $LOG"