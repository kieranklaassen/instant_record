# Plan: Typed Row-Delta Live Bus & Read-Tracked Surgical Patching

## Goal

Upgrade `records_changed` / `ir_notice` and `BroadcastChannel` from flat `"Type:id"` lines and revision-integer wildcards into a compact typed row-delta bus (`{ type, id, op, changed_columns, attrs }`), add lightweight table/partition read tracking during `handle_request` and `render`, and teach `frontend/live.js` (`liveProps`) to apply surgical row updates or skip reloads when unaffected tables or partitions changed.

## Verified Basis

- `lib/instant_record/client.rb:57-61` emits only `"records_changed\nType:id"` with no operation, changed column list, or attribute payload.
- `compiled/web/src/worker.js:129, 427` broadcasts only a bare `snapshotRevision` integer over `BroadcastChannel`, causing peer tabs to emit wildcard `records_changed` reloads.
- `compiled/pipeline/native/instant_record_native.h:41-43` exposes only flat `Type:id` lines from `ir_notice()` and has no read-tracking accessor.
- `frontend/live.js` filters only by `change.type === model`, has no table/partition read awareness, and always falls back to a full Inertia partial reload.

## Architecture & Units

### Unit 1: Lightweight Table/Partition Read Tracking (`lib/instant_record/read_tracker.rb`)
- Add Spinel-safe `InstantRecord::ReadTracker` (`track`, `capture`, `record_sql`, `record`, `serialize`, `affects?`, `last_reads`).
- Subscribe to `sql.active_record` during `track`/`capture` in CRuby (including `in_browser` tests); expose `record_sql(sql, binds)` for Spinel's `SqliteAdapter` / `Db`.
- Parse `SELECT`/`WITH` queries for referenced tables (ignoring internal metadata tables) and sound outer `WHERE` equality/`IN` predicates on partition/key columns (`id`, `*_id`, `sync_window.partition_by`, `sync_scope`).
- Intersect constrained partition columns across multiple queries on the same table (and fall back to whole-table tracking whenever any query lacks a constraint or uses top-level `OR`).
- Map tracked tables to synced model names via `InstantRecord.syncable_models` so downstream JS/native consumers need no Ruby inflection.
- Vendor `lib/instant_record/read_tracker.rb` in `GemVendor::COPY` and inject optional SQL tracking hooks in `WasmTree`.

### Unit 2: Compact Structured Row Deltas (`lib/instant_record/client.rb`, `lib/instant_record/syncable.rb`, `lib/instant_record/client/notifier.rb`)
- Upgrade `Client.note_change` / add `Client.note_record_change` to collect structured deltas `{ "type", "id", "op", "changed_columns", "attrs" }`, coalescing repeated mutations to the same `(type, id)` within a batch.
- Keep deltas compact: enforce `MAX_LISTED_CHANGES = 200`, omit individual attribute values over `MAX_ATTR_BYTES = 4096` (keeping their column name in `changed_columns`), and degrade to `"records_changed"` wildcard if serialized notice exceeds `MAX_NOTICE_BYTES = 65_536`.
- Include partition/key context columns (`id`, `partition_by`, `sync_scope`, `*_id`) in `attrs` on `update` and `destroy` so partition-aware subscribers can filter every op soundly.
- Add `Client.capture_local_changes` and hook `Syncable#record_outbox_mutation` when capturing so local `handle_request` / `action` writes emit typed deltas too.
- Emit structured deltas from `apply_change` (`create`/`update`/`destroy`) and bootstrapped `apply_results` (`mark_synced`, `reconcile_to_server_state`, `reconcile_rejection`), keeping `evict_beyond_windows`, `bootstrap`, and `reset` as `"records_changed"` wildcards; suppress delta pollution in `fetch_history`.
- Emit JSONL lines after `"records_changed\n"` in `Client.changes_notice`.

### Unit 3: Compiler Entry Points, Native ABI & Inertia Renderer (`entry_builder.rb`, `native_shim.c`, `instant_record_native.h`, `LibraryEngine.swift`, `inertia.rb`)
- Wrap `WasmBridge`/`NativeBridge.handle_request` with `ReadTracker.track` + `Client.capture_local_changes` and emit `X-Instant-Record-Reads` header.
- Wrap `NativeBridge.render` with `ReadTracker.track` and publish via `reads` slot (`ir_reads()`), keeping `out` identical to `screen.json`.
- Wrap `NativeBridge.action` with `Client.capture_local_changes` so `ir_notice()` carries structured deltas.
- Add `READS` slot and `const char *ir_reads(void)` to `native_shim.c` and `instant_record_native.h`, document JSONL delta format on `ir_notice(void)`, and expose `reads()` in `LibraryEngine.swift`.
- Support optional partition metadata in `InstantRecord::Inertia.live_props` (preserving existing hash shape when passed plain models) and emit `X-Instant-Record-Reads` from `Inertia::Renderer` when reads are captured.

### Unit 4: Worker & BroadcastChannel Typed Delta Bus (`compiled/web/src/changes.js`, `app-host.js`, `worker.js`, `main.js`)
- Upgrade `readNotice` in `changes.js` to parse structured JSONL deltas (with backwards-compatible `"Type:id"` and wildcard fallback) and add `encodeBroadcast`, `decodeBroadcast`, `parseReads`, `mergeReads`, `affectsReads`.
- Update `AppHost#request` to clear/read `/host/notify` and parse `X-Instant-Record-Reads`.
- Update `worker.js` to track `activeReads`, pass typed deltas through `save(changes)` into `BroadcastChannel` `{ revision, changes }`, decode peer broadcasts without turning them into wildcards, and forward `{ type: "records_changed", changes, reads }` to the page.
- Update `main.js` to maintain `window.__spinel.reads`, pass `reads` in `instant-record:records-changed`, and skip `window.location.reload()` on non-refresh pages when `affectsReads` is false.

### Unit 5: Surgical Live Props Engine (`frontend/live.js`, `frontend/http.js`, `frontend/index.js`)
- Implement `affectsReads`, `filterChanges`, `applyRowDeltas`, `patchProp`, and `createLiveTransport` in `frontend/live.js`.
- Skip reloads when unaffected tables/models or unaffected partitions changed (always reloading when a partition column itself is in `changed_columns`, when `changes` is `null`, or when `attrs` lacks the partition key).
- Support surgical in-place row patching (`create`, `update`, `destroy`) with identity preservation for untouched rows and safe fallback to partial reload when any delta is incomplete or unpatchable.
- Export new primitives from `frontend/index.js` and propagate `X-Instant-Record-Reads` in `frontend/http.js`.

## Verification

1. Ruby gem test suite: `bundle exec rake test` (covering `Client` structured deltas, coalescing, byte budgets, `ReadTracker` SQL/partition extraction and soundness, `EntryBuilder`/`GemVendor`/`WasmTree`, `Inertia`, `NativeScreen`).
2. Node JS test suites: `node --test compiled/web/src/*.test.js frontend/*.test.js` (covering `changes.js` JSONL + legacy parsing, `BroadcastChannel` encode/decode, `affectsReads`/`mergeReads`, and `frontend/live.test.js` covering table/partition skipping, surgical row patching, identity stability, and safe reload fallback).
3. Merge `origin/main` into `feat/typed-row-delta-live-bus`, re-run all tests, merge `--no-ff` into `main`, push `main`, and delete branch locally and remotely per `AGENTS.md`.
