// Undo for a page's writes:
// - On compiled local-SQLite pages that pass `durable` (held OutboxMutation
//   descriptors with `release_at`) and `onCancel`, tracks durable SQLite holds
//   across reloads without flushing on pagehide.
// - On non-compiled server-rendered pages (or when `durable` is omitted), holds
//   writes in memory for `ms` and flushes with `{ keepalive: true }` on leave.
import { useEffect, useMemo, useRef, useState } from "react"
import { durableHeldActions, heldActions } from "./held.js"
import { local } from "./window.js"

const NOTHING = { pending: [], held: new Set() }

// useUndoable({ ms, durable, onCancel }) answers { pending, held, hold, undo, flush }:
// held.js says what each is. `held` is the ids to leave out of what is drawn.
export function useUndoable({ ms = 5000, durable, onCancel } = {}) {
  const isDurable = local() && Array.isArray(durable)
  const [state, setState] = useState(NOTHING)
  const cancelRef = useRef(onCancel)
  cancelRef.current = onCancel

  const volatile = useRef(null)
  const persistent = useRef(null)
  if (!isDurable) volatile.current ||= heldActions({ ms, onChange: setState })
  if (isDurable) persistent.current ||= durableHeldActions({ onChange: setState, onCancel: (entry) => cancelRef.current?.(entry) })

  useEffect(() => {
    if (!isDurable) return
    persistent.current.sync(durable)
    return () => persistent.current.dispose()
  }, [isDurable, durable])

  useEffect(() => {
    if (isDurable) return
    const leave = () => volatile.current.flush({ keepalive: true })
    window.addEventListener("pagehide", leave)
    return () => {
      window.removeEventListener("pagehide", leave)
      leave()
    }
  }, [isDurable])

  return useMemo(() => ({
    ...state,
    hold: (action) => (isDurable ? action?.commit?.() : volatile.current.hold(action)),
    undo: () => (isDurable ? persistent.current.undo() : volatile.current.undo()),
    flush: (options) => (isDurable ? persistent.current.flush(options) : volatile.current.flush(options)),
  }), [state, isDurable])
}
