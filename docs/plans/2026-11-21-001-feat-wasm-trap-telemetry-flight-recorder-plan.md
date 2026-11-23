# Plan: WASM Trap/Stderr Surfacing, Circuit Breaker, Ruby Notification Bridge & `.irtrace` Flight Recorder

Date: 2026-11-21
Branch: `feat/wasm-trap-telemetry-flight-recorder`

## Problem & Verified Basis

1. **Swallowed WASM traps and stderr (`compiled/web/src/app-host.js:94, 125-127, 196`; `compiled/web/src/worker.js:176-197`)**
   - `AppHost` buffers stderr in `this.errors` and returns `pending: -1` when `wasm_sync` traps or exits non-zero, while `syncState()` drops `exit`/`errors` completely.
   - `worker.js` ignores `result.exit` and `result.errors` on `host.sync()`, `host.consumeStream()`, `host.syncState()`, and `host.request()`:
     - Post-bootstrap: `pending: -1` fails `result.pending > 0`, silently stalling sync with no error surfaced.
     - Pre-bootstrap: `needsBootstrap` stays `true`, causing an infinite silent retry loop.
     - `consumeStream()` failure overwrites `currentCursor` with `0`.
     - `pollChanges()` and `runFill()` catch and swallow non-network WASM exceptions silently.
2. **Unbridged Ruby instrumentation (`lib/instant_record/client.rb:614-616`; `compiled/web/src/worker.js:22-29`)**
   - `InstantRecord::Client.instrument` emits `ActiveSupport::Notifications` (`*.instant_record`) that never cross the WASI/worker boundary; JS only logs shallow timing tuples.
3. **No deterministic bug reproduction / trace capture**
   - Reproducing a WASM trap or sync failure requires manual Node scripts and unredacted browser DBs.

## Scope & Architecture

### Unit 1: Fault Model, Circuit Breaker & `AppHost` Core (`compiled/web/src/faults.js`, `app-host-core.js`, `app-host.js`, `changes.js`)
- Extract `createAppHostClass` into zero-dependency `compiled/web/src/app-host-core.js`; keep `compiled/web/src/app-host.js` as a thin `@bjorn3/browser_wasi_shim` wrapper so Vite bundling stays unchanged and Node unit tests can exercise real WASM modules directly.
- Add `WasmFaultError`, `buildFault`, and `CircuitBreaker` in `compiled/web/src/faults.js`:
  - Fatal WASM traps (`WebAssembly.RuntimeError` / `wasm_boot` trap) poison the `AppHost` instance (`this.poisoned = true`) and trip the circuit breaker immediately (`state: "open"`).
  - Consecutive non-zero Ruby exits (`exit !== 0`) emit `instant_record.fault` on every occurrence and trip the circuit breaker after `maxConsecutiveFailures` (default `3`), preventing both silent stalls and infinite retry loops. A healthy `exit === 0` resets consecutive failures.
- Inspect `result.exit`, `result.errors`, and bridged `/host/events` on every `AppHost.call`; expose `exit`, `errors`, `events`, and `fault` on `request`, `sync`, `consumeStream`, and `syncState`, and throw `WasmFaultError` from `syncPlan`, `history`, and `ensureBooted`.
- Capture full exchange records (`{ method, url, requestBody, status, responseBody }`) on `AppHost` alongside the existing `this.exchanges` summary array.

### Unit 2: Ruby Notification Bridge Across the WASI/Worker Boundary (`lib/instant_record/client.rb`, `client/notifier.rb`, `compiler/entry_builder.rb`)
- Add bounded in-memory event capture in `InstantRecord::Client` (`recorded_events`, `clear_events`, `events_notice`) updated inside `Client.instrument` when `InstantRecord.browser?` (preserving all existing CRuby `ActiveSupport::Notifications` semantics and 32-bit Spinel integer safety).
- Flush notifications immediately via `Notifier::Worker#events_emitted` to `/host/events` (guarded by `File.directory?("/host")` for CRuby test safety, and rewritten automatically by `EntryBuilder.rewrite_native_client_host` while keeping `seams == 2`).
- Clear per-call event buffers at the start of every `WasmBridge` / `NativeBridge` entrypoint so each WASM call returns only its own notifications (including notifications completed right before a mid-call trap).

### Unit 3: Worker Fault Telemetry, Circuit Breaker Enforcement & Main-Thread Dev Surfacing (`compiled/web/src/worker.js`, `main.js`)
- Wire `CircuitBreaker`, `FlightRecorder`, and notification forwarding into `worker.js`:
  - Emit `console.error` + `{ type: "instant_record.fault", fault, circuit, traceAvailable }` unconditionally on every non-zero exit or trap.
  - Emit `{ type: "instant_record.notification", ... }` for every bridged Ruby notification and record structured entries in the debug buffer.
  - Never overwrite `currentCursor` or commit DB snapshots on failed `sync`/`consumeStream` calls; never treat `pending: -1` as healthy; cancel `kickTimer` and `fillTimer` and halt retries once the circuit trips open.
  - Support `instant_record.reset_circuit` to reset the breaker and reload a clean `AppHost` from IndexedDB.
- Wire `main.js`:
  - Surface `instant_record.fault` via `console.error`, `window.__spinel.lastFault` / `faults` / `circuit`, `CustomEvent("instant-record:fault")`, and a fail-loud dismissible dev error banner (with Reset runtime and Export `.irtrace` controls when active).
  - Forward `instant_record.notification` via `window.__spinel.notifications` and `CustomEvent("instant-record:notification")`.
  - Expose opt-in `window.__spinel.trace` (`enable`, `disable`, `status`, `clear`, `export`, `download`) and pre-boot activation via `?irtrace=1` or `sessionStorage`.

### Unit 4: Opt-in `.irtrace` Flight Recorder & Schema-Aware PII Redaction (`compiled/web/src/sha256.js`, `redactor.js`, `flight-recorder.js`, `sqlite-redactor.js`, `lib/instant_record/trace/`)
- Implement synchronous pure-JS SHA-256 (`sha256.js`) for deterministic DB and output digests in both browser workers and Node.
- Implement `Redactor` (`redactor.js`) with schema-aware column classification (using table/column metadata extracted from `db/schema.rb` via `VITE_TRACE_SCHEMA` + configurable PII/safe rules + HTTP/cookie/env/exchange redaction) and deterministic per-trace pseudonymization.
- Implement `FlightRecorder` (`flight-recorder.js`): opt-in (off by default), two-epoch rolling ring buffer preserving a consistent base DB checkpoint + SHA-256 digest before `steps[0]`, recording WASI boundary inputs, ordered exchanges, bridged Ruby events, and outcomes, exportable as version 1 `.irtrace` JSON. Fail-safe PII protection omits raw SQLite bytes when PII columns exist and no SQLite redactor hook is attached unless explicitly opted in.
- Implement real SQLite checkpoint redaction in Node (`sqlite-redactor.js` via `node:sqlite`) and Ruby (`InstantRecord::Trace::Redactor` via `sqlite3` gem): redacts PII columns per table, redacts `instant_record_outbox.changes_payload` JSON by `record_type`, redacts `instant_record_sync_metadata` identity, runs `VACUUM`, and updates digests.
- Pass `VITE_TRACE_SCHEMA` from `InstantRecord::Compiler::WasmBuild` using `InstantRecord::Trace::SchemaExtractor`.

### Unit 5: Deterministic Node Replay & `rails instant_record:replay <file>` (`compiled/web/src/wasi-minimal.js`, `replay.js`, `lib/instant_record/trace/replayer.rb`, `lib/tasks/instant_record.rake`)
- Implement `compiled/web/src/replay.js` (and `wasi-minimal.js` fallback when `@bjorn3/browser_wasi_shim` is absent from `node_modules`) to boot `AppHost` in Node, restore & digest-verify the base checkpoint DB, replay every recorded WASI step with deterministic queued exchanges, compare outcomes/traps/stderr/events, and emit human-readable or `--json` reports.
- Implement `InstantRecord::Trace::Replayer` and the `rails instant_record:replay` rake task supporting positional (`rails instant_record:replay file.irtrace`), bracket (`rails "instant_record:replay[file.irtrace]"`), and env-var (`TRACE=... WASM=...`) invocations.

## Verification Plan
- **JS unit & integration tests (`node --test compiled/web/src/*.test.js`)**:
  - Real WebAssembly module tests (hand-assembled WASM binary exercising `wasm_boot`, `wasm_sync`, `wasm_stream`, `wasm_request`, `wasm_cursor`, `wasm_sync_plan`, `wasm_history`, stderr output, `/host/events` notifications, `/host/request`->`/host/response` exchanges, non-zero Ruby exits, and hard `unreachable` WASM traps!).
  - `CircuitBreaker` state transitions (fatal immediate trip, consecutive non-zero trip, reset on success, manual reset).
  - Worker loop behavior tests covering pre-bootstrap loop termination, post-bootstrap `pending: -1` non-stall, `consumeStream` cursor preservation, and bridged notification forwarding.
  - `sha256.js` verified against `node:crypto`.
  - `Redactor` & `sqlite-redactor.js` verifying schema-aware PII redaction, deterministic pseudonymization, outbox JSON redaction, `VACUUM` byte purge, and fail-safe checkpoint omission.
  - `FlightRecorder` rolling two-epoch ring buffer rotation + full record -> export `.irtrace` -> Node `replay.js` deterministic replay reproducing both healthy syncs and WASM traps!
- **Ruby gem tests (`bundle exec rake test`)**:
  - Bridged notification buffering, payload normalization, CRuby `ActiveSupport::Notifications` compatibility, and `Notifier::Worker` `/host/events` safety.
  - `SchemaExtractor` parsing `db/schema.rb` and `WasmBuild` passing `VITE_TRACE_SCHEMA`.
  - `InstantRecord::Trace::Redactor` SQLite checkpoint + `.irtrace` redaction + `VACUUM` verification.
  - `InstantRecord::Trace::Replayer` + `instant_record:replay` rake task end-to-end replay against a real WASM fixture!
  - Existing 260 tests (including `CompilerTest`, `FilesTest` 32-bit int guard, `InstrumentationTest`, `SyncLoopTest`) all remain green.
