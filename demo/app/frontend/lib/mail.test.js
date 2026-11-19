import assert from "node:assert/strict"
import { test } from "node:test"
import { resolveFocus } from "../../../../frontend/focus.js"
import { archivedLabel, draftKey, firstOf, seenBefore, withOverlay, withPending } from "./mail.js"

const row = (id, unread = false) => ({ id, unread })
const none = { held: new Set(), marks: new Map() }

test("with nothing on its way the list is the list", () => {
  const rows = [row("a", true), row("b")]
  assert.equal(withOverlay(rows, 1, none).rows, rows)
})

test("held rows leave in order, and only unread ones lower the count", () => {
  const rows = [row("a", true), row("b"), row("c", true), row("d")]
  const shown = withOverlay(rows, 2, { held: new Set(["b", "c"]), marks: new Map() })
  assert.deepEqual(shown.rows.map((r) => r.id), ["a", "d"])
  assert.equal(shown.unreadCount, 1)
})

test("marking a mix read changes only the unread rows", () => {
  const rows = [row("a", true), row("b"), row("c")]
  const read = { unread: false }
  const shown = withOverlay(rows, 1, { held: new Set(), marks: new Map([["a", read], ["b", read], ["c", read]]) })
  assert.deepEqual(shown.rows.map((r) => r.unread), [false, false, false])
  assert.equal(shown.unreadCount, 0)
  assert.equal(shown.rows[1], rows[1])
})

test("a row marked unread and then held does not count", () => {
  const shown = withOverlay([row("a")], 0, { held: new Set(["a"]), marks: new Map([["a", { unread: true }]]) })
  assert.equal(shown.unreadCount, 0)
})

test("archiving rows 2 to 4 of eight from row 4 leaves focus on what was the fifth", () => {
  const ids = ["r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8"]
  const gone = new Set(["r2", "r3", "r4"])
  const from = firstOf(ids, gone)
  assert.equal(from, "r2")
  const left = ids.filter((id) => !gone.has(id))
  assert.deepEqual(resolveFocus(left, from, ids.indexOf(from)), { id: "r5", index: 1 })
})

test("the archive label counts", () => {
  assert.equal(archivedLabel(1), "Conversation archived")
  assert.equal(archivedLabel(3), "3 conversations archived")
})

const sent = (key, body, seen = 0) => ({ key, author: "maya", body, at: "2026-11-19T10:00:00Z", seen })

test("a reply on its way is shown after the thread's replies, until the thread holds it", () => {
  const before = [{ id: "1", author: "theo", body: "On it" }]
  const entry = sent("p1", "Thanks")
  assert.deepEqual(withPending(before, [entry]).map((r) => r.id), ["1", "p1"])
  assert.equal(withPending(before, [entry]).at(-1).pending, true)

  const after = [...before, { id: "2", author: "maya", body: "Thanks" }]
  assert.deepEqual(withPending(after, [entry]).map((r) => r.id), ["1", "2"])
})

test("an older reply that reads the same is not taken for the new one", () => {
  const replies = [{ id: "1", author: "maya", body: "Thanks" }]
  const entry = sent("p1", "Thanks", seenBefore(replies, { author: "maya", body: "Thanks" }))
  assert.deepEqual(withPending(replies, [entry]).map((r) => r.id), ["1", "p1"])
})

test("two replies that read the same are dropped one at a time", () => {
  const pending = [sent("p1", "Thanks"), sent("p2", "Thanks")]
  const one = [{ id: "1", author: "maya", body: "Thanks" }]
  assert.deepEqual(withPending(one, pending).map((r) => r.id), ["1", "p2"])
  const two = [...one, { id: "2", author: "maya", body: "Thanks" }]
  assert.deepEqual(withPending(two, pending).map((r) => r.id), ["1", "2"])
})

test("a draft's key differs by member, inbox and conversation", () => {
  const keys = new Set([
    draftKey({ member: "maya", inbox: "support" }, "1"),
    draftKey({ member: "theo", inbox: "support" }, "1"),
    draftKey({ member: "maya", inbox: "billing" }, "1"),
    draftKey({ member: "maya", inbox: "support" }, "2"),
    draftKey({ member: "maya", inbox: "support" }, "compose"),
  ])
  assert.equal(keys.size, 5)
})
