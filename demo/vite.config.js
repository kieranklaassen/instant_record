import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

// One bundle for the one Inertia page. It lands in app/assets/builds, where
// Propshaft serves it like any other asset and the compiled build picks it up.
export default defineConfig({
  plugins: [react()],
  // The gem's frontend package lives outside this app: its imports resolve here.
  resolve: { dedupe: ["react", "react-dom", "react-virtuoso", "@inertiajs/core", "@inertiajs/react"] },
  publicDir: false,
  build: {
    outDir: "app/assets/builds",
    emptyOutDir: false,
    rollupOptions: {
      input: "app/frontend/inbox.jsx",
      output: { entryFileNames: "inbox.js", codeSplitting: false },
    },
  },
})
