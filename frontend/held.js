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
