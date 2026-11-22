// Writes held for a moment so they can be taken back. No React here, so the
// tests import this file alone; undo.js wraps it in a hook.
//
// heldActions({ ms, onChange }) answers { hold, undo, flush, snapshot }.
//
//   hold({ label, ids, commit, context })
//       keeps an action for `ms`. Its ids count as held from now until its
//       write has been answered, so whoever draws them can leave them out.
//   undo()
//       drops the newest held action without committing it, and answers it
//       (its `context` says what to put back), or null.
//   flush(options)
//       commits everything held now, oldest first. `options` reach `commit`.
//
// `commit(options)` does the write and may answer a promise. The ids stay
// held until it settles, so a row cannot return between a write and the
// answer that drops it. Reporting a failure is commit's own job.
//
// `onChange({ pending, held })` is called whenever either changes: `pending`
// is the actions that can still be undone, newest last.
export function heldActions({ ms = 5000, onChange = () => {} } = {}) {
  let pending = []
  let next = 1
  const committing = new Map()

  const snapshot = () => ({
    pending: pending.map(({ timer, ...entry }) => entry),
    held: new Set([...pending.flatMap((entry) => entry.ids), ...committing.keys()]),
  })
  const changed = () => onChange(snapshot())

  const count = (ids, by) => {
    for (const id of ids) {
      const left = (committing.get(id) || 0) + by
      if (left > 0) committing.set(id, left)
      else committing.delete(id)
    }
  }

  const run = (entry, options) => {
    count(entry.ids, 1)
    let answer
    try {
      answer = entry.commit(options)
    } catch (error) {
      answer = Promise.reject(error)
    }
    return Promise.resolve(answer).catch(() => {}).then(() => {
      count(entry.ids, -1)
      changed()
    })
  }

  const expire = (entry) => {
    pending = pending.filter((other) => other !== entry)
    run(entry)
    changed()
  }

  return {
    snapshot,

    hold({ label, ids, commit, context }) {
      const entry = { key: next++, label, ids, commit, context }
      entry.timer = setTimeout(() => expire(entry), ms)
      pending.push(entry)
      changed()
      return entry.key
    },

    undo() {
      const entry = pending.pop()
      if (!entry) return null
      clearTimeout(entry.timer)
      changed()
      return entry
    },

    flush(options) {
      if (!pending.length) return
      const entries = pending
      pending = []
      for (const entry of entries) {
        clearTimeout(entry.timer)
        run(entry, options)
      }
      changed()
    },
  }
}

// Durable undo state backed by local SQLite OutboxMutation rows (`hold_for:`).
// Unlike `heldActions` (which keeps writes in JS memory for non-compiled
// server-rendered pages), the write is already in SQLite with a `release_at`
// timestamp: this tracks unexpired rows across reloads, clears each toast when
// its `release_at` passes, and delegates `undo()` to `onCancel(entry)` (which
// calls `InstantRecord.cancel_pending(mutation_id)`).
const MAX_TIMEOUT_MS = 2_147_483_647

export function durableHeldActions({ onChange = () => {}, onCancel = () => {}, now = Date.now } = {}) {
  let pending = []
  let timer = null

  const parseRelease = (entry) => {
    const raw = entry.releaseAt ?? entry.release_at
    if (typeof raw === "number") return raw
    if (raw instanceof Date) return raw.getTime()
    const parsed = Date.parse(raw)
    return Number.isNaN(parsed) ? 0 : parsed
  }

  const samePending = (a, b) =>
    a.length === b.length &&
    a.every((entry, i) =>
      entry.key === b[i].key &&
      entry.id === b[i].id &&
      entry.label === b[i].label &&
      entry._releaseMs === b[i]._releaseMs,
    )

  const snapshot = () => ({
    pending: pending.map(({ _releaseMs, ...entry }) => entry),
    held: new Set(),
  })

  const clearTimer = () => {
    if (timer !== null) {
      clearTimeout(timer)
      timer = null
    }
  }

  const schedule = () => {
    clearTimer()
    if (!pending.length) return
    const nextMs = Math.min(...pending.map((entry) => entry._releaseMs))
    const delay = Math.min(Math.max(0, nextMs - now()), MAX_TIMEOUT_MS)
    timer = setTimeout(prune, delay)
  }

  const prune = () => {
    const current = now()
    const remaining = pending.filter((entry) => entry._releaseMs > current)
    if (remaining.length !== pending.length) {
      pending = remaining
      onChange(snapshot())
    }
    schedule()
  }

  return {
    snapshot,

    sync(entries = []) {
      const current = now()
      const next = entries
        .map((entry) => {
          const releaseMs = parseRelease(entry)
          return { ...entry, key: entry.key ?? entry.id, _releaseMs: releaseMs }
        })
        .filter((entry) => entry._releaseMs > current)
      const changed = !samePending(pending, next)
      pending = next
      schedule()
      if (changed) onChange(snapshot())
    },

    undo() {
      const current = now()
      const before = pending.length
      pending = pending.filter((entry) => entry._releaseMs > current)
      const entry = pending.pop()
      if (!entry) {
        schedule()
        if (pending.length !== before) onChange(snapshot())
        return null
      }
      schedule()
      const { _releaseMs, ...plain } = entry
      onChange(snapshot())
      onCancel(plain)
      return plain
    },

    // Durable writes are already persisted in SQLite; leaving the page needs no flush.
    flush() {},

    dispose() {
      clearTimer()
    },
  }
}
