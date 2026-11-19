import assert from "node:assert/strict"
import { test } from "node:test"
import { rangeBetween } from "./range.js"

const ids = ["a", "b", "c", "d", "e"]

test("a range grows from its anchor and shrinks back toward it", () => {
  assert.deepEqual(rangeBetween(ids, "b", "d"), ["b", "c", "d"])
  assert.deepEqual(rangeBetween(ids, "b", "c"), ["b", "c"])
})

test("a range upward holds the same rows as the same range downward", () => {
  assert.deepEqual(rangeBetween(ids, "d", "b"), rangeBetween(ids, "b", "d"))
})

test("an anchor that left the list leaves only the cursor's row", () => {
  assert.deepEqual(rangeBetween(ids, "gone", "c"), ["c"])
})

test("an empty list has no range", () => {
  assert.deepEqual(rangeBetween([], "a", "b"), [])
})
