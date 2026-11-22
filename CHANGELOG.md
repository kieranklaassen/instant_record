# Changelog

## 0.3.0 (2026-11-21)

### Sync, Access Control, and Files

- **Record file attachments (`sync_file`).** Declare `sync_file max_size:` on a `Syncable` model so each record carries an immutable file addressed by `(type, id)`. The `frontend/` package (0.3.0) adds `fileStore()` and `useFile`, writing files to the browser's Origin Private File System (OPFS) first (online or offline), uploading in resumable 4 MB chunks in the background, and fetching via `Range` requests on other devices. Authorization follows the record's own `sync_scope` / `syncable_to` / `writable_by` rules, and destroying a record deletes its server file. Files are stored under `storage/instant_record` (`config.file_store`, `config.max_file_size`), and `bin/rails instant_record:files:sweep` removes abandoned partial uploads. Keep model-level `max_size:` under 2 GiB (compiled 32-bit integers); larger limits belong in `config.max_file_size`.
- **Per-client scoping (`sync_scope`) and rule-based authorization (`syncable_to`, `writable_by`).** `sync_scope :column` scopes bootstrap, change stream, and history pages to `InstantRecord.config.scope_from` (plus `NULL` shared rows) and stamps creates server-side. `syncable_to` and `writable_by` accept server-only blocks returning ActiveRecord relations; changes to newly hidden rows stream out as empty destroys so revoked records leave browsers. Bootstrap returns an identity key; when the session identity changes, polls return a `reset` event that drops scoped rows and queued writes and re-bootstraps. Adds a nullable `scope` column to `instant_record_changes` (run `bin/rails db:migrate`). **Changed:** `POST /instant_record/mutations` now returns `415` for non-JSON requests, `GET /bootstrap` is `no-store`, and `InstantRecord.request_scope` is replaced by `InstantRecord::SyncScope.identity`.
- **Structured change notices.** `instant-record:records-changed` now includes `detail.changes` (`[{ type, id }]` up to 200 records) when the sync pass can enumerate changed rows, or `null` after bootstrap, eviction, acked writes, or cross-tab updates.
- **Instrumentation (`ActiveSupport::Notifications`).** `InstantRecord::Client` instruments `bootstrap`, `drain` (with rejection counts and reasons), `poll`, `stream`, `fetch_history`, `reset`, and `offline` as `<event>.instant_record`.
- **SSE idle heartbeats and quiet disconnects.** `GET /events` emits `: hb` comments after `config.instant_record.sse_heartbeat_seconds` (default 15s) to keep reverse proxies from closing idle streams and detect dead peers cleanly without backtrace spam. Documented `config.instant_record.sse_window_seconds` sizing for Puma (25s default) vs Falcon (fiber-per-stream, e.g. 600s).

### Pure-Ruby Compiler and Consumer App Readiness

- **Pure-Ruby build pipeline.** Replaced all Python compiler scripts with in-process Ruby classes under `InstantRecord::Compiler` (`WasmBuild`, `NativeBuild`, `GemVendor`, `EntryBuilder`, `WasmTree`, `BrowserMigrations`, `Toolchain`, `PathScrubber`, `SourcePages`, `Runner`). Added `bin/rails instant_record:doctor` (and `bundle exec rake compile:doctor`) to validate toolchain paths before building.
- **Consumer-app compiler parity.**
  - `GemVendor` now strips `server_only` and unwraps `browser_only` / `client_only` blocks across `app/models`, `app/controllers`, `app/helpers`, and `app/screens` (previously model and helper `browser_only` blocks were silently dropped).
  - `EntryBuilder` and `instant_record:compile` / `instant_record:native` now preserve every consumer model's declared `sync_window` and initialize `InstantRecord.config.endpoint` and `mount_path` at boot.
  - `InstantRecord.server_url(path)` now works in compiled consumer apps with default or custom `mount_path` and preserves existing query strings (`?` vs `&`).
  - `compiled/web/src/worker.js` forwards any safe same-origin `instant_record_network=1` path for consumer apps (preserving request and response `Content-Type` and honoring custom `mount_path`) instead of restricting to demo-only routes, and `compiled/web/src/main.js` passes `/service-worker.js`, `/instant-record-release.json`, and same-origin sync/file paths straight to the network.
  - `InstantRecord::CompiledSite` serves `/service-worker.js` with `cache-control: no-cache` when present in the published build.
- **Onboarding and packaging.**
  - `bin/rails generate instant_record:install` now generates both `config/instant_record_toolchain.env` and a commented `config/initializers/instant_record.rb` starter, with clearer next steps.
  - `bin/rails instant_record:compile` checks toolchain presence up front and aborts cleanly on build errors; missing `WEB_NODE_MODULES` reports actionable setup instructions.
  - Cleaned up `instant_record.gemspec` (zero RubyGems warnings, excluded demo overlays and JS tests, aligned gem version `0.3.0` with `frontend/package.json`).
- **Faster first visits.** Preloads external stylesheets from app layouts (`WasmBuild#outside_stylesheets`), warms app scripts while Wasm compiles (`WasmBuild#warm_scripts`), and fetches the initial bootstrap in parallel with Wasm compilation (`earlyBootstrap` in `compiled/web/src/worker.js`).

### Inertia & React (`frontend/` 0.3.0)

- Added `InstantRecord::Inertia` (`render inertia: "Page", live: { mail: MailEntry }`) when `inertia_rails` is present.
- Expanded the `frontend/` npm package (`npm install "$(bundle show instant_record)/frontend"`) with `instantRecord()`, `localHttpClient`, `liveTransport`, `LiveList`, `useLiveWindow`, `useLiveParam`, `useLiveSearch`, `useHistory`, `useStableRows`, `useKeyboardNavigation`, `useShortcuts` (`chord`, `match`, `keycaps`), `useSelection`, `useUndoable`, `write`, `fileStore`, and `useFile`.

### Native iOS Screens (Experimental)

- Added `InstantRecord::Native::Screen` DSL (`navigation`, `list`, `section`, `row`, `stack`, `spacer`, `text`, `date`, `image`, `button`, `swipe`, `toolbar`, `bottom`, `field`, `more`, `swift` custom views, and menu `link:` / `replace:` / `sheet:`), shipped RBS types (`sig/instant_record/native.rbs`), and added `client_only` as an alias for `browser_only`.
- Added `bin/rails "instant_record:native[iphonesimulator|iphoneos]"` to build static libraries, `bin/rails generate instant_record:ios Name --screen first` to scaffold a thin Xcode project (`InstantRecord::Native::XcodeProject` with `packages:`), and `config.instant_record.native_dev = true` for rebuild-free local screen iteration over HTTP.
- Added the `native/ios/InstantRecordNative` SwiftUI package (zero external dependencies) with off-main-thread sync, SSE event streaming, `Theme` styling, and instant multi-database switching via `ir_open`.

### Demo

- Added the Auth demo (`/auth`) exercising real Rails sessions, `syncable_to` / `writable_by`, and identity reset; the Assistant demo (`/assistant`) with `sync_scope :visitor_id`, server RubyLLM replies, and on-device Chrome Prompt API replies; and the Inertia React Inbox (`/email`) with background history fill, local + server-widened search, bulk selection, undoable archive, optional shell snapshot (`?shell=1`), and PWA app-shell service worker caching.
- Built the experimental iPhone Inbox app (`native/ios/Inbox`) with Cora theming, instant inbox switching, and a feedback sheet.

## 0.2.0

Roundhouse and Spinel now provide the gem’s sole browser runtime. The generated app runs against SQLite. The install generator writes the compiler configuration, and both `instant_record:compile` and `instant_record:build` build the compiled site.

For apps upgrading from the former ruby.wasm/PGlite backend, sync pending writes before switching. The compiled runtime bootstraps SQLite from Rails. It does not import an old PGlite database. Existing compiled SQLite profiles continue to use their saved rows and outbox.

## 0.1.0

First release. Real Active Record models running in the browser on ruby.wasm
and PGlite, writing optimistically through a durable outbox that syncs to a
Rails + Postgres server.

- Browser-runtime migrations: `InstantRecord.prepare_database!` brings a returning visitor's local database up to the app's current schema. `DatabaseTasks.prepare_all` alone cannot — the browser VM's working directory is `/`, so ActiveRecord's relative `db/migrate` resolves to nothing and the migrator silently reports zero pending. `InstantRecord::LocalSchema` reconciles `schema_migrations` by the rule `assume_migrated_upto_version` would have used, then migrates only what is genuinely newer. Ships `instant_record/pglite_compat`, without which no in-browser migration could run at all (Rails' PostgreSQL statement pool asks the PGlite connection for a `status` it does not define, and DDL clears the pool).
- Microsecond timestamps on every wire path, in both directions, via `InstantRecord.wire_attributes`. The change log and outbox previously serialized through ActiveSupport's JSON encoder (milliseconds) while bootstrap and records kept all six places; the mismatch lost `(created_at, id)` keyset neighbours between history pages and biased last-write-wins against whichever side was rounded.
- Writes that lose last-write-wins are no longer badged as delivered: the server returns the row that won, the client reconciles to it, and `on_discarded_change` lets a model observe what was thrown away. A client running ahead of the server's schema now gets a rejection rather than jamming the outbox behind a mutation that would retry forever.
- `InstantRecord.server_url` for app paths that must reach the authoritative server from either runtime.
- Windowed sync: `sync_window limit:, partition_by:` on Syncable models bounds what syncs — fresh clients hydrate from `GET /bootstrap` (windowed snapshot + cursor) instead of replaying the whole change log, a cold boot evicts windowed models back to their window (pending rows never evicted), and older rows page in through `GET /records` keyset cursors via `InstantRecord.fetch_history` (local-first, idempotent, no outbox noise). The service worker gains an `instant_record.fetch_history` page message sharing the tick's single-flight guard.
- Swiss Slack demo: thousands of seeded history messages (unlogged `insert_all` backfill, preserved across resets), windowed conversation rendering with scroll-up pagination, and in-place DOM morphing on sync — no more full-page reload on the conversation view.
- Demo pages that let a visitor check the claims rather than take them on trust: `/console` (a REPL against whichever runtime served the page — the eval action is defined inside `browser_only`, so it does not exist on the server), `/source` (each page's own source, read off disk by the runtime that rendered it), `/receipts` (bundle size and query latency measured on the visitor's device, local and server side by side), and `/migrate` (shipping a v2 migration on demand against a local database that still holds rows and a full outbox).
- Initial spike: gem skeleton, engine, Syncable concern, sync protocol, demo app.
- Auto-mount the sync engine; models opt in by including `Syncable` (no registration).
- `server_only` / `browser_only` blocks for runtime-scoped model rules.
- `instant_record:install` generator and `instant_record:build` task; opt-in `build_on_precompile`.
- Ruby-owned sync loop: `InstantRecord.configure` / `start` / `sync_now`; transport moved from service-worker JS into Ruby via JS-fetch interop.
- SSE endpoint rewritten as a Rack streaming body (no `ActionController::Live`): no thread per stream, no database connection pinned while idle, query cache bypassed in the poll loop. Falcon documented and measured as the recommended server for SSE-heavy deployments (500 concurrent streams, p50 378ms).
- Browser bundle shrunk 87.2MB -> 61.7MB raw (17.1MB gzipped): `public/` unpacked, mail-family frameworks excluded, wasm-opt strip pass wired into `wasmify:pack`.
- `InstantRecord::RuntimeScoped`: `server_only`/`browser_only` blocks now work on any class (controllers, jobs) via `extend`; Syncable models get them automatically as before. Demo and README show server-only auth/scoping patterns.
- Review-driven simplification pass: sync loop consolidated into `InstantRecord::Client` (hash-native, no intra-VM JSON round-trips); fixed tick starvation — change polls now request `window=0` so a tick never holds the server's SSE tail window; cursor persisted once per poll; `MutationApplier` extracted from the mutations controller; `Change.poll` owns the connection-scoped uncached read; shared CORS/mount-path constants; SSE window configurable (`config.instant_record.sse_window_seconds`) with ±10% reconnect jitter; service worker template is single-source (demo copies via `rake pwa:sync`); gem tests run standalone and share helpers.
