// A selected set over a list of ids, with the anchor a range grows from.
// What a selection means (archive it, mark it) is the page's business.
import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { rangeBetween } from "./range.js"

const NONE = { selected: new Set(), anchor: null }

// useSelection(ids) answers { selected, anchor, toggle, extendTo, all, clear }.
//
//   toggle(id)          selects or deselects one row, and anchors there
//   extendTo(id, from)  replaces the selection with the range from the anchor
//                       to `id`, so a range shrinks as well as grows. With
//                       nothing anchored yet, `from` is the anchor.
//   all()               every id in the list
//
// An id that leaves the list leaves the selection.
export function useSelection(ids) {
  const [state, setState] = useState(NONE)
  const live = useRef(ids)
  live.current = ids

  useEffect(() => {
    setState((state) => {
      if (!state.selected.size) return state
      const here = new Set(ids)
      const selected = new Set([...state.selected].filter((id) => here.has(id)))
      if (selected.size === state.selected.size) return state
      return selected.size ? { ...state, selected } : NONE
    })
  }, [ids])

  const toggle = useCallback((id) => setState((state) => {
    const selected = new Set(state.selected)
    if (!selected.delete(id)) selected.add(id)
    return selected.size ? { selected, anchor: id } : NONE
  }), [])

  const extendTo = useCallback((id, from) => setState((state) => {
    const anchor = state.anchor ?? from ?? id
    return { selected: new Set(rangeBetween(live.current, anchor, id)), anchor }
  }), [])

  const all = useCallback(() => setState({ selected: new Set(live.current), anchor: live.current[0] ?? null }), [])
  const clear = useCallback(() => setState(NONE), [])

  return useMemo(() => ({ ...state, toggle, extendTo, all, clear }), [state, toggle, extendTo, all, clear])
}
