import assert from "node:assert/strict"
import { test } from "node:test"
import { createSyncNoticesStore, diffNotice } from "./sync-notices.js"

const sampleConflict = {
  id: "notice-1",
  kind: "conflict",
  record_type: "Note",
  record_id: "note-1",
  operation: "update",
  reason: "Overwritten by a newer server change",
  attempted_changes: { id: "note-1", title: "My offline edit", body: "Same", updated_at: "2026-11-21T00:00:01Z" },
  server_attributes: { id: "note-1", title: "Teammate edit", body: "Same", server_version: 4, updated_at: "2026-11-21T00:00:05Z" },
  server_version: 4,
}

const sampleRejection = {
  id: "notice-2",
  kind: "rejected",
  record_type: "Issue",
  record_id: "iss-9",
  operation: "create",
  reason: "Title is not allowed by the server",
  attempted_changes: { id: "iss-9", title: "reject me", state: "open" },
  server_attributes: {},
  server_version: 0,
}

test("diffNotice computes field changes while omitting bookkeeping columns and unchanged fields", () => {
  assert.deepEqual(diffNotice(sampleConflict), [
    { field: "title", local: "My offline edit", server: "Teammate edit" },
  ])
  assert.deepEqual(diffNotice(sampleRejection), [
    { field: "title", local: "reject me", server: undefined },
    { field: "state", local: "open", server: undefined },
  ])
  assert.deepEqual(
    diffNotice({
      operation: "destroy",
      attempted_changes: {},
      server_attributes: { id: "iss-1", title: "Protected", server_version: 2 },
    }),
    [{ field: "title", local: null, server: "Protected" }],
  )
})

test("store refreshes, filters by recordType/recordId, and updates via live setNotices", async () => {
  const snapshots = []
  const store = createSyncNoticesStore({
    recordType: "Note",
    transport: {
      list: async () => ({ ok: true, notices: [sampleConflict, sampleRejection] }),
      resolve: async () => ({ ok: true, notices: [] }),
    },
    onChange: (snap) => snapshots.push(snap),
  })

  await store.refresh()
  assert.equal(store.snapshot().count, 1)
  assert.equal(store.snapshot().notices[0].id, "notice-1")
  assert.equal(store.snapshot().loading, false)

  store.setNotices([sampleRejection])
  assert.equal(store.snapshot().count, 0)
  assert.ok(snapshots.length >= 2)
})

test("store retry, fork, and dismiss forward overrides and update state", async () => {
  const calls = []
  const store = createSyncNoticesStore({
    initial: [sampleConflict, sampleRejection],
    transport: {
      list: async () => ({ ok: true, notices: [sampleConflict, sampleRejection] }),
      resolve: async (req) => {
        calls.push(req)
        if (req.action === "retry") {
          return { ok: true, record_id: "iss-9", notices: [sampleConflict] }
        }
        if (req.action === "fork") {
          return { ok: true, record_id: "note-fork-1", notices: [] }
        }
        return { ok: true, notices: [] }
      },
    },
  })

  const retried = await store.retry("notice-2", { title: "allowed title" })
  assert.equal(retried.ok, true)
  assert.equal(store.snapshot().count, 1)
  assert.deepEqual(calls[0], { action: "retry", id: "notice-2", overrides: { title: "allowed title" } })

  const forked = await store.fork("notice-1", { title: "My offline edit (copy)" })
  assert.equal(forked.record_id, "note-fork-1")
  assert.equal(store.snapshot().count, 0)
  assert.deepEqual(calls[1], { action: "fork", id: "notice-1", overrides: { title: "My offline edit (copy)" } })

  store.setNotices([sampleConflict])
  await store.dismiss("notice-1")
  assert.equal(store.snapshot().count, 0)
  assert.deepEqual(calls[2], { action: "dismiss", id: "notice-1", overrides: {} })
})

test("store surfaces transport errors without dropping notices", async () => {
  const store = createSyncNoticesStore({
    initial: [sampleRejection],
    transport: {
      list: async () => ({ ok: false, error: "offline" }),
      resolve: async () => ({ ok: false, error: "Title can't be blank", notices: [sampleRejection] }),
    },
  })

  const failed = await store.retry("notice-2", { title: "" })
  assert.equal(failed.ok, false)
  assert.equal(store.snapshot().error, "Title can't be blank")
  assert.equal(store.snapshot().count, 1)
})
