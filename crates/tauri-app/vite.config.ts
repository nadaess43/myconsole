import { defineConfig } from "vite";

const host = process.env.TAURI_DEV_HOST;

export default defineConfig({
  root: ".",
  publicDir: "public",
  server: {
    host: host || "127.0.0.1",
    port: 5173,
    strictPort: true,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 5174,
        }
      : undefined,
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "esnext",
  },
});
