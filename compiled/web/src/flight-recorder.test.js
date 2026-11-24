import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { createAppHostClass } from "./app-host-core.js";
import { buildTestWasmModule } from "./wasm-fixture.test.js";
import { FlightRecorder, TRACE_FORMAT, TRACE_VERSION } from "./flight-recorder.js";
import { Redactor } from "./redactor.js";
import { formatReplayReport, replayTrace } from "./replay.js";
import { sha256Hex } from "./sha256.js";
import { redactSqliteBytes } from "./sqlite-redactor.js";
import * as minimalWasi from "./wasi-minimal.js";

test("government identifiers are sensitive while foreign keys and safe overrides are preserved", () => {
  const redactor = new Redactor({ salt: "test" });
  for (const column of ["tax_id", "national_id", "billing_tax_id", "customer_national_id"]) {
    assert.equal(redactor.isPiiColumn("users", column), true, column);
  }
  for (const column of ["id", "user_id", "account_id", "created_at"]) {
    assert.equal(redactor.isPiiColumn("users", column), false, column);
  }
  const safe = new Redactor({ safeColumns: { users: ["tax_id"] } });
  assert.equal(safe.isPiiColumn("users", "tax_id"), false);
});

const AppHost = createAppHostClass(minimalWasi);

function makeSampleSqliteDb() {
  const dir = mkdtempSync(join(tmpdir(), "irtrace-sample-db-"));
  const file = join(dir, "development.sqlite3");
  try {
    const db = new DatabaseSync(file);
    db.exec(`
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        email TEXT,
        phone TEXT,
        role TEXT,
        created_at TEXT,
        server_version INTEGER,
        sync_state TEXT
      );
      CREATE TABLE instant_record_outbox (
        id TEXT PRIMARY KEY,
        record_type TEXT,
        record_id TEXT,
        operation TEXT,
        changes_payload TEXT,
        base_version INTEGER
      );
      CREATE TABLE instant_record_sync_metadata (
        key TEXT PRIMARY KEY,
        value TEXT
      );
    `);
    db.prepare(
      "INSERT INTO users (id, email, phone, role, created_at, server_version, sync_state) VALUES (?, ?, ?, ?, ?, ?, ?)",
    ).run("u-1", "alice@secret-corp.example", "+1-415-555-0199", "admin", "2026-11-21T00:00:00Z", 3, "synced");
    db.prepare(
      "INSERT INTO instant_record_outbox (id, record_type, record_id, operation, changes_payload, base_version) VALUES (?, ?, ?, ?, ?, ?)",
    ).run(
      "m-1",
      "User",
      "u-1",
      "update",
      JSON.stringify({ id: "u-1", email: "alice@secret-corp.example", role: "admin" }),
      3,
    );
    db.prepare("INSERT INTO instant_record_sync_metadata (key, value) VALUES (?, ?)").run("cursor", "42");
    db.prepare("INSERT INTO instant_record_sync_metadata (key, value) VALUES (?, ?)").run("identity", "alice@secret-corp.example");
    db.close();
    return new Uint8Array(readFileSync(file));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("sha256Hex matches node:crypto across empty, UTF-8, and multi-block binary inputs", () => {
  const samples = [
    new Uint8Array(),
    new TextEncoder().encode("abc"),
    new TextEncoder().encode("instant_record flight recorder determinism check ".repeat(20)),
    Uint8Array.from({ length: 1024 }, (_, i) => (i * 31) & 0xff),
  ];
  for (const sample of samples) {
    const expected = createHash("sha256").update(sample).digest("hex");
    assert.equal(sha256Hex(sample), expected);
  }
});

test("Redactor performs schema-aware deterministic PII pseudonymization across HTTP, exchanges, and env", () => {
  const redactor = new Redactor({
    schema: {
      users: ["id", "email", "phone", "role", "created_at"],
      notes: ["id", "title", "secret_note"],
    },
    piiColumns: { notes: ["secret_note"] },
    salt: "fixed-test-salt",
  });

  assert.equal(redactor.isPiiColumn("User", "email"), true);
  assert.equal(redactor.isPiiColumn("User", "id"), false);
  assert.equal(redactor.isPiiColumn("User", "created_at"), false);
  assert.equal(redactor.isPiiColumn("Note", "secret_note"), true);
  assert.equal(redactor.isPiiColumn("Note", "title"), false);

  const rawHttp =
    "POST /users?scope=tok-123&page=2 HTTP/1.1\r\n" +
    "Host: localhost\r\n" +
    "Cookie: _session=super-secret-cookie\r\n" +
    "Content-Type: application/x-www-form-urlencoded\r\n" +
    "Content-Length: 48\r\n\r\n" +
    "user[email]=alice@example.com&user[role]=member";

  const redactedHttp = redactor.redactHttpRequest(rawHttp);
  assert.doesNotMatch(redactedHttp, /super-secret-cookie/);
  assert.doesNotMatch(redactedHttp, /tok-123/);
  assert.doesNotMatch(redactedHttp, /alice@example\.com/);
  assert.match(redactedHttp, /page=2/);
  assert.match(redactedHttp, /user%5Brole%5D=member|user\[role\]=member/);

  const ex1 = redactor.redactExchange({
    method: "POST",
    url: "/instant_record/mutations?scope=tok-123",
    requestBody: JSON.stringify({
      identity: "alice@example.com",
      mutations: [{ id: "m-1", record_type: "User", changes: { id: "u-1", email: "alice@example.com", role: "member" } }],
    }),
    status: 200,
    responseBody: JSON.stringify({
      results: [{ mutation_id: "m-1", status: "applied", version: 2 }],
    }),
  });
  const parsedReq = JSON.parse(ex1.requestBody);
  assert.equal(parsedReq.mutations[0].changes.id, "u-1");
  assert.equal(parsedReq.mutations[0].changes.role, "member");
  assert.match(parsedReq.mutations[0].changes.email, /^redacted-[0-9a-f]{12}@redacted\.invalid$/);
  // Deterministic pseudonymization: same value produces identical pseudonym.
  assert.equal(parsedReq.mutations[0].changes.email, redactor.pseudonymize("alice@example.com", "email"));

  const env = redactor.redactEnv({ RAILS_ENV: "production", SECRET_KEY_BASE: "0123456789abcdef" });
  assert.equal(env.RAILS_ENV, "production");
  assert.notEqual(env.SECRET_KEY_BASE, "0123456789abcdef");
});

test("redactSqliteBytes scrubs PII from user tables, outbox JSON, sync metadata, and VACUUMs raw bytes", () => {
  const rawDb = makeSampleSqliteDb();
  const redactor = new Redactor({
    schema: { users: ["id", "email", "phone", "role", "created_at"] },
    salt: "sqlite-test-salt",
  });

  const result = redactSqliteBytes(rawDb, redactor);
  assert.notEqual(result.digest, result.originalDigest);
  assert.equal(result.digest, sha256Hex(result.bytes));

  // Verify raw PII strings are completely purged even at the binary page level (VACUUM).
  const rawAscii = Buffer.from(result.bytes).toString("latin1");
  assert.equal(rawAscii.includes("alice@secret-corp.example"), false, "raw email must not remain in SQLite pages");
  assert.equal(rawAscii.includes("+1-415-555-0199"), false, "raw phone must not remain in SQLite pages");

  // Verify SQLite integrity and deterministic consistency between users and outbox.
  const dir = mkdtempSync(join(tmpdir(), "irtrace-verify-db-"));
  const file = join(dir, "clean.sqlite3");
  try {
    writeFileSync(file, result.bytes);
    const db = new DatabaseSync(file);
    assert.equal(db.prepare("PRAGMA integrity_check").get().integrity_check, "ok");
    const user = db.prepare("SELECT * FROM users WHERE id = 'u-1'").get();
    assert.equal(user.role, "admin");
    assert.equal(user.created_at, "2026-11-21T00:00:00Z");
    assert.match(user.email, /^redacted-[0-9a-f]{12}@redacted\.invalid$/);

    const outbox = db.prepare("SELECT changes_payload FROM instant_record_outbox WHERE id = 'm-1'").get();
    const payload = JSON.parse(outbox.changes_payload);
    assert.equal(payload.email, user.email, "outbox pseudonym must match user table pseudonym");
    assert.equal(payload.role, "admin");

    const cursor = db.prepare("SELECT value FROM instant_record_sync_metadata WHERE key = 'cursor'").get();
    assert.equal(cursor.value, "42");
    const identity = db.prepare("SELECT value FROM instant_record_sync_metadata WHERE key = 'identity'").get();
    assert.notEqual(identity.value, "alice@secret-corp.example");
    db.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("FlightRecorder is opt-in, rotates epochs cleanly, and fails safe on PII checkpoints", () => {
  const offRecorder = new FlightRecorder({ enabled: false });
  offRecorder.recordStep({ exportName: "wasm_cursor", inputBytes: new Uint8Array(), outcome: { exit: 0 } });
  assert.equal(offRecorder.status().stepCount, 0);

  const recorder = new FlightRecorder({
    enabled: true,
    maxEntries: 4,
    checkpointEvery: 2,
    schema: { users: ["id", "email"] },
    salt: "ring-salt",
  });

  const db1 = makeSampleSqliteDb();
  for (let i = 1; i <= 6; i++) {
    recorder.recordStep({
      exportName: "wasm_cursor",
      inputBytes: new TextEncoder().encode(`step-${i}`),
      outcome: { exit: 0, out: new TextEncoder().encode(`out-${i}`) },
      preCallSnapshot: { dbBytes: db1, schemaVersion: 1, env: { SECRET_KEY_BASE: "topsecret" }, cookies: { sid: "abc" } },
    });
  }

  const status = recorder.status();
  assert.ok(status.stepCount <= 4, `expected <= 4 retained steps, got ${status.stepCount}`);
  assert.ok(status.droppedEntries >= 2, "oldest epoch should have rotated out");

  // Fail-safe browser export: PII schema without SQLite redactor omits raw DB bytes.
  const safeTrace = recorder.exportTrace();
  assert.equal(safeTrace.format, TRACE_FORMAT);
  assert.equal(safeTrace.version, TRACE_VERSION);
  assert.equal(safeTrace.checkpoint.mode, "digest");
  assert.equal(safeTrace.checkpoint.data, null);
  assert.equal(safeTrace.checkpoint.omittedReason, "pii_redaction_required");
  assert.equal(safeTrace.checkpoint.digest, sha256Hex(db1));

  // With Node SQLite redactor attached, export embeds the redacted SQLite checkpoint.
  const fullTrace = recorder.exportTrace({ redactDatabase: redactSqliteBytes });
  assert.equal(fullTrace.checkpoint.mode, "sqlite3");
  assert.equal(fullTrace.checkpoint.redacted, true);
  assert.ok(fullTrace.checkpoint.data.length > 0);
  assert.equal(fullTrace.checkpoint.originalDigest, sha256Hex(db1));
  assert.notEqual(fullTrace.checkpoint.digest, fullTrace.checkpoint.originalDigest);
});

test("FlightRecorder + replayTrace deterministically reproduce exchanges, Ruby events, and WASM traps in Node AppHost", async () => {
  // Step 1: healthy sync with an exchange and bridged Ruby notification, then Step 2: hard trap.
  const mod = buildTestWasmModule({
    syncExit: 0,
    syncOut: "changed pending=0 cursor=9",
    syncRequest: "GET /instant_record/bootstrap\n",
    syncEvents: JSON.stringify([{ name: "bootstrap.instant_record", payload: { records: 2 }, duration_ms: 1.5 }]),
    streamTraps: true,
    streamStderr: "fatal: unreachable trap in stream\n",
  });

  const recorder = new FlightRecorder({
    enabled: true,
    schema: { issues: ["id", "title"] },
    salt: "replay-salt",
  });

  const host = new AppHost(mod, {
    env: { RAILS_ENV: "production", SECRET_KEY_BASE: "deterministic-secret" },
    exchange: (method, url) => {
      assert.equal(method, "GET");
      assert.equal(url, "/instant_record/bootstrap");
      return { status: 200, body: JSON.stringify({ cursor: 9, records: [] }) };
    },
    recorder,
  });

  const syncResult = host.sync("/instant_record");
  assert.equal(syncResult.exit, 0);
  assert.equal(syncResult.events.length, 1);

  const streamResult = host.consumeStream("id: 10\ndata: {\"type\":\"Issue\",\"id\":\"1\"}\n\n");
  assert.equal(streamResult.fault.kind, "wasm_trap");
  assert.equal(host.poisoned, true);

  const trace = recorder.exportTrace();
  assert.equal(trace.steps.length, 2);
  assert.equal(trace.steps[0].exchanges.length, 1);
  assert.equal(trace.faults.length, 1);

  const report = await replayTrace(trace, { wasmModule: mod, wasiShim: minimalWasi });
  assert.equal(report.ok, true, formatReplayReport(report));
  assert.equal(report.mismatches, 0);
  assert.equal(report.reproducedFault, true);
  assert.equal(report.executedSteps, 2);
  assert.equal(report.steps[0].actual.events[0].name, "bootstrap.instant_record");
  assert.equal(report.steps[1].actual.trapped, true);
  assert.deepEqual(report.steps[1].actual.errors, ["fatal: unreachable trap in stream"]);
});
