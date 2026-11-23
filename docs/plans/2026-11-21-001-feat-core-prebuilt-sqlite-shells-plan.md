---
title: "feat: Extract InstantRecord::Shell engine primitive for browser and iOS cold starts"
type: feat
status: ready
date: 2026-11-21
---

# Extract `InstantRecord::Shell` Engine Primitive for Browser and Native iOS

## Goal

Promote the Inbox demo's cold-start SQLite snapshot mechanism (`MailShell` + `Email::ShellBuildJob` + `fetchShell`) into a first-class, model-agnostic `InstantRecord::Shell` engine primitive with:
1. Model-agnostic SQLite shell generation reusing `InstantRecord::Compiler::BrowserMigrations` DDL, `InstantRecord::SyncScope.visible`, and `InstantRecord::SyncWindow`, stamped with `SyncMetadata["cursor"]`, `"identity"`, `"compiled_models"`, `"shell_fingerprint"`, and `"schema_version"`.
2. Authenticated, HMAC-signed `/instant_record/shell` and `/instant_record/shell/file` delivery partitioned per `SyncScope` identity + scope token, with `Cache-Control: private, no-store` and `Vary: Authorization, Cookie` so private shells never leak to unauthenticated callers or shared caches.
3. Generic `fetchShell` in `compiled/web/src/worker.js` usable by every compiled app (not gated on Inbox `mailboxScope`), with scoped file downloads and cursor + identity validation.
4. Native iOS cold-start shell hydration via `ir_open` (`Engine.open(database:)`) in `InstantRecordNative`'s `AppHost.swift`, using the build's compile-time `shell_fingerprint` from `NativeBridge.sync_plan` and binary `Transport.download`.
5. Migration of the Inbox demo onto `InstantRecord::Shell` + `InstantRecord::ShellBuildJob`, removing `demo/app/models/mail_shell.rb`, `demo/app/jobs/email/shell_build_job.rb`, and their carve exclusions from `DemoCarver::REMOVE`.

## Key Technical Decisions

- **KTD1. Single fingerprint contract across server, Wasm, and Native iOS.**
  `InstantRecord::Shell::FORMAT = 1` and `InstantRecord::Shell.fingerprint(models:, schema:, schema_path:)` are the single source of truth. `WasmBuild` and `NativeBuild` compute the fingerprint through `InstantRecord::Shell.fingerprint` (removing duplicate `WasmBuild::SHELL_FORMAT`), injecting it into `VITE_SHELL_FINGERPRINT` for Wasm and `sync_plan` (`"fingerprint"`) for both Wasm and Native bridges.
- **KTD2. Reuse `BrowserMigrations` DDL with schema-version stamping.**
  Add `InstantRecord::Compiler::BrowserMigrations.schema_ddl(root:, migration_paths: nil)` which compiles all migrations (no baseline skip) into ordered SQLite DDL plus `version`. `InstantRecord::Shell` executes those statements inside the draft SQLite file and writes `SyncMetadata["schema_version"] = format("%020d", version)` so Native iOS `ir_open` skips already-applied migrations cleanly. When `db/schema.rb` or portable migrations are unavailable (e.g., plain ActiveRecord gem unit tests), fall back cleanly to ActiveRecord connection introspection.
- **KTD3. Per-user `SyncScope` isolation on disk and on the wire.**
  A shell's disk partition key hashes both `SyncScope.key(identity)` and `SyncScope.token(identity)` (`SHA256("#{key}\0#{token}")[0, 24]`), so callers with distinct `sync_scope` tokens or distinct `syncable_to` identities never share a shell file (critical for multi-dimensional identities like `DemoAsker`). Signed download URLs bind `partition`, `holder`, and `file` with `ActiveSupport::MessageVerifier` (`purpose: :instant_record_shell`, `expires_in: 5.minutes`), and `/instant_record/shell/file` re-checks the live `SyncScope.identity(request)` on download. Both `/shell` and `/shell/file` return `Cache-Control: private, no-store` and `Vary: Authorization, Cookie`.
- **KTD4. Safe async building for arbitrary `scope_from` identities and custom sources.**
  `InstantRecord::ShellBuildJob` rebuilds either default engine shells (serializing `nil`, `String`, `Integer`, GlobalID ActiveRecord models natively, or custom objects via optional `Shell.identity_serializer` / `Shell.identity_deserializer`) or registered custom sources (`Shell.register(:mailbox) { |id| ... }`). Unserializable custom identities never crash `ShellsController` with `ActiveJob::SerializationError`. Fingerprint mismatches return `204 No Content` before enqueueing any job.
- **KTD5. Binary shell download and `ir_open` hydration on iOS.**
  `Transport.download(_ urlString: String)` fetches raw `Data` using `prepare(&request)` (preserving `Authorization` headers) and `.reloadIgnoringLocalCacheData`, avoiding UTF-8 corruption. On a fresh database (`bootstrap == true`, `push.isEmpty`, non-empty `fingerprint`), `AppHost` fetches `/shell?fingerprint=...`, downloads the binary SQLite file to a staging path, validates the 16-byte `"SQLite format 3\0"` header, opens it with `engine.open(database: stagingPath)` (`ir_open`), validates `bootstrap == "ready"`, `cursor`, and `identity`, atomically promotes it to `store.database` and re-opens `store.database`, draws screens immediately, and triggers catch-up sync from the shell's cursor. Any failure rolls back cleanly and falls through to `/bootstrap`.

## Implementation Units

### Unit 1: `BrowserMigrations.schema_ddl` + `InstantRecord::Shell` + `InstantRecord::ShellBuildJob`
- **Files:**
  - `lib/instant_record/compiler/browser_migrations.rb`: add `BrowserMigrations.schema_ddl(root:, migration_paths: nil)` returning `{ version:, statements: }`.
  - `lib/instant_record/shell.rb`: new server-only `InstantRecord::Shell` class (constants, `fingerprint`, `partition_key`, `latest`, `build`, `build_source`, `register`, `snapshot`, `find_signed`, `valid_sqlite?`, `serializable_identity?`, `dump_identity`, `load_identity`, instance methods `built_at`, `bytes`, `stale?`, `servable?`, `signed_token`).
  - `app/jobs/instant_record/shell_build_job.rb`: `InstantRecord::ShellBuildJob < ActiveJob::Base`.
  - `lib/instant_record/engine.rb`: require `instant_record/shell`, add `config.instant_record.shell_snapshot = nil`.
  - `lib/tasks/instant_record.rake`: pass `shell_snapshot:` when configured, add `instant_record:shell:build` rake task if helpful.

### Unit 2: `/instant_record/shell` and `/instant_record/shell/file` Delivery
- **Files:**
  - `config/routes.rb`: add `get "shell"`, `get "shell/file"`, and `options` preflight routes.
  - `app/controllers/instant_record/shells_controller.rb`: `ShellsController < ActionController::API` serving grants and signed SQLite files with strict per-user `SyncScope` enforcement and `Cache-Control: private, no-store`, `Vary: Authorization, Cookie`, `X-Content-Type-Options: nosniff`.

### Unit 3: Compiler Fingerprint Integration + Generic Browser `fetchShell`
- **Files:**
  - `lib/instant_record/compiler.rb`: accept `shell_snapshot: nil` in `Compiler.build`.
  - `lib/instant_record/compiler/wasm_build.rb`: delegate `SHELL_FORMAT` and fingerprint computation to `InstantRecord::Shell`; return `shell_fingerprint` from `emit_tree`.
  - `lib/instant_record/compiler/entry_builder.rb`: pass `shell_fingerprint:` into `write_wasm_entry` and `write_native_entry`, emitting `fingerprint` in `sync_plan`.
  - `lib/instant_record/compiler/native_build.rb`: forward `emitted[:shell_fingerprint]` to `EntryBuilder.write_native_entry`.
  - `lib/instant_record/compiler/app_stage.rb`: remove `"app/models/mail_shell.rb"` and `"app/jobs/email/shell_build_job.rb"` from `DemoCarver::REMOVE`.
  - `compiled/web/src/shell.js` + `compiled/web/src/shell.test.js`: pure helpers for shell request gating, grant validation, SQLite header check, and cursor/identity validation.
  - `compiled/web/src/worker.js`: make `fetchShell` model/scope-agnostic (remove `!scope` gate), pass `scope=` to `/shell/file`, validate 16-byte SQLite header + grant `path` prefix + cursor + identity.

### Unit 4: Native iOS `ir_open` Shell Hydration
- **Files:**
  - `native/ios/InstantRecordNative/Sources/InstantRecordNative/Transport.swift`: add binary `download(_ urlString: String) -> (status: Int, data: Data)?` using `prepare(&request)` and `.reloadIgnoringLocalCacheData`.
  - `native/ios/InstantRecordNative/Sources/InstantRecordNative/AppHost.swift`: wire cold-start shell fetch + `SQLite format 3\0` validation + staging + `engine.open(database:)` (`ir_open`) + cursor/identity check + atomic promotion + catch-up poll, with transparent fallback to `/bootstrap` on any miss/error; add injectable `download` seam for tests.
  - `native/ios/InstantRecordNative/Tests/InstantRecordNativeTests/Support.swift` & `AppHostTests.swift`: add tests for iOS shell hydration happy path (fresh boot and `replace`), catch-up events after shell cursor, fallback on 204 / bad magic bytes / cursor mismatch / identity mismatch / `open` failure, and skipping shell when pending local mutations exist.

### Unit 5: Migrate Inbox Demo onto `InstantRecord::Shell`
- **Files:**
  - Delete `demo/app/models/mail_shell.rb` and `demo/app/jobs/email/shell_build_job.rb`.
  - `demo/config/initializers/instant_record.rb`: configure `InstantRecord::Shell.models`, `identity_serializer`/`deserializer`, and `register(:mailbox)`.
  - `demo/app/controllers/email/sync_controller.rb`: use `InstantRecord::Shell` and `InstantRecord::ShellBuildJob`, with `Cache-Control: private, no-store` and `Vary: Authorization, Cookie`.
  - `demo/script/mail_shell_first_load.rb`: update comments/usage to `InstantRecord::Shell`.
  - `demo/test/controllers/email/shell_test.rb`: update to `InstantRecord::Shell` and `InstantRecord::ShellBuildJob`.
  - `demo/test/controllers/instant_record/shells_controller_test.rb`: new comprehensive integration tests for `/instant_record/shell` and `/instant_record/shell/file` covering `SyncScope` isolation (`AuthNote`, `AssistantChat`), `SyncWindow` (`Message`), signed tokens, expiry, cross-user refusal, cache headers, and `BrowserMigrations` DDL.
  - `test/shell_test.rb`: new gem unit tests for `InstantRecord::Shell` and `BrowserMigrations.schema_ddl`.

## Verification Plan

1. `bundle exec rake test` (all gem unit tests including new `test/shell_test.rb` and `test/compiler_test.rb`).
2. `cd demo && PGPORT=5433 bin/rails test` (all demo Rails integration tests including updated `test/controllers/email/shell_test.rb` and new `test/controllers/instant_record/shells_controller_test.rb`).
3. `node --test compiled/web/src/*.test.js` (including new `compiled/web/src/shell.test.js`).
4. `cd native/ios/InstantRecordNative && swift test` (all Swift package tests including new iOS shell `ir_open` hydration tests).
5. Code simplification + self-review pass, then `AGENTS.md` workflow: merge `origin/main` into branch, re-run required tests, merge `--no-ff` into `main`, push `main`, delete branch.
