import assert from "node:assert/strict";
import { test } from "node:test";
import { BranchManager } from "./branch-manager.js";
import { formatBreakdown, formatMutationSummary, formatOutcomeNotice } from "./branch-preview.js";

// In-memory fake AppHost simulating a live SQLite database snapshot (`bytes`),
// its records table, and its durable `outbox` table.
class FakeAppHost {
  constructor({ bytes, records = {}, outbox = [], env = {} } = {}) {
    this.bytes = bytes ? new Uint8Array(bytes) : new Uint8Array([1, 2, 3, 4]);
    this.records = new Map(Object.entries(records).map(([id, row]) => [id, { ...row }]));
    this.outbox = outbox.map((m) => ({ ...m, changes: { ...(m.changes || {}) } }));
    this.env = env;
    this.booted = false;
  }

  ensureBooted() {
    this.booted = true;
  }

  databaseBytes() {
    return this.bytes;
  }

  cloneDatabaseBytes() {
    return new Uint8Array(this.bytes);
  }

  // Simulate a local write (e.g. POST/PATCH/DELETE in the compiled Rails app).
  write(operation, recordType, recordId, changes = {}) {
    const mutation = {
      id: `mut-${this.outbox.length + 1}-${recordId}`,
      record_type: recordType,
      record_id: recordId,
      operation,
      changes: { ...changes },
      base_version: this.records.get(recordId)?.server_version || 0,
    };
    if (operation === "create") {
      this.records.set(recordId, { id: recordId, ...changes, sync_state: "pending", server_version: 0 });
    } else if (operation === "update") {
      const existing = this.records.get(recordId);
      if (existing) this.records.set(recordId, { ...existing, ...changes, sync_state: "pending" });
    } else if (operation === "destroy") {
      this.records.delete(recordId);
    }
    this.outbox.push(mutation);
    // Mutate bytes to prove copy-on-write isolation from main's byte array.
    this.bytes[0] = (this.bytes[0] + 1) & 0xff;
    return mutation;
  }

  branchOutbox(excludeIds = []) {
    const excluded = new Set(excludeIds.map(String));
    const mutations = this.outbox.filter((m) => !excluded.has(String(m.id)));
    const by_operation = {};
    const by_type = {};
    for (const m of mutations) {
      by_operation[m.operation] = (by_operation[m.operation] || 0) + 1;
      by_type[m.record_type] = (by_type[m.record_type] || 0) + 1;
    }
    return { count: mutations.length, by_operation, by_type, mutations };
  }

  branchReplay(mutations, { conflict = "lww" } = {}) {
    let applied = 0;
    let skipped = 0;
    const conflicts = [];
    const changes = [];
    for (const m of mutations) {
      if (m.operation === "create") {
        if (this.records.has(m.record_id)) {
          skipped++;
          conflicts.push({ mutation_id: m.id, record_id: m.record_id, reason: "id already exists" });
          continue;
        }
        this.records.set(m.record_id, { id: m.record_id, ...m.changes, sync_state: "pending", server_version: 0 });
        this.outbox.push(m);
        changes.push({ type: m.record_type, id: m.record_id });
        applied++;
      } else if (m.operation === "update") {
        const existing = this.records.get(m.record_id);
        if (!existing) {
          skipped++;
          conflicts.push({ mutation_id: m.id, record_id: m.record_id, reason: "record not found" });
          continue;
        }
        if (conflict === "lww" && m.changes.updated_at && existing.updated_at && m.changes.updated_at < existing.updated_at) {
          skipped++;
          conflicts.push({ mutation_id: m.id, record_id: m.record_id, reason: "stale" });
          continue;
        }
        this.records.set(m.record_id, { ...existing, ...m.changes, sync_state: "pending" });
        this.outbox.push({ ...m, base_version: existing.server_version || 0 });
        changes.push({ type: m.record_type, id: m.record_id });
        applied++;
      } else if (m.operation === "destroy") {
        if (!this.records.has(m.record_id)) {
          skipped++;
          conflicts.push({ mutation_id: m.id, record_id: m.record_id, reason: "already destroyed" });
          continue;
        }
        this.records.delete(m.record_id);
        this.outbox.push(m);
        changes.push({ type: m.record_type, id: m.record_id });
        applied++;
      }
    }
    return { applied, skipped, conflicts, changes };
  }
}

function makeForkFactory(sourceHost) {
  return (bytes, _version, branchName) => new FakeAppHost({
    bytes,
    records: Object.fromEntries(sourceHost.records),
    outbox: sourceHost.outbox,
    env: { INSTANT_RECORD_BRANCH: branchName },
  });
}

test("fork creates an isolated copy-on-write snapshot and excludes pre-fork outbox mutations", () => {
  const manager = new BranchManager();
  const main = new FakeAppHost({
    bytes: new Uint8Array([10, 20, 30]),
    records: { "i-1": { id: "i-1", title: "Original", server_version: 1 } },
    outbox: [{ id: "pre-1", record_type: "Issue", record_id: "i-0", operation: "create", changes: { title: "Main offline" } }],
  });

  const status = manager.fork({ name: "bulk-edit", mainHost: main, createHost: makeForkFactory(main), schemaVersion: 1 });
  assert.equal(status.active, true);
  assert.equal(status.name, "bulk-edit");
  assert.equal(status.stagedCount, 0);
  assert.equal(manager.host().env.INSTANT_RECORD_BRANCH, "bulk-edit");

  // Mutate branch: main bytes and records stay untouched.
  manager.host().write("update", "Issue", "i-1", { title: "Staged title" });
  manager.host().write("create", "Issue", "i-2", { title: "Staged new" });

  assert.equal(main.databaseBytes()[0], 10, "copy-on-write branch bytes must never mutate main's bytes");
  assert.equal(main.records.get("i-1").title, "Original");
  assert.equal(main.records.has("i-2"), false);

  const inspected = manager.inspect();
  assert.equal(inspected.stagedCount, 2);
  assert.deepEqual(inspected.byOperation, { update: 1, create: 1 });
  assert.deepEqual(inspected.byType, { Issue: 2 });
  assert.equal(inspected.mutations.some((m) => m.id === "pre-1"), false, "pre-fork main outbox must be excluded");
});

test("approve replays ONLY branch mutations onto current main even after concurrent main deltas arrive", async () => {
  const manager = new BranchManager();
  const main = new FakeAppHost({
    records: {
      "i-1": { id: "i-1", title: "Original 1", state: "open", server_version: 1, updated_at: "2026-11-21T10:00:00.000000Z" },
      "i-2": { id: "i-2", title: "Original 2", state: "open", server_version: 1, updated_at: "2026-11-21T10:00:00.000000Z" },
    },
  });

  manager.fork({ name: "agent-batch", mainHost: main, createHost: makeForkFactory(main) });

  // Branch edits i-1 (at 10:01) and creates i-branch, plus edits i-2 (at 10:01).
  manager.host().write("update", "Issue", "i-1", { state: "done", updated_at: "2026-11-21T10:01:00.000000Z" });
  manager.host().write("update", "Issue", "i-2", { title: "Branch stale edit", updated_at: "2026-11-21T10:01:00.000000Z" });
  manager.host().write("create", "Issue", "i-branch", { title: "Drafted by agent", updated_at: "2026-11-21T10:01:00.000000Z" });

  // Concurrent remote deltas arrive on `main` during branch review!
  main.records.set("i-remote", { id: "i-remote", title: "Remote arrived during review", server_version: 1 });
  main.records.set("i-2", {
    id: "i-2", title: "Newer remote winner", state: "open", server_version: 2, updated_at: "2026-11-21T10:05:00.000000Z",
  });
  const updatedState = manager.noteMainDelta(2);
  assert.equal(updatedState.mainDeltasDuringReview, 2);

  const result = await manager.approve({
    conflict: "lww",
    onMain: (mutations, conflict) => main.branchReplay(mutations, { conflict }),
  });

  assert.equal(manager.isActive(), false);
  assert.equal(result.approved, true);
  assert.equal(result.applied, 2);
  assert.equal(result.skipped, 1);
  assert.equal(result.mainDeltasDuringReview, 2);
  assert.equal(result.conflicts[0].reason, "stale");
  assert.equal(result.conflicts[0].record_id, "i-2");

  // Concurrent main records preserved + non-conflicting branch mutations applied!
  assert.equal(main.records.get("i-remote").title, "Remote arrived during review");
  assert.equal(main.records.get("i-2").title, "Newer remote winner");
  assert.equal(main.records.get("i-1").state, "done");
  assert.equal(main.records.get("i-branch").title, "Drafted by agent");
});

test("discard drops staged edits with zero main mutations and zero side effects", () => {
  const manager = new BranchManager();
  const main = new FakeAppHost({
    records: { "i-1": { id: "i-1", title: "Untouched" } },
  });

  manager.fork({ name: "throwaway", mainHost: main, createHost: makeForkFactory(main) });
  manager.host().write("create", "Issue", "i-draft", { title: "Drop me" });
  manager.host().write("destroy", "Issue", "i-1");

  const report = manager.discard();
  assert.equal(manager.isActive(), false);
  assert.equal(report.discarded, true);
  assert.equal(report.dropped, 2);
  assert.equal(main.records.get("i-1").title, "Untouched");
  assert.equal(main.records.has("i-draft"), false);
  assert.equal(main.outbox.length, 0);
});

test("failed approve keeps staging branch active so edits are not lost", async () => {
  const manager = new BranchManager();
  const main = new FakeAppHost();
  manager.fork({ name: "safe", mainHost: main, createHost: makeForkFactory(main) });
  manager.host().write("create", "Issue", "i-1", { title: "Keep safe" });

  await assert.rejects(
    () => manager.approve({ onMain: () => { throw new Error("IndexedDB write failed"); } }),
    /IndexedDB write failed/,
  );

  assert.equal(manager.isActive(), true);
  assert.equal(manager.inspect().stagedCount, 1);
});

test("branch lifecycle guards reject invalid transitions", async () => {
  const manager = new BranchManager();
  const main = new FakeAppHost();

  assert.deepEqual(manager.inspect(), { active: false });
  assert.throws(() => manager.discard(), /No active staging branch/);
  await assert.rejects(() => manager.approve({ onMain: () => {} }), /No active staging branch/);
  assert.throws(() => manager.fork({ mainHost: null, createHost: () => {} }), /before the app has booted/);

  manager.fork({ name: "one", mainHost: main, createHost: makeForkFactory(main) });
  assert.throws(
    () => manager.fork({ name: "two", mainHost: main, createHost: makeForkFactory(main) }),
    /Already on staging branch 'one'/,
  );
});

test("branch-preview formatters render concise human-readable summaries", () => {
  assert.equal(formatBreakdown({ create: 2, update: 1, destroy: 3 }), "2 created · 1 updated · 3 deleted");
  assert.equal(
    formatMutationSummary({
      operation: "update",
      record_type: "Issue",
      record_id: "12345678-abcd-ef00",
      changes: { title: "Renamed", state: "done", updated_at: "2026-11-21T00:00:00Z" },
    }),
    "UPDATE Issue#12345678 (title, state)",
  );
  assert.equal(
    formatOutcomeNotice({ approved: true, name: "triage", applied: 3, skipped: 1, mainDeltasDuringReview: 2 }),
    "Approved 'triage': 3 mutations replayed onto main · 1 skipped (LWW conflict) · preserved 2 main updates",
  );
  assert.equal(
    formatOutcomeNotice({ discarded: true, name: "draft", dropped: 4 }),
    "Discarded 'draft': 4 staged changes dropped · 0 server impact",
  );
});
