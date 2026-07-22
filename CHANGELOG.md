# Changelog

## Unreleased

- Initial spike: gem skeleton, engine, Syncable concern, sync protocol, demo app.
- Auto-mount the sync engine; models opt in by including `Syncable` (no registration).
- `server_only` / `browser_only` blocks for runtime-scoped model rules.
- `instant_record:install` generator and `instant_record:build` task; opt-in `build_on_precompile`.
- Ruby-owned sync loop: `InstantRecord.configure` / `start` / `sync_now`; transport moved from service-worker JS into Ruby via JS-fetch interop.
- SSE endpoint rewritten as a Rack streaming body (no `ActionController::Live`): no thread per stream, no database connection pinned while idle, query cache bypassed in the poll loop. Falcon documented and measured as the recommended server for SSE-heavy deployments (500 concurrent streams, p50 378ms).
- Browser bundle shrunk 87.2MB -> 61.7MB raw (17.1MB gzipped): `public/` unpacked, mail-family frameworks excluded, wasm-opt strip pass wired into `wasmify:pack`.
- `InstantRecord::RuntimeScoped`: `server_only`/`browser_only` blocks now work on any class (controllers, jobs) via `extend`; Syncable models get them automatically as before. Demo and README show server-only auth/scoping patterns.
