# Optimization report: compiled-app-speed

What was optimized: the compiled browser build of the demo (Todo and Slack code plus the gem's
sync client, one wasm module), as a person experiences it. Measured by `node bench/bench.mjs` in
headless Chrome on one Mac against the real Rails sync server on localhost.

## Overall result

Original baseline (benchmark-corrected, revision `0241ac9`) against the final state (`5c053e7`),
three runs each, interleaved in one sitting. Medians.

| Objective | Baseline | Final | Change |
|---|---|---|---|
| Warm boot to a rendered Slack conversation (primary) | 122.2 ms | 113.3 ms | -8.9 ms, -7.3% |
| Cold boot, fresh browser, including bootstrap from Rails | 1237.5 ms | 199.3 ms | -1038 ms, -83.9% |
| Switch channel | 22.9 ms | 22.6 ms | no change |
| Todo write to rendered row | 38.7 ms | 15.9 ms | -22.8 ms, -58.9% |
| First-visit download, gzipped | 2,561,115 bytes | 2,561,591 bytes | no change |

No targets were declared. All twelve behavior checks pass on both revisions; no check that the
baseline passed fails on the final state.

## What was kept, forecast against result

| Change | Forecast | Measured (candidate against the best before it) | Forecast held? |
|---|---|---|---|
| 1. On a first visit, take the server snapshot at boot, before the first page is rendered | cold boot down 700 to 900 ms | cold 1230.4 to 207.9 ms, 3 samples, threshold 5% | Better than forecast: cold wasm compile is cheaper than assumed |
| 2. Run the sync pass a write asks for once the worker has been quiet for 30 ms | write down 15 to 25 ms | write 49.3 to 27.5 ms, 3 samples | Yes |
| 6. Compile the module from the shell page; boot and first page in one round trip; redirects followed in the worker | warm boot down 10 to 17 ms | write about 20 to 16.2 ms against a same-sitting reference; warm boot inside noise at the time | No for warm boot as forecast; kept for the write path. The final confirmation shows warm boot 7.3% lower than the baseline |

All three are standalone comparisons on the optimization branch; each built on the one before it.
The overall gain is the baseline-to-final measurement above, not a sum of these rows.

## What was tried and not kept

- 4 MB memory slab per wasm run (experiment 3): no difference against a same-sitting reference.
- Skipping the schema-creation statements when the schema is known (experiment 4): the run it
  targeted did not get faster and cold boot got worse; reverted.
- Compiling the generated C for size, `spinel -O z` (experiment 5): 15.2% fewer bytes
  (2,561,301 to 2,171,203) and a slightly faster boot, but channel switches went from 22.6 to
  29.1 ms in the same sitting, over the 20% limit set for that number. Reverted. This is a real
  trade-off (390 KB less to download against about 6 ms per click), not noise.

## Evidence quality

- Boot times repeat within 1 to 2% inside a sitting and drift a few percent over an hour.
- `switch_ms` and `write_ms` moved 15 to 30% between sittings with no code change. One early
  decision (experiment 3) would have been a false keep against a stale reference; it was caught
  by re-measuring the reference and not kept. Every later decision used a reference measured in
  the same sitting. The benchmark should take that paired reference itself before a next run.
- The first baseline (warm 199 ms, cold 1313 ms) timed boots from the test driver, which notices
  the app replacing the shell document about 80 ms late. The benchmark was corrected to the page's
  own clock before any experiment ran, and the baseline re-measured.
- A constant page that renders instantly and does nothing fails eleven of the twelve checks, so
  the timings cannot be won by not doing the work.
- No hold-out benchmark was configured: gains were selected and are reported on the same two pages,
  on one machine, against localhost. Real networks change cold boot most.
- Not verified by the benchmark: multi-tab behavior, and whether a write and its outbox row are
  atomic.

## Remaining opportunity

- Warm boot is now mostly the first two wasm runs of a fresh page (about 65 of about 113 ms; the
  same runs cost about 11 ms once warmed up). Nothing tried shortens them except compiling for size.
- `wasm-opt` (binaryen) is the main untried size lever. It needs a new tool, which was not approved
  in this run.
- Keeping the module alive across page loads (a service worker, with the gem's sync driven in
  phases the host can await) would cut warm boot within a session, but not for a visit hours
  later, so this benchmark would overstate it. It is a redesign, not an experiment.
- A long-lived instance instead of one run per request would cut per-click cost; not attempted.

## Run accounting

- Stopped because no runnable hypothesis was left: what remained was below what the benchmark can
  resolve, needs an unapproved tool, or is a redesign.
- 6 experiments: 3 kept, 2 reverted, 1 inconclusive (not kept). No errors or timeouts.
- About 45 minutes inside the loop, plus setup and the final confirmation.
- Model spend was not metered; no dollar figure is available.
- The run's ledger (spec, log) stays in the working checkout under `.context/` and is not part of
  this repository.
