import { defineConfig } from "vite";
// The app's own assets live under /assets, so the harness builds into /harness.
export default defineConfig({
  build: { assetsDir: "harness", target: "esnext", sourcemap: false },
  worker: { format: "es" },
});
