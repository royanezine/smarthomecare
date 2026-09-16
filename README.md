# SmartHomeCare

Aplikasi layanan home care (portal booking pasien, CMS admin, API backend).

## Struktur monorepo

```
smartHomeCare/
├── apps/
│   ├── api/                 Laravel 13 (API + Sanctum + Midtrans)
│   ├── cms-admin/           React + Vite (CMS admin, dipublish di /cms/)
│   ├── portal/              Next.js (web publik, serve di port 3011)
│   └── websocket-service/   Go websocket (server chat/walkie, port 8088)
├── deploy/
│   ├── apache2/sites-available/   vhost portal+cms & subdomain api
│   ├── systemd/                   unit portal / queue / websocket
│   ├── env/                       template .env produksi
│   └── scripts/                   00-setup-server / 01-build / 02-deploy
├── docs/DEPLOYMENT.md        panduan deploy ke Apache2 lengkap
└── scripts/                  helper git windows (push.bat, update.bat)
```

## Deploy Apache2

Baca `docs/DEPLOYMENT.md`. Ringkasnya:

1. `sudo bash deploy/scripts/00-setup-server.sh`
2. Isi `deploy/env/*` (domain, DB, Midtrans)
3. `bash deploy/scripts/01-build.sh`
4. `SERVER=user@host bash deploy/scripts/02-deploy.sh`
5. `certbot --apache -d smarthomecare.id -d api.smarthomecare.id`

Arsitektur: `smarthomecare.id` → portal Next.js (reverse proxy port 3011) +
`/cms/` statis; `api.smarthomecare.id` → Laravel via PHP-FPM +
`/ws` → Go websocket (8088).

## Develop lokal

```bash
# API (backend)
cd apps/api
composer install && cp .env.example .env && php artisan key:generate
php artisan serve --port=8000

# Portal
cd apps/portal
npm install && npm run dev          # default http://localhost:3000

# CMS admin
cd apps/cms-admin
npm install && npm run dev          # default http://localhost:5173
```