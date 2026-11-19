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

// How much of a model's history the local database holds, as the worker's
// background fill reports it: { done, full, rows }. `done` says the beginning
// is here, so every read and every count is whole. With no local database the
// server answers and everything is whole already.
export function useHistory() {
  const [state, setState] = useState(() => (local() ? window.__spinel.history || { done: false } : { done: true }))
  useEffect(() => {
    if (!local()) return
    const update = (event) => setState(event.detail)
    window.addEventListener("instant-record:history", update)
    if (window.__spinel.history) setState(window.__spinel.history)
    return () => window.removeEventListener("instant-record:history", update)
  }, [])
  return state
}

// useLiveSearch widens a search past what the local database holds. The page
// has already answered `term` from that database. This asks the sync server
// for the matches it holds beyond it, and reloads `only` when some arrive and
// the reader is still on the same term. Answers { waiting, partial }: partial
// says the server could not be asked, so what is shown is this device's part.
export function useLiveSearch(term, { only, model }) {
  const [state, setState] = useState({ waiting: false, partial: false })
  const current = useRef(term)
  current.current = term

  useEffect(() => {
    if (!term || !local()) return setState({ waiting: false, partial: false })
    setState({ waiting: true, partial: false })
    widenWindow({ type: model, search: term }).then((reply) => {
      if (current.current !== term) return
      setState({ waiting: false, partial: !reply.ok })
      if (reply.ok && reply.applied > 0) router.reload({ only })
    })
  }, [term, model])
  return state
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
//   search   the term the list is narrowed by, if any, so older pages are too
//
// Answers { more, older, failed }. `older(upTo)` loads the next page, or as
// far as index `upTo`: first into the local database where there is one, then
// into the prop, by a wider `limit` in the address. The list stays one prop
// however long it gets, so a live reload keeps all of it current and a
// reload of the page returns to the same depth.
export function useLiveWindow({ prop, window, model, cursor, search = "", pageSize = 50 }) {
  const [limit, setLimit] = useState(window.limit)
  const [exhausted, setExhausted] = useState(false)
  const [failed, setFailed] = useState(false)
  const only = useMemo(() => [prop], [prop])
  useLiveParam("limit", limit, { only, answered: window.limit, omit: (value) => value <= pageSize })
  // Beside a local database, older rows may still be on the sync server.
  const more = window.more || (local() && !exhausted)
  const busy = useRef(false)
  const now = useRef({})
  now.current = { window, more, limit, search }
  // Another search is another list: start it at the first page. The search
  // the page arrived with keeps the depth its address asked for.
  const searched = useRef(search)
  useEffect(() => {
    if (searched.current === search) return
    searched.current = search
    setExhausted(false)
    setLimit(pageSize)
  }, [search, pageSize])

  const older = useCallback(async (upTo = 0) => {
    const { window, more, limit, search } = now.current
    // One step at a time: wait for the answer to the last one.
    if (busy.current || !more || window.limit < limit) return
    busy.current = true
    try {
      const last = window.rows.at(-1)
      // Until the whole history is here, rows the database holds further down
      // may lie past a gap (a search brought them in), so the page below the
      // last row is asked for even when there are local rows to show. A page
      // asked for before is answered by the worker without the server.
      const whole = !local() || window.__spinel.history?.done === true
      if (last && (!window.more || !whole)) {
        const reply = await widenWindow({ type: model, before: cursor(last), limit: pageSize, ...(search ? { search } : {}) })
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
