#!/usr/bin/env bash
# ============================================================
# SmartHomeCare - Deploy ke server
#
#   SERVER=user@server-ip \
#   bash deploy/scripts/02-deploy.sh
#
# Meng-rsync backend, portal, cms ke /var/www/html/smarthomecare,
# menjalankan migrate + config cache, build websocket Go,
# lalu me-restart service systemd.
# ============================================================
set -euo pipefail

SERVER="${SERVER:?Set SERVER=user@server-ip}"
REMOTE="${REMOTE:-/var/www/html/smarthomecare}"

echo "==> Aktifkan maintenance mode..."
ssh "$SERVER" "cd $REMOTE/api && sudo -u www-data php artisan down --retry=3" || true

echo "==> rsync backend Laravel (kecuali dependensi & storage cache)..."
rsync -az --delete \
    --exclude '.env' \
    --exclude 'vendor' \
    --exclude 'node_modules' \
    --exclude 'storage/app/public' \
    --exclude 'storage/framework/cache' \
    --exclude 'storage/framework/sessions' \
    --exclude 'storage/framework/views' \
    --exclude '.git' \
    backend/ "$SERVER:$REMOTE/api/"

echo "==> rsync portal Next.js (build sudah ada)..."
rsync -az --delete \
    --exclude 'node_modules' \
    --exclude 'src' \
    --exclude 'public' \
    --exclude '.git' \
    portal/ "$SERVER:$REMOTE/portal/"

echo "==> rsync CMS build..."
rsync -az --delete cms-admin/dist/ "$SERVER:$REMOTE/cms/"

echo "==> Build + deploy WebSocket Go..."
rsync -az --delete backend/websocket-service/ "$SERVER:/tmp/smarthomecare-ws-build/"
ssh "$SERVER" "cd /tmp/smarthomecare-ws-build && go build -o ws-service . && sudo cp ws-service /opt/smarthomecare-ws/ws-service && sudo chown www-data:www-data /opt/smarthomecare-ws/ws-service"

echo "==> Install dependensi backend & migrate..."
ssh "$SERVER" bash -s <<'EOF'
set -euo pipefail
cd /var/www/html/smarthomecare/api
sudo -u www-data composer install --no-dev --optimize-autoloader
sudo -u www-data php artisan migrate --force
sudo -u www-data php artisan config:cache
sudo -u www-data php artisan route:cache
sudo -u www-data php artisan view:cache
sudo chown -R www-data:www-data storage bootstrap/cache
EOF

echo "==> Restart service..."
ssh "$SERVER" "sudo systemctl restart smarthomecare-portal smarthomecare-api-queue smarthomecare-websocket && sudo systemctl reload apache2"

echo "==> Matikan maintenance mode..."
ssh "$SERVER" "cd $REMOTE/api && sudo -u www-data php artisan up" || true

echo "=========================================================="
echo "DEPLOY SELESAI. Verifikasi:"
echo "  curl -I https://smarthomecare.citrasolusi.id"
echo "  curl -I https://smarthomecare.citrasolusi.id/cms/"
echo "  curl -I https://smarthomecare.citrasolusi.id/api/api  # login ke Laravel"
echo "=========================================================="