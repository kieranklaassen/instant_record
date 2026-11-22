---
title: "feat: CI-ready headless dual-runtime parity and seeded chaos simulation harness"
type: feat
status: active
date: 2026-11-21
---

# Headless Dual-Runtime Parity & Seeded Chaos Simulation Harness

## Problem & Verified Basis

`bundle exec rake test` currently exercises `InstantRecord` only under CRuby against an in-memory SQLite database. Compiled runtime paths go unverified until a full browser test runs:

- `compiled/web/src/app-host.js:10` already boots and drives the compiled WASI reactor (`app.wasm`) identically in Node and browsers via synchronous `exchange(method, url, body)`.
- `compiled/pipeline/native/instant_record_native.h:13-39` exposes the C ABI (`ir_set_exchange`, `ir_boot`, `ir_open`, `ir_call`, `ir_notice`, `ir_error`) with an injectable synchronous exchange callback.
- `lib/instant_record/client.rb:28-38` exposes injectable `Client.transport=` and `Client.notifier=` seams for CRuby execution.
- Regressions in compiled codepaths — such as wasm32 32-bit signed integer overflow (`RangeError: integer overflow in *`, documented in `docs/solutions/2026-11-21-a-number-in-a-compiled-file-has-32-bits.md`) and `frontend/http.js:36-49` local-fetch writes — are invisible to CRuby unit tests.

## Goals

1. Build a fast, CI-ready headless runner (`rake instant_record:verify_parity` and `rake instant_record:chaos`) usable both from a host Rails app (via `lib/tasks/instant_record.rake`, using CRuby+Postgres) and from the gem root (`Rakefile`).
2. Execute shared model, controller, sync, and `frontend/http.js` parity assertions simultaneously across CRuby, compiled `app.wasm` (Node `AppHost`), and compiled Native C ABI (Ruby `Fiddle`).
3. Execute deterministic seeded multi-client chaos traces exercising:
   - network partitions (offline, asymmetric POST/GET drops, HTTP 503, response dropped after server commit to prove idempotency)
   - clock skew (LWW ordering, tie-breaking, and `applied + skipped` authoritative reconciliation)
   - 32-bit integer boundary values (`INT32_MAX` cursors, `server_version`, config reads, boundary strings)
   - identity switches (`anonymous` / `ada` / `ben` / `cleo`, `event: reset`, scoped vs unscoped outbox survival, `replay_from`)
   - mid-bootstrap aborts (transport failure / truncated response before cursor commit, idempotent retry)
   - split SSE stream chunks and echo suppression
4. Strictly assert WASI/native `stderr` is empty on every non-fault operation (and contains no unexpected errors even under injected network faults) and assert bit-for-bit database & state convergence across all runtimes and against the authoritative server.

## Architecture & Implementation Units

### Unit 1: Host Shared Library Output in `NativeBuild`
- **File:** `lib/instant_record/compiler/native_build.rb`
- When `@target.nil?` (host build), compile host objects with `-fPIC` (portable across macOS and Linux) and link `libinstant_record_app.dylib` (macOS) or `libinstant_record_app.so` (Linux) alongside `libinstant_record_app.a` and `host`, exporting all `instant_record_native.h` symbols for direct `Fiddle.dlopen`.

### Unit 2: Core Testing Harness & Authoritative Server
- **Files:**
  - `lib/instant_record/testing.rb` — Top-level API (`verify_parity`, `run_chaos`, artifact discovery, canonical state normalization & bit-for-bit diffing).
  - `lib/instant_record/testing/authoritative_server.rb` — Two server backends behind one `exchange(method, url, body, identity:)` + `visible_state(identity:)` + `server_write(...)` + `advance_cursor_to(n)` interface:
    - `RackServer`: dispatches real requests to a mounted Rails application (CRuby + Postgres) via `Rack::MockRequest` with session/cookie identity management.
    - `StandaloneServer`: lightweight ActiveRecord server (connects to PostgreSQL via `DATABASE_URL` when provided, or isolated SQLite otherwise) with real `Issue` (`server_only` `"reject me"` exclusion), `AuthNote` (`syncable_to`/`writable_by` matching `AuthPerson` roles), `MutationApplier`, `SyncScope`, and `Change`.
  - `lib/instant_record/testing/fault_network.rb` — Per-client deterministic fault injector wrapping `AuthoritativeServer`: partitions (`:online`, `:offline`, `:drop_post`, `:drop_get`, `:server_503`, `:drop_after_apply`), one-shot `:abort_bootstrap`, per-client identity switching, per-client clock skew, and exchange audit logging (`fault_injected?`).

### Unit 3: Unified Runtime Drivers (`CRuby`, `Wasm`, `Native`)
- **Files:**
  - `lib/instant_record/testing/runtimes/base.rb` — Shared `ClientHandle` contract, strict stderr validator (`assert_clean_stderr!`), canonical SQLite table reader (`SQLite3::Database`), and HTTP form/controller helper.
  - `lib/instant_record/testing/runtimes/cruby_runtime.rb` — Multi-client CRuby driver using injectable `InstantRecord::Client.transport=` and `InstantRecord::Client.notifier=` seams (`lib/instant_record/client.rb:28-38`) with one isolated SQLite DB per client.
  - `lib/instant_record/testing/runtimes/wasm_runtime.rb` & `lib/instant_record/testing/wasm_host_bridge.mjs` — Persistent Node.js worker wrapping `compiled/web/src/app-host.js`. Compiles `app.wasm` once, creates N `AppHost` instances, relays synchronous `exchange` calls back to Ruby over stdin/stdout NDJSON, returns WASI `stderr` (`errors`) and `exit` on every call, exports `databaseBytes()` for direct SQLite inspection, and exposes a `verify_frontend_http` probe running `frontend/http.js` (`write` + `localHttpClient.request`) against `AppHost`.
  - `lib/instant_record/testing/runtimes/native_runtime.rb` — In-process Ruby `Fiddle` driver loading `libinstant_record_app.{dylib,so}`, binding `ir_set_exchange`, `ir_boot`, `ir_open`, `ir_call`, `ir_notice`, `ir_error`, managing N client SQLite files via `ir_open`, pinning exchange return buffers safely across C `strdup`, and capturing native stderr.

### Unit 4: Shared Parity Suite & Seeded Chaos Simulator
- **Files:**
  - `lib/instant_record/testing/parity_suite.rb` — Runs identical parity scenarios across all selected runtimes and asserts bit-for-bit parity and empty WASI/native stderr:
    1. Boot & 32-bit config safety (`InstantRecord.config`, `sync_state`, `sync_plan`)
    2. Model & controller CRUD (`GET`, `POST`, `PATCH` via `_method`, `DELETE` via `_method`) + outbox drain
    3. Server-only rejection & rollback (`Issue` `"reject me"`)
    4. 32-bit signed integer boundaries (`cursor` & `server_version` at `2_147_483_646` / `2_147_483_647`, boundary numeric text)
    5. Identity scoping, identity switch, `event: reset`, scoped purge vs unscoped outbox survival, `replay_from`
    6. Mid-bootstrap abort (503 / network drop / malformed body) & idempotent retry
    7. Split SSE chunk parsing (`consume_stream` / `wasm_stream` / `ir_call("stream")`) & echo suppression
    8. `frontend/http.js` `write()` + `localHttpClient.request()` against `AppHost` (when Wasm active)
  - `lib/instant_record/testing/chaos_simulator.rb` — Seeded deterministic PRNG (`SEED`, `STEPS`, `CLIENTS`) driving heterogeneous clients (CRuby + Wasm + Native simultaneously, or CRuby-only when no compiled artifacts exist) through randomized partitions, clock skew, 32-bit boundary events, identity switches, mid-bootstrap aborts, split SSE frames, server writes, and rejections; enforces step-by-step invariants (`stderr` clean, `exit == 0`, `pending >= 0`, cursor monotonicity) and heals all clients to assert bit-for-bit convergence against the server and across runtimes, printing a reproducible `SEED` + trace on failure.

### Unit 5: Rake Tasks & Test Suite
- **Files:**
  - `lib/tasks/instant_record.rake` — Adds `instant_record:verify_parity` and `instant_record:chaos` tasks for host Rails apps (running against `Rails.application` + Postgres).
  - `Rakefile` — Adds `instant_record:verify_parity` and `instant_record:chaos` tasks for gem-root CI invocation.
  - `test/dual_runtime_parity_test.rb` — Unit & integration tests covering canonical diffing, fault network, parity suite, strict stderr catching, and compiled Wasm/Native execution when artifacts exist.
  - `test/chaos_simulator_test.rb` — Multi-seed deterministic chaos tests verifying reproducibility, convergence under all fault classes, and failure trace reporting.

## Verification Plan

1. Compile the demo for both Wasm (`rake compile`) and Native (`rake compile:native`) using the local toolchain and verify `libinstant_record_app.dylib` and `app-*.wasm` are produced cleanly.
2. Run `bundle exec rake instant_record:verify_parity REQUIRE_COMPILED=1` and `bundle exec rake instant_record:chaos REQUIRE_COMPILED=1 SEEDS=3 STEPS=60` from the gem root (testing CRuby + Wasm `AppHost` + Native Fiddle simultaneously).
3. Run `bin/rails instant_record:verify_parity` and `bin/rails instant_record:chaos` inside `demo` against live PostgreSQL (`PGPORT=5433`) with compiled Wasm and Native artifacts!
4. Run `bundle exec rake test` (gem tests) and `cd demo && PGPORT=5433 bin/rails test` (if demo touched).
5. Merge `origin/main` into branch, re-run tests, merge `--no-ff` into `main`, push `main`, and delete branch locally/remotely per `AGENTS.md`.
