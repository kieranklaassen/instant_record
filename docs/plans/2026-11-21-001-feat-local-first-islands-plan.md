---
title: Local-First Islands Incremental Compilation - Plan
type: feat
date: 2026-11-21
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Local-First Islands Incremental Compilation - Plan

## Goal Capsule

- **Objective:** Enable existing Rails monoliths to compile a single local-first route subtree ("island") instead of all of `app/`, retiring the hardcoded 21-entry `DemoCarver::REMOVE` denylist, `DEMO_ROUTES`, `DEMO_MODELS`, and hardcoded sync windows/server routes by dogfooding the exact same `AppStage` + manifest pipeline on `demo/`.
- **Means:** Add a `local_first` Rails route DSL + optional declarative `config/instant_record.yml` overrides, a Prism route analyzer and transitive reachability tracer (controllers, models, views/partials, helpers, migrations, native screens) with crisp missing-symbol diagnostics, a canonical `instant_record.manifest.json` consumed by `EntryBuilder`, `worker.js`, and `main.js`, and unify `WasmBuild`/`NativeBuild` so `demo/` stages through `AppStage`.
- **Authority hierarchy:** `AGENTS.md` (no PRs; branch, merge `origin/main`, test gem + demo, merge `--no-ff` into `main`, push `main`, delete branch; stop if tests fail or conflict) > user request > Product Contract (R-IDs) > Planning Contract (KTD-IDs) > Implementation Units (U-IDs).
- **Stop conditions:** Any gem or demo test failure, any unresolvable merge conflict with `origin/main`, or inability to run required tests before merging to `main` (per `AGENTS.md`).
- **Execution profile:** Single branch (`feat/local-first-islands`), shipped via `AGENTS.md` merge-to-main workflow (no PR).

## Product Contract

### Summary

Rails monoliths cannot adopt local-first compilation if the compiler blindly copies all of `app/`, runs every migration in `db/migrate/`, and relies on hand-maintained denylists. This feature introduces declarative **Local-First Islands**: developers mark the route subtree(s) they want compiled with `local_first do ... end` in `config/routes.rb` (or `config/routes/*.rb`), optionally declare include overrides for dynamic Ruby patterns (STI subclasses, computed partials, extra helpers/files/migrations), and the compiler statically traces only reachable controllers, models, views, helpers, and migrations using Prism. The compiler emits a canonical `instant_record.manifest.json` describing synced models, `sync_window`, `sync_scope`, local routes, and server routes, which drives `EntryBuilder`, `worker.js`, and `main.js`. The `demo/` app dogfoods this exact path, retiring `DemoCarver::REMOVE`, `DEMO_ROUTES`, `DEMO_MODELS`, hardcoded `Message.sync_window`, and hardcoded demo server routes in `worker.js`.

### Requirements

#### Route DSL & Declarative Config
- R1. Provide `local_first(name = nil, include: nil, server_routes: nil, &block)` on `ActionDispatch::Routing::Mapper` (loaded via `InstantRecord::Engine` and requirable standalone). On the Rails server it yields transparently without altering URL generation or route matching.
- R2. Support optional declarative configuration via `config/instant_record.yml` and `config.instant_record.island` / `config.instant_record.include` (and `island:` / `overrides:` options on `InstantRecord::Compiler.build` / `build_native`) for explicit include overrides (`models`, `controllers`, `views`, `partials`, `helpers`, `migrations`, `files`) and dual-runtime `server_routes`.

#### Prism Route Analysis & Reachability Tracing
- R3. Parse `config/routes.rb` and recursively `draw(:subfile)` files under `config/routes/` using Prism without booting Rails or executing app Ruby. Partition routes into `local_routes` (inside `local_first` blocks, optionally filtered by `island:` name) and `server_routes` (outside `local_first` blocks, plus explicit `server_routes` overrides). Emit a clean rewritten `config/routes.rb` containing only the local-first route subtrees when `local_first` blocks exist.
- R4. Trace transitive reachability from local-first routes using Prism (plus Erubi for `.erb` templates), strictly skipping `server_only do ... end` blocks while traversing `browser_only`/`client_only` blocks:
  - Route controllers -> action views, explicit `render` templates/partials/layouts, controller/namespace/referenced helpers, `include`/`extend`/`prepend` concerns, superclasses, and referenced models.
  - Models -> associations (`belongs_to`, `has_many`, `has_one`, `has_and_belongs_to_many` with `class_name:`), superclasses, concerns, and constant references.
  - Views/partials -> nested `render` partials/templates, referenced constants, and called helper methods.
  - Native screens (`app/screens/**/*.rb`) when `native: true`.
  - Migrations (`db/migrate/*.rb`) filtered to those touching reachable model tables, core `instant_record_*` tables, or explicitly included migrations, and pass filtered migration files to `BrowserMigrations.plan`.
- R5. Provide crisp, actionable missing-symbol diagnostics:
  - Fail with `BuildError` (including `file:line`, symbol/template name, and remediation hint) for: missing route controller, missing explicit `render` template/partial/layout, reference outside `server_only` to a constant defined in an unstaged app directory (e.g. `app/jobs/`, `app/services/`, `app/mailers/`), missing association model, missing explicit `include:` override, or unknown requested `island:` name.
  - Emit structured diagnostic warnings in the manifest for dynamic Ruby patterns (`render partial: expr`, `constantize`, `const_get`, STI `type` column / inheritance hints) pointing developers to explicit `include:` overrides.
- R6. Maintain full backwards compatibility for consumer apps that have not added `local_first` blocks yet (whole-app `"full"` mode still stages `app/`, emits `instant_record.manifest.json`, and supports explicit `models:`).

#### Canonical Manifest & Runtime Consumers
- R7. Emit a canonical, versioned `instant_record.manifest.json` (`schema_version: 1`) in the build directory and published `dist/` (and serve it in `InstantRecord::CompiledSite`) containing: `mode` (`"island"` or `"full"`), `island`, `models` (`name`, `table`, `file`, `sync_window`, `sync_scope`, `sync_file`), `local_routes`, `server_routes`, `staged` file lists, `includes`, and `diagnostics`.
- R8. Update `EntryBuilder` to consume `instant_record.manifest.json` (retiring `DEMO_MODELS` and hardcoded `Message.sync_window`) to emit `InstantRecord.sync(...)`, `<Model>.sync_window(...)`, and `<Model>.sync_scope(...)` dynamically for all apps.
- R9. Update `worker.js` and `main.js` (via a unit-tested `compiled/web/src/manifest.js` module fed by `VITE_MANIFEST`) to consume `instant_record.manifest.json`: replace all hardcoded demo server route allowlists in `worker.js` with manifest `server_routes` + sync endpoint matching, and scope `isLocal` navigation in `main.js` to manifest `local_routes` in island mode.

#### Dogfooding `demo/`
- R10. Retire `DemoCarver`, `DemoCarver::REMOVE`, `DemoCarver::DEMO_ROUTES`, `DemoCarver.trim_slack_seeds`, `DemoCarver.enable_mail_entry_sync`, and `DemoCarver.adapt_migration_view`. Mark local-first routes in `demo/config/routes.rb` and `demo/config/routes/*.rb`, use `browser_only` in `demo/app/models/mail_entry.rb` and `server_only` in `demo/app/models/slack/seeds.rb` and `demo/app/models/message.rb`, move the compiled migration view overlay into `compiled/pipeline/demo/views/migrate/notes/index.html.erb`, and stage `demo/` through `AppStage.stage`.
- R11. Update `WasmBuild`, `NativeBuild`, `GemVendor`, `SourcePages`, `lib/tasks/instant_record.rake`, `demo/test/compiled_carve_test.rb`, `demo/test/controllers/email/shell_test.rb`, `demo/app/models/mail_shell.rb`, `test/compiler_test.rb`, and docs to reflect the unified island pipeline.

### Scope Boundaries

- `db/schema.rb` is staged unmodified so `MailShell.fingerprint` and Roundhouse schema generation remain intact; migration filtering applies to `db/migrate/` and `BrowserMigrations.plan`.
- External compiler binaries (Roundhouse, Spinel, WASI SDK) are unchanged.
- `DEMO_MIGRATION_PLAN` in `WasmBuild` stays for the demo's v1 IndexedDB schema contract (the live `/migrate` demo uses `sqlite_release.rb`).

## Planning Contract

### Key Technical Decisions

- KTD1. **Static Prism + Erubi analysis with zero Rails boot**: Parse routes, Ruby files, ERB templates (`Erubi::Engine`), and migrations purely with Prism so monolith islands compile without booting the full Rails app or executing server initializers. Governs R3, R4, R5.
- KTD2. **AST-preserving `config/routes.rb` emission**: Generate the staged `config/routes.rb` by walking Prism route ASTs, unwrapping `local_first` blocks, inlining `draw(:subfile)` calls that contain local-first routes, and dropping non-local statements. Preserves all Rails route options (`as:`, `only:`, `path:`, etc.) so Roundhouse generates identical path helpers. Governs R3, R10.
- KTD3. **Two-tier missing-symbol diagnostics**: Index all constant definitions across the host app's `app/**/*.rb` and `lib/**/*.rb` to distinguish real app symbols living outside the island (e.g. `app/jobs/`, `app/services/`, `app/mailers/`) from Ruby/Rails/gem constants without false positives; fail loudly with `file:line` and fix hints for missing routes/partials/associations/unstaged-app-symbols, and emit structured warnings for dynamic Ruby patterns. Governs R5.
- KTD4. **Unified `AppStage` with optional `overlay_dir:`**: Retire `DemoCarver` entirely. `AppStage.stage` runs `RouteAnalyzer` -> `ReachabilityTracer` -> `Manifest` -> file staging -> optional `overlay_dir:` copy (used only for demo AOT showcase files in `compiled/pipeline/demo/`). Extend `GemVendor#rewrite_scoped_blocks` to also unwrap `browser_only`/`client_only` in `app/models` before `unnest_syncable_concern`, retiring `enable_mail_entry_sync` and `trim_slack_seeds`. Governs R4, R10.
- KTD5. **Manifest-driven `EntryBuilder` and `compiled/web/src/manifest.js`**: Emit `instant_record.manifest.json` as the single source of truth shared between Ruby (`EntryBuilder`, `WasmBuild`, `NativeBuild`) and JS (`VITE_MANIFEST` -> `manifest.js` -> `worker.js` and `main.js`). Route patterns like `/email/sync/:member/:inbox/incoming` compile to deterministic regex matchers in JS. Governs R7, R8, R9.

### High-Level Technical Design

```
config/routes.rb (+ config/routes/*.rb) + optional config/instant_record.yml
        │
        ▼
  RouteAnalyzer (Prism)
   ├── local_routes, server_routes, inline includes
   └── rewritten local-only config/routes.rb
        │
        ▼
  ReachabilityTracer (Prism + Erubi)
   ├── BFS from local controllers + layouts + includes (+ screens if native)
   ├── skips server_only blocks; traverses browser_only/client_only
   ├── extracts synced models, sync_window, sync_scope, sync_file
   ├── filters db/migrate/ to reachable tables + instant_record_* tables
   └── produces crisp missing-symbol errors & dynamic-pattern warnings
        │
        ▼
  Manifest (instant_record.manifest.json)
   ├── consumed by AppStage (stages only reachable files + rewritten routes)
   ├── consumed by BrowserMigrations.plan (compiles only reachable migrations)
   ├── consumed by EntryBuilder (InstantRecord.sync, sync_window, sync_scope)
   └── embedded in dist/ + VITE_MANIFEST -> manifest.js -> worker.js & main.js
```

## Implementation Units

### U1. Route DSL & Manifest Schema
- **Goal:** Add `InstantRecord::Routing` (`local_first`), hook it into `ActionDispatch::Routing::Mapper` via `Engine`, add `island`/`include` engine options, and implement `InstantRecord::Compiler::Manifest` + declarative `config/instant_record.yml` loader.
- **Requirements:** R1, R2, R7
- **Files:** `lib/instant_record/routing.rb`, `lib/instant_record/engine.rb`, `lib/instant_record/compiler/manifest.rb`
- **Verification:** Unit tests for `local_first` DSL transparency, manifest serialization/deserialization, and config loading.

### U2. Prism RouteAnalyzer & ReachabilityTracer
- **Goal:** Build `RouteAnalyzer` (Prism parsing of `config/routes.rb` + `draw`, local/server route extraction, AST-preserving local `config/routes.rb` emission) and `ReachabilityTracer` (transitive Prism+Erubi BFS, `server_only` skipping, sync metadata extraction, migration table filtering, crisp missing-symbol errors and dynamic warnings).
- **Requirements:** R3, R4, R5, R6
- **Files:** `lib/instant_record/compiler/route_analyzer.rb`, `lib/instant_record/compiler/reachability_tracer.rb`, `lib/instant_record/compiler/browser_migrations.rb`
- **Verification:** Comprehensive unit tests covering namespaces, scopes, `resources`/`resource`, `draw`, named islands, STI/dynamic-partial include overrides, missing controller/partial/association/unstaged-service diagnostics, `server_only` exclusion, migration filtering, and full-mode fallback.

### U3. Unified `AppStage`, `GemVendor`, `EntryBuilder`, `WasmBuild`, `NativeBuild`, `Compiler` & Rake Tasks
- **Goal:** Replace `DemoCarver` with unified `AppStage.stage` & `AppStage.analyze`, unwrap `browser_only`/`client_only` in `app/models` in `GemVendor`, drive `EntryBuilder` from `Manifest` (retiring `DEMO_MODELS` and hardcoded `Message.sync_window`), wire `instant_record.manifest.json` + `VITE_MANIFEST` + filtered migrations into `WasmBuild`/`NativeBuild`/`Compiler`/`CompiledSite`/`SourcePages`, and expose `island`/`include`/`manifest` in `lib/tasks/instant_record.rake`.
- **Requirements:** R6, R7, R8, R10, R11
- **Files:** `lib/instant_record/compiler/app_stage.rb`, `lib/instant_record/compiler/gem_vendor.rb`, `lib/instant_record/compiler/entry_builder.rb`, `lib/instant_record/compiler/wasm_build.rb`, `lib/instant_record/compiler/native_build.rb`, `lib/instant_record/compiler/source_pages.rb`, `lib/instant_record/compiler.rb`, `lib/instant_record/compiled_site.rb`, `lib/tasks/instant_record.rake`, `instant_record.gemspec`
- **Verification:** `bundle exec rake test`

### U4. Browser Runtime Manifest Consumption (`manifest.js`, `worker.js`, `main.js`)
- **Goal:** Add `compiled/web/src/manifest.js` and `compiled/web/src/manifest.test.js`, update `worker.js` to authorize `serverRequest` from manifest `server_routes` + sync endpoint (removing hardcoded demo paths), and update `main.js` to scope `isLocal` using manifest `local_routes` in island mode.
- **Requirements:** R9
- **Files:** `compiled/web/src/manifest.js`, `compiled/web/src/manifest.test.js`, `compiled/web/src/worker.js`, `compiled/web/src/main.js`
- **Verification:** `node --test compiled/web/src/*.test.js`

### U5. Dogfood `demo/` & Update Tests and Docs
- **Goal:** Mark `local_first` routes in `demo/config/routes.rb` and `demo/config/routes/*.rb`, convert `mail_entry.rb`, `slack/seeds.rb`, and `message.rb` to `browser_only`/`server_only`, add `compiled/pipeline/demo/views/migrate/notes/index.html.erb`, update `demo/test/compiled_carve_test.rb`, `demo/test/controllers/email/shell_test.rb`, `demo/app/models/mail_shell.rb`, `demo/README.md`, and add comprehensive gem tests in `test/local_first_islands_test.rb` + updated `test/compiler_test.rb`.
- **Requirements:** R10, R11
- **Files:** `demo/config/routes.rb`, `demo/config/routes/*.rb`, `demo/app/models/mail_entry.rb`, `demo/app/models/slack/seeds.rb`, `demo/app/models/message.rb`, `demo/app/models/mail_shell.rb`, `compiled/pipeline/demo/views/migrate/notes/index.html.erb`, `demo/test/compiled_carve_test.rb`, `demo/test/controllers/email/shell_test.rb`, `demo/README.md`, `test/compiler_test.rb`, `test/local_first_islands_test.rb`, `test/compiled_release_test.rb`
- **Verification:** `bundle exec rake test`, `node --test compiled/web/src/*.test.js`, `cd demo && bin/rails test`

## Verification Contract

- `bundle exec rake test` passes with 0 failures and 0 errors.
- `node --test compiled/web/src/*.test.js` passes with 0 failures.
- `cd demo && bin/rails test` passes with 0 failures and 0 errors (required per `AGENTS.md` because `demo/` changes).
- `DemoCarver`, `DEMO_ROUTES`, `DEMO_MODELS`, and hardcoded demo server paths in `worker.js` are completely retired.
- Staging `demo/` via `AppStage.stage` excludes all 21 previously denylisted paths, discovers all 9 synced models + `Message.sync_window` + `AssistantChat`/`AssistantTurn`/`AuthNote` sync scopes, and emits valid `instant_record.manifest.json`.
