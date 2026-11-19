import { createInertiaApp } from "@inertiajs/react"
import { createRoot } from "react-dom/client"
import { instantRecord } from "./instant_record"

const pages = import.meta.glob("./pages/**/*.jsx", { eager: true })

createInertiaApp({
  ...instantRecord(),
  resolve: (name) => pages[`./pages/${name}.jsx`],
  setup({ el, App, props }) {
    createRoot(el).render(<App {...props} />)
  },
  progress: false,
})
