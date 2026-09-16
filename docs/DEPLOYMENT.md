=DEPLOYMENT.md

# SmartHomeCare - Panduan Deploy ke Server Apache2

## Arsitektur

```
Browser
  │
  ├─ https://smarthomecare.id        → Apache :80/443
  │    ├─ /     → reverse proxy → 127.0.0.1:3011  (Next.js portal)
  │    └─ /cms/ → file statis build Vite           (React CMS)
  │
  └─ https://api.smarthomecare.id          → Apache
       ├─ /   → PHP-FPM 8.3 → Laravel (document root api/public)
       └─ /ws → proxy wss   → 127.0.0.1:8088     (Go websocket)
```

Struktur direktori di server:

```
/var/www/smarthomecare/
├── api/                 <- dari apps/api/ (Laravel)
│   └── public/          <- DocumentRoot vhost api
├── cms/                 <- isi dist/ build React (di-serve /cms/)
└── portal/              <- dari apps/portal/ (Next.js, dijalankan via systemd port 3011)

/opt/smarthomecare-ws/   <- binary ws-service (Go)
```

## 1. Persiapan

- Restore repo, pastikan struktur final:

```
smarthomecare/
├── apps/
│   ├── api/               Laravel (harus direstore/di-rollback seperti sebelumnya)
│   ├── cms-admin/         React + Vite
│   ├── portal/            Next.js
│   └── websocket-service/ Go websocket
├── deploy/                (folder ini)
├── docs/
└── scripts/
```

## 2. Setup server (sekali saja)

```bash
sudo bash deploy/scripts/00-setup-server.sh
```

Skrip ini menginstall: Apache2, PHP 8.3-FPM + ekstensi, Composer, Node 20,
certbot, modul Apache (`rewrite alias proxy proxy_fcgi proxy_wstunnel headers`),
unit systemd, dan membuat database MySQL.

## 3. DNS

Arahkan kedua (atau tiga) nama ke IP server:

```
smarthomecare.id     A  <IP>
www.smarthomecare.id A  <IP>
api.smarthomecare.id A  <IP>
```

## 4. Isi file env

- `deploy/env/.env.api.production.example` → isi DB, Midtrans, LLM key, lalu
  copy ke `/var/www/smarthomecare/api/.env` dan jalankan `php artisan key:generate`.
- `deploy/env/.env.cms.production.example` / `.env.portal.production.example`
  sudah di-copy otomatis oleh `01-build.sh`.

## 5. Build & deploy

Jalankan dari repo (dev machine / CI):

```bash
API_URL=https://api.smarthomecare.id \
SERVER=faruq@192.168.18.12 \
bash deploy/scripts/01-build.sh
bash deploy/scripts/02-deploy.sh
```

`02-deploy.sh` meng-rsync ke `/var/www/smarthomecare`, menjalankan
migrate/config-cache di server, lalu me-restart service.

## 6. SSL (certbot)

```bash
certbot --apache -d smarthomecare.id -d www.smarthomecare.id -d api.smarthomecare.id
```

## Service systemd

| Unit                          | Fungsi                     | Port |
|-------------------------------|----------------------------|------|
| `smarthomecare-portal.service`| Next.js `next start`       | 3011 |
| `smarthomecare-api-queue.service`| Laravel `queue:work`     | -    |
| `smarthomecare-websocket.service` | Go ws-service           | 8088 |

```bash
sudo systemctl status smarthomecare-portal
sudo journalctl -u smarthomecare-portal -f
```

## Catatan penting (TODOs di repositori)

1. **`apps/api` hilang saat restruktur** — RESTORE dulu (git remote / local history /
   backup). Semua konfigurasi deploy mengasumsikan `apps/api/` berisi Laravel.

2. **CORS Laravel** — `apps/api/config/cors.php` saat ini default ke
   `citra.faaruq.com`. Di produksi baru set di .env:
   `CORS_ALLOWED_ORIGINS=https://smarthomecare.id,https://www.smarthomecare.id`.

3. **URL old Citra → ganti** — portal & CMS masih punya fallback hardcoded
   `https://citra.faaruq.com`. Di produksi build wajib diset `NEXT_PUBLIC_API_URL`
   dan `VITE_API_BASE_URL` (sudah otomatis oleh build script), jadi fallback tidak terpakai.

4. **URL WebSocket hardcoded** — `apps/cms-admin/src/pages/admin/AdminChatDetail.jsx:39`
   dan `apps/portal/src/app/booking/aktif/page.js:248` memakai
   `ws://192.168.18.12:8088/ws...`. Ganti menjadi
   `wss://api.smarthomecare.id/ws?...` (via Apache proxy wss, sudah disediakan
   di vhost api).

5. **base /cms/** — `apps/cms-admin/vite.config.js` kini `base='/cms/'` saat
   production; `dist/` siap diletakkan di `/cms/`.

6. **Port portal = 3011** (bukan 3000), diatur di systemd unit & `ProxyPass` Apache.

## Verifikasi

```bash
curl -I https://smarthomecare.id          # portal -> 200, X-Powered-By Next.js
curl -I https://smarthomecare.id/cms/     # CMS -> 200 index.html
curl -I https://api.smarthomecare.id/api  # Laravel -> 200 JSON (404 ter-handle route)
curl -I https://api.smarthomecare.id/storage/logo/logo.png  # file storage
```