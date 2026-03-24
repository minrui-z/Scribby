import { defineConfig } from "vite";
import { resolve } from "node:path";

export default defineConfig({
  root: resolve(__dirname, "../frontend"),
  resolve: {
    alias: {
      "@tauri-apps/api": resolve(__dirname, "node_modules/@tauri-apps/api"),
    },
  },
  server: {
    host: "127.0.0.1",
    port: 1420,
    strictPort: true,
  },
  build: {
    outDir: resolve(__dirname, "../frontend/dist"),
    emptyOutDir: true,
  },
});
