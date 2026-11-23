import assert from "node:assert/strict";
import { test } from "node:test";
import {
  SQLITE_MAGIC,
  isValidSqliteBytes,
  parseShellGrant,
  scopedUrl,
  shouldFetchShell,
  validateShellState,
} from "./shell.js";

test("shouldFetchShell works for any app path when enabled or opted in with ?shell=1", () => {
  const fp = "a".repeat(64);
  assert.equal(shouldFetchShell({ path: "/todo", fingerprint: fp, always: true, offline: false }), true);
  assert.equal(shouldFetchShell({ path: "/todo?shell=1", fingerprint: fp, always: false, offline: false }), true);
  assert.equal(shouldFetchShell({ path: "/todo", fingerprint: fp, always: false, offline: false }), false);
  assert.equal(shouldFetchShell({ path: "/todo?shell=1", fingerprint: fp, always: true, offline: true }), false);
  assert.equal(shouldFetchShell({ path: "/todo?shell=1", fingerprint: "", always: true, offline: false }), false);
  assert.equal(shouldFetchShell({ path: "/email?shell=1", fingerprint: fp, always: true, offline: false, blocked: true }), false);
});

test("scopedUrl appends scope cleanly to bare and parameterized URLs", () => {
  assert.equal(scopedUrl("/instant_record/shell/file?token=abc", "tok/1"), "/instant_record/shell/file?token=abc&scope=tok%2F1");
  assert.equal(scopedUrl("/instant_record/bootstrap", "tok1"), "/instant_record/bootstrap?scope=tok1");
  assert.equal(scopedUrl("/instant_record/bootstrap", ""), "/instant_record/bootstrap");
});

test("parseShellGrant validates path prefix, integer cursor, and optional identity", () => {
  assert.deepEqual(
    parseShellGrant(JSON.stringify({ path: "/shell/file?token=xyz", cursor: 42, identity: "abc123" })),
    { path: "/shell/file?token=xyz", cursor: 42, identity: "abc123" },
  );
  assert.deepEqual(
    parseShellGrant(JSON.stringify({ path: "/shell/file?token=xyz", cursor: 0 })),
    { path: "/shell/file?token=xyz", cursor: 0, identity: "" },
  );
  assert.equal(parseShellGrant(JSON.stringify({ path: "https://evil.test/db", cursor: 1 })), null);
  assert.equal(parseShellGrant(JSON.stringify({ path: "/shell/file?token=x", cursor: -1 })), null);
  assert.equal(parseShellGrant(JSON.stringify({ path: "/shell/file?token=x", cursor: "1" })), null);
  assert.equal(parseShellGrant("not json"), null);
});

test("isValidSqliteBytes requires the full 16-byte SQLite format 3 header", () => {
  const valid = new TextEncoder().encode(SQLITE_MAGIC + "rest");
  assert.equal(isValidSqliteBytes(valid), true);
  assert.equal(isValidSqliteBytes(new TextEncoder().encode("SQLite format 3")), false);
  assert.equal(isValidSqliteBytes(new TextEncoder().encode("SQLite format 3X")), false);
  assert.equal(isValidSqliteBytes(new Uint8Array(0)), false);
});

test("validateShellState checks bootstrapped, cursor, and identity when present", () => {
  assert.equal(validateShellState({ bootstrapped: true, cursor: 7, identity: "id1" }, { cursor: 7, identity: "id1" }), true);
  assert.equal(validateShellState({ bootstrapped: true, cursor: 7, identity: "" }, { cursor: 7, identity: "" }), true);
  assert.equal(validateShellState({ bootstrapped: false, cursor: 7, identity: "id1" }, { cursor: 7, identity: "id1" }), false);
  assert.equal(validateShellState({ bootstrapped: true, cursor: 6, identity: "id1" }, { cursor: 7, identity: "id1" }), false);
  assert.equal(validateShellState({ bootstrapped: true, cursor: 7, identity: "other" }, { cursor: 7, identity: "id1" }), false);
});
