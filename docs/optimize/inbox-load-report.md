# Inbox load: what was measured and what was kept

Date: 2026-11-19. Branch `optimize/inbox-load`, from main at e3cce27.

## Result

Measured with `compiled/bench/inbox-load.mjs` in a compiled build: headless Chromium, a link of 60 ms on every request and 20 Mbit/s, the Support inbox seeded with 600 conversations (`demo/script/seed_offline_inbox.rb`). Each run is the median of five first visits and ten return visits. Baseline and final runs were interleaved through the session.

| | Baseline (6 runs) | Final (8 runs) | Change |
|---|---|---|---|
| First visit, new profile, until mail is painted | 1,474 ms | 1,357 ms | 117 ms less (7.9%) |
| Return visit, files cached and database saved | 416 ms | 398 ms | 19 ms less (4.5%), inside the run-to-run noise |

Every load in every run was one paint with its mail, showed the same top conversation, and raised no page error. The keep cleared the run's bar (more than 3% on a required number, the other not worse) on three paired runs: 1,355 against 1,506.

## What was kept

**The shell asks for the layout's outside stylesheets while the module downloads** (`outside_stylesheets` in `compiled/pipeline/build.py`). The page the app writes names its Google Fonts stylesheet only once the app is up, and a stylesheet holds the paint. The request took 100 to 340 ms after the mail was ready. Forecast: 60 to 250 ms off a first visit, nothing on a return. Measured: 117 ms off a first visit. The stylesheet was also the main source of noise in the baseline.

## What was tried and dropped

| Change | Forecast | Measured | Why |
|---|---|---|---|
| The worker asks for the bootstrap the moment it starts | 80 to 110 ms off a first visit | 1,348 against 1,341, one pair | The bootstrap already ran beside the VM boot, which blocks only the worker. It was never on the critical path. |
| The shell modulepreloads the Inbox bundle | unknown, 40 ms at most | 1,354 against a best of 1,357 | From cache the bundle arrives 25 ms after the page is written. The paint does not move. |
| The Inbox bundle runs as an async module, ahead of Turbo and Stimulus | unknown, 110 ms at most | 1,353 against 1,360, return 407 against 396, three pairs | Script order is not what holds the last 110 ms. |

## Where a first visit goes now

- 0 to 75 ms: the shell.
- 80 to 1,025 ms: the module, 1.80 MB gzipped at 20 Mbit/s. The bootstrap and the stylesheets travel beside it.
- 1,025 to 1,240 ms: VM boot 121 ms, applying the bootstrap 42 ms, the first render 45 ms. A warm controller answers the same page in 8 ms whatever the mailbox holds, so the first render is a cold VM and not its queries.
- 1,240 to 1,357 ms: the page's scripts, React's first render, the paint.

## What is left, and what it needs

- **Brotli for the module.** 1,797,234 bytes with gzip -9, 1,219,127 with brotli 11: about 230 ms off a first visit at 20 Mbit/s, more on a slower link. Not run. It needs a brotli-capable host in `compiled/deploy` (nginx's stock image has no brotli module) and the same in the bench's static host.
- **`wasm-opt -Oz` in the build.** Measured on the module: 1,797,234 to 1,717,362 gzipped, about 32 ms. `build.py` already runs it when it is on the PATH; nothing installs it. It adds 84 s to a build. Not checked that the optimized module runs.
- **The service worker answers the shell from its cache on a return visit.** The navigation is network first and costs about 80 ms of a 400 ms return. Not run: right after a release a visitor would get the old shell once.
- **The last 110 ms**, from the page being written to rows in the DOM, is not located. It needs a CPU profile of the bundle's evaluation and first render.

## Limits of this evidence

- One workload. The change was chosen and is reported on the same inbox; there is no held-out set.
- Headless Chromium in a cloud container, not the deployed site and not a phone. Responses are paced one by one, so parallel downloads do not share the 20 Mbit/s.
- The fonts stylesheet comes from the real Google Fonts over this container's network. A stalled request failed two baseline runs outright; they were rerun.
- The build here has no `wasm-opt`, so its module is the unoptimized 9.2 MB.

## Checks on the kept change

`bundle exec rake test` (140 runs, 0 failures), demo `npm test` (36 pass), `compiled/test/offline-inbox.mjs` against the build (7 of 7). Demo `bin/rails test`: 169 runs; `Slack::ChannelsControllerTest#test_show_renders_the_seeded_welcome_message_and_the_server_only_marker` failed in two of four runs and passed in the others. This change touches only `compiled/pipeline/build.py`, which that suite does not load.

## Run accounting

Stopped on plateau: three experiments in a row without a gain. Four experiments: one kept, two reverted, one inconclusive. About 80 minutes of experiments after a 15 minute toolchain build. No scoring cost. The run log is outside the repo, in the project's files under `ce-optimize/inbox-load/`.
