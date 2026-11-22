---
title: Conflict and Rejection Quarantine Ledger (InstantRecord::SyncNotice) - Plan
type: feat
date: 2026-11-21
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Conflict and Rejection Quarantine Ledger (`InstantRecord::SyncNotice`) - Plan

## Goal Capsule

- **Objective:** Offline writes rejected by the server or overwritten by last-write-wins (LWW) are preserved in a durable local ledger with their attempted changes, winning server values, and reasons, and surfaced across React, Hotwire, and Native SwiftUI so users can retry, fork as a new record, or dismiss them without silent data loss.
- **Means:** Add a local `instant_record_sync_notices` table and `InstantRecord::SyncNotice` model recorded atomically before outbox removal (`KTD1`), propagate notices through `ir_notice`/worker events (`KTD2`), and expose resolution actions via a shared bridge entry point plus `useSyncNotices`, a Hotwire partial helper/controller, and Native SwiftUI notice surfacing (`KTD3`, `KTD4`, `KTD5`).
- **Authority Hierarchy:** User request + `AGENTS.md` (no PRs; merge `origin/main`, run tests, `--no-ff` merge to `main`, push, delete branch) > Product Contract > Planning Contract > Implementation Units.
- **Stop Conditions:** Unresolvable merge conflict with `origin/main`, failing tests in Ruby/JS/Swift (or demo if demo changes), or refused push to `main`.
- **Execution Profile:** Single branch (`feat/conflict-rejection-quarantine`), merged `--no-ff` into `main` per `AGENTS.md`.

## Product Contract

### Summary

Add `InstantRecord::SyncNotice` backed by `instant_record_sync_notices` to quarantine rejected mutations and LWW-overwritten offline writes before removing the outbox row. Surface newly created and persisted notices through `ir_notice`, browser worker messages, a React `useSyncNotices` hook in `frontend/`, a Hotwire partial helper and engine controller, and Native SwiftUI banner/sheet UI with retry, fork-as-new, and dismiss actions.

### Problem Frame

`lib/instant_record/client.rb` currently reconciles `skipped` (LWW-lost) and `rejected` mutations back to server state (or destroys rejected local creates) and immediately deletes the outbox mutation via `mutation.destroy!`. Even though `app/models/instant_record/mutation_applier.rb` already returns human-readable rejection reasons and `server_attributes`, both the user's attempted offline changes and the reason are discarded silently.

### Requirements

#### Ledger & Client Quarantine
- R1. Persist every server-rejected mutation (`status: "rejected"`) and server LWW-skipped mutation (`status: "applied", skipped: true`) to `instant_record_sync_notices` before deleting the `OutboxMutation`, storing `mutation_id`, `kind` (`"rejected"` or `"conflict"`), `record_type`, `record_id`, `operation`, human-readable `reason`, `attempted_changes`, `server_attributes`, and `server_version`.
- R2. When an incoming non-authoritative server update overwrites a local `pending` row that has no remaining `OutboxMutation` (preventing duplicates when an outbox row will produce a `skipped` conflict), quarantine the overwritten local attributes as a `"conflict"` notice before overwriting.
- R3. Clear `SyncNotice` rows belonging to wiped `types` during `Client.reset` (identity change) so notices never leak across users.
- R4. Provide non-destructive resolution on `InstantRecord::SyncNotice`: `dismiss!` (sets `dismissed_at`), `retry!(overrides = {})` (re-applies attempted local write as a fresh local write so a new outbox mutation is queued, then dismisses), and `fork!(overrides = {})` (creates a new record with a fresh UUID combining server/local base attributes with attempted local changes and overrides, then dismisses).

#### Transport & Events (`ir_notice` / Worker)
- R5. Surface newly recorded sync notices through `InstantRecord::Client.changes_notice` / `ir_notice` without breaking existing `"records_changed"` / `"Type:id"` consumers, and emit an `ActiveSupport::Notifications` event (`"notice.instant_record"`).
- R6. Parse sync notices in `compiled/web/src/changes.js`, expose a `"notices"` bridge entry point (`WasmBridge.notices` / `NativeBridge.notices` / `wasm_notices` / `ir_call("notices", ...)`), broadcast `"instant_record.sync_notices"` from `worker.js`, and dispatch `"instant-record:sync-notices"` from `main.js`.

#### UI Surfaces
- R7. Provide `useSyncNotices` (and a pure diff/store helper) in `frontend/` exported from `frontend/index.js`, supporting list, live updates, `retry`, `fork`, and `dismiss` in both local compiled runtime and server-backed mode.
- R8. Provide a Hotwire partial helper (`instant_record_sync_notices`), ERB partial, and engine controller routes (`GET sync_notices`, `POST sync_notices/:id/retry`, `POST sync_notices/:id/fork`, `POST sync_notices/:id/dismiss`, `DELETE sync_notices/:id`) that work in both CRuby Rails and compiled worker HTTP routing.
- R9. Provide Native SwiftUI notice surfacing in `InstantRecordNative`: `SyncNotice` model, `AppHost.notices` hydrated from `ir_notice` and `"notices"` bridge calls, `retryNotice`/`forkNotice`/`dismissNotice` on `AppHost`, and a non-intrusive banner + review sheet in `AppView` without breaking existing `AppHostTests` expectations.

### Scope Boundaries

- Server-side `MutationApplier` protocol stays backwards-compatible (already returns `reason`, `skipped`, `server_attributes`, `version`).
- Existing `on_discarded_change` hook for remote changes discarded by a newer local row remains unchanged.
- Do not modify `demo/` unless needed; keep gem migrations, compiler seams, `frontend/`, `compiled/web/`, and `native/ios/InstantRecordNative/` fully self-contained and tested.

## Planning Contract

### Key Technical Decisions

- KTD1. **Atomic quarantine & idempotency on `mutation_id`**: Wrap reconciliation, `SyncNotice.record!`, and `mutation.destroy!` in `OutboxMutation.transaction` inside `Client.apply_results`, deduplicating by `mutation_id` when present so crash recovery never creates duplicate notices.
- KTD2. **Line-oriented `sync_notice:<json>` extension to `ir_notice` / `/host/notify`**: Keep `"records_changed"` as the first line and append `"sync_notice:" + JSON.generate(notice.as_notice)` lines only when notices were recorded in that pass. Existing tests asserting `"records_changed"` or `"records_changed\nType:id"` remain byte-for-byte identical when no notices occurred.
- KTD3. **Single `"notices"` bridge entry + `notices=<N>` in `cursor`**: Add `notices` to `EntryBuilder::BRIDGE`, `WasmBuild::REACTOR_EXPORTS`, `reactor_shim.c`, and `native_shim.c` handling `list`/`retry`/`fork`/`dismiss`, and append `notices=<count>` to `cursor` so `AppHost` and `worker.js` only fetch persisted notices on boot when `notices > 0` (preserving existing `AppHostTests` call-sequence assertions).
- KTD4. **Unified Hotwire + React resolution paths**: Mount `InstantRecord::SyncNoticesController` in `config/routes.rb` for CRuby Rails apps and intercept the same `/sync_notices` paths in `compiled/web/src/worker.js` so `<%= instant_record_sync_notices %>` works with plain HTML forms in both runtimes. Export `useSyncNotices` plus pure testable `createSyncNoticesStore` and `diffNotice` from `frontend/notices.js`.
- KTD5. **Spinel AOT safety**: Avoid `to_json` overrides (use `as_notice`), avoid metaprogramming/dynamic `send`, use `self.id = SecureRandom.uuid if id.blank?`, and add `lib/instant_record/sync_notice.rb` (and helper) to `GemVendor::COPY`.

## Implementation Units

### U1. Migration & `InstantRecord::SyncNotice` Model
- **Goal:** Create `instant_record_sync_notices` migration and `InstantRecord::SyncNotice` model with recording, scopes, diffing, `dismiss!`, `retry!`, `fork!`, and `resolve`.
- **Requirements:** R1, R4.
- **Files:** `db/migrate/20261121000001_create_instant_record_sync_notices.rb`, `lib/instant_record/sync_notice.rb`, `lib/instant_record.rb`, `lib/instant_record/compiler/gem_vendor.rb`, `test/test_helper.rb`, `test/compiler_test.rb`.
- **Approach:** Portable SQLite/Postgres migration compatible with `BrowserMigrations`. Implement `SyncNotice` with JSON-serialized `attempted_changes` and `server_attributes`, transactional `retry!` and `fork!` preserving base attributes on updates, and `InstantRecord.sync_notices` convenience accessors.
- **Verification:** `bundle exec rake test TEST=test/sync_notice_test.rb` and `test/compiler_test.rb`.

### U2. Client Quarantine, Reset Cleanup, and `ir_notice` Surfacing
- **Goal:** Record notices in `Client.apply_results` and unqueued inbound LWW overwrites in `upsert_from_server`, clear notices on `Client.reset`, instrument `"notice.instant_record"`, and append `sync_notice:<json>` lines to `changes_notice`.
- **Requirements:** R1, R2, R3, R5.
- **Files:** `lib/instant_record/client.rb`, `test/sync_notice_test.rb`, `test/client_test.rb`, `test/identity_reset_test.rb`, `test/instrumentation_test.rb`.
- **Verification:** `bundle exec rake test`.

### U3. Compiled Bridge, Shims, and Browser Worker Events
- **Goal:** Expose `notices` entry in `EntryBuilder`, `WasmBuild`, `reactor_shim.c`, `native_shim.c`, and `instant_record_native.h`; parse `sync_notice:` in `changes.js`; wire `app-host.js`, `worker.js`, and `main.js` for live `"instant-record:sync-notices"` events, `call("notices", ...)`, and local Hotwire `/sync_notices` form handling.
- **Requirements:** R5, R6, R8.
- **Files:** `lib/instant_record/compiler/entry_builder.rb`, `lib/instant_record/compiler/wasm_build.rb`, `compiled/pipeline/reactor_shim.c`, `compiled/pipeline/native_shim.c`, `compiled/pipeline/native/instant_record_native.h`, `compiled/web/src/changes.js`, `compiled/web/src/changes.test.js`, `compiled/web/src/app-host.js`, `compiled/web/src/worker.js`, `compiled/web/src/main.js`.
- **Verification:** `node --test compiled/web/src/*.test.js` and `bundle exec rake test TEST=test/compiler_test.rb`.

### U4. Frontend React Hook (`useSyncNotices`)
- **Goal:** Implement `frontend/notices.js` (`useSyncNotices`, `createSyncNoticesStore`, `diffNotice`), export from `frontend/index.js`, and add thorough Node unit tests in `frontend/notices.test.js`.
- **Requirements:** R7.
- **Files:** `frontend/notices.js`, `frontend/index.js`, `frontend/notices.test.js`.
- **Verification:** `node --test frontend/*.test.js`.

### U5. Hotwire Partial Helper & Engine Controller
- **Goal:** Add `InstantRecord::SyncNoticesController`, engine routes, `InstantRecord::SyncNoticesHelper` (`instant_record_sync_notices`, `instant_record_notice_diff`), and `app/views/instant_record/sync_notices/_notices.html.erb`, wired into `Engine` and `GemVendor`.
- **Requirements:** R8.
- **Files:** `app/controllers/instant_record/sync_notices_controller.rb`, `app/helpers/instant_record/sync_notices_helper.rb`, `app/views/instant_record/sync_notices/_notices.html.erb`, `config/routes.rb`, `lib/instant_record/engine.rb`, `lib/instant_record/compiler/gem_vendor.rb`, `test/sync_notices_helper_test.rb`.
- **Verification:** `bundle exec rake test`.

### U6. Native SwiftUI Notice Surfacing
- **Goal:** Add `SyncNotice` model, `NoticeSignal` parser, `SyncNoticesSheet` SwiftUI view, `AppHost` notice state and `retryNotice`/`forkNotice`/`dismissNotice` actions, `AppView` banner/sheet integration, and unit tests in `InstantRecordNativeTests`.
- **Requirements:** R9.
- **Files:** `native/ios/InstantRecordNative/Sources/InstantRecordNative/SyncNotice.swift`, `native/ios/InstantRecordNative/Sources/InstantRecordNative/AppHost.swift`, `native/ios/InstantRecordNative/Sources/InstantRecordNative/ScreenView.swift`, `native/ios/InstantRecordNative/Tests/InstantRecordNativeTests/SyncNoticeTests.swift`, `native/ios/InstantRecordNative/Tests/InstantRecordNativeTests/Support.swift`.
- **Verification:** `swift test --package-path native/ios/InstantRecordNative`.

## Verification Contract

- Gem Ruby suite: `bundle exec rake test` (0 failures, 0 errors).
- Frontend & compiled web JS suites: `node --test frontend/*.test.js compiled/web/src/*.test.js` (all passing).
- Native SwiftUI package tests: `swift test --package-path native/ios/InstantRecordNative` (all passing).
- Browser migration compilation verification: verify `BrowserMigrations.plan` compiles `20261121000001_create_instant_record_sync_notices.rb` cleanly.
- If `demo/` is modified: `cd demo && bin/rails test` (all passing).

## Definition of Done

- All requirements R1–R9 implemented and verified by unit/integration tests across Ruby, JavaScript, and Swift.
- No abandoned or dead experimental code left in the diff.
- `git fetch origin && git merge origin/main` integrated cleanly on branch, full verification suites re-run and passing, merged `--no-ff` into `main`, pushed to `origin/main`, and branch deleted locally and on remote per `AGENTS.md`.
