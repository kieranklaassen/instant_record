# Changelog

## Unreleased

- Windowed sync: `sync_window limit:, partition_by:` on Syncable models bounds what syncs — fresh clients hydrate from `GET /bootstrap` (windowed snapshot + cursor) instead of replaying the whole change log, a cold boot evicts windowed models back to their window (pending rows never evicted), and older rows page in through `GET /records` keyset cursors via `InstantRecord.fetch_history` (local-first, idempotent, no outbox noise). The service worker gains an `instant_record.fetch_history` page message sharing the tick's single-flight guard.
- Swiss Slack demo: thousands of seeded history messages (unlogged `insert_all` backfill, preserved across resets), windowed conversation rendering with scroll-up pagination, and in-place DOM morphing on sync — no more full-page reload on the conversation view.

- Initial spike: gem skeleton, engine, Syncable concern, sync protocol, demo app.
- Auto-mount the sync engine; models opt in by including `Syncable` (no registration).
- `server_only` / `browser_only` blocks for runtime-scoped model rules.
- `instant_record:install` generator and `instant_record:build` task; opt-in `build_on_precompile`.
- Ruby-owned sync loop: `InstantRecord.configure` / `start` / `sync_now`; transport moved from service-worker JS into Ruby via JS-fetch interop.
- SSE endpoint rewritten as a Rack streaming body (no `ActionController::Live`): no thread per stream, no database connection pinned while idle, query cache bypassed in the poll loop. Falcon documented and measured as the recommended server for SSE-heavy deployments (500 concurrent streams, p50 378ms).
- Browser bundle shrunk 87.2MB -> 61.7MB raw (17.1MB gzipped): `public/` unpacked, mail-family frameworks excluded, wasm-opt strip pass wired into `wasmify:pack`.
- `InstantRecord::RuntimeScoped`: `server_only`/`browser_only` blocks now work on any class (controllers, jobs) via `extend`; Syncable models get them automatically as before. Demo and README show server-only auth/scoping patterns.
- Review-driven simplification pass: sync loop consolidated into `InstantRecord::Client` (hash-native, no intra-VM JSON round-trips); fixed tick starvation — change polls now request `window=0` so a tick never holds the server's SSE tail window; cursor persisted once per poll; `MutationApplier` extracted from the mutations controller; `Change.poll` owns the connection-scoped uncached read; shared CORS/mount-path constants; SSE window configurable (`config.instant_record.sse_window_seconds`) with ±10% reconnect jitter; service worker template is single-source (demo copies via `rake pwa:sync`); gem tests run standalone and share helpers.
