# Residual Review Findings — windowed sync & infinite scroll

Branch `feat/windowed-sync-infinite-scroll`. Findings from the ce-code-review and ce-simplify-code passes that were **not** applied, with the reason each was left. Actionable P0/P1/P2 findings and the security P0 were fixed in commit `00643bd`; this file is the durable record for the remainder (no external tracker is configured for this repo).

## Deferred by design

- **Deep-jump contiguity mark poisoning (P2, anchor 50, advisory).** `InstantRecord.fetch_history`'s local-first short-circuit tracks one per-partition low-water mark. A caller that fetches a page far below the current frontier (skipping an unfetched gap) can extend the mark across that gap, so a later page inside the gap is served locally with holes. The Slack demo paginates strictly sequentially and never hits this; it only affects a gem consumer calling `fetch_history` with arbitrary non-adjacent `before` cursors. Fixing it properly means tracking multiple contiguous regions (or fetched ranges) rather than a single oldest tuple — a larger design change than this branch warrants. `client.rb` `extend_history_mark` / `page_local?`.

- **Forged `backfill-` id survives reset (P3, advisory).** Reset preserves history by exempting rows whose id starts with `Slack::Seeds::BACKFILL_PREFIX`. A client that crafts a message id with that prefix would survive every reset. No security impact — the demo is auth-less and all data is already public — and it is demo-only glue, not gem surface. A server-side `Message` validation rejecting reserved id prefixes would close it if the demo ever grows a threat model. `resets_controller.rb`.

- **Pending row occupies a slot in the eviction window (residual).** `SyncWindow#beyond_window` ranks all rows including `pending`; the delete scope excludes pending. A pending row inside the newest-N therefore displaces one synced row out of the retained window (that synced row is evicted). Defensible — the window counts all local rows — but means the retained synced set can be slightly under `limit` while unsynced writes are outstanding. Untested. `sync_window.rb`, `client.rb` `evict_beyond_windows`.

## Accepted operational risks (browser runtime)

- **Change-log cursor gap under concurrent commits.** Change ids are assigned before commit, so a writer in flight during the bootstrap snapshot read can commit a lower id that `after=cursor` polling never returns. Pre-existing in the incremental poll; documented in the plan's KTD2 and accepted at demo scale. No re-bootstrap/gap-detection hook exists.

- **SW-update double-VM window.** During a service-worker update, the new worker boots a second VM against the same PGlite store while the old worker's VM may still tick; the new worker (zero controlled clients at install) also arms eviction. The `sw_updated` reload closes the window quickly, but two writers briefly share one local database. Pre-existing SW-lifecycle behavior, widened slightly by eviction now running at boot.

- **Cold-boot eviction detection is timing-sensitive.** `clients.matchAll` deciding `cold_boot` can misfire at claim-timing edges: eviction skipped on a genuine cold boot (benign — local DB just stays larger) or run on a warm restart under an open reader (scrollback trimmed mid-read; recoverable, pending rows never evicted). `rails.sw.js` `startSync`.

- **The live-refresh page fetch has no timeout.** Unlike the 15s-guarded history fetch, the live-refresh page fetch can hang on an unresponsive SW-rendered request, latching the controller's busy flag and silently stopping live updates for the session: `sync()` sets `this.busy = true` and clears it in a `finally`, so a fetch that never settles means the `finally` never runs and every later `sync()` returns early. Low likelihood in the demo; a timeout wrapper mirroring `fetchHistoryViaWorker` would harden it. `conversation_controller.js` `fetchMessageList`, reached via `merge` from `sync`.

- **Unbounded catch-up poll.** `Change.poll` still returns all rows after the cursor in one batch. Bootstrap removes the worst case (the fresh client), but a long-offline returning client can still pull a large batch and, combined with the SW busy-retry budget, surface a spurious "sync busy". Already listed as deferred follow-up work in the plan's Scope Boundaries.
