import assert from "node:assert/strict";
import { test } from "node:test";
import { parseRules, resolveSyncContext } from "./sync-context.js";

const RULES = [
  {
    path: "/email",
    partitionParam: "inbox",
    partitionDefault: "support",
    partitionKey: "mailbox_id",
    scopeParam: "member",
    scopeDefault: "maya",
    scopeHeader: "X-Instant-Record-Member",
    valid: "^[a-z]{1,32}$",
    lookupParams: ["before", "thread"],
    preloadBefore: { idParam: "before", atParam: "at", type: "MailEntry", limit: 50 },
    shellPath: "/email/shell",
  },
];

test("unmatched routes return null context", () => {
  assert.equal(resolveSyncContext("/todo", RULES), null);
  assert.equal(resolveSyncContext("/email", []), null);
});

test("matched partitioned route builds partition headers, storage key, and lookups", () => {
  const ctx = resolveSyncContext("/email?member=theo&inbox=billing&thread=t-1&before=m-9&at=2026-11-01T00:00:00Z", RULES);
  assert.equal(ctx.valid, true);
  assert.equal(ctx.storageKey, "theo/billing");
  assert.equal(ctx.partition, "mailbox_id:billing");
  assert.deepEqual(ctx.headers, {
    "X-Instant-Record-Partition": "mailbox_id:billing",
    "X-Instant-Record-Member": "theo",
  });
  assert.deepEqual(ctx.lookupIds, ["m-9", "t-1"]);
  assert.deepEqual(ctx.preloadBefore, {
    type: "MailEntry",
    before: { id: "m-9", created_at: "2026-11-01T00:00:00Z" },
    limit: 50,
  });
  assert.equal(ctx.shellPath, "/email/shell");
});

test("defaults apply when query params are omitted", () => {
  const ctx = resolveSyncContext("/email", RULES);
  assert.equal(ctx.valid, true);
  assert.equal(ctx.storageKey, "maya/support");
  assert.equal(ctx.headers["X-Instant-Record-Partition"], "mailbox_id:support");
  assert.equal(ctx.headers["X-Instant-Record-Member"], "maya");
});

test("invalid param values produce an invalid context with no headers", () => {
  const ctx = resolveSyncContext("/email?member=../bad&inbox=support", RULES);
  assert.equal(ctx.valid, false);
  assert.equal(ctx.storageKey, "invalid");
  assert.deepEqual(ctx.headers, {});
});

test("parseRules handles JSON strings and malformed input safely", () => {
  assert.equal(parseRules(JSON.stringify(RULES)).length, 1);
  assert.deepEqual(parseRules("not-json"), []);
  assert.deepEqual(parseRules(""), []);
});
