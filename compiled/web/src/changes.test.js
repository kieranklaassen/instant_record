import assert from "node:assert/strict";
import { test } from "node:test";
import { readNotice } from "./changes.js";

test("no notice", () => {
  assert.deepEqual(readNotice(""), { notified: false, changes: null });
});

test("a notice alone means anything may have changed", () => {
  assert.deepEqual(readNotice("records_changed"), { notified: true, changes: null });
});

test("a notice lists the records that changed", () => {
  assert.deepEqual(readNotice("records_changed\nMailEntry:a-1\nIssue:urn:7"), {
    notified: true,
    changes: [{ type: "MailEntry", id: "a-1" }, { type: "Issue", id: "urn:7" }],
  });
});
