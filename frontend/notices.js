// React hook for InstantRecord::SyncNotice quarantine items.
//
// In the compiled browser runtime it talks to the worker's `notices` bridge
// and listens for `instant-record:sync-notices` events. Against a Rails server
// it falls back to the mounted engine's `/instant_record/sync_notices` JSON
// endpoints.
import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { SYNC_NOTICES_EVENT, createSyncNoticesStore, diffNotice } from "./sync-notices.js"
import { local } from "./window.js"

const xsrf = () =>
  typeof document === "undefined"
    ? ""
    : decodeURIComponent(document.cookie.match(/(?:^|; )XSRF-TOKEN=([^;]*)/)?.[1] || "")

function workerTransport() {
  return {
    list: () => window.__spinel.call("notices", { action: "list" }),
    resolve: ({ action, id, overrides }) =>
      window.__spinel.call("notices", { action, id, overrides }),
  }
}

function httpTransport(endpoint) {
  const base = endpoint.replace(/\/+$/, "")
  const jsonHeaders = () => {
    const headers = { Accept: "application/json", "Content-Type": "application/json" }
    const token = xsrf()
    if (token) headers["X-XSRF-TOKEN"] = token
    return headers
  }

  return {
    async list() {
      const response = await fetch(`${base}.json`, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      })
      if (!response.ok) return { ok: false, error: `Request failed (${response.status})` }
      return response.json()
    },

    async resolve({ action, id, overrides }) {
      const response = await fetch(`${base}/${encodeURIComponent(id)}/${action}.json`, {
        method: "POST",
        headers: jsonHeaders(),
        body: JSON.stringify({ overrides: overrides || {} }),
        credentials: "same-origin",
      })
      const data = await response.json().catch(() => ({}))
      if (!response.ok) return { ok: false, error: data.error || `Request failed (${response.status})`, notices: data.notices }
      return data
    },
  }
}

export function useSyncNotices({
  endpoint = "/instant_record/sync_notices",
  recordType = null,
  recordId = null,
} = {}) {
  const isLocal = local()
  const initial = isLocal && Array.isArray(window.__spinel?.notices) ? window.__spinel.notices : []
  const transport = useMemo(
    () => (isLocal ? workerTransport() : httpTransport(endpoint)),
    [isLocal, endpoint],
  )
  const storeRef = useRef(null)
  const [state, setState] = useState(() => {
    const store = createSyncNoticesStore({ transport, initial, recordType, recordId })
    return store.snapshot()
  })

  useEffect(() => {
    const store = createSyncNoticesStore({
      transport,
      initial: isLocal && Array.isArray(window.__spinel?.notices) ? window.__spinel.notices : [],
      recordType,
      recordId,
      onChange: setState,
    })
    storeRef.current = store
    setState(store.snapshot())
    store.refresh()

    if (!isLocal || typeof window === "undefined") return undefined
    const onNotices = (event) => {
      store.setNotices(event?.detail?.notices || [])
    }
    const onRecordsChanged = () => {
      store.refresh()
    }
    window.addEventListener(SYNC_NOTICES_EVENT, onNotices)
    window.addEventListener("instant-record:records-changed", onRecordsChanged)
    return () => {
      window.removeEventListener(SYNC_NOTICES_EVENT, onNotices)
      window.removeEventListener("instant-record:records-changed", onRecordsChanged)
    }
  }, [transport, isLocal, recordType, recordId])

  const refresh = useCallback(() => storeRef.current?.refresh(), [])
  const retry = useCallback((id, overrides = {}) => storeRef.current?.retry(id, overrides), [])
  const fork = useCallback((id, overrides = {}) => storeRef.current?.fork(id, overrides), [])
  const dismiss = useCallback((id) => storeRef.current?.dismiss(id), [])

  return {
    notices: state.notices,
    count: state.count,
    loading: state.loading,
    error: state.error,
    refresh,
    retry,
    fork,
    dismiss,
  }
}

export { SYNC_NOTICES_EVENT, createSyncNoticesStore, diffNotice }
