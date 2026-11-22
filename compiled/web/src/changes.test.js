import assert from "node:assert/strict";
import { test } from "node:test";
import { readNotice } from "./changes.js";

test("no notice", () => {
  assert.deepEqual(readNotice(""), { notified: false, changes: null, notices: [] });
});

test("a notice alone means anything may have changed", () => {
  assert.deepEqual(readNotice("records_changed"), { notified: true, changes: null, notices: [] });
});

test("a notice lists the records that changed", () => {
  assert.deepEqual(readNotice("records_changed\nMailEntry:a-1\nIssue:urn:7"), {
    notified: true,
    changes: [{ type: "MailEntry", id: "a-1" }, { type: "Issue", id: "urn:7" }],
    notices: [],
  });
});

test("a notice extracts sync_notice JSON lines without treating them as record changes", () => {
  const notice = {
    id: "notice-1",
    kind: "rejected",
    record_type: "Issue",
    record_id: "iss-1",
    operation: "create",
    reason: "Title is not allowed by the server",
    attempted_changes: { title: "reject me" },
    server_attributes: {},
    server_version: 0,
  };
  const payload = `records_changed\nIssue:iss-1\nsync_notice:${JSON.stringify(notice)}`;
  assert.deepEqual(readNotice(payload), {
    notified: true,
    changes: [{ type: "Issue", id: "iss-1" }],
    notices: [notice],
  });
});

test("a notice with only sync_notice lines keeps changes null for unlisted refresh", () => {
  const notice = { id: "notice-2", kind: "conflict", record_type: "Note", record_id: "n-1", operation: "update" };
  const payload = `records_changed\nsync_notice:${JSON.stringify(notice)}`;
  assert.deepEqual(readNotice(payload), {
    notified: true,
    changes: null,
    notices: [notice],
  });
});
