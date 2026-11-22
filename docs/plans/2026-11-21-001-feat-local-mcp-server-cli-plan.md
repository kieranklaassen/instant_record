---
title: "Local MCP stdio server and offline CLI for compiled native host"
date: 2026-11-21
status: ready
branch: feat/local-mcp-server-cli
---

# Local MCP stdio server and offline CLI (`rails instant_record:mcp`)

## Goal

Package the screenless native `host` binary already compiled by `InstantRecord::Compiler::NativeBuild` (`lib/instant_record/compiler/native_build.rb`) as a drop-in local MCP stdio server and offline CLI (`rails instant_record:mcp` and `exe/instant_record_mcp`). It syncs a scoped local SQLite replica with a Rails server using configurable token/session/cookie/header auth and exposes synced model queries, search, and validated local actions as `<1ms` offline MCP tools, verified with tests against the demo app.

## Architecture

### Components

1. **`InstantRecord::Mcp::HostProcess`** (`lib/instant_record/mcp/host_process.rb`)
   - Manages one persistent child process of the compiled native `host` binary (`compiled/pipeline/native/host.c`) over binary pipes (`Open3.popen3`, `binmode`, background stderr drain).
   - Serializes every call with a `Mutex` matching the single-threaded C ABI in `compiled/pipeline/native/instant_record_native.h`.
   - Speaks the exact byte-counted stdio framing (`boot`, `open`, `call <entry> <bytes>`, `ok <out> <notice>`, `error <bytes>`, `exchange <bytes>`).
   - Routes inline `exchange` network requests during `sync` to an injectable exchange callable (`HttpExchange` in production, Rack/stub in tests).

2. **`InstantRecord::Mcp::HttpExchange`** (`lib/instant_record/mcp/http_exchange.rb`)
   - Translates `"METHOD URL\nBODY"` into `Net::HTTP` requests and returns `"STATUS\nBODY"` or `"0\n"` when offline/unreachable.
   - Supports configurable auth and scoping:
     - `token:` -> `Authorization: Bearer <token>`
     - `cookie:` -> `Cookie: <cookie>` (plus optional cookie persistence from `Set-Cookie` headers)
     - `headers:` -> arbitrary HTTP headers
     - `scope:` -> appends `scope=<value>` query param when absent (matching `InstantRecord.config.scope_from`)
     - `offline:` -> immediately returns `"0\n"` without network I/O
     - `timeout:` -> open/read timeout (default 10s)
   - Records per-pass HTTP status/error telemetry so `sync` reports auth failures (401/403) and offline states cleanly.

3. **`InstantRecord::Mcp::Replica`** (`lib/instant_record/mcp/replica.rb`)
   - Read-only `SQLite3::Database` interface (`readonly: true`, `busy_timeout = 5000`) over the native host's local SQLite replica for `<1ms` offline queries, search, schema introspection, and outbox inspection.
   - Discovers synced models from explicit `models:` allowlist, `instant_record_sync_metadata` (`compiled_models`), or non-internal SQLite tables.
   - Validates every model/table and column identifier against `PRAGMA table_info` before generating parameterized SQL (zero SQL injection).
   - Supports `models`, `query` (equality, `nil`, `IN`, comparison operators `ne`/`gt`/`gte`/`lt`/`lte`/`like`/`not_null`, validated `order`, `limit`/`offset`, column projection), `find`, `search` (case-insensitive multi-term `LIKE ... ESCAPE '\'` across text columns), `outbox`, and `reopen`.

4. **`InstantRecord::Mcp::Runtime`** (`lib/instant_record/mcp/runtime.rb`)
   - Coordinates `HostProcess`, `HttpExchange`, and `Replica` under a single mutex.
   - Exposes: `status`, `sync`, `list_models`, `query_records`, `get_record`, `search_records`, `outbox`, `render_screen`, `perform_action`, `app_request`, `fetch_history`, `open_database`, `close`.
   - All offline reads, screen renders, screen actions, and compiled Rails controller requests run locally in `<1ms` with full model validations and atomic outbox recording.

5. **`InstantRecord::Mcp::Server`** (`lib/instant_record/mcp/server.rb`)
   - Spec-compliant MCP JSON-RPC 2.0 stdio server (newline-delimited JSON on stdin/stdout; diagnostics strictly on stderr).
   - Handles `initialize`, `notifications/initialized`, `notifications/cancelled`, `ping`, `tools/list`, `tools/call`, `resources/list`, `resources/read`.
   - Exposes 11 tools: `instant_record_status`, `instant_record_sync`, `instant_record_models`, `instant_record_query`, `instant_record_get`, `instant_record_search`, `instant_record_outbox`, `instant_record_render_screen`, `instant_record_action`, `instant_record_request`, `instant_record_history`.
   - Exposes MCP resources: `instant-record://status`, `instant-record://models`, `instant-record://outbox`, and `instant-record://models/<ModelName>`.

6. **`InstantRecord::Mcp::Cli`** (`lib/instant_record/mcp/cli.rb`), **`exe/instant_record_mcp`**, and **`rails instant_record:mcp`** (`lib/tasks/instant_record.rake`)
   - CLI wrapper supporting `serve` (default), `sync`, `status`, `models`, `query`, `get`, `search`, `outbox`, `render`, `action`, `request`, `history`.
   - Configurable via CLI flags and `INSTANT_RECORD_*` environment variables.
   - `rails instant_record:mcp` discovers the compiled native `host` binary (optionally building via `Compiler.build_native(..., out: $stderr)` when `--build` / `INSTANT_RECORD_BUILD=1`), discovers Rails syncable models and screens, and launches the MCP stdio server or offline CLI subcommand.

7. **Compiler & Packaging Updates**
   - Forward optional `out: $stdout` in `InstantRecord::Compiler.build_native` and `build_demo_native` so MCP auto-build writes compiler output to `$stderr`.
   - Add `exe/instant_record_mcp` to `instant_record.gemspec`.
   - Document `rails instant_record:mcp` and CLI usage in `README.md`.

## Verification Plan

1. **Gem tests (`bundle exec rake test`)**:
   - `test/mcp_host_process_test.rb`: framing protocol, UTF-8 byte lengths, `exchange` callbacks, `open`/`boot`, error handling, crash recovery.
   - `test/mcp_http_exchange_test.rb`: Bearer token auth, Cookie auth, custom headers, `scope` query param injection, offline mode, network error handling, POST JSON headers.
   - `test/mcp_replica_test.rb`: model discovery (`compiled_models` + fallback), filtered queries & operators, SQL injection guards, single record lookup, multi-term/multi-column search with LIKE wildcard escaping, outbox reading, `<1ms` latency assertion.
   - `test/mcp_server_cli_test.rb`: MCP JSON-RPC 2.0 lifecycle (`initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`, `resources/list`, `resources/read`, parse/method/tool error handling) and CLI subcommands (`serve`, `sync`, `status`, `models`, `query`, `get`, `search`, `outbox`, `render`, `action`, `request`, `history`).
2. **Demo app tests (`cd demo && bin/rails test`)**:
   - `demo/test/integration/mcp_server_test.rb`:
     - End-to-end tests against the demo app's real sync endpoints (`/email/sync/maya/support` with Bearer token auth and unauthorized rejection, `/instant_record` with session cookie auth for `AuthNote` and `scope` scoping for `AssistantChat`, plus `Issue`/`Note` sync).
     - Full MCP stdio JSON-RPC round-trip: `sync`, `<1ms` offline `query` and `search`, validated local `action` (`MailboxScreen` archive / `ThreadScreen` reply) and `request` (`POST /todo/issues` valid + validation rejection), offline persistence & reconnect drain to server.
     - Real compiled native `host` binary integration test (runs automatically when `INSTANT_RECORD_NATIVE_HOST` or `INSTANT_RECORD_TOOLCHAIN` is present, and verified locally with the installed Spinel/Roundhouse toolchain!).
3. **Final Git Workflow (`AGENTS.md`)**:
   - Merge `origin/main` into `feat/local-mcp-server-cli`, re-run `bundle exec rake test` and `cd demo && bin/rails test`.
   - Merge `--no-ff` into `main` and push `main`.
   - Delete branch locally (and remotely if pushed).
