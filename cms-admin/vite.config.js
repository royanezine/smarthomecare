import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  plugins: [react(), tailwindcss()],
server: {
    proxy: {
      // API Laravel lokal di port 8000
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
      },
      // Teruskan permintaan gambar artikel (/storage/...) ke backend lokal
      '/storage': {
        target: 'http://localhost:8000',
        changeOrigin: true,
      },
    },
  },
});