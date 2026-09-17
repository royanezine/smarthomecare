#!/usr/bin/env bash
# ============================================================
# SmartHomeCare - Build frontend (portal + cms)
#
#   API_URL=https://smarthomecare.citrasolusi.id \
#   PORTAL_URL=https://smarthomecare.citrasolusi.id \
#   SERVER=user@server-ip \
#   bash deploy/scripts/01-build.sh
#
# Menghasilkan:
#   - portal/.next  (siap di-serve via next start port 3011)
#   - cms-admin/dist (file statis untuk /cms/)
# ============================================================
set -euo pipefail

API_URL="${API_URL:-https://smarthomecare.citrasolusi.id}"
WS_URL="${WS_URL:-wss://smarthomecare.citrasolusi.id/ws}"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"

echo "==> Build Portal (Next.js)..."
cd portal
cat > .env.production.local <<EOF
NEXT_PUBLIC_API_URL=${API_URL}
NEXT_PUBLIC_API_BASE_URL=${API_URL}
NEXT_PUBLIC_WS_URL=${WS_URL}
NEXT_PUBLIC_GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
NODE_ENV=production
EOF
npm ci --omit=dev || npm install
npm run build
cd ..

echo "==> Build CMS Admin (Vite)..."
cd cms-admin
cat > .env.production.local <<EOF
VITE_API_BASE_URL=${API_URL}
VITE_URLDEV=${API_URL}/api
VITE_WS_URL=${WS_URL}
EOF
npm ci --omit=dev || npm install
npm run build
cd ..

echo "=========================================================="
echo "BUILD SELESAI."
echo "  Persiapkan berkas ke server:"
echo "    - rsync -az portal/   $SERVER:/var/www/html/smarthomecare/portal/"
echo "    - rsync -az cms-admin/dist/ $SERVER:/var/www/html/smarthomecare/cms/"
echo "  Lalu jalankan deploy/scripts/02-deploy.sh"
echo "=========================================================="