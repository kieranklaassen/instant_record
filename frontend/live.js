// InstantRecord as a transport for Inertia's live props.
//
// A page object names, under `liveProps`, the events each prop listens for,
// and Inertia reloads a prop when one of its events arrives: a partial
// reload, throttled, paused while the tab is hidden, and repeated for every
// live prop when a dropped connection returns.
//
// Here an event is a synced model's name (`live: { mail: MailEntry }` in
// Ruby). The runtime dispatches "instant-record:records-changed" on the window
// whenever sync, a local write, or a peer tab touched the local database, with
// structured row deltas as `detail.changes` ({ type, id, op, changed_columns,
// attrs } each) and optional read tracking as `detail.reads` ({ tables, models,
// partitions }).
//
// Two fast paths avoid unnecessary reloads:
//   1. Table/partition skipping: when structured deltas only touch unaffected
//      models/tables or non-matching partitions, the handler is not invoked.
//   2. Surgical row patching: when a patcher is registered (via
//      `createLiveTransport({ patch })` or `liveTransport.registerPatcher`),
//      deltas can update rows in place via `applyRowDeltas` / `patchProp` and
//      return true to suppress Inertia's partial reload. When any delta is
//      unpatchable (wildcard, omitted large column, or filtered create), the
//      transport falls back to `handler({ changes })`.
//
// Served by Rails alone there is no local database and so no signal: a slow
// poll stands in for it, and the reload goes to the server.

const CHANGED = "instant-record:records-changed"
const POLL_MS = 4000

const isLocal = () => typeof window !== "undefined" && !!window.__spinel

function matchesPartitions(delta, constraints) {
  if (!constraints || typeof constraints !== "object") return true
  const attrs = delta?.attrs
  if (!attrs || typeof attrs !== "object") return true
  const changedCols = Array.isArray(delta.changed_columns) ? delta.changed_columns : []

  for (const [col, allowed] of Object.entries(constraints)) {
    // On an update where the partition column itself changed, the row may have
    // entered or left this partition — conservatively treat it as affecting the read.
    if (delta.op === "update" && changedCols.includes(col)) continue
    if (!Object.prototype.hasOwnProperty.call(attrs, col)) continue
    const val = attrs[col]
    if (val === null || val === undefined) continue
    const list = Array.isArray(allowed) ? allowed.map(String) : [String(allowed)]
    if (!list.includes(String(val))) return false
  }
  return true
}

// Sound check: returns true if any delta in `changes` could affect `reads`
// ({ tables, models, partitions }). Wildcard `changes` (null) or missing `reads`
// conservatively return true.
export function affectsReads(changes, reads) {
  if (!changes || !reads) return true
  if (changes.length === 0) return false

  const models = Array.isArray(reads.models) ? reads.models : []
  const tables = Array.isArray(reads.tables) ? reads.tables : []
  if (models.length === 0 && tables.length === 0) return false

  const partitions = reads.partitions && typeof reads.partitions === "object" ? reads.partitions : {}

  return changes.some((delta) => {
    if (!delta || typeof delta !== "object") return true
    const type = delta.type || ""
    const table = delta.table || ""
    let matchedKey = null
    if (type && models.includes(type)) matchedKey = type
    else if (table && tables.includes(table)) matchedKey = table
    if (!matchedKey) return false

    const constraints = partitions[matchedKey] || (table ? partitions[table] : null)
    return matchesPartitions(delta, constraints)
  })
}

// Filter structured deltas for a single subscribed model, respecting optional
// page/prop read tracking and explicit channel partitions.
//
// Returns:
//   null     -> wildcard (anything may have changed; caller must reload)
//   []       -> unaffected (skip reload)
//   Delta[]  -> matching deltas for this model/partition
export function filterChanges(changes, { model, reads = null, partitions = null } = {}) {
  if (!changes) return null
  if (!Array.isArray(changes) || changes.length === 0) return []

  const modelDeltas = changes.filter((delta) => {
    if (!delta || typeof delta !== "object") return false
    return delta.type === model || (delta.table && delta.table === model)
  })
  if (modelDeltas.length === 0) return []

  return modelDeltas.filter((delta) => {
    if (partitions && !matchesPartitions(delta, partitions)) return false
    if (reads) {
      const models = Array.isArray(reads.models) ? reads.models : []
      const tables = Array.isArray(reads.tables) ? reads.tables : []
      const hasAnyScope = models.length > 0 || tables.length > 0
      if (hasAnyScope) {
        const table = delta.table || ""
        const inModels = delta.type && models.includes(delta.type)
        const inTables = table && tables.includes(table)
        if (!inModels && !inTables) return false
      } else {
        // Explicit empty read set: nothing was read from the database.
        return false
      }
      const readPartitions = reads.partitions?.[delta.type] || (delta.table ? reads.partitions?.[delta.table] : null)
      if (readPartitions && !matchesPartitions(delta, readPartitions)) return false
    }
    return true
  })
}

// Apply structured row deltas surgically to an array of rows, preserving object
// identity (`===`) for untouched rows.
//
// Returns:
//   { patched: true, rows, changed }   when every delta applied cleanly
//   { patched: false, reason }         when any delta requires a full reload
export function applyRowDeltas(rows, deltas, options = {}) {
  if (!Array.isArray(rows)) return { patched: false, reason: "rows_not_array" }
  if (!Array.isArray(deltas)) return { patched: false, reason: "wildcard" }
  if (deltas.length === 0) return { patched: true, rows, changed: false }

  const {
    idKey = "id",
    getId = (row) => (row && typeof row === "object" ? String(row[idKey]) : null),
    create = null,
    update = null,
    matches = null,
    insertAt = "start",
    allowCreate = true,
    allowUpdate = true,
    allowDestroy = true,
    missingUpdate = "ignore",
  } = options

  let next = rows.slice()
  let changed = false

  for (const delta of deltas) {
    if (!delta || typeof delta !== "object" || !delta.op) {
      return { patched: false, reason: "untyped_delta" }
    }
    const id = String(delta.id)
    const idx = next.findIndex((row) => getId(row) === id)
    const attrs = delta.attrs && typeof delta.attrs === "object" ? delta.attrs : {}
    const changedCols = Array.isArray(delta.changed_columns) ? delta.changed_columns : []

    if (delta.op === "destroy") {
      if (!allowDestroy) return { patched: false, reason: "destroy_disallowed" }
      if (idx !== -1) {
        next.splice(idx, 1)
        changed = true
      }
      continue
    }

    if (delta.op === "create") {
      if (!allowCreate) return { patched: false, reason: "create_disallowed" }
      // If a column changed but was omitted from attrs (e.g. byte cap), reload.
      if (changedCols.some((col) => !Object.prototype.hasOwnProperty.call(attrs, col))) {
        return { patched: false, reason: "incomplete_attrs" }
      }
      if (matches && !matches(attrs, delta)) continue
      const built = create ? create(delta) : (Object.keys(attrs).length ? { id, ...attrs } : null)
      if (!built) return { patched: false, reason: "cannot_build_row" }

      if (idx !== -1) {
        next[idx] = built
      } else if (typeof insertAt === "function") {
        next = insertAt(next, built, delta)
      } else if (insertAt === "end") {
        next.push(built)
      } else {
        next.unshift(built)
      }
      changed = true
      continue
    }

    if (delta.op === "update") {
      if (!allowUpdate) return { patched: false, reason: "update_disallowed" }
      if (changedCols.some((col) => !Object.prototype.hasOwnProperty.call(attrs, col))) {
        return { patched: false, reason: "incomplete_attrs" }
      }
      if (idx === -1) {
        if (missingUpdate === "reload") return { patched: false, reason: "missing_row" }
        continue
      }
      const existing = next[idx]
      const updated = update ? update(existing, delta) : { ...existing, ...attrs }
      if (!updated) return { patched: false, reason: "cannot_update_row" }
      if (matches && !matches(updated, delta)) {
        next.splice(idx, 1)
        changed = true
        continue
      }
      next[idx] = updated
      changed = true
      continue
    }

    return { patched: false, reason: "unknown_op" }
  }

  return { patched: true, rows: changed ? next : rows, changed }
}

// Convenience wrapper that patches either a plain array prop `[row, ...]` or a
// windowed prop `{ rows: [...], ... }` (preserving sibling keys like `more` / `limit`).
export function patchProp(propValue, deltas, options = {}) {
  if (Array.isArray(propValue)) {
    const result = applyRowDeltas(propValue, deltas, options)
    return result.patched ? { patched: true, value: result.rows, changed: result.changed } : result
  }
  if (propValue && typeof propValue === "object" && Array.isArray(propValue.rows)) {
    const result = applyRowDeltas(propValue.rows, deltas, options)
    if (!result.patched) return result
    return {
      patched: true,
      value: result.changed ? { ...propValue, rows: result.rows } : propValue,
      changed: result.changed,
    }
  }
  return { patched: false, reason: "unsupported_prop_shape" }
}

export function createLiveTransport(options = {}) {
  const patchers = new Map()
  if (options.patch && typeof options.patch === "object") {
    for (const [model, fn] of Object.entries(options.patch)) {
      if (typeof fn === "function") patchers.set(model, fn)
    }
  }
  const defaultPatch = typeof options.patch === "function" ? options.patch : null
  const getReads = typeof options.reads === "function" ? options.reads : null
  const onSkip = typeof options.onSkip === "function" ? options.onSkip : null

  return {
    registerPatcher(model, patcher) {
      patchers.set(model, patcher)
      return () => {
        if (patchers.get(model) === patcher) patchers.delete(model)
      }
    },

    subscribe(channel, model, handler) {
      if (!channel || channel.name !== "instant_record") return () => {}

      const changed = (event) => {
        const changes = event?.detail?.changes ?? null
        const reads = event?.detail?.reads ?? getReads?.() ?? channel.reads ?? (typeof window !== "undefined" ? window.__spinel?.reads ?? null : null)
        const partitions = channel.partitions ?? null

        const mine = filterChanges(changes, { model, reads, partitions })
        if (mine === null) return handler({ changes: null })
        if (mine.length === 0) {
          onSkip?.({ model, channel, changes, reads })
          return
        }

        const patcher = patchers.get(model) || defaultPatch
        if (patcher) {
          const applied = patcher(mine, { model, channel, reads, applyRowDeltas, patchProp })
          if (applied === true || applied?.patched === true) return
        }

        handler({ changes: mine })
      }

      window.addEventListener(CHANGED, changed)
      const poll = isLocal() ? null : setInterval(() => navigator.onLine && changed(), POLL_MS)
      return () => {
        window.removeEventListener(CHANGED, changed)
        if (poll) clearInterval(poll)
      }
    },

    onStatusChange(callback) {
      const up = () => callback(true)
      const down = () => callback(false)
      window.addEventListener("online", up)
      window.addEventListener("offline", down)
      callback(navigator.onLine)
      return () => {
        window.removeEventListener("online", up)
        window.removeEventListener("offline", down)
      }
    },
  }
}

export const liveTransport = createLiveTransport()
