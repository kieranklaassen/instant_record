import assert from "node:assert/strict";
import { test } from "node:test";
import { createAppHostClass } from "./app-host-core.js";
import { CircuitBreaker, WasmFaultError, buildFault, readEvents } from "./faults.js";
import { createWorkerRuntime } from "./reactor-runtime.js";
import * as minimalWasi from "./wasi-minimal.js";
import { buildTestWasmModule } from "./wasm-fixture.test.js";

const AppHost = createAppHostClass(minimalWasi);

test("CircuitBreaker trips immediately on fatal WASM traps and resets cleanly", () => {
  const trips = [];
  const breaker = new CircuitBreaker({ maxConsecutiveFailures: 3, onTrip: (snap) => trips.push(snap) });

  assert.equal(breaker.isOpen(), false);
  const trap = buildFault({ exportName: "wasm_sync", exit: "trap: unreachable", trapped: true, fatal: true });
  const outcome = breaker.recordFault(trap);

  assert.equal(outcome.trippedNow, true);
  assert.equal(outcome.open, true);
  assert.equal(trips.length, 1);
  assert.throws(() => breaker.assertClosed("sync"), WasmFaultError);

  breaker.reset();
  assert.equal(breaker.isOpen(), false);
  assert.doesNotThrow(() => breaker.assertClosed("sync"));
});

test("CircuitBreaker tracks consecutive failures per export so healthy requests do not mask a failing sync loop", () => {
  const breaker = new CircuitBreaker({ maxConsecutiveFailures: 3 });
  const rubyErr = buildFault({
    exportName: "wasm_sync",
    exit: 1,
    errors: ["RangeError: integer overflow in *"],
  });

  assert.equal(breaker.recordFault(rubyErr).open, false);
  // A healthy page render on wasm_request must NOT reset wasm_sync's consecutive failures.
  breaker.recordSuccess("wasm_request");
  assert.equal(breaker.consecutiveFailures, 1);

  assert.equal(breaker.recordFault(rubyErr).open, false);
  // A healthy wasm_sync DOES reset wasm_sync's counter.
  breaker.recordSuccess("wasm_sync");
  assert.equal(breaker.consecutiveFailures, 0);

  assert.equal(breaker.recordFault(rubyErr).open, false);
  breaker.recordSuccess("wasm_request");
  assert.equal(breaker.recordFault(rubyErr).open, false);
  const third = breaker.recordFault(rubyErr);
  assert.equal(third.trippedNow, true);
  assert.equal(third.open, true);
  assert.equal(third.snapshot.consecutiveFailures, 3);
});

test("readEvents parses JSON arrays, NDJSON lines, and survives truncated lines", () => {
  assert.deepEqual(readEvents(""), []);
  assert.deepEqual(readEvents('[{"name":"drain.instant_record","payload":{"posted":2}}]'), [
    { name: "drain.instant_record", payload: { posted: 2 } },
  ]);
  assert.deepEqual(
    readEvents('{"name":"bootstrap.instant_record","payload":{"records":5}}\n{"name":"truncated'),
    [{ name: "bootstrap.instant_record", payload: { records: 5 } }],
  );
});

test("AppHost surfaces non-zero Ruby exits, stderr, and calls onFault without swallowing", () => {
  const mod = buildTestWasmModule({
    syncExit: 1,
    syncStderr: "RangeError: integer overflow in *\n",
    syncOut: "",
  });
  const faults = [];
  const host = new AppHost(mod, {
    exchange: () => ({ status: 200, body: "{}" }),
    onFault: (f) => faults.push(f),
  });

  const result = host.sync("/instant_record");
  assert.equal(result.exit, 1);
  assert.equal(result.pending, -1);
  assert.deepEqual(result.errors, ["RangeError: integer overflow in *"]);
  assert.equal(result.fault.kind, "ruby_error");
  assert.equal(result.fault.exportName, "wasm_sync");
  assert.equal(faults.length, 1);
  assert.equal(host.poisoned, false);
});

test("AppHost catches hard WASM traps, poisons instance, and preserves pre-trap bridged Ruby events", () => {
  const mod = buildTestWasmModule({
    syncTraps: true,
    syncStderr: "fatal: stack smash\n",
    syncEvents: JSON.stringify([{ name: "drain.instant_record", payload: { posted: 3, rejected: 0 }, duration_ms: 4.5 }]),
  });
  const faults = [];
  const seenEvents = [];
  const host = new AppHost(mod, {
    exchange: () => ({ status: 200, body: "{}" }),
    onFault: (f) => faults.push(f),
    onEvents: (events, exportName) => seenEvents.push({ events, exportName }),
  });

  const result = host.sync("/instant_record");
  assert.equal(host.poisoned, true);
  assert.equal(result.fault.kind, "wasm_trap");
  assert.equal(result.fault.fatal, true);
  assert.match(String(result.exit), /^trap:/);
  assert.deepEqual(result.errors, ["fatal: stack smash"]);
  assert.equal(result.events.length, 1);
  assert.equal(result.events[0].name, "drain.instant_record");
  assert.equal(seenEvents.length, 1);
  assert.equal(faults.length, 1);

  // Subsequent calls on a poisoned instance refuse to re-enter corrupt WASM memory.
  const second = host.syncState();
  assert.equal(second.fault.fatal, true);
  assert.match(String(second.exit), /poisoned/);
  assert.equal(second.pending, -1);
});

test("AppHost exposes exit/errors/fault on syncState and consumeStream and throws WasmFaultError on syncPlan/history/boot", () => {
  const failMod = buildTestWasmModule({
    streamExit: 1,
    streamStderr: "NoMethodError: undefined method\n",
    cursorExit: 1,
    planExit: 1,
    histExit: 1,
  });
  const host = new AppHost(failMod, { exchange: () => ({ status: 200, body: "{}" }) });

  const stream = host.consumeStream("data: {}\n\n");
  assert.equal(stream.exit, 1);
  assert.equal(stream.fault.exportName, "wasm_stream");
  assert.deepEqual(stream.errors, ["NoMethodError: undefined method"]);

  const state = host.syncState();
  assert.equal(state.exit, 1);
  assert.equal(state.pending, -1);
  assert.equal(state.fault.exportName, "wasm_cursor");

  assert.throws(() => host.syncPlan(), (err) => err instanceof WasmFaultError && err.exportName === "wasm_sync_plan");
  assert.throws(() => host.history("type=Note"), (err) => err instanceof WasmFaultError && err.exportName === "wasm_history");

  const bootTrapMod = buildTestWasmModule({ bootTraps: true });
  const bootFaults = [];
  const bootHost = new AppHost(bootTrapMod, { onFault: (f) => bootFaults.push(f) });
  assert.throws(() => bootHost.ensureBooted(), (err) => err instanceof WasmFaultError && err.fatal && err.exportName === "wasm_boot");
  assert.equal(bootHost.poisoned, true);
  assert.equal(bootFaults.length, 1);
});

test("reactor-runtime surfaces WASM faults, bridges Ruby notifications, recovers poisoned AppHost on reset_circuit, and exports .irtrace", async () => {
  const store = new Map([
    ["development.sqlite3", new Uint8Array([1, 2, 3, 4])],
    ["rails_schema_version", 1],
    ["schema_digest", "abc123"],
    ["migration_history", {}],
  ]);
  const posted = [];
  const runtime = createWorkerRuntime({
    env: {
      VITE_SCHEMA_VERSION: "1",
      VITE_MIGRATION_HISTORY: "{}",
      VITE_SCHEMA_DIGEST: "abc123",
      VITE_TRACE_SCHEMA: JSON.stringify({ users: [{ name: "email", type: "string" }] }),
    },
    AppHost,
    openSnapshot: () => {},
    withFiles: async (_mode, op) => op(
      async key => store.get(key),
      (key, val) => store.set(key, val),
      key => store.delete(key),
    ),
    openStorage: async () => ({ mode: "indexeddb", close() {}, wipe: async () => {} }),
    fetchImpl: async () => ({
      status: 200,
      headers: { get: () => "application/json" },
      text: async () => '{"results":[]}',
    }),
    postMessage: msg => posted.push(msg),
    origin: "http://localhost",
    locks: null,
    pollIntervalMs: 0,
    streamEnabled: false,
  });

  const rpc = async (type, payload) => {
    const id = posted.length + 1;
    await runtime.handleMessage({ data: { id, type, payload } });
    const reply = posted.find(m => m.id === id);
    assert.ok(reply, `expected reply for ${type}`);
    if (reply.error) throw new Error(reply.error);
    return reply.result;
  };

  const mod = buildTestWasmModule({
    reqOut: "200\nContent-Type: text/html\n\nhello",
    planOut: JSON.stringify({ push: '{"mutations":[]}', mutation_ids: [], bootstrap: false }),
    cursorOut: "cursor=1 pending=0 bootstrap=ready identity= notices=0 held=0",
    syncTraps: true,
    syncStderr: "fatal wasm_sync trap\n",
    syncEvents: '[{"name":"before_trap.instant_record","payload":{"step":2},"duration_ms":3}]',
  });

  const booted = await rpc("boot", { module: mod, path: "/ok", trace: true });
  assert.equal(booted.first.result.body, "hello");
  assert.equal(booted.circuit.state, "closed");

  // Triggering sync hits a hard WASM trap -> emits bridged notification + instant_record.fault and trips breaker OPEN.
  const trapped = await rpc("sync");
  assert.ok(trapped.fault);
  assert.equal(runtime.breaker.isOpen(), true);
  assert.ok(posted.some(m => m.type === "instant_record.fault" && m.trippedNow === true && m.circuit.state === "open"));
  assert.ok(posted.some(m => m.type === "instant_record.notification" && m.name === "before_trap.instant_record"));

  // While open, requests fail fast with the tripped fault without re-entering the poisoned WASM instance.
  await assert.rejects(() => rpc("request", { method: "GET", path: "/blocked" }), /fatal wasm_sync trap/);

  // Exporting .irtrace succeeds even while circuit breaker is open.
  const trace = await rpc("instant_record.trace.export", { redact: true });
  assert.equal(trace.format, "instant_record.trace");
  assert.equal(trace.circuit.state, "open");
  assert.ok(trace.steps.some(s => s.outcome.trapped === true));

  // Resetting the circuit recreates the poisoned AppHost so subsequent requests succeed.
  const reset = await rpc("instant_record.reset_circuit");
  assert.equal(reset.ok, true);
  assert.equal(reset.circuit.state, "closed");
  const recovered = await rpc("request", { method: "GET", path: "/after-reset" });
  assert.equal(recovered.status, 200);
  assert.equal(recovered.body, "hello");

  runtime.shutdown();
});
