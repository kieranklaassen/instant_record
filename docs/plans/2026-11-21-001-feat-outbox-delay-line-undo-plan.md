# Durable SQLite Outbox Delay-Line Undo (`hold_for:`)

## Problem & Motivation

Currently, `frontend/held.js` (`heldActions`) and `frontend/undo.js` (`useUndoable`) implement 5-second undo hold windows purely in volatile React/JS memory using `setTimeout`. This has two architectural gaps:

1. **Volatile across reloads:** Refreshing or closing the browser drops the undo window (flushing immediately on `pagehide` or losing held state).
2. **React/Inertia-only:** Hotwire pages and Native SwiftUI screens (`InstantRecordNative`) have no access to the undo delay-line primitive.

Meanwhile, InstantRecord already writes every local mutation atomically to SQLite's `instant_record_outbox` (`InstantRecord::OutboxMutation` in `lib/instant_record/syncable.rb`), and both the web worker (`compiled/web/src/worker.js` via `kickSync(delay)`) and the Native SwiftUI host (`SyncSchedule` / `AppHost.swift`) already schedule delayed sync passes.

## Goal

Promote the undo hold window into a durable SQLite `OutboxMutation` delay-line primitive (`hold_for:`) shared across Inertia, Hotwire, and Native SwiftUI, while keeping `frontend/held.js` and `frontend/undo.js` working cleanly on non-compiled server-rendered pages.

## Architecture & Concrete Changes

### 1. Migration & `InstantRecord::OutboxMutation`
- **New migration:** `db/migrate/20261121000001_add_delay_line_to_instant_record_outbox.rb`
  - `add_column :instant_record_outbox, :release_at, :datetime`
  - `add_column :instant_record_outbox, :rollback_payload, :text`
  - `add_index :instant_record_outbox, :release_at`
  - Compatible with `BrowserMigrations` (uses only `add_column` and `add_index`).
- **`lib/instant_record/outbox_mutation.rb`**:
  - `serialize :rollback_payload, coder: JSON`
  - Scopes:
    - `scope :matured, ->(now = Time.now.utc) { where("release_at IS NULL OR release_at <= :now", now: now) }`
    - `scope :held, ->(now = Time.now.utc) { where("release_at IS NOT NULL AND release_at > :now", now: now) }`
  - Instance helpers:
    - `held?(now = Time.now.utc)`: `!release_at.nil? && release_at > now`
    - `matured?(now = Time.now.utc)`: `release_at.nil? || release_at <= now`
  - `as_mutation` wire payload remains unchanged (`id`, `record_type`, `record_id`, `operation`, `changes`, `base_version`) — `release_at` and `rollback_payload` are strictly client-local.

### 2. Recording Held Mutations (`Syncable` & `InstantRecord.hold_for`)
- **`lib/instant_record.rb`**:
  - `InstantRecord.hold_for(seconds, &block)`: delegates to `Client.with_hold(seconds, &block)`. Accepts numeric seconds (or `ActiveSupport::Duration`, converted via `.to_f`). Raises `ArgumentError` if `< 0`; `nil` or `0` means no hold. Restores prior hold in `ensure` for safe nesting.
  - `InstantRecord.cancel_pending(mutation_id)`: delegates to `Client.cancel_pending(mutation_id)`.
  - `InstantRecord.held_mutations`: delegates to `Client.held_mutations`.
  - `InstantRecord.held_count`: delegates to `Client.held_count`.
  - `InstantRecord.next_release_at` / `InstantRecord.next_release_ms`: delegates to `Client`.
  - `InstantRecord.tick_json`: includes `next_release_ms` when present.
- **`lib/instant_record/syncable.rb`**:
  - Add `attr_accessor :hold_for` and `attr_reader :last_outbox_mutation_id` (Spinel-safe, no `**kwargs` splat forwarding, no large integer literals or multiplications per `test/files_test.rb`).
  - Support `destroy(hold_for: nil)` and `destroy!(hold_for: nil)` using `super()` inside `InstantRecord.hold_for(hold_for)` when given.
  - Support `Model.create!(..., hold_for: 5)`, `record.update!(..., hold_for: 5)`, `record.hold_for = 5; record.save!`, and `InstantRecord.hold_for(5) { ... }`.
  - Consume and clear `@hold_for = nil` in `record_outbox_mutation`, `after_rollback`, and server-side save/destroy so a hold never leaks onto a subsequent write on the same Ruby object.
  - In `record_outbox_mutation(operation)`:
    - Compute `delay = effective_hold_for`; validate non-negative; if `delay && delay > 0`, compute `release_at = Time.now.utc + delay` and capture `rollback_payload`:
      - `"create"`: `nil` (undo deletes the created row).
      - `"update"`: full pre-mutation attributes hash via `attributes.merge(saved_changes.transform_values(&:first))`, timestamps formatted with `TIME_PRECISION` (preserving `"sync_state"` and `"server_version"`).
      - `"destroy"`: full pre-destroy `attributes` hash with microsecond timestamps (preserving `"sync_state"` and `"server_version"`).
    - Store `mutation.id` on `@last_outbox_mutation_id`.

### 3. Matured Outbox Filtering, Causal Order, and Compensating Cancel (`Client`)
- **`lib/instant_record/client.rb`**:
  - `with_hold(seconds)` / `current_hold_for`: manages `@hold_for` safely with `ensure` restoration (Spinel-safe, no `IsolatedExecutionState` dependency in browser runtime). Also fix `applying_remote` to preserve prior nesting state.
  - `pending_mutations(now = Time.now.utc)`:
    - Filters to matured rows (`release_at IS NULL OR release_at <= now`) while preserving per-record causal order: if an earlier held mutation exists for `(record_type, record_id)`, later mutations for that same record wait behind it until it matures or is cancelled; mutations for other records drain immediately without head-of-line blocking.
  - `pending_count(now = Time.now.utc)`: count of ready/matured pending mutations (consistent with `pending_mutations.size` so retry backoff in `worker.js` and `SyncSchedule` never hammers while only held rows wait).
  - `held_mutations(now = Time.now.utc)`: `OutboxMutation.held(now).ordered`
  - `held_count(now = Time.now.utc)`: `OutboxMutation.held(now).count`
  - `next_release_at(now = Time.now.utc)`: earliest `release_at` among held mutations, or `nil`.
  - `next_release_ms(now = Time.now.utc)`: remaining milliseconds clamped to `0..86_400_000` (always fits safely in 32-bit signed integer for Spinel wasm32!).
  - `cancel_pending(mutation_id, now: Time.now.utc)`:
    - Runs atomically inside `OutboxMutation.transaction`.
    - Returns `false` if mutation does not exist, is not held (`release_at.nil? || release_at <= now` — already matured or released, avoiding races with in-flight pushes), has a later outbox mutation for the same `(record_type, record_id)`, or its model is unknown.
    - Under `applying_remote` (so no new outbox rows are enqueued):
      - `"create"`: destroys the local record (`model.find_by(id: mutation.record_id)&.destroy!`).
      - `"update"` / `"destroy"`: restores the record from `rollback_payload` (using `find_or_initialize_by(id:)`, assigning sliced pre-mutation attributes including `server_version`, `sync_state`, and exact microsecond timestamps with `record_timestamps = false` when supported; reconciles `sync_state` to `"synced"` and preserves newer `server_version` if an earlier outbox row on the same record was already acked during the hold).
      - Destroys the `OutboxMutation` row.
    - Records `note_change(mutation.record_type, mutation.record_id)` and emits `cancel_pending.instant_record` notification.
    - Returns `true`.

### 4. Reactor Bridge, Browser Worker, and Native SwiftUI Scheduling
- **`lib/instant_record/compiler/entry_builder.rb`**:
  - `sync_plan`: include `next_release_ms` when present.
  - `handle_sync` and `cursor`: append `held=<n>` and (when present) `next_release_ms=<ms>` while keeping existing `cursor=`, `pending=`, `bootstrap=`, `identity=` token format intact.
- **`compiled/web/src/app-host.js`**:
  - Parse `held` and `nextReleaseMs` (`next_release_ms=(\d+)`) in `sync()` and `syncState()`.
- **`compiled/web/src/sync-schedule.js` & `compiled/web/src/worker.js`**:
  - Extract a small pure scheduling helper (`compiled/web/src/sync-schedule.js`) so the delay-line scheduling policy is directly unit-tested with `node --test`.
  - `kickSync(delay = QUIET_MS, { held = false } = {})` tracks `kickHeld`:
    - When a write in `runRequest` leaves `pending > 0`, schedule `kickSync()` (30ms, `held: false`).
    - When `pending === 0` and `nextReleaseMs != null`, schedule `kickSync(nextReleaseMs, { held: true })`.
    - When `pending === 0` and `nextReleaseMs == null` (e.g., after `cancel_pending`), clear any held timer.
    - When `drain()` finishes with `pending === 0` and `nextReleaseMs != null`, reset `drainDelayMs` and schedule `kickSync(nextReleaseMs, { held: true })`.
    - On `boot()` with a restored database (page reload!), inspect `host.syncState()` and schedule `kickSync(0)` if `pending > 0 || !bootstrapped` or `kickSync(nextReleaseMs, { held: true })` if `nextReleaseMs != null`.
    - In `pollChanges()` and `fillStep()`, only defer for `(kickTimer && !kickHeld)` so live inbound polling continues uninterrupted during a 5-second hold window; when `currentCursor === null` (e.g. peer tab reload), also schedule `kickSync(state.nextReleaseMs, { held: true })` if not already scheduled.
- **`native/ios/InstantRecordNative/Sources/InstantRecordNative/SyncSchedule.swift` & `AppHost.swift`**:
  - Add optional `nextRelease: TimeInterval? = nil` parameter to `SyncSchedule.finished(ok:pending:nextRelease:)`: when `ok && pending == 0 && !wanted`, plan `max(0, nextRelease)` (while still letting `pace.poll` win if sooner via `plan`).
  - In `AppHost.swift`, parse `next_release_ms` from `position()` and pass `nextRelease` through `Outcome` -> `ended(...)` -> `schedule.finished(...)`.

### 5. Frontend (`frontend/held.js`, `frontend/undo.js`, `frontend/index.js`)
- **`frontend/held.js`**:
  - Keep `heldActions({ ms = 5000, onChange = () => {} } = {})` 100% backwards-compatible for non-compiled server-rendered pages.
  - Add `durableHeldActions({ onChange = () => {}, onCancel = () => {}, now = Date.now } = {})` for compiled pages hydrated from SQLite `OutboxMutation` rows (`sync(entries)` filters unexpired entries by `release_at`, schedules a single UI-expiry timer for the earliest `release_at`, exposes LIFO `undo()` invoking `onCancel(entry)`, and needs no `flush()` on unload).
- **`frontend/undo.js`** & **`frontend/index.js`**:
  - Extend `useUndoable({ ms = 5000, durable, onCancel } = {})`:
    - When `local()` and `durable` is provided (array of held SQLite mutation descriptors), use `durableHeldActions` (survives reloads, skips `pagehide` flush).
    - Otherwise (non-compiled server-rendered pages, or callers not passing `durable`), keep existing `heldActions` + `pagehide` flush behavior unchanged.
  - Export `durableHeldActions` from `frontend/index.js`.

## Verification Plan

1. **Gem Ruby tests (`bundle exec rake test`)**:
   - New `test/delay_line_test.rb` covering:
     - `hold_for:` on `create!`, `update!`, `destroy!`, `save!` (virtual attr + block + `destroy!(hold_for:)`)
     - Atomic transaction rollback leaves no outbox row
     - `OutboxMutation` `release_at`, `rollback_payload`, `matured`/`held` scopes, `as_mutation` wire format untouched
     - `Client.pending_mutations` filters matured rows (`release_at IS NULL OR release_at <= now`), drains independent records immediately, preserves per-record causal ordering when a non-held write follows a held write on the same record
     - `Client.pending_count`, `Client.held_count`, `Client.next_release_at`, `Client.next_release_ms` (including 32-bit clamping for huge delays)
     - `InstantRecord.cancel_pending(mutation_id)`:
       - Cancelling a held `create` deletes local record & outbox row without enqueueing new outbox rows
       - Cancelling a held `update` restores exact pre-mutation columns, `server_version`, `sync_state`, and microsecond `updated_at`
       - Cancelling a held `destroy` re-inserts the exact record with original UUID, `server_version`, `sync_state`, and microsecond timestamps
       - LIFO multi-step undo on the same record (refuses out-of-order cancel of older mutation while newer exists; succeeds newest-first)
       - Refuses cancel after `release_at` has matured, for non-held mutations, for unknown IDs, or after already drained
       - Concurrent ack of earlier mutation during a subsequent held update restores `sync_state: "synced"` and keeps the acked `server_version`
     - `InstantRecord.tick_json` includes `next_release_ms` when held mutations exist
     - `Syncable` `@hold_for` does not leak onto subsequent writes on the same record (including after validation rollback or on server runtime)
     - `EntryBuilder` output includes `next_release_ms` and `held=`
     - `files_test.rb` 32-bit integer guard still passes
2. **Frontend & Worker JS tests (`node --test frontend/*.test.js compiled/web/src/*.test.js`)**:
   - Existing `frontend/held.test.js` passes unchanged (non-compiled server-rendered path).
   - New tests in `frontend/held.test.js` for `durableHeldActions` (rehydration after reload, expiry timer at `release_at`, LIFO `undo` calling `onCancel`, already-expired entries omitted).
   - New `compiled/web/src/sync-schedule.test.js` testing delay-line `kickSync` scheduling decisions (normal write, held write, cancel clearing held timer, reload hydration, backoff vs held reset).
3. **Native SwiftUI tests (`cd native/ios/InstantRecordNative && swift test`)**:
   - New tests in `SyncScheduleTests.swift` and `AppHostTests.swift` verifying `next_release_ms` parsing from `cursor` and scheduling the exact delayed sync pass without backoff.
4. **AGENTS.md delivery**:
   - Commit on `feat/outbox-delay-line-undo`.
   - Merge `origin/main` into `feat/outbox-delay-line-undo` and run all tests on the merged result.
   - Merge `--no-ff` into `main`, push `main`, and delete the branch.
