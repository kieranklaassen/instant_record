# Compiled browser build (experiment)

The demo's Todo and Slack code and the gem's own sync client, compiled ahead of time to one
WebAssembly module instead of interpreted by ruby.wasm.

    demo Ruby + lib/instant_record  ->  Roundhouse  ->  Spinel  ->  app.wasm (+ SQLite)

Status: an experiment. It works end to end against the real Rails sync server, it depends on
unreleased builds of both compilers, and it carries patches for compiler bugs that should go
upstream. Nothing here is loaded by the gem.

## Numbers

Headless Chrome on one Mac, Rails sync server on localhost, medians of three runs.

| | ruby.wasm build | This build |
|---|---|---|
| First visit, gzipped | 17.1 MB (`app.wasm` alone) | 2.56 MB |
| Warm boot to a rendered Slack conversation | about 2.3 to 2.8 s | 113 ms |
| Cold boot, including bootstrap from Rails | 3.3 to 8.8 s over a real network | 199 ms |
| Switch channel | not measured | 23 ms |
| Todo write to rendered row | not measured | 16 ms |

The ruby.wasm column was measured against the live demo; it is not a like-for-like run. Boot times
are taken on the page's own clock (the first frame in which the conversation is laid out).

Before an optimization pass these were 122 ms, 1238 ms, 23 ms and 39 ms; what changed and what
did not work is in `docs/optimize/compiled-app-speed-report.md`.

## What is the same code

- `lib/instant_record/client.rb` (drain, bootstrap, poll, last-write-wins, rejection rollback) is
  compiled byte for byte.
- The demo's views are untouched except the layout and the Slack sidebar, which lose server-only
  pieces.
- Models change by one include line each, and lose their `server_only` blocks.
- The demo's own importmap, Turbo and Stimulus controllers run unchanged in the page.
- String primary keys work, so the URLs are the real ones.

## How it is put together

| Step | File | What it does |
|---|---|---|
| Carve | `pipeline/carve.py` | Copies `demo/`, keeps only the Todo and Slack demos |
| Seams | `pipeline/vendor_gem.py` | Vendors the gem's Ruby into the app and applies 16 source seams |
| Emit | Roundhouse `--target spinel` | Rails app to a Spinel project |
| Entry | `pipeline/make_wasm_entry.py` | A one-shot entry: one request or one sync pass per run of the module |
| Wasm copy | `pipeline/make_wasm_tree.py` | Single-threaded stand-ins for the runtime's threads, plus patches for compiler bugs |
| Compile | Spinel `--target=wasm32-wasi` | Ruby to C to wasm, SQLite linked in |
| Host | `web/src/` | A worker runs the module per request on an in-memory WASI filesystem saved to IndexedDB |

The 16 source seams are listed, numbered and explained in `pipeline/vendor_gem.py`. The main ones:
the gem's JS-interop transport and notifier become a file-based host seam, `class_eval` and
`descendants` go, the `Syncable` concern is un-nested, and SQLite stands in for PGlite.

## Compiler bugs worked around

Found on Roundhouse main, patched in the emitted output by `pipeline/make_wasm_tree.py`:

- `each_with_index` in a view builds each row and drops it.
- `button_to ..., form: {...}` puts the option on the `<button>`, which detaches it from its form.
- A view's loop variable named like an instance variable (`channel` and `@channel`) shadows it.
- Mass assignment does not cast timestamp strings.
- A new record gets an empty-string id instead of nil.
- A concern nested in a module is not folded into the models that include it.

Missing from the emitted runtime: `ActiveRecord#changed`, `Hash#deep_stringify_keys`,
`controller_path` in layouts.

## Not done

- History paging, boot-time eviction and the held-open SSE stream (it polls every second).
- File uploads.
- Two tabs each run their own copy of the local database.
- Atomic write-plus-outbox is not verified.
- Integers are 32-bit on wasm32; nothing hit that, and it is untested.
- The page still says "ruby.wasm" and "PGlite": that text is the demo's own.

## Building it

Needs, all outside this repo:

- Spinel, built from source (developed against commit `7c56323d`), with `make wasm-rt`.
- Roundhouse, built from its main branch (developed against commit `b937108c`).
- wasi-sdk 34 and the SQLite amalgamation (3.54.1).
- Node, and the packages in `web/package.json`.
- For the benchmark: Chrome, `playwright-core`, and this repo's demo Rails server with Postgres.

Copy `toolchain.env.example` to `toolchain.env`, fill in the paths, then:

    python3 pipeline/build.py     # writes web/dist
    node bench/serve.mjs          # serves it on http://127.0.0.1:4174
    node bench/bench.mjs          # builds, measures, and runs the behavior checks

`bench/env.mjs` holds one machine's Rails and Postgres settings; adjust it to yours.

`bench/bench.mjs` prints one JSON object: the timings above and twelve behavior checks against
the Rails sync server (create, toggle, delete, a server write arriving, a rejection rolling back,
a Slack post with its bot reply, a thread reply, reload, a fresh browser bootstrapping, no page
errors).
