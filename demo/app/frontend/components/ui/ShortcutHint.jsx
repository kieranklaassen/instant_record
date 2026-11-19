import { useEffect, useState } from "react"
import Kbd from "./Kbd"

const SEEN = "instant-record-demo:shortcut-hint"

const seen = () => {
  try {
    return !!window.localStorage.getItem(SEEN)
  } catch {
    return false
  }
}

// Says once that the page has keys: a pill that leaves after five seconds or
// the first key press and does not come back. Not shown where the pointer is
// coarse (ui.css), since there is no keyboard to press.
export default function ShortcutHint() {
  const [shown, setShown] = useState(() => !seen())

  useEffect(() => {
    if (!shown) return
    const leave = () => {
      setShown(false)
      try {
        window.localStorage.setItem(SEEN, "1")
      } catch {
        // No storage: the hint shows again next time, which is fine.
      }
    }
    const timer = setTimeout(leave, 5000)
    window.addEventListener("keydown", leave, { once: true })
    return () => {
      clearTimeout(timer)
      window.removeEventListener("keydown", leave)
    }
  }, [shown])

  if (!shown) return null
  return <div className="ui-hint">Press <Kbd chord="?" tone="on-ink" /> for keyboard shortcuts</div>
}
