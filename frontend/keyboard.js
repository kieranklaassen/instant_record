// Keyboard navigation for one list: a focused row, a registry the virtual
// list answers so a row it has not drawn can be scrolled into view, and focus
// that survives whatever redraws the list. The keys themselves are bindings
// (shortcuts.js): bind j to `move(1)` and k to `move(-1)`.
import { useCallback, useEffect, useRef, useState } from "react"
import { resolveFocus } from "./focus.js"

// useKeyboardNavigation({ ids, startAt, more, onNeed })
//
//   ids      the list's row ids, in order
//   startAt  the row to start on (the one the address names)
//   more     whether rows exist past the end of `ids`
//   onNeed   called with an index past the end, to load that far
//
// Answers { focusedId, focusedIndex, focus, move, register }.
export function useKeyboardNavigation({ ids, startAt, more, onNeed }) {
  const [focused, setFocused] = useState(() => ({ id: startAt || null, index: Math.max(ids.indexOf(startAt), 0) }))
  const scroller = useRef(null)
  const live = useRef({})
  live.current = { ids, focused, more, onNeed }

  // Whatever redraws the list, focus stays on its row, or passes to the row
  // that took its place.
  useEffect(() => {
    const next = resolveFocus(ids, focused.id, focused.index)
    if (next.id !== focused.id || next.index !== focused.index) setFocused(next)
  }, [ids, focused])

  // The virtual list registers how to bring a row into view.
  const register = useCallback((scrollTo) => {
    scroller.current = scrollTo
    return () => {
      if (scroller.current === scrollTo) scroller.current = null
    }
  }, [])

  const focus = useCallback((id) => {
    const at = live.current.ids.indexOf(id)
    if (at < 0) return
    setFocused({ id, index: at })
    scroller.current?.(at)
  }, [])

  const move = useCallback((step) => {
    const { ids, focused, more, onNeed } = live.current
    if (!ids.length) return null
    const wanted = focused.index + step
    if (wanted >= ids.length && more) onNeed?.(wanted)
    const at = Math.min(Math.max(wanted, 0), ids.length - 1)
    setFocused({ id: ids[at], index: at })
    scroller.current?.(at)
    return ids[at]
  }, [])

  return { focusedId: focused.id, focusedIndex: focused.index, focus, move, register }
}
