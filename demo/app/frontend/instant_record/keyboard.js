// Keyboard navigation for one list: a focused row, a key map, a registry the
// virtual list answers so a row it has not drawn can be scrolled into view,
// and focus that survives whatever redraws the list.
import { useCallback, useEffect, useRef, useState } from "react"

// Where focus belongs in `ids`, given the row that had it and where that row
// last stood. A row that left the list (archived here, or by a teammate)
// hands focus to the row that took its place, never to the top.
export function resolveFocus(ids, id, index) {
  if (!ids.length) return { id: null, index: 0 }
  const at = ids.indexOf(id)
  if (at >= 0) return { id, index: at }
  const next = Math.min(Math.max(index, 0), ids.length - 1)
  return { id: ids[next], index: next }
}

const typing = (target) =>
  target instanceof HTMLElement && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))

// useKeyboardNavigation({ ids, keys, startAt, more, onNeed })
//
//   ids      the list's row ids, in order
//   keys     { key: handler } for everything but movement
//   startAt  the row to start on (the one the address names)
//   more     whether rows exist past the end of `ids`
//   onNeed   called with an index past the end, to load that far
//
// Answers { focusedId, focusedIndex, focus, move, register }.
export function useKeyboardNavigation({ ids, keys, startAt, more, onNeed }) {
  const [focused, setFocused] = useState(() => ({ id: startAt || null, index: Math.max(ids.indexOf(startAt), 0) }))
  const scroller = useRef(null)
  const live = useRef({})
  live.current = { ids, keys, focused, more, onNeed }

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

  useEffect(() => {
    const press = (event) => {
      if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return
      if (typing(event.target)) {
        // Keys belong to the text while a field has focus. Escape hands them back.
        if (event.key === "Escape") event.target.blur()
        return
      }
      const handler = live.current.keys[event.key]
      if (!handler) return
      event.preventDefault()
      handler(event)
    }
    window.addEventListener("keydown", press)
    return () => window.removeEventListener("keydown", press)
  }, [])

  return { focusedId: focused.id, focusedIndex: focused.index, focus, move, register }
}
