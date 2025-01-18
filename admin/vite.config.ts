import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import svgr from 'vite-plugin-svgr';
import path from 'path';

// https://vite.dev/config/
export default defineConfig({
    base: '/',
    plugins: [
        svgr({ svgrOptions: { icon: true } }),
        react(),
    ],
    resolve: {
        alias: {
            '@': path.resolve(__dirname, './src')
        },
    },
    build: {
        outDir: 'www',
        rollupOptions: {
            output: {
                entryFileNames: `assets/[hash].js`,
                chunkFileNames: `assets/[hash].js`,
                assetFileNames: `assets/[hash].[ext]`
            }
        }
    },
    server: {
        proxy: {
            '/api': {
                target: 'http://127.0.0.1:9669',
                changeOrigin: true,
                secure: false,
            },
            '/admin': {
                target: 'http://127.0.0.1:9669',
                changeOrigin: true,
                secure: false,
            },
            '/wallet': {
                target: 'http://127.0.0.1:9669',
                changeOrigin: true,
                secure: false,
            },
        },
    },
})
