import assert from "node:assert/strict"
import { test } from "node:test"
import { resolveFocus } from "./focus.js"

test("focus follows its row when the list is redrawn around it", () => {
  assert.deepEqual(resolveFocus(["new", "a", "b"], "b", 1), { id: "b", index: 2 })
})

test("a row that left the list hands focus to the row that took its place", () => {
  assert.deepEqual(resolveFocus(["a", "c"], "b", 1), { id: "c", index: 1 })
})

test("the last row leaving moves focus up, never to the top", () => {
  assert.deepEqual(resolveFocus(["a", "b"], "c", 2), { id: "b", index: 1 })
})

test("an empty list holds no focus", () => {
  assert.deepEqual(resolveFocus([], "a", 3), { id: null, index: 0 })
})
