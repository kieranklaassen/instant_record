// Undo for a page's writes: hold a write for a few seconds, show that it can
// be taken back, and send it when the time passes or the reader leaves.
import { useEffect, useMemo, useRef, useState } from "react"
import { heldActions } from "./held.js"

const NOTHING = { pending: [], held: new Set() }

// useUndoable({ ms }) answers { pending, held, hold, undo, flush }: held.js
// says what each is. `held` is the ids to leave out of what is drawn.
//
// Leaving the page flushes with { keepalive: true }, which a commit hands to
// its request so the browser may finish it after the page is gone.
export function useUndoable({ ms = 5000 } = {}) {
  const [state, setState] = useState(NOTHING)
  const actions = useRef(null)
  actions.current ||= heldActions({ ms, onChange: setState })

  useEffect(() => {
    const leave = () => actions.current.flush({ keepalive: true })
    window.addEventListener("pagehide", leave)
    return () => {
      window.removeEventListener("pagehide", leave)
      leave()
    }
  }, [])

  return useMemo(() => ({
    ...state,
    hold: (action) => actions.current.hold(action),
    undo: () => actions.current.undo(),
    flush: (options) => actions.current.flush(options),
  }), [state])
}
