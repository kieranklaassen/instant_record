import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

// The bundle of the Inertia todo app at /inertia, kept apart from the Inbox's
// so that neither carries the other.
export default defineConfig({
  plugins: [react()],
  publicDir: false,
  build: {
    outDir: "app/assets/builds",
    emptyOutDir: false,
    rollupOptions: {
      input: "app/frontend/todos.jsx",
      output: { entryFileNames: "todos.js", codeSplitting: false },
    },
  },
})
