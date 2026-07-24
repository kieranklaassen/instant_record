# Changelog

## Unreleased

- SSE idle heartbeat: `GET /events` writes a comment (`: hb`) after `config.instant_record.sse_heartbeat_seconds` (default 15) of quiet. Keeps reverse proxies from reaping "idle" streams, and turns a vanished client into an `EPIPE` within one interval instead of a fiber held to the end of the window. Client hang-ups now end the stream quietly instead of logging a backtrace per departed visitor. Comments are invisible to clients — EventSource ignores them by spec and the gem's parser skips them.
- Documented the window/server relationship: the 25s `sse_window_seconds` default is Puma sizing (a stream holds a thread); under Falcon streams are fibers and minutes-long windows are the norm (Mercure defaults to 600s). The demo reads `INSTANT_RECORD_SSE_WINDOW_SECONDS` so a deployment can raise it without code changes.

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
