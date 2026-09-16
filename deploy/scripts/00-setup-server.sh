#!/usr/bin/env bash
# ============================================================
# SmartHomeCare - Setup Server (jalankan SEKALI saja, sebagai root)
#
#   sudo bash deploy/scripts/00-setup-server.sh
#
# Menginstall: Apache2, PHP 8.3-FPM + ekstensi, Composer, Node.js 20,
# certbot, modul Apache (rewrite alias proxy proxy_fcgi proxy_wstunnel headers),
# unit systemd, dan membuat user + database MySQL.
# ============================================================
set -euo pipefail

echo "==> Update sistem..."
apt update -y && apt upgrade -y

echo "==> Install Apache2 + modul..."
apt install -y apache2
a2enmod rewrite alias proxy proxy_http proxy_fcgi proxy_wstunnel headers ssl

echo "==> Install PHP 8.3-FPM + ekstensi..."
apt install -y software-properties-common
add-apt-repository -y ppa:ondrej/php || true
apt update -y
apt install -y php8.3-fpm php8.3-mysql php8.3-mbstring php8.3-xml \
    php8.3-curl php8.3-gd php8.3-zip php8.3-bcmath php8.3-intl php8.3-redis

echo "==> Install Composer..."
apt install -y composer || {
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
}

echo "==> Install Node.js 20 + npm..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "==> Install certbot..."
apt install -y certbot python3-certbot-apache

echo "==> Buat struktur direktori..."
mkdir -p /var/www/smarthomecare/{api,cms,portal}
mkdir -p /opt/smarthomecare-ws
chown -R www-data:www-data /var/www/smarthomecare

echo "==> Setup MySQL (user + database)..."
if command -v mysql >/dev/null 2>&1; then
    read -rsp "Password root MySQL: " MYSQL_ROOT_PW
    echo
    read -rp "Username DB aplikasi [smartcare]: " DB_USER
    DB_USER=${DB_USER:-smartcare}
    # Ganti APP_DB_PASSWORD di deploy/env/.env.api.production dengan nilai ini
    read -rsp "Password DB aplikasi: " APP_DB_PASSWORD
    echo
    mysql -u root -p"$MYSQL_ROOT_PW" <<SQL
CREATE DATABASE IF NOT EXISTS smartHomeCare CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${APP_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON smartHomeCare.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    echo "==> Database 'smartHomeCare' siap (user: ${DB_USER})"
else
    echo "WARNING: mysql CLI tidak ditemukan. Buat database manual:
    CREATE DATABASE smartHomeCare CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER 'smartcare'@'localhost' IDENTIFIED BY '<password>';
    GRANT ALL PRIVILEGES ON smartHomeCare.* TO 'smartcare'@'localhost';
    FLUSH PRIVILEGES;"
fi

echo "==> Aktifkan vhost di Apache..."
a2ensite smarthomecare-id
a2dissite 000-default || true
systemctl reload apache2

echo "==> Install unit systemd..."
cp deploy/systemd/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable smarthomecare-portal smarthomecare-api-queue smarthomecare-websocket

echo "=========================================================="
echo "SETUP SELESAI. Langkah berikutnya:"
echo "  1. Arahkan DNS: smarthomecare.citrasolusi.id -> IP server"
echo "  2. Jalankan: certbot --apache -d smarthomecare.citrasolusi.id"
echo "  3. Isi kredensial di deploy/env/*.production lalu jalankan deploy/scripts/01-build.sh"
echo "=========================================================="