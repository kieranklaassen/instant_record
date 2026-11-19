import assert from "node:assert/strict"
import { mock, test } from "node:test"
import { heldActions } from "./held.js"

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
