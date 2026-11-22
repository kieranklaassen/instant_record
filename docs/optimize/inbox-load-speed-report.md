# Inbox Load Speed Optimization Report

**Target:** Compiled browser Inbox load times (`/email?member=maya&inbox=support`, 600 seeded conversations, simulated 60 ms RTT / 20 Mbit/s link via `compiled/bench/inbox-load-harness.mjs`)  
**Branch:** `optimize/inbox-load-speed` (`90562bd` -> `3a4283b`)  
**Date:** 2026-11-21  
**Stopping Criterion:** `plateau_iterations: 3` (6 of 8 iterations run; 3 consecutive non-keeps: Exp #4, Exp #5, Exp #6)

---

## Overall Result (Confirmed Interleaved Baseline-to-Final Pairing)

Measured as 3 interleaved pairs of original baseline (`90562bd`) vs final revision (`3a4283b`) under the paired 3% relative threshold (`decide.mjs` -> **`keep`**):

| Metric | Baseline (`90562bd`) | Final (`3a4283b`) | Absolute Delta | Relative Delta | Verdict |
|---|---:|---:|---:|---:|---|
| **`first_visit_ms`** (primary, min) | **1,196.9 ms** (`[1190.8, 1200.0, 1196.9]`) | **851.4 ms** (`[850.4, 870.2, 851.4]`) | **-345.5 ms** | **-28.9%** | **Improved** |
| **`return_visit_ms`** (required, min) | **210.0 ms** (`[210.8, 207.9, 210.0]`) | **212.1 ms** (`[213.7, 211.9, 212.1]`) | +2.1 ms | +1.0% | Inconclusive (flat, within 3%) |
| `first_visit_bytes` (diagnostic) | 2,076,316 B | 1,504,562 B | -571,754 B | -27.5% | Improved |
| `phase_bundle_ms` (diagnostic) | 954.4 ms | 604.5 ms | -349.9 ms | -36.7% | Improved |
| Gates (`build_ok`, `one_paint`, `same_mail`, `page_errors`) | 1 / 1 / 1 / 0 (3/3) | 1 / 1 / 1 / 0 (3/3) | — | — | All passed |

No target threshold was set in `spec.yaml` (open-ended minimization). No holdout workload was configured; selection and confirmation ran on the same Support inbox workload (600 conversations, 60 ms / 20 Mbit/s), with fresh interleaved confirmation runs comparing `90562bd` directly against `3a4283b`.

---

## Opportunity -> Result (Retained Changes)

| Exp | Revision | Change | Forecast (Original Opportunity) | Standalone Measured Result | Workload & Reference | Supported? |
|---|---|---|---|---|---|---|
| **#1** | `bdc1534` (+ `d15ece1`, `3a4283b` `serve.mjs` drain-flush parity) | Precompressed Brotli-11 (with gzip-9 fallback) in `compiled/bench/serve.mjs`, mirrored faithfully in `compiled/deploy/Dockerfile` (`nginx-mod-http-brotli`, `brotli -q 11`, `gzip -9`) and `compiled/deploy/nginx.conf` (`brotli_static on;`). | `first_visit_ms`: -180 to -260 ms (-15% to -22%); `return_visit_ms`: ~0 ms | `first_visit_ms`: **1,195.2 -> 963.8 ms** (**-231.4 ms / -19.4%**, 3 runs); `return_visit_ms`: 216.1 -> 212.1 ms (-1.9%, inconclusive); `phase_bundle_ms`: 953.0 -> 720.5 ms; `first_visit_bytes`: 2,076,316 -> 1,504,562 B | Support inbox (600 convos, 60 ms / 20 Mbit/s), vs `90562bd` | **Yes** — landed squarely inside forecast range |
| **#3** | `5e4e571` | Add `priority: "high"` to Wasm fetch (`compiled/web/index.html`) and `fetchpriority="high"` to worker modulepreload; keep only 3 core stylesheets (`base`, `ui`, `mail`) as `<link rel="preload" as="style" fetchpriority="low">` so `mail-hold` stays in memory cache (`one_paint == 1`) while freeing 3 of 6 HTTP/1.1 Wave-1 sockets for `index.js`, `worker.js`, and `app.wasm`; move the remaining 8 demo stylesheets to low-priority `warm_scripts` (`compiled/pipeline/build.py`). | `first_visit_ms`: -105 to -125 ms (-11% to -13%); `return_visit_ms`: ~0 ms; `one_paint: 1` | `first_visit_ms`: **963.8 -> 839.2 ms** (**-124.6 ms / -12.9%**, 3 runs); `return_visit_ms`: 212.1 -> 207.3 ms (-2.3%, inconclusive); `phase_bundle_ms`: 720.5 -> 588.8 ms; `one_paint: 1` | Support inbox (600 convos, 60 ms / 20 Mbit/s), vs `bdc1534` | **Yes** — matched forecast and preserved `one_paint == 1` |

*Note on `serve.mjs` drain-flush fix (`3a4283b`):* During wrap-up confirmation, `setImmediate` EOF flushing in `d15ece1` still allowed `app.wasm` (1.28 MB, backpressured) to hit `inbox-load.mjs`'s final-chunk timer race on 2/3 runs. Updating `sendPayload` to wait for `drain` before a 1 ms final-byte flush (`3a4283b`) eliminated all spikes and timeouts (6/6 clean runs, 100% deterministic `first_visit_bytes: 1,504,562`, adding ~1 ms conservative overhead reflected in the confirmed `851.4 ms` / `212.1 ms` numbers above).

---

## Evidence Quality & Verification

- **Confirmation & uncertainty:** Confirmed via 3 interleaved baseline-vs-final pairs (`90562bd` vs `3a4283b`) under the 3% paired relative threshold (`decide.mjs` -> `keep`). Spread across the 3 confirmation runs:
  - Baseline: `first_visit_ms` 9.2 ms (0.8%), `return_visit_ms` 2.9 ms (1.4%).
  - Final: `first_visit_ms` 19.8 ms (2.3%), `return_visit_ms` 1.8 ms (0.9%).
- **Correctness suites on final revision (`3a4283b`):**
  - `inbox-load-harness.mjs` gates (`build_ok`, `one_paint`, `same_mail`, `page_errors`): **passed 3/3** on confirmation (15 first visits + 30 return visits, zero page errors).
  - `bundle exec rake test`: **216 runs, 719 assertions, 0 failures, 0 errors, 1 skip**.
  - `cd demo && npm test`: **36/36 passed**.
  - `cd demo && PARALLEL_WORKERS=1 bin/rails test`: **256 runs, 1,068 assertions, 0 failures, 0 errors, 19 skips** (note: `PARALLEL_WORKERS=1` + `PGGSSENCMODE=disable` used on macOS to avoid a pre-existing `pg` gem fork segfault in parallel test workers).
  - `node compiled/test/shell-worker.mjs`: **passed**.
  - `compiled/test/offline-inbox.mjs`: passed 7/7 on baseline and Exp #1; check 4's `mouse.wheel` scroll test exhibits a pre-existing intermittent stall reproduced identically on pre-Exp-3 `d15ece1`.
- **Harness limitation discovered:** `compiled/bench/inbox-load.mjs` (immutable) has a subtle timer-ordering race between `answer.on("data")` (`setTimeout(..., wait)`) and `answer.on("end")` (`setTimeout(..., due - now)`) when a static server sends a large payload's final chunk with `wait >= 1 ms`. Waiting for `drain` + 1-byte tail in `serve.mjs` avoids it cleanly; a future harness improvement should chain `response.end()` after the last `response.write()` callback in `inbox-load.mjs`.
- **Held-out / per-case regressions:** No holdout or per-case set was configured (selected and confirmed on the same Support inbox workload; per-case regression list: unrecorded).

---

## Key Rejected / Reverted Findings

- **Exp #2 (`degenerate`):** Moving all 11 CSS preloads out of `<link rel="preload" as="style">` proved the `-118.6 ms` Wave-1 speedup (`845.2 ms`) but broke `one_paint == 1` because `mail.css` (`mail-hold`) left Blink's memory cache. Directly guided Exp #3.
- **Exp #4 (`reverted`, inconclusive):** Deferring Turbo/Stimulus + 16 controller modulepreloads until after `data-mail-ready` shaved 6–10 ms off `postWriteToReady` in CDP profiling but moved end-to-end medians by only `-3.2 ms` (`-0.4%`) cold / `-2.1 ms` (`-1.0%`) return, below the 3% bar.
- **Exp #5 (`reverted`, regressed):** Eliminating 5 of 8 SQL queries and all 1,200 correlated archive/unread subqueries in `Email::MailboxesController#index` only trimmed `phase_render_ms` by 3.7 ms (`33 -> 29 ms`), proving the remaining ~28 ms render time is Spinel Ruby row hydration/serialization (`Time#iso8601`, `JSON.generate`, `html_escape`), not SQLite queries. Calling `pluck` also pulled +58 KB of dead-code-eliminated ActiveRecord code into `app.wasm`.
- **Exp #6 (`reverted`, mixed):** Pre-evaluating `inbox.js` on the idle main thread + in-place Inbox hydration (avoiding `document.open()/document.write()`) + worker `prepare()` **improved `return_visit_ms` by -9.0 ms (-4.34% to `198.3 ms`)** and cut `postWriteToReady` by 18.3 ms return / 18.7 ms cold with `one_paint == 1`, but regressed `first_visit_ms` by +20.0 ms due to two scheduling bugs (starting `import(inbox.js)` before `window.__wasm` resolved stalled `bundle` by +25.8 ms on return, and starting `earlyBootstrap` before `app.wasm` finished contended on the cold 20 Mbit/s wire by +24.5 ms).

---

## Remaining Opportunities

1. **H7 — Refined in-place Inbox hydration (`frontend-hydration`, high confidence — fresh evidence from Exp #6 CDP profile):** Fix Exp #6's two scheduling bugs: start `import(inbox.js)` only *after* posting `boot` to the worker (so `window.__wasm` is never blocked on the main thread), keep `earlyBootstrap` after `app.wasm` completes on cold visits, and exclude `inbox.js` from `warm_scripts` on `/email`. Projected: **`return_visit_ms` ~175–187 ms (-10% to -15%)** and **`first_visit_ms` ~810–821 ms (-3% to -5%)**.
2. **H5 — Trim `inbox.js` initial React/Virtuoso mount (`frontend-bundle`, medium confidence — post-Exp-6 profile shows ~32 ms remaining in React/Virtuoso mount):** Measure and trim initial render cost (`LiveList` `FIRST_DRAW`, lazy modals).
3. **H6 — Wasm runtime / `wasm_boot` + `wasm_request` (`wasm-runtime`, low/unknown):** `wasm_boot` (26 ms return / 58 ms cold) and Ruby row serialization in `wasm_request` (24–32 ms) remain the dominant worker-side costs; `wasm-opt --converge --merge-similar-functions` was probed and saved only 3 KB Brotli (`<2 ms`), and remaining unpruned runtime modules account for only 1.8% of `app.c`.

---

## Run Accounting

- **Stopping reason:** `plateau_iterations: 3` (consecutive non-keeps: Exp #4, #5, #6)
- **Active duration:** ~68 minutes (`4,080 s` active inside Phase 3 + confirmation)
- **Outcome counts (6 iterations):**
  - Kept: 2 (`Exp #1`, `Exp #3`)
  - Runner-up kept: 0
  - Reverted: 3 (`Exp #4`, `Exp #5`, `Exp #6`)
  - Degenerate: 1 (`Exp #2`)
  - Not selected: 0 · Inconclusive (standalone): 0 · Censored: 0 · Deferred: 0 · Errors: 0 · Timeouts: 0
- **Scoring / run cost:** `$0` judge spend (hard metric); host model spend is not metered by this environment.
- **Experiment log:** `.context/compound-engineering/ce-optimize/inbox-load-speed/experiment-log.yaml`
