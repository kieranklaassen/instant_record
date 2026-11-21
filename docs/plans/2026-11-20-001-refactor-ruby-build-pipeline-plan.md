---
title: Pure-Ruby Build Pipeline - Plan
type: refactor
date: 2026-11-20
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Pure-Ruby Build Pipeline - Plan

## Goal Capsule

- **Objective:** Developers and Rails apps using `instant_record` can build browser Wasm sites and native iOS/macOS libraries using only Ruby and the existing compiler toolchain (Roundhouse, Spinel, WASI SDK / Xcode, Node), with zero Python dependency, clear preflight diagnostics, and smooth CLI/Rake entry points.
- **Means:** Replace all 11 Python scripts in `compiled/pipeline/` and `compiled/deploy/` with in-process Ruby classes under `lib/instant_record/compiler/`, backed by thin Ruby CLI wrappers and Rake tasks (KTD1, KTD2).
- **Authority hierarchy:** `AGENTS.md` (no PRs; branch, test, merge `--no-ff`, push `main`, delete branch; stop if tests fail) > user request > Product Contract (R-IDs) > Planning Contract (KTD-IDs) > Implementation Units (U-IDs).
- **Stop conditions:** Any gem test failure, any unresolved ambiguity in build behavior, or inability to run required tests before merging to `main` (per `AGENTS.md`).
- **Execution profile:** Single branch (`refactor/ruby-build-pipeline`), shipped via `AGENTS.md` merge-to-main workflow (no PR).

## Product Contract

### Summary

Remove Python completely from the `instant_record` build and deploy pipeline. Move the build stages into clean, testable, in-process Ruby modules under `lib/instant_record/compiler/`, add a `doctor` preflight check for toolchain setup, provide clean Rake and CLI entry points, and remove redundant process-spawning and pipeline-file copying.

### Problem Frame

`instant_record` is a Ruby gem, yet its build pipeline currently depends on Python 3 across 10 scripts in `compiled/pipeline/` and 1 in `compiled/deploy/`. None of the external tools (Spinel, Roundhouse, WASI SDK, SQLite, Node/Vite) require Python. Running `bin/rails instant_record:compile` currently copies `compiled/pipeline/` into `tmp/`, spawns `python3 build.py`, which spawns `ruby browser_migrations.rb` and 4–5 additional `python3` subprocesses (and for native builds, another `ruby native_screens.rb` subprocess). This adds an unnecessary runtime requirement, slows down builds with repeated process hops, and makes the pipeline hard to unit-test from Ruby.

### Requirements

#### Python Removal & Packaging
- R1. Remove all `.py` files from `compiled/pipeline/` and `compiled/deploy/`, remove `*.py` from `instant_record.gemspec`, remove `__pycache__/` from `compiled/.gitignore`, and remove `PYTHONDONTWRITEBYTECODE` from `InstantRecord::Compiler`.
- R2. Preserve exact static asset paths expected by external consumers and Xcode projects: `compiled/pipeline/native/instant_record_native.h`, `compiled/pipeline/native/host.c`, `compiled/pipeline/sqlite/rh_shim.c`, `compiled/pipeline/reactor_shim.c`, `compiled/pipeline/native_shim.c`, `compiled/pipeline/sqlite_release.rb`, and `compiled/pipeline/demo/`.

#### Build Pipeline Behavior Parity
- R3. `InstantRecord::Compiler.build` and the demo Wasm build produce the same staged app, vendored gem seams, Roundhouse output, versioned controller importmaps, `main_wasm.rb`, single-threaded `wasm-tree` (with dead-subsystem pruning for demo), cached `libsqlite3.a`, Spinel/clang reactor Wasm, stripped/optimized output, Vite site with `VITE_*` env vars, `instant-record-release.json`, assets, demo source pages, service worker, preloads, `warm_scripts`, and atomic `web/dist` swap.
- R4. `InstantRecord::Compiler.build_native` and the demo native build produce the same `main_native.rb`, `NativeHost` transport/notifier rewrites, screen `case` dispatch via `InstantRecord::Native.class_name`, C type guards (`loose_node_fields`, `certain_type_errors`), host `libinstant_record_app.a` + `host` binary, and iOS cross-compiled `libinstant_record_app.a` + `libspinel_rt.a` for `iphonesimulator` and `iphoneos`.
- R5. `BrowserMigrations` compiles Rails migrations in-process without modifying `ActiveRecord::Base.connection` (preserving the host Rails app's database connection) while keeping `compiled/pipeline/browser_migrations.rb` compatible with existing requires.
- R6. `PathScrubber` performs the same-length binary prefix replacement in Wasm files as `scrub_path.py` via both `InstantRecord::Compiler.scrub_path` and `compiled/deploy/scrub_path.rb`.

#### Developer Experience & Tooling
- R7. Provide smooth, idiomatic entry points: `bin/rails instant_record:compile`, `bin/rails instant_record:native[target]`, `bin/rails instant_record:doctor[target]`, root `Rakefile` tasks (`rake compile`, `rake compile:native[target]`, `rake compile:doctor[target]`), and executable Ruby scripts (`compiled/pipeline/build.rb`, `compiled/pipeline/build_native.rb`, `compiled/deploy/scrub_path.rb`).
- R8. Provide `InstantRecord::Compiler.doctor` to validate toolchain configuration and executables up front with clear, actionable diagnostics before a build fails mid-flight.
- R9. Resolve `turbo.min.js`, `stimulus.min.js`, and `stimulus-loading.js` in Ruby via `Dir.glob` against `RAILS_GEMS` (no `find` subprocess) with fallback to `Gem.loaded_specs` when `RAILS_GEMS` is unset or does not contain them.
- R10. Update tests (`test/`, `demo/test/`), benchmark harness (`compiled/bench/bench.mjs`), and docs (`README.md`, `compiled/README.md`, `demo/README.md`, `native/ios/README.md`, `native/ios/ui-test.sh`, `compiled/deploy/Dockerfile`, code comments) to reference the Ruby pipeline exclusively.

### Scope Boundaries

- External compiler binaries (Spinel, Roundhouse, WASI SDK, SQLite amalgamation, Node/Vite) remain configured via `toolchain.env`; this refactor does not replace or download them.
- C shims (`reactor_shim.c`, `native_shim.c`, `rh_shim.c`, `host.c`, `instant_record_native.h`) and browser JS harness (`compiled/web/`) are unchanged.

## Planning Contract

### Key Technical Decisions

- KTD1. **In-process Ruby pipeline under `lib/instant_record/compiler/`**: House all pipeline stages in `lib/instant_record/compiler/` (`toolchain.rb`, `runner.rb`, `browser_migrations.rb`, `app_stage.rb`, `gem_vendor.rb`, `entry_builder.rb`, `wasm_tree.rb`, `source_pages.rb`, `wasm_build.rb`, `native_build.rb`, `path_scrubber.rb`) so `InstantRecord::Compiler` executes every Ruby stage directly in-process without copying `compiled/pipeline/` into `tmp/` or spawning intermediate Ruby/Python processes. Governs R1, R3, R4, R7.
- KTD2. **Thin executable Ruby wrappers in `compiled/pipeline/` and `compiled/deploy/`**: Keep `compiled/pipeline/build.rb`, `compiled/pipeline/build_native.rb`, `compiled/pipeline/browser_migrations.rb`, and `compiled/deploy/scrub_path.rb` as minimal wrappers delegating to `InstantRecord::Compiler`, preserving familiar standalone CLI usage alongside `rake compile` / `bin/rails instant_record:compile`. Governs R2, R6, R7.
- KTD3. **Isolated `SQLite3Adapter` for in-process `BrowserMigrations`**: Instantiate `ActiveRecord::ConnectionAdapters::SQLite3Adapter.new({ adapter: "sqlite3", database: ":memory:" })` and `disconnect!` in `ensure` instead of calling `ActiveRecord::Base.establish_connection`, ensuring host Rails apps never lose their primary database connection when compiling migrations in-process. Governs R5.
- KTD4. **Direct Ruby constants in tests**: Expose `DemoCarver::REMOVE`, `WasmBuild::SHELL_FORMAT`, `EntryBuilder::DEMO_MODELS`, `NativeBuild.loose_node_fields`, and `NativeBuild.certain_type_errors` as public Ruby APIs so `test/native_build_guards_test.rb`, `demo/test/compiled_carve_test.rb`, and `demo/test/controllers/email/shell_test.rb` call/read Ruby directly instead of shelling out to Python or regex-scraping scripts. Governs R4, R10.

### High-Level Technical Design

```
InstantRecord::Compiler (facade)
 ├── Toolchain          (parses toolchain.env, $VAR expansion, doctor preflight)
 ├── Runner             (Open3.capture2e, log files, crisp BuildError)
 ├── BrowserMigrations  (Prism AST -> isolated SQLite3Adapter DDL + SHA256 history)
 ├── AppStage / DemoCarver (stages consumer app or carves demo/ with overlay)
 ├── GemVendor          (copies gem Ruby + applies host/demo seams)
 ├── EntryBuilder       (generates main_wasm.rb, main_native.rb, NativeHost rewrites)
 ├── WasmTree           (single-threaded runtime rewrites + demo dead-code pruning)
 ├── SourcePages        (lazy HTML source drawers for demo)
 ├── WasmBuild          (input_digest, sqlite cache, Spinel/clang/wasm-opt, Vite, preloads, swap)
 ├── NativeBuild        (C guards, host lib + binary, iOS cross-compiled runtime + lib)
 └── PathScrubber       (same-length binary path scrub for deploy)
```

### Risks & Dependencies

- Local verification environment has Ruby 3.4.2 (gem tests pass), whereas `demo/Gemfile` pins Ruby `3.3.3` and requires PostgreSQL, and Spinel/Roundhouse/WASI SDK are not installed on this machine. We will mitigate build-orchestration risk with thorough unit tests for every module PLUS a full end-to-end mocked-toolchain integration test exercising `Compiler.build` and `Compiler.build_native` with stub binaries.

## Implementation Units

### U1. Core Infrastructure: Toolchain, Runner, PathScrubber, BrowserMigrations
- **Goal:** Build the foundational compiler primitives in Ruby with isolated SQLite migration compilation and toolchain `doctor` checks.
- **Requirements:** R5, R6, R8
- **Files:** `lib/instant_record/compiler/runner.rb`, `lib/instant_record/compiler/toolchain.rb`, `lib/instant_record/compiler/path_scrubber.rb`, `lib/instant_record/compiler/browser_migrations.rb`, `compiled/pipeline/browser_migrations.rb`, `compiled/deploy/scrub_path.rb`
- **Approach:** Implement `BuildError`, `Runner`, `Toolchain` (with `$VAR` expansion and `doctor`), `PathScrubber`, and `BrowserMigrations` (using standalone `SQLite3Adapter` per KTD3). Keep `compiled/pipeline/browser_migrations.rb` as a compatibility shim.
- **Test Scenarios:** Toolchain parsing & `$VAR` expansion; missing file/keys; `doctor` reporting passing/missing tools; `PathScrubber` replacing bytes while preserving length; `BrowserMigrations.plan` compiling migrations without altering `ActiveRecord::Base.connection`.
- **Verification:** `bundle exec rake test`

### U2. Source Staging & Transformation: AppStage, DemoCarver, GemVendor, EntryBuilder, WasmTree, SourcePages
- **Goal:** Port all app-staging, gem-vendoring, entry-generation, Wasm-tree rewriting, and source-page generation stages from Python to clean Ruby modules.
- **Requirements:** R2, R3, R4
- **Files:** `lib/instant_record/compiler/app_stage.rb`, `lib/instant_record/compiler/gem_vendor.rb`, `lib/instant_record/compiler/entry_builder.rb`, `lib/instant_record/compiler/wasm_tree.rb`, `lib/instant_record/compiler/source_pages.rb`
- **Approach:** Preserve every seam, regex, migration SQL escaping rule, `NativeHost` rewrite, screen `case` dispatch (calling `InstantRecord::Native.class_name` directly), threading rename, and dead-subsystem stub. Expose `DemoCarver::REMOVE` and `EntryBuilder::DEMO_MODELS` (KTD4).
- **Test Scenarios:** Demo carving removes excluded files and applies overlays/seeds/mail_entry edits; consumer app staging enforces `db/schema.rb`; gem vendoring applies all seams idempotently and unwraps `browser_only`/`client_only` while stripping `server_only`; entry generation produces valid `main_wasm.rb` and `main_native.rb` with escaped SQL and screen dispatch; `WasmTree` renames threading constants, injects `wasm_threads.rb`, patches `message_digest.rb`/`db.rb`/`base.rb`/views, and prunes stubs for demo only; `SourcePages` generates escaped HTML with InstantRecord line markers.
- **Verification:** `bundle exec rake test`

### U3. Build Orchestrators & Facade: WasmBuild, NativeBuild, Compiler, CLI & Rake Tasks
- **Goal:** Implement `WasmBuild`, `NativeBuild`, update `InstantRecord::Compiler`, add thin CLI wrappers (`build.rb`, `build_native.rb`), and add Rake tasks (`compile`, `compile:native`, `compile:doctor`, `instant_record:doctor`).
- **Requirements:** R1, R3, R4, R7, R8, R9
- **Files:** `lib/instant_record/compiler/wasm_build.rb`, `lib/instant_record/compiler/native_build.rb`, `lib/instant_record/compiler.rb`, `lib/tasks/instant_record.rake`, `Rakefile`, `compiled/pipeline/build.rb`, `compiled/pipeline/build_native.rb`
- **Approach:** Wire shared `emit_tree`, input digest stamp caching, SQLite archive caching, Spinel/clang/wasm-opt/Vite invocation, Ruby `Dir.glob` + `Gem.loaded_specs` JS asset resolution, preloads/`warm_scripts`, atomic `web/dist` swap, C type guards (`loose_node_fields`, `certain_type_errors`), host/iOS native builds, and workspace locking without copying `compiled/pipeline/` into `tmp/`.
- **Test Scenarios:** End-to-end `Compiler.build` (consumer & demo) and `Compiler.build_native` (host & iOS targets) with fake toolchain executables; stamp caching skips rebuild on unchanged inputs; C type guards catch loose fields and `TypeError` lines; invalid targets raise clearly; `doctor` prints clear status.
- **Verification:** `bundle exec rake test`

### U4. Remove Python Artifacts, Update Tests, Packaging, Benchmarks & Docs
- **Goal:** Delete all 11 `.py` files and `native_screens.rb`, update gemspec, `.gitignore`, tests, benchmark runner, and documentation.
- **Requirements:** R1, R2, R10
- **Files:** Delete `compiled/pipeline/*.py`, `compiled/pipeline/native_screens.rb`, `compiled/deploy/scrub_path.py`; update `instant_record.gemspec`, `compiled/.gitignore`, `compiled/bench/bench.mjs`, `compiled/deploy/Dockerfile`, `compiled/pipeline/native_shim.c`, `test/native_build_guards_test.rb`, `test/native_spinel_test.rb`, `test/compiler_test.rb`, `demo/test/compiled_carve_test.rb`, `demo/test/controllers/email/shell_test.rb`, `demo/test/integration/native_inbox_test.rb`, `demo/app/models/mail_shell.rb`, `sig/instant_record/native.rbs`, `lib/instant_record/native.rb`, `README.md`, `compiled/README.md`, `demo/README.md`, `native/ios/README.md`, `native/ios/ui-test.sh`.
- **Test Scenarios:** All existing + new gem tests pass; `git grep -i python` returns zero active pipeline references; `ruby -c` passes on all edited Ruby files including `demo/test/` files; standalone verification of `demo/test/compiled_carve_test.rb` and `demo/test/controllers/email/shell_test.rb` assertions.
- **Verification:** `bundle exec rake test`, `cd demo && bin/rails test` (if Ruby 3.3.3 & Postgres available; otherwise stop before merge to `main` per `AGENTS.md`).

## Verification Contract

- `bundle exec rake test` — all gem tests pass with 0 failures and 0 errors (including `test/native_build_guards_test.rb`, `test/compiled_release_test.rb`, and new `test/compiler_test.rb`).
- `cd demo && bin/rails test` — required per `AGENTS.md` before merging to `main` because `demo/` files are updated.
- Zero `.py` files remain in the repository (`find . -name '*.py' -not -path '*/.git*'`).
- `ruby -c` passes on all new and modified `.rb` files.

## Definition of Done

- All 4 units (U1–U4) implemented cleanly with no dead/abandoned code.
- No Python scripts or Python references remain in the build/deploy pipeline, gemspec, or tests.
- All gem unit and end-to-end mocked-toolchain tests pass.
- Code simplified (`ce-simplify-code`) and reviewed (`ce-code-review`) with eligible findings applied.
- Shipped per `AGENTS.md` if all required tests pass, or stopped cleanly on the feature branch with a clear report if `cd demo && bin/rails test` cannot run in this environment.
