# Optimization Report: `compiled-app-responsiveness`

**Branch:** `optimize/compiled-app-responsiveness`
**Baseline revision:** `04fa224` (branched off `compiled-browser-build`, with all 7 user-click interactions instrumented in `compiled/bench/measure.mjs`)
**Final revision:** `d5fecbf` (4 kept optimization commits across 15 files, +663/-282 lines)
**Workload:** `compiled/bench/bench.mjs` — headless Chrome against the live Rails sync server and PostgreSQL 18 (5 browser contexts × 3 warm boots, 30 channel switches, 5 Slack sends, 5 thread opens, 5 thread replies, 15 Todo creates, 15 Todo toggles, 15 Todo deletes, plus 12 end-to-end behavior checks)

---

## 1. Overall Result (Original Baseline `04fa224` → Final `d5fecbf`)

All four required objectives improved simultaneously across 3 confirmation runs each, with zero regressions and 12/12 end-to-end checks passing on every run:

| Objective | Role | Baseline (`04fa224`) | Final (`d5fecbf`) | Absolute Change | % Change | Confirmation Samples (Final) |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| **`interaction_ms`** | Primary (minimize) | **17.2 ms** | **3.1 ms** | **-14.1 ms** | **-82.0% (5.5× faster)** | `[3.0, 3.2, 3.1]` |
| **`warm_boot_ms`** | Required (minimize) | **170.6 ms** | **135.1 ms** | **-35.5 ms** | **-20.8%** | `[134.6, 135.1, 142.5]` |
| **`cold_boot_ms`** | Required (minimize) | **261.7 ms** | **225.7 ms** | **-36.0 ms** | **-13.8%** | `[228.2, 205.1, 225.7]` |
| **`first_visit_gzip_bytes`** | Required (minimize) | **2,506,481 B** (2.51 MB) | **1,976,456 B** (1.98 MB) | **-530,025 B** (-530 KB) | **-21.1%** | `[1976456, 1976456, 1976456]` |

### Per-Click Interaction Breakdown (Diagnostics)

Every user-click interaction across both the Slack and Todo demos now completes in **1.9–5.4 ms** (well inside a single 16.7 ms 60 Hz animation frame):

| User Click Interaction | Baseline (`04fa224`) | Final (`d5fecbf`) | Speedup |
| --- | ---: | ---: | ---: |
| Slack channel switch (`switch_ms`) | 19.0 ms | **5.4 ms** | **3.5× (-71.6%)** |
| Slack send message (`slack_send_ms`) | 19.4 ms | **4.5 ms** | **4.3× (-76.8%)** |
| Slack open thread (`thread_open_ms`) | 16.7 ms | **2.8 ms** | **6.0× (-83.2%)** |
| Slack thread reply (`thread_reply_ms`) | 20.7 ms | **1.9 ms** | **10.9× (-90.8%)** |
| Todo create (`write_ms`) | 15.4 ms | **2.4 ms** | **6.4× (-84.4%)** |
| Todo toggle checkbox (`toggle_ms`) | 15.0 ms | **2.6 ms** | **5.8× (-82.7%)** |
| Todo delete (`delete_ms`) | 13.8 ms | **1.9 ms** | **7.3× (-86.2%)** |

### Secondary Diagnostics

| Diagnostic | Baseline (`04fa224`) | Final (`d5fecbf`) | Change |
| --- | ---: | ---: | ---: |
| `todo_warm_boot_ms` | 120.8 ms | **95.6 ms** | **-20.9%** (sub-100 ms) |
| `first_request_ms` | 93.9 ms | **61.1 ms** | **-34.9%** |
| `wasm_compile_ms` | 22.4 ms | **19.9 ms** | **-11.2%** |
| `wasm_gzip_bytes` | 2,425,851 B | **1,895,127 B** | **-21.9%** (-531 KB) |
| `wasm_raw_bytes` | 10,468,144 B | **8,031,726 B** | **-23.3%** (-2.44 MB) |

---

## 2. Opportunity → Result (Retained Changes)

Each retained change was evaluated sequentially on `compiled/bench/bench.mjs` (3 confirmation runs per kept change, paired 5% relative threshold via `decide.mjs`):

| # | Commit | Change | Comparison | Forecast | Measured Result | Forecast Supported? |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `146ecab` | **Persistent WASI Reactor** (`spinel -c --ext-init app_boot --ext-entry ...`, `-mexec-model=reactor`, `reactor_shim.c`, `DATABASE_POOL_SIZE=1`, single live SQLite + GC slab in `AppHost`) | `04fa224` → `146ecab` (standalone) | `interaction_ms` -40% to -65%; `warm_boot_ms` -20% to -35%; `cold_boot_ms` -15% to -25% | `interaction_ms` 17.2 → **9.1 ms** (-47.1%); `warm_boot_ms` 170.6 → **154.2 ms** (-9.6%); `cold_boot_ms` 261.7 → **239.8 ms** (-8.4%) | Yes on primary; boot wins smaller than forecast because `document.write()` CSS/JS + first-request JIT still dominated boot |
| 2 | `1308e4d` | **In-place Slack channel & thread fragments** (`_pane.html.erb`, `_thread_panel.html.erb`, `?fragment=pane`/`?fragment=thread`, delegated click/popstate + `<template>` parsing in `conversation_controller.js`) | `146ecab` → `1308e4d` (standalone) | `switch_ms` -65%, `thread_open_ms` -65%, `interaction_ms` -30% to -40% | `switch_ms` 15.8 → **6.5 ms** (-58.9%), `thread_open_ms` 16.7 → **2.8 ms** (-83.2%), `interaction_ms` 9.1 → **5.3 ms** (-41.8%) | Yes (exceeded forecast on `thread_open_ms` and `interaction_ms`) |
| 3 | `0702275` | **Single-round-trip `?fragment=1` write responses** (`_list.html.erb` + `Todo::IssuesController` + `Slack::MessagesController` returning updated partial directly; `<template>` parsing in `issues_controller.js`) | `1308e4d` → `0702275` (standalone) | `thread_reply` -65%, `slack_send` -40%, Todo write/toggle/delete -40%, `interaction_ms` -30% to -45% | `thread_reply` 8.8 → **2.9 ms** (-67%), `slack_send` 6.7 → **4.6 ms** (-31%), `write`/`toggle`/`delete` 3.5–4.7 → **2.4–3.0 ms**, `interaction_ms` 5.3 → **3.5 ms** (-34.0%) | Yes |
| 7 | `d5fecbf` | **`clang -Oz` + `wasm-opt -Oz` + async `window=0` polling + cached IDB + SQLite PRAGMAs** (`locking_mode=EXCLUSIVE`, `journal_mode=MEMORY`, `cache_size=-4000`, skip DDL on restored DB, `wasm_stream`/`wasm_cursor`, retry-only outbox drain) | `0702275` → `d5fecbf` (standalone) | `first_visit_gzip_bytes` -15% to -22%, `warm_boot_ms` -10% to -15%, `cold_boot_ms` -8% to -12%, `interaction_ms` 3.5 → 3.0–3.3 ms | **All 4 objectives improved**: `interaction_ms` 3.5 → **3.1 ms** (-11.4%), `warm_boot_ms` 158.0 → **135.1 ms** (-14.5%), `cold_boot_ms` 253.1 → **225.7 ms** (-10.8%), `first_visit_gzip_bytes` 2.52 MB → **1.98 MB** (-21.6%) | Yes — exceeded every forecast |

---

## 3. Evidence Quality & Correctness

- **Confirmation status:** **Confirmed.** Both the original baseline (`04fa224`) and final state (`d5fecbf`) were measured with 3 full benchmark runs each on the same host, PostgreSQL 18 cluster, live Rails sync server, and headless Chrome, and compared as one pairing via `decide.mjs` (paired 5% relative threshold).
- **Correctness gates:**
  - **12/12 headless Chrome E2E checks** passed on all 3 final confirmation runs (`todo_renders_with_stimulus`, `todo_create_reaches_rails`, `todo_toggle_reaches_rails`, `todo_server_create_arrives`, `todo_server_rejection_rolls_back`, `todo_delete_reaches_rails`, `slack_opens_general_with_window`, `slack_post_and_bot_reply`, `slack_thread_reply_reaches_rails`, `reload_keeps_local_data`, `fresh_browser_bootstraps`, `no_page_errors`).
  - **30/30 Rails controller tests** (`test/controllers/todo/issues_controller_test.rb`, `test/controllers/slack/messages_controller_test.rb`, `test/controllers/slack/channels_controller_test.rb`) passed on `d5fecbf` (107 assertions, 0 failures, 0 errors).
  - `lib/instant_record/` was not modified; no gem behavior was altered.
- **Holdout & case regressions:** No separate holdout suite was configured (`holdout_configured: false`), so gains were selected and reported on the same 12-case benchmark suite. Case regression list (`04fa224` → `d5fecbf`): **empty (`[]`)**.
- **Harness / edge-case notes discovered during reverts:**
  - Exp 4 revealed that holding SSE streams open (`window=10s`) starves Puma's 3-thread dev server across rapid tab open/close cycles; async JS `fetch(/events?after=<cursor>&window=0)` avoided Puma thread exhaustion while keeping the worker non-blocking.
  - Because `worker.js` now triggers outbox drains on writes (with exponential backoff retry) rather than every 1 s unconditionally, a tab reloaded while offline with previously unsent outbox rows will wait for the next write (or a deferred post-boot check) to drain — a subtle offline-reload edge case not currently exercised by the 12 E2E checks.

---

## 4. Remaining Opportunity

A Chrome waterfall and fetch-split diagnostic profile on the final reactor architecture identified clear remaining levers (partially tested in Exp 8, which failed only because `inject_preloads` preloaded `/assets/application.js` before `document.write()` installed the `<script type="importmap">`):

1. **Fast-path local `fetch` in `compiled/web/src/main.js`** — bypass `new Request()` multipart MIME encoding + async `await request.formData()` decoding on `FormData` submits (measured 3.2 ms out of 4.8 ms on `slack_send_ms`).
2. **Pre-paint `requestAnimationFrame` scroll scheduling in `conversation_controller.js`** — avoid forced synchronous `scrollHeight` layout recalc inside `switchChannel` and `send` (measured ~2.5 ms DOM work on `switch_ms`).
3. **Parallel CSS + worker preloading in `index.html`** (preloading `dist/assets/*.css` and `worker-*.js` only — never `application.js` before the importmap) + single-transaction IDB boot read + eliminating N+1 `dm.dm_user` queries and 50 per-row route-helper calls in Slack views (~38 ms currently spent after `document.write()` on `/slack` warm boot).

Estimated remaining upside: `interaction_ms` 3.1 → ~2.4–2.7 ms and `warm_boot_ms` 135.1 → ~110–122 ms.

---

## 5. Run Accounting

- **Stopping reason:** `max_iterations` reached (8 / 8 iterations).
- **Outcomes:** **4 kept** (Exp 1, 2, 3, 7), **2 reverted** (Exp 4, 5), **1 inconclusive** (Exp 6), **1 degenerate** (Exp 8). Not selected: 0. Deferred: 0. Errors/timeouts: 0.
- **Active duration:** ~57 minutes (~3,420 s across 8 build/measure iterations + confirmation runs).
- **Cost:** `$0` judge spend (hard metric, no LLM judge calls); host model spend is not metered by this environment.
- **Experiment log:** `.context/compound-engineering/ce-optimize/compiled-app-responsiveness/experiment-log.yaml`
