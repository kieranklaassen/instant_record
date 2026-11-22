import assert from "node:assert/strict";
import { test } from "node:test";
import { affectsReads, decodeBroadcast, encodeBroadcast, mergeReads, parseReads, readNotice } from "./changes.js";

test("no notice", () => {
  assert.deepEqual(readNotice(""), { notified: false, changes: null });
});

test("a notice alone means anything may have changed", () => {
  assert.deepEqual(readNotice("records_changed"), { notified: true, changes: null });
});

test("a notice parses structured JSON row deltas", () => {
  const line1 = JSON.stringify({
    type: "MailEntry",
    id: "a-1",
    op: "create",
    changed_columns: ["id", "subject", "mailbox_id"],
    attrs: { id: "a-1", subject: "Hello", mailbox_id: "support" },
  });
  const line2 = JSON.stringify({
    type: "Issue",
    id: "urn:7",
    op: "destroy",
    changed_columns: [],
    attrs: { id: "urn:7" },
  });

  assert.deepEqual(readNotice(`records_changed\n${line1}\n${line2}`), {
    notified: true,
    changes: [
      {
        type: "MailEntry",
        id: "a-1",
        op: "create",
        changed_columns: ["id", "subject", "mailbox_id"],
        attrs: { id: "a-1", subject: "Hello", mailbox_id: "support" },
      },
      {
        type: "Issue",
        id: "urn:7",
        op: "destroy",
        changed_columns: [],
        attrs: { id: "urn:7" },
      },
    ],
  });
});

test("a notice remains backwards compatible with flat Type:id lines", () => {
  assert.deepEqual(readNotice("records_changed\nMailEntry:a-1\nIssue:urn:7"), {
    notified: true,
    changes: [
      { type: "MailEntry", id: "a-1", op: null, changed_columns: [], attrs: {} },
      { type: "Issue", id: "urn:7", op: null, changed_columns: [], attrs: {} },
    ],
  });
});

test("malformed JSON line degrades safely to wildcard notice", () => {
  assert.deepEqual(readNotice("records_changed\n{not-json"), { notified: true, changes: null });
});

test("broadcast messages carry revision and typed changes, with integer fallback", () => {
  const deltas = [{ type: "Issue", id: "i-1", op: "update", changed_columns: ["title"], attrs: { id: "i-1", title: "Fix" } }];
  const encoded = encodeBroadcast(42, deltas);
  assert.deepEqual(encoded, { revision: 42, changes: deltas });
  assert.deepEqual(decodeBroadcast(encoded), { revision: 42, changes: deltas });
  assert.deepEqual(decodeBroadcast(42), { revision: 42, changes: null });
});

test("parseReads, mergeReads, and affectsReads soundly filter tables and partitions", () => {
  const r1 = parseReads(JSON.stringify({
    tables: ["mail_entries"],
    models: ["MailEntry"],
    partitions: { MailEntry: { mailbox_id: ["support"], parent_id: ["p-1"] } },
  }));
  const r2 = parseReads(JSON.stringify({
    tables: ["mail_entries", "channels"],
    models: ["MailEntry", "Channel"],
    partitions: { MailEntry: { mailbox_id: ["support"] } },
  }));

  const merged = mergeReads(r1, r2);
  assert.deepEqual(merged, {
    tables: ["channels", "mail_entries"],
    models: ["Channel", "MailEntry"],
    partitions: { MailEntry: { mailbox_id: ["support"] } },
  });

  // Unaffected table -> false
  assert.equal(
    affectsReads([{ type: "Issue", id: "1", op: "create", changed_columns: ["title"], attrs: { title: "x" } }], merged),
    false,
  );
  // Different partition on create -> false (even though changed_columns lists all created cols)
  assert.equal(
    affectsReads([{ type: "MailEntry", id: "3", op: "create", changed_columns: ["id", "mailbox_id", "subject"], attrs: { id: "3", mailbox_id: "billing", subject: "y" } }], merged),
    false,
  );
  // Different partition -> false
  assert.equal(
    affectsReads([{ type: "MailEntry", id: "2", op: "update", changed_columns: ["subject"], attrs: { mailbox_id: "billing", subject: "y" } }], merged),
    false,
  );
  // Same partition -> true
  assert.equal(
    affectsReads([{ type: "MailEntry", id: "2", op: "update", changed_columns: ["subject"], attrs: { mailbox_id: "support", subject: "y" } }], merged),
    true,
  );
  // Partition column moved -> true
  assert.equal(
    affectsReads([{ type: "MailEntry", id: "2", op: "update", changed_columns: ["mailbox_id"], attrs: { mailbox_id: "billing" } }], merged),
    true,
  );
  // Wildcard changes or unknown reads -> true
  assert.equal(affectsReads(null, merged), true);
  assert.equal(affectsReads([{ type: "Issue", id: "1", op: "create", changed_columns: [], attrs: {} }], null), true);
  // Empty read set -> false for typed changes
  assert.equal(
    affectsReads([{ type: "Issue", id: "1", op: "create", changed_columns: [], attrs: {} }], { tables: [], models: [], partitions: {} }),
    false,
  );
});
