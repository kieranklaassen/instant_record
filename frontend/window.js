// What a page asks of InstantRecord beyond what Inertia already gives it.
// Nothing here knows about mail: it is written to move into the gem.
import { router, usePage } from "@inertiajs/react"
import { useCallback, useEffect, useMemo, useRef, useState } from "react"

// True where the page runs beside a local database (the compiled runtime).
export const local = () => typeof window !== "undefined" && !!window.__spinel

// The local database holds a window of each model. This asks the worker to
// widen it past `before`, and answers { ok, has_more }. With no local
// database the server already has everything, so there is nothing to widen.
export function widenWindow(request) {
  const worker = local() && window.__spinel.worker
  if (!worker) return Promise.resolve({ ok: true })
  return new Promise((resolve) => {
    const channel = new MessageChannel()
    const timer = setTimeout(() => resolve({ ok: false, busy: true, error: "history request timed out" }), 15000)
    channel.port1.onmessage = (event) => {
      clearTimeout(timer)
      resolve(event.data || { ok: false, error: "empty reply" })
    }
    worker.postMessage({ type: "instant_record.fetch_history", request }, [channel.port2])
  })
}

// useLiveParam keeps one query parameter of the address at `value` and the
// props that depend on it answered for it.
//
//   only      the props to reload when the value changes
//   answered  the value the props on the page were answered for
//   omit      (value) => true where the address should not carry it
//
// The address changes first, with a client-side visit, and the partial
// reload follows. Every reload, this one or one Inertia starts for a live
// prop, reads the address as it stands, so none can answer for an older
// value and put it back. An answer that still arrives for another value is
// asked for once more.
export function useLiveParam(name, value, { only, answered, omit }) {
  const { url } = usePage()
  const asked = useRef(null)

  useEffect(() => {
    if (value === null || value === undefined) return
    const want = String(value)
    const address = new URL(url, window.location.origin)
    const current = address.searchParams.get(name)
    const stale = String(answered) !== want && asked.current !== `${want}:${answered}`
    const reload = () => {
      if (!stale) return
      asked.current = `${want}:${answered}`
      router.reload({ only })
    }
    if (current === want || (current === null && omit?.(value))) return reload()

    if (omit?.(value)) address.searchParams.delete(name)
    else address.searchParams.set(name, want)
    router.replace({ url: address.pathname + address.search, preserveState: true, preserveScroll: true, onFinish: reload })
  }, [name, value, answered, url])
}

// useLiveWindow grows a list prop with the reader's scroll.
//
//   prop     the prop's name, to reload it alone
//   window   the prop itself: { rows, more, limit }, the rows, whether this
//            database holds more, and the limit the answer was made for
//   model    the synced model the rows are, by name
//   cursor   (row) => { created_at, id } of a row, to ask for what is older
//
// Answers { more, older, failed }. `older(upTo)` loads the next page, or as
// far as index `upTo`: first into the local database where there is one, then
// into the prop, by a wider `limit` in the address. The list stays one prop
// however long it gets, so a live reload keeps all of it current and a
// reload of the page returns to the same depth.
export function useLiveWindow({ prop, window, model, cursor, pageSize = 50 }) {
  const [limit, setLimit] = useState(window.limit)
  const [exhausted, setExhausted] = useState(false)
  const [failed, setFailed] = useState(false)
  const only = useMemo(() => [prop], [prop])
  useLiveParam("limit", limit, { only, answered: window.limit, omit: (value) => value <= pageSize })
  // Beside a local database, older rows may still be on the sync server.
  const more = window.more || (local() && !exhausted)
  const busy = useRef(false)
  const now = useRef({})
  now.current = { window, more, limit }

  const older = useCallback(async (upTo = 0) => {
    const { window, more, limit } = now.current
    // One step at a time: wait for the answer to the last one.
    if (busy.current || !more || window.limit < limit) return
    busy.current = true
    try {
      const last = window.rows.at(-1)
      if (last && !window.more) {
        const reply = await widenWindow({ type: model, before: cursor(last), limit: pageSize })
        if (!reply.ok) throw new Error(reply.error)
        if (reply.has_more === false) setExhausted(true)
      }
      setFailed(false)
      setLimit(Math.max(window.limit + pageSize, Math.ceil((upTo + 1) / pageSize) * pageSize))
    } catch {
      setFailed(true)
    } finally {
      busy.current = false
    }
  }, [model, cursor, pageSize])

  return { more, older, failed }
}

// Turns each raw row of a prop into an object once, and hands back the same
// object for as long as the row's data is unchanged, so a memoized row
// component redraws only when its own record did.
export function useStableRows(raw, build) {
  const kept = useRef(new Map())
  return useMemo(() => {
    const next = new Map()
    const rows = raw.map((fields) => {
      const key = JSON.stringify(fields)
      const row = kept.current.get(key) || build(fields)
      next.set(key, row)
      return row
    })
    kept.current = next
    return rows
  }, [raw, build])
}
