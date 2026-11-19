import assert from "node:assert/strict";
import { test } from "node:test";
import { START, advance, fresh, held, query } from "./history-fill.js";

const message = (id, at) => ({ id, attributes: { kind: "message", created_at: at } });
const reply = (id, at) => ({ id, attributes: { kind: "reply", created_at: at } });

test("the first page asked for is the newest", () => {
  assert.equal(new URLSearchParams(query(fresh(), 200)).get("before_id"), "~");
  assert.equal(held(fresh(), { created_at: "2026-11-19T00:00:00.000000Z", id: "a" }), false);
});

test("a page moves the edge to its oldest conversation, whatever rides along", () => {
  const page = { has_more: true, records: [message("b", "2026-11-02T00:00:00.000000Z"), message("a", "2026-11-01T00:00:00.000000Z"), reply("z", "2026-11-18T00:00:00.000000Z")] };
  const next = advance(fresh(), page, 1000, 5000);
  assert.deepEqual(next, { before: { created_at: "2026-11-01T00:00:00.000000Z", id: "a" }, rows: 3, done: false, full: false });
  assert.equal(held(next, { created_at: "2026-11-02T00:00:00.000000Z", id: "b" }), true);
  assert.equal(held(next, { created_at: "2026-11-01T00:00:00.000000Z", id: "a" }), false);
  assert.equal(held(next, { created_at: "2026-10-01T00:00:00.000000Z", id: "a" }), false);
});

test("the last page ends the fill and every read is local", () => {
  const next = advance(fresh(), { has_more: false, records: [message("a", "2026-11-01T00:00:00.000000Z")] }, 9000, 5000);
  assert.equal(next.done, true);
  assert.equal(next.full, false);
  assert.equal(held(next, { created_at: "2020-01-01T00:00:00.000000Z", id: "a" }), true);
  assert.equal(held(next, null), true);
});

test("past its budget the fill stops and says so", () => {
  const next = advance(fresh(), { has_more: true, records: [message("a", "2026-11-01T00:00:00.000000Z")] }, 9000, 5000);
  assert.equal(next.full, true);
  assert.equal(next.done, false);
});

test("an empty page that says more keeps the edge where it was", () => {
  const state = advance(fresh(), { has_more: true, records: [] }, 0, 5000);
  assert.equal(state.before, START);
});
