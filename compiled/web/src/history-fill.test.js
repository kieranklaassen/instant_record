import assert from "node:assert/strict";
import { test } from "node:test";
import { START, advance, fresh, held, query } from "./history-fill.js";

const row = (id, at, kind = "message") => ({ id, attributes: { kind, created_at: at } });

test("the first page asked for is the newest for any declared model", () => {
  const state = fresh({ type: "MailEntry", page_size: 200 });
  const params = new URLSearchParams(query(state));
  assert.equal(params.get("type"), "MailEntry");
  assert.equal(params.get("before_id"), "~");
  assert.equal(params.get("limit"), "200");
  assert.equal(held(state), false);
  assert.equal(held(undefined), false);
});

test("a page moves the edge to the server's next_before root cursor, whatever rides along", () => {
  const page = {
    has_more: true,
    next_before: { created_at: "2026-11-01T00:00:00.000000Z", id: "a" },
    records: [row("b", "2026-11-02T00:00:00.000000Z"), row("a", "2026-11-01T00:00:00.000000Z"), row("z", "2026-11-18T00:00:00.000000Z", "reply")],
  };
  const next = advance(fresh({ type: "MailEntry", page_size: 200 }), page, 1000, 5000);
  assert.deepEqual(next.before, { created_at: "2026-11-01T00:00:00.000000Z", id: "a" });
  assert.equal(next.rows, 3);
  assert.equal(next.done, false);
  assert.equal(next.full, false);
  assert.equal(held(next), false);
});

test("falls back to the last record when next_before is omitted", () => {
  const page = { has_more: true, records: [row("b", "2026-11-02T00:00:00.000000Z"), row("a", "2026-11-01T00:00:00.000000Z")] };
  const next = advance(fresh({ type: "Message", page_size: 50 }), page, 1000, 5000);
  assert.deepEqual(next.before, { created_at: "2026-11-01T00:00:00.000000Z", id: "a" });
});

test("the last page ends the fill and every read is local", () => {
  const next = advance(fresh({ type: "MailEntry" }), { has_more: false, records: [row("a", "2026-11-01T00:00:00.000000Z")] }, 9000, 5000);
  assert.equal(next.done, true);
  assert.equal(next.full, false);
  assert.equal(held(next), true);
});

test("past its budget the fill stops and says so", () => {
  const next = advance(fresh({ type: "MailEntry" }), { has_more: true, records: [row("a", "2026-11-01T00:00:00.000000Z")] }, 9000, 5000);
  assert.equal(next.full, true);
  assert.equal(next.done, false);
  assert.equal(held(next), false);
});

test("an empty page that says more keeps the edge where it was", () => {
  const state = advance(fresh({ type: "MailEntry" }), { has_more: true, records: [] }, 0, 5000);
  assert.equal(state.before, START);
});
