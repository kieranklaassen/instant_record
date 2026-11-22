import { createInertiaApp } from "@inertiajs/react"
import { createRoot } from "react-dom/client"
import Index from "./todos/Index"

// The Inertia todo app (/inertia), one of the four at /compare. It is plain
// Inertia against the Rails server, with none of InstantRecord in it.
createInertiaApp({
  resolve: () => Index,
  setup({ el, App, props }) {
    createRoot(el).render(<App {...props} />)
  },
  progress: false,
})
