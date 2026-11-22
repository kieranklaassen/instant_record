import { defineConfig } from "vite";

// The built shell loads no module in the page: no module script and no modulepreload. It writes
// the app's own page into this document, and a browser that takes one import map only before
// the first module load (Firefox) would refuse the app's import map and fail on `import
// "application"`. The worker is a module in a scope of its own, which does not count.
const classicShell = {
  name: "instant-record-classic-shell",
  apply: "build",
  transformIndexHtml: {
    order: "post",
    handler: html => html.replace(/<script type="module" crossorigin src=/g, "<script defer src="),
  },
};

// The app's own assets live under /assets, so the harness builds into /harness.
export default defineConfig({
  build: { assetsDir: "harness", target: "esnext", sourcemap: false, rollupOptions: { output: { format: "iife" } } },
  worker: { format: "es" },
  plugins: [classicShell],
});
