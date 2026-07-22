# Changelog

## Unreleased

- Initial spike: gem skeleton, engine, Syncable concern, sync protocol, demo app.
- Auto-mount the sync engine; models opt in by including `Syncable` (no registration).
- `server_only` / `browser_only` blocks for runtime-scoped model rules.
- `instant_record:install` generator and `instant_record:build` task; opt-in `build_on_precompile`.
- Ruby-owned sync loop: `InstantRecord.configure` / `start` / `sync_now`; transport moved from service-worker JS into Ruby via JS-fetch interop.
