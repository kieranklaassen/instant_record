import assert from "node:assert/strict";
import { test } from "node:test";
import { detectSchemaDrift, openOrRehydrate, reloadOrRehydrateSnapshot } from "./schema-recovery.js";

function makeFakeHostFactory({
  outboxRows = [],
  failBootWhenRestored = false,
  failExtract = false,
  booted = [],
} = {}) {
  let nextId = 1;
  return () => {
    const host = {
      id: nextId++,
      restoredBytes: null,
      restoredVersion: null,
      extractedFrom: null,
      importedRows: [],
      booted: false,
      cookies: new Map(),
      restoreDatabase(bytes, version) {
        this.restoredBytes = bytes;
        this.restoredVersion = version;
      },
      ensureBooted() {
        if (this.restoredBytes && failBootWhenRestored) {
          throw new Error("SQLiteException: duplicate column name: priority");
        }
        this.booted = true;
        booted.push(this);
      },
      extractOutbox(bytes) {
        if (failExtract) throw new Error("SQLiteException: file is not a database");
        this.extractedFrom = bytes;
        return outboxRows.map(row => ({ ...row }));
      },
      importOutbox(rows) {
        this.importedRows.push(...rows);
        return { imported: rows.length };
      },
      databaseBytes() {
        return new Uint8Array([1, 2, 3, this.id]);
      },
    };
    return host;
  };
}

const SAMPLE_BYTES = new Uint8Array([83, 81, 76, 105, 116, 101]);
const SAMPLE_OUTBOX = [
  {
    id: "mut-1",
    record_type: "Note",
    record_id: "note-1",
    operation: "create",
    changes_payload: '{"id":"note-1","title":"offline draft"}',
    base_version: 0,
    created_at: "2026-11-20T00:00:00.000000Z",
    updated_at: "2026-11-20T00:00:00.000000Z",
  },
  {
    id: "mut-2",
    record_type: "Note",
    record_id: "note-1",
    operation: "update",
    changes_payload: '{"title":"edited offline"}',
    base_version: 0,
    created_at: "2026-11-20T00:00:01.000000Z",
    updated_at: "2026-11-20T00:00:01.000000Z",
  },
];

test("detectSchemaDrift returns null for valid fresh boot and valid forward migration", () => {
  assert.equal(
    detectSchemaDrift({
      bytes: null,
      version: null,
      targetSchema: 2,
      legacySchema: "",
      history: null,
      migrationHistory: { 1: "h1", 2: "h2" },
      previousDigest: null,
      schemaDigest: "d2",
    }),
    null,
  );

  assert.equal(
    detectSchemaDrift({
      bytes: SAMPLE_BYTES,
      version: 1,
      targetSchema: 2,
      legacySchema: "",
      history: { 1: "h1" },
      migrationHistory: { 1: "h1", 2: "h2" },
      previousDigest: "d1",
      schemaDigest: "d2",
    }),
    null,
  );
});

test("openOrRehydrate auto-rehydrates on every drift condition and preserves all outbox rows", () => {
  const driftCases = [
    {
      name: "unversioned snapshot with no baseline",
      args: { version: null, targetSchema: 2, legacySchema: "", history: null, migrationHistory: { 2: "h2" }, previousDigest: null, schemaDigest: "d2" },
      expectedReason: "unversioned_snapshot",
    },
    {
      name: "saved schema ahead of release (rollback)",
      args: { version: 3, targetSchema: 2, legacySchema: "", history: { 1: "h1", 2: "h2", 3: "h3" }, migrationHistory: { 1: "h1", 2: "h2" }, previousDigest: "d3", schemaDigest: "d2" },
      expectedReason: "schema_version_ahead:3",
    },
    {
      name: "saved schema below baseline",
      args: { version: 1, targetSchema: 3, legacySchema: "2", history: { 1: "h1" }, migrationHistory: { 3: "h3" }, previousDigest: "d1", schemaDigest: "d3" },
      expectedReason: "schema_version_below_baseline:1",
    },
    {
      name: "published migration history mutated",
      args: { version: 2, targetSchema: 2, legacySchema: "", history: { 1: "old-h1", 2: "h2" }, migrationHistory: { 1: "new-h1", 2: "h2" }, previousDigest: "d2", schemaDigest: "d2" },
      expectedReason: "published_migration_changed:1",
    },
    {
      name: "compiled schema digest drifted without version bump",
      args: { version: 2, targetSchema: 2, legacySchema: "", history: { 1: "h1", 2: "h2" }, migrationHistory: { 1: "h1", 2: "h2" }, previousDigest: "old-digest", schemaDigest: "new-digest" },
      expectedReason: "schema_digest_mismatch",
    },
    {
      name: "missing browser migration for target schema",
      args: { version: 1, targetSchema: 2, legacySchema: "", history: { 1: "h1" }, migrationHistory: { 1: "h1" }, previousDigest: "d1", schemaDigest: "d2" },
      expectedReason: "missing_browser_migration:2",
    },
  ];

  for (const tc of driftCases) {
    const reports = [];
    const outcome = openOrRehydrate({
      bytes: SAMPLE_BYTES,
      ...tc.args,
      shell: null,
      createHost: makeFakeHostFactory({ outboxRows: SAMPLE_OUTBOX }),
      onReport: entry => reports.push(entry),
    });

    assert.equal(outcome.restored, false, `${tc.name}: must trigger re-bootstrap`);
    assert.equal(outcome.rehydrated.reason, tc.expectedReason, tc.name);
    assert.equal(outcome.rehydrated.preservedOutbox, 2, tc.name);
    assert.equal(outcome.host.booted, true, tc.name);
    assert.equal(outcome.host.restoredBytes, null, `${tc.name}: must rebuild on clean DB`);
    assert.deepEqual(outcome.host.importedRows, SAMPLE_OUTBOX, `${tc.name}: must preserve outbox order and IDs`);
    assert.equal(reports.length, 1);
    assert.equal(reports[0].method, "REHYDRATE");
  }
});

test("openOrRehydrate falls back to outbox-preserving rehydration when a transactional migration fails at boot", () => {
  const outcome = openOrRehydrate({
    bytes: SAMPLE_BYTES,
    version: 1,
    targetSchema: 2,
    legacySchema: "",
    history: { 1: "h1" },
    migrationHistory: { 1: "h1", 2: "h2" },
    previousDigest: "d1",
    schemaDigest: "d2",
    shell: null,
    createHost: makeFakeHostFactory({ outboxRows: SAMPLE_OUTBOX, failBootWhenRestored: true }),
  });

  assert.equal(outcome.restored, false);
  assert.equal(outcome.rehydrated.reason, "migration_failed");
  assert.equal(outcome.rehydrated.preservedOutbox, 2);
  assert.deepEqual(outcome.host.importedRows, SAMPLE_OUTBOX);
});

test("openOrRehydrate recovers cleanly when corrupt bytes cannot be opened for extraction", () => {
  const outcome = openOrRehydrate({
    bytes: new Uint8Array([0, 0, 0]),
    version: 3,
    targetSchema: 2,
    legacySchema: "",
    history: null,
    migrationHistory: {},
    previousDigest: null,
    schemaDigest: "d2",
    shell: null,
    createHost: makeFakeHostFactory({ outboxRows: SAMPLE_OUTBOX, failExtract: true }),
  });

  assert.equal(outcome.restored, false);
  assert.equal(outcome.rehydrated.extractFailed, true);
  assert.equal(outcome.rehydrated.preservedOutbox, 0);
  assert.equal(outcome.host.booted, true);
});

test("reloadOrRehydrateSnapshot notifies release_required without throwing or clobbering IDB when peer tab is ahead", () => {
  let notified = 0;
  const outcome = reloadOrRehydrateSnapshot({
    bytes: SAMPLE_BYTES,
    savedSchema: 5,
    targetSchema: 4,
    createHost: makeFakeHostFactory({ outboxRows: SAMPLE_OUTBOX }),
    onReleaseRequired: () => { notified++; },
  });

  assert.equal(notified, 1);
  assert.equal(outcome.persist, false, "old tab must not overwrite newer tab's IndexedDB schema");
  assert.equal(outcome.needsBootstrap, true);
  assert.equal(outcome.rehydrated.reason, "peer_schema_ahead:5");
  assert.deepEqual(outcome.host.importedRows, SAMPLE_OUTBOX);
});

test("reloadOrRehydrateSnapshot persists clean rehydration when snapshot schema is stale or fails to boot", () => {
  const stale = reloadOrRehydrateSnapshot({
    bytes: SAMPLE_BYTES,
    savedSchema: 1,
    targetSchema: 2,
    createHost: makeFakeHostFactory({ outboxRows: SAMPLE_OUTBOX }),
  });
  assert.equal(stale.persist, true);
  assert.equal(stale.needsBootstrap, true);
  assert.equal(stale.rehydrated.reason, "snapshot_schema_mismatch:1");
  assert.deepEqual(stale.host.importedRows, SAMPLE_OUTBOX);

  const broken = reloadOrRehydrateSnapshot({
    bytes: SAMPLE_BYTES,
    savedSchema: 2,
    targetSchema: 2,
    createHost: makeFakeHostFactory({ outboxRows: SAMPLE_OUTBOX, failBootWhenRestored: true }),
  });
  assert.equal(broken.persist, true);
  assert.equal(broken.needsBootstrap, true);
  assert.equal(broken.rehydrated.reason, "snapshot_boot_failed");
  assert.deepEqual(broken.host.importedRows, SAMPLE_OUTBOX);
});
