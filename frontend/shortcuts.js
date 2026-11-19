// One keydown listener for a page, run from a table of bindings (chord.js
// says what a binding is). Keys belong to the text while a field has focus,
// unless a binding says otherwise, and Escape hands them back.
import { useEffect, useRef } from "react"
import { match, place } from "./chord.js"

export function useShortcuts(bindings) {
  const live = useRef(bindings)
  live.current = bindings

  useEffect(() => {
    const press = (event) => {
      if (event.defaultPrevented) return
      const binding = match(live.current, event, event.target)
      if (!binding) {
        if (event.key === "Escape" && place(event.target).typing) event.target.blur()
        return
      }
      event.preventDefault()
      binding.run(event)
    }
    window.addEventListener("keydown", press)
    return () => window.removeEventListener("keydown", press)
  }, [])
}
