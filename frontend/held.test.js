import assert from "node:assert/strict"
import { mock, test } from "node:test"
import { durableHeldActions, heldActions } from "./held.js"

const settled = () => new Promise((resolve) => setImmediate(resolve))

test("an action that is not undone commits once when its time passes", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const commit = mock.fn()
  const actions = heldActions({ ms: 5000 })
  actions.hold({ label: "one", ids: ["a"], commit })

  t.mock.timers.tick(4999)
  assert.equal(commit.mock.callCount(), 0)
  t.mock.timers.tick(1)
  assert.equal(commit.mock.callCount(), 1)
  assert.equal(actions.snapshot().pending.length, 0)
  t.mock.timers.tick(10000)
  assert.equal(commit.mock.callCount(), 1)
})

test("undo takes back the newest action and leaves an older one to its own time", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const first = mock.fn()
  const second = mock.fn()
  const actions = heldActions({ ms: 5000 })
  actions.hold({ label: "first", ids: ["a"], commit: first })
  t.mock.timers.tick(2000)
  actions.hold({ label: "second", ids: ["b"], commit: second, context: { focus: "b" } })

  const undone = actions.undo()
  assert.equal(undone.label, "second")
  assert.deepEqual(undone.context, { focus: "b" })
  t.mock.timers.tick(3000)
  assert.equal(first.mock.callCount(), 1)
  t.mock.timers.tick(5000)
  assert.equal(second.mock.callCount(), 0)
})

test("ids are held while pending and until their write is answered", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  let answer
  const actions = heldActions({ ms: 5000 })
  actions.hold({ label: "one", ids: ["a", "b"], commit: () => new Promise((resolve) => { answer = resolve }) })
  actions.hold({ label: "two", ids: ["c"], commit: () => {} })
  assert.deepEqual([...actions.snapshot().held].sort(), ["a", "b", "c"])

  actions.undo()
  assert.deepEqual([...actions.snapshot().held].sort(), ["a", "b"])

  t.mock.timers.tick(5000)
  assert.equal(actions.snapshot().pending.length, 0)
  assert.deepEqual([...actions.snapshot().held].sort(), ["a", "b"])

  answer()
  await settled()
  assert.equal(actions.snapshot().held.size, 0)
})

test("a write that fails releases its ids", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const changes = []
  const actions = heldActions({ ms: 5000, onChange: (state) => changes.push(state.held.size) })
  actions.hold({ label: "one", ids: ["a", "b"], commit: () => Promise.reject(new Error("refused")) })
  t.mock.timers.tick(5000)
  await settled()
  assert.equal(actions.snapshot().held.size, 0)
  assert.equal(changes.at(-1), 0)
})

test("flush commits everything held at once, oldest first", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const order = []
  const actions = heldActions({ ms: 5000 })
  actions.hold({ label: "first", ids: ["a"], commit: (options) => order.push(["first", options]) })
  actions.hold({ label: "second", ids: ["b"], commit: (options) => order.push(["second", options]) })

  actions.flush({ keepalive: true })
  assert.deepEqual(order, [["first", { keepalive: true }], ["second", { keepalive: true }]])
  t.mock.timers.tick(10000)
  assert.equal(order.length, 2)
})

test("undo with nothing held answers null", () => {
  assert.equal(heldActions().undo(), null)
})

test("durableHeldActions hydrates unexpired SQLite holds across reloads and drops them at release_at", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 1_700_000_000_000 })
  const changes = []
  const actions = durableHeldActions({ onChange: (state) => changes.push(state.pending.map((e) => e.id)) })

  actions.sync([
    { id: "expired", label: "already sent", release_at: new Date(1_700_000_000_000 - 1000).toISOString() },
    { id: "m1", label: "first archived", release_at: new Date(1_700_000_000_000 + 2000).toISOString() },
    { id: "m2", label: "second archived", release_at: new Date(1_700_000_000_000 + 5000).toISOString() },
  ])

  assert.deepEqual(actions.snapshot().pending.map((e) => e.id), ["m1", "m2"])
  assert.equal(actions.snapshot().held.size, 0)

  t.mock.timers.tick(1999)
  assert.deepEqual(actions.snapshot().pending.map((e) => e.id), ["m1", "m2"])

  t.mock.timers.tick(1)
  assert.deepEqual(actions.snapshot().pending.map((e) => e.id), ["m2"])

  t.mock.timers.tick(3000)
  assert.deepEqual(actions.snapshot().pending, [])
  assert.deepEqual(changes, [["m1", "m2"], ["m2"], []])
  actions.dispose()
})

test("durableHeldActions undo cancels newest entry via onCancel and flush is a no-op", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 1_700_000_000_000 })
  const cancelled = []
  const actions = durableHeldActions({ onCancel: (entry) => cancelled.push(entry.id) })

  actions.sync([
    { id: "m1", label: "first", release_at: new Date(1_700_000_000_000 + 3000).toISOString() },
    { id: "m2", label: "second", release_at: new Date(1_700_000_000_000 + 5000).toISOString() },
  ])

  actions.flush({ keepalive: true })
  assert.equal(actions.snapshot().pending.length, 2, "durable holds are already persisted in SQLite")

  const undone = actions.undo()
  assert.equal(undone.id, "m2")
  assert.deepEqual(cancelled, ["m2"])
  assert.deepEqual(actions.snapshot().pending.map((e) => e.id), ["m1"])

  t.mock.timers.tick(3000)
  assert.equal(actions.undo(), null)
  actions.dispose()
})

test("durableHeldActions.sync ignores unchanged entries and accepts Date releaseAt values", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 1_700_000_000_000 })
  const onChange = mock.fn()
  const actions = durableHeldActions({ onChange })
  const release = new Date(1_700_000_000_000 + 2500)

  actions.sync([{ id: "m1", label: "archived", releaseAt: release }])
  actions.sync([{ id: "m1", label: "archived", releaseAt: new Date(release.getTime()) }])
  assert.equal(onChange.mock.callCount(), 1, "unchanged durable entries must not trigger React re-render loops")

  t.mock.timers.tick(2500)
  assert.equal(onChange.mock.callCount(), 2)
  assert.deepEqual(actions.snapshot().pending, [])
  assert.equal(actions.undo(), null)
  assert.equal(onChange.mock.callCount(), 2, "undo on empty state must not fire onChange")
  actions.dispose()
})
