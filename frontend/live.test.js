import assert from "node:assert/strict"
import { test } from "node:test"
import { affectsReads, applyRowDeltas, createLiveTransport, filterChanges, patchProp } from "./live.js"

function withFakeWindow(run) {
  const prevWindow = globalThis.window
  const prevNavigatorDesc = Object.getOwnPropertyDescriptor(globalThis, "navigator")
  const prevCustomEvent = globalThis.CustomEvent
  const listeners = new Map()

  globalThis.window = {
    __spinel: { reads: null },
    addEventListener(name, fn) {
      if (!listeners.has(name)) listeners.set(name, new Set())
      listeners.get(name).add(fn)
    },
    removeEventListener(name, fn) {
      listeners.get(name)?.delete(fn)
    },
    dispatchEvent(event) {
      for (const fn of [...(listeners.get(event.type) || [])]) fn(event)
      return true
    },
  }
  Object.defineProperty(globalThis, "navigator", { value: { onLine: true }, configurable: true })
  globalThis.CustomEvent = class FakeCustomEvent {
    constructor(type, init = {}) {
      this.type = type
      this.detail = init.detail
    }
  }

  try {
    return run(globalThis.window)
  } finally {
    globalThis.window = prevWindow
    if (prevNavigatorDesc) Object.defineProperty(globalThis, "navigator", prevNavigatorDesc)
    else delete globalThis.navigator
    globalThis.CustomEvent = prevCustomEvent
  }
}

test("filterChanges skips unaffected models/tables and unaffected partitions", () => {
  const reads = {
    tables: ["mail_entries"],
    models: ["MailEntry"],
    partitions: { MailEntry: { mailbox_id: ["support"] } },
  }

  assert.deepEqual(
    filterChanges(
      [{ type: "Issue", id: "1", op: "create", changed_columns: ["title"], attrs: { id: "1", title: "Bug" } }],
      { model: "MailEntry", reads },
    ),
    [],
  )

  assert.deepEqual(
    filterChanges(
      [{ type: "MailEntry", id: "2", op: "update", changed_columns: ["subject"], attrs: { id: "2", mailbox_id: "billing", subject: "Invoice" } }],
      { model: "MailEntry", reads },
    ),
    [],
  )

  const matching = [{ type: "MailEntry", id: "3", op: "update", changed_columns: ["subject"], attrs: { id: "3", mailbox_id: "support", subject: "Help" } }]
  assert.deepEqual(filterChanges(matching, { model: "MailEntry", reads }), matching)

  // Partition column moved -> never skipped
  const moved = [{ type: "MailEntry", id: "4", op: "update", changed_columns: ["mailbox_id"], attrs: { id: "4", mailbox_id: "billing" } }]
  assert.deepEqual(filterChanges(moved, { model: "MailEntry", reads }), moved)

  // Wildcard -> null
  assert.equal(filterChanges(null, { model: "MailEntry", reads }), null)
})

test("affectsReads respects empty reads, matching tables, and partition keys", () => {
  const delta = [{ type: "Issue", id: "1", op: "create", changed_columns: ["title"], attrs: { id: "1", title: "New" } }]
  assert.equal(affectsReads(delta, { tables: [], models: [], partitions: {} }), false)
  assert.equal(affectsReads(delta, { tables: ["issues"], models: ["Issue"], partitions: {} }), true)
  assert.equal(affectsReads(null, { tables: [], models: [], partitions: {} }), true)
})

test("applyRowDeltas patches create, update, and destroy while preserving untouched row identity", () => {
  const first = { id: "1", title: "One", done: false }
  const second = { id: "2", title: "Two", done: false }
  const rows = [first, second]

  const result = applyRowDeltas(rows, [
    { type: "Issue", id: "2", op: "update", changed_columns: ["done"], attrs: { id: "2", done: true } },
    { type: "Issue", id: "3", op: "create", changed_columns: ["id", "title", "done"], attrs: { id: "3", title: "Three", done: false } },
    { type: "Issue", id: "1", op: "destroy", changed_columns: [], attrs: { id: "1" } },
  ])

  assert.equal(result.patched, true)
  assert.equal(result.changed, true)
  assert.deepEqual(result.rows, [
    { id: "3", title: "Three", done: false },
    { id: "2", title: "Two", done: true },
  ])

  // Untouched row keeps identical reference when another row updates
  const stay = { id: "10", title: "Stay" }
  const edit = { id: "11", title: "Before" }
  const partial = applyRowDeltas([stay, edit], [
    { type: "Issue", id: "11", op: "update", changed_columns: ["title"], attrs: { id: "11", title: "After" } },
  ])
  assert.equal(partial.patched, true)
  assert.equal(partial.rows[0], stay)
  assert.notEqual(partial.rows[1], edit)
  assert.equal(partial.rows[1].title, "After")
})

test("applyRowDeltas falls back cleanly on omitted large columns or disallowed ops", () => {
  const rows = [{ id: "1", title: "Old", body: "Short" }]

  // Body changed but was omitted from attrs (over MAX_ATTR_BYTES) -> must reload
  const truncated = applyRowDeltas(rows, [
    { type: "Issue", id: "1", op: "update", changed_columns: ["body"], attrs: { id: "1" } },
  ])
  assert.deepEqual(truncated, { patched: false, reason: "incomplete_attrs" })

  // allowCreate: false -> reload on create, patch on update
  const blocked = applyRowDeltas(rows, [
    { type: "Issue", id: "2", op: "create", changed_columns: ["id", "title"], attrs: { id: "2", title: "New" } },
  ], { allowCreate: false })
  assert.deepEqual(blocked, { patched: false, reason: "create_disallowed" })
})

test("patchProp supports windowed { rows, more, limit } props", () => {
  const prop = { rows: [{ id: "1", title: "A" }], more: true, limit: 50 }
  const patched = patchProp(prop, [
    { type: "Issue", id: "1", op: "update", changed_columns: ["title"], attrs: { id: "1", title: "B" } },
  ])
  assert.equal(patched.patched, true)
  assert.deepEqual(patched.value, { rows: [{ id: "1", title: "B" }], more: true, limit: 50 })
})

test("createLiveTransport skips unaffected reloads, applies surgical patchers, and falls back when unpatchable", () => {
  withFakeWindow((win) => {
    const channel = { name: "instant_record", type: "local" }
    const reloaded = []
    const skipped = []
    let prop = { rows: [{ id: "m-1", subject: "Before", mailbox_id: "support" }], more: false, limit: 50 }

    const transport = createLiveTransport({
      onSkip: (info) => skipped.push(info),
    })

    const unpatch = transport.registerPatcher("MailEntry", (deltas, helpers) => {
      const res = helpers.patchProp(prop, deltas)
      if (!res.patched) return false
      prop = res.value
      return true
    })

    const unsub = transport.subscribe(channel, "MailEntry", (payload) => reloaded.push(payload))

    win.__spinel.reads = {
      tables: ["mail_entries"],
      models: ["MailEntry"],
      partitions: { MailEntry: { mailbox_id: ["support"] } },
    }

    // 1. Unaffected table -> skipped (no patch, no reload)
    win.dispatchEvent(new CustomEvent("instant-record:records-changed", {
      detail: {
        changes: [{ type: "Issue", id: "i-1", op: "create", changed_columns: ["title"], attrs: { id: "i-1", title: "Other" } }],
      },
    }))
    assert.equal(reloaded.length, 0)
    assert.equal(skipped.length, 1)

    // 2. Unaffected partition -> skipped (no patch, no reload)
    win.dispatchEvent(new CustomEvent("instant-record:records-changed", {
      detail: {
        changes: [{ type: "MailEntry", id: "m-9", op: "create", changed_columns: ["id", "subject", "mailbox_id"], attrs: { id: "m-9", subject: "Billing", mailbox_id: "billing" } }],
      },
    }))
    assert.equal(reloaded.length, 0)
    assert.equal(skipped.length, 2)

    // 3. Matching partition with complete attrs -> patched surgically, ZERO reloads!
    win.dispatchEvent(new CustomEvent("instant-record:records-changed", {
      detail: {
        changes: [{ type: "MailEntry", id: "m-1", op: "update", changed_columns: ["subject"], attrs: { id: "m-1", mailbox_id: "support", subject: "After" } }],
      },
    }))
    assert.equal(prop.rows[0].subject, "After")
    assert.equal(reloaded.length, 0)

    // 4. Matching partition with omitted oversized column -> patcher declines -> falls back to reload!
    win.dispatchEvent(new CustomEvent("instant-record:records-changed", {
      detail: {
        changes: [{ type: "MailEntry", id: "m-1", op: "update", changed_columns: ["body"], attrs: { id: "m-1", mailbox_id: "support" } }],
      },
    }))
    assert.equal(reloaded.length, 1)
    assert.equal(reloaded[0].changes[0].id, "m-1")

    // 5. Wildcard -> falls back to reload with changes: null
    win.dispatchEvent(new CustomEvent("instant-record:records-changed", {
      detail: { changes: null },
    }))
    assert.equal(reloaded.length, 2)
    assert.equal(reloaded[1].changes, null)

    unpatch()
    unsub()
  })
})
