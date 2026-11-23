// Pure state and diff helpers for InstantRecord::SyncNotice quarantine items.
// Kept framework-free so the logic tests directly under Node without React.

const BOOKKEEPING = new Set(["id", "server_version", "sync_state", "created_at", "updated_at"])

export const SYNC_NOTICES_EVENT = "instant-record:sync-notices"

// Compute field-level differences between a notice's attempted local changes
// and the winning server attributes, skipping gem bookkeeping columns.
export function diffNotice(notice) {
  if (!notice || typeof notice !== "object") return []
  const attempted = notice.attempted_changes && typeof notice.attempted_changes === "object"
    ? notice.attempted_changes
    : {}
  const server = notice.server_attributes && typeof notice.server_attributes === "object"
    ? notice.server_attributes
    : {}
  const serverKeys = Object.keys(server)
  const keys = (notice.operation === "destroy" ? serverKeys : Object.keys(attempted))
    .filter((key) => !BOOKKEEPING.has(key))

  const diffs = []
  for (const field of keys) {
    const local = notice.operation === "destroy" ? null : attempted[field]
    const remote = server[field]
    if (serverKeys.length > 0 && local === remote) continue
    diffs.push({ field, local, server: remote })
  }
  return diffs
}

export function filterNotices(notices, { recordType = null, recordId = null } = {}) {
  const list = Array.isArray(notices) ? notices : []
  return list.filter((notice) => {
    if (recordType && notice.record_type !== recordType) return false
    if (recordId && notice.record_id !== recordId) return false
    return true
  })
}

// Framework-free controller driving useSyncNotices. `transport` abstracts the
// compiled browser worker (`window.__spinel.call("notices", ...)`) vs server
// HTTP requests so tests can exercise every resolution path directly.
export function createSyncNoticesStore({
  transport,
  initial = [],
  recordType = null,
  recordId = null,
  onChange = () => {},
} = {}) {
  let state = {
    all: Array.isArray(initial) ? initial : [],
    notices: filterNotices(initial, { recordType, recordId }),
    loading: false,
    error: null,
  }

  const emit = (patch) => {
    const all = patch.all !== undefined ? patch.all : state.all
    state = {
      ...state,
      ...patch,
      all,
      notices: filterNotices(all, { recordType, recordId }),
    }
    onChange(snapshot())
  }

  const snapshot = () => ({
    notices: state.notices,
    count: state.notices.length,
    loading: state.loading,
    error: state.error,
  })

  const setNotices = (list) => {
    emit({ all: Array.isArray(list) ? list : [], error: null })
  }

  const refresh = async () => {
    emit({ loading: true, error: null })
    try {
      const reply = await transport.list()
      if (!reply || reply.ok === false) {
        emit({ loading: false, error: reply?.error || "Could not load sync notices" })
        return reply || { ok: false, error: "Could not load sync notices" }
      }
      emit({ all: reply.notices || [], loading: false, error: null })
      return reply
    } catch (err) {
      const message = err?.message || String(err)
      emit({ loading: false, error: message })
      return { ok: false, error: message }
    }
  }

  const act = async (action, id, overrides = {}) => {
    emit({ loading: true, error: null })
    try {
      const reply = await transport.resolve({ action, id, overrides })
      if (!reply || reply.ok === false) {
        const message = reply?.error || `Could not ${action} sync notice`
        emit({
          all: Array.isArray(reply?.notices) ? reply.notices : state.all,
          loading: false,
          error: message,
        })
        return reply || { ok: false, error: message }
      }
      const next = Array.isArray(reply.notices)
        ? reply.notices
        : state.all.filter((notice) => notice.id !== id)
      emit({ all: next, loading: false, error: null })
      return reply
    } catch (err) {
      const message = err?.message || String(err)
      emit({ loading: false, error: message })
      return { ok: false, error: message }
    }
  }

  return {
    snapshot,
    setNotices,
    refresh,
    retry: (id, overrides = {}) => act("retry", id, overrides),
    fork: (id, overrides = {}) => act("fork", id, overrides),
    dismiss: (id) => act("dismiss", id),
  }
}
