# A number in a file the browser compiles has 32 bits

Date: 2026-11-21. From `sync_file` (a record that carries a file). Seen in a compiled build of the demo on Linux x86_64, in headless Chromium and in Node.

## What was believed and was wrong

- **A default in `configuration.rb` is server business.** `lib/instant_record/configuration.rb` is on `vendor_gem.py`'s list: it is compiled into the browser's app. Its `initialize` set `@max_file_size = 2 * 1024 * 1024 * 1024`. Spinel's integer on wasm32 is 32 bits and raises on overflow (`SP_INT_OVERFLOW_MODE_RAISE`), so the first read of `InstantRecord.config` in the browser raised `RangeError: integer overflow in *`.
- **A build that compiles is a build that syncs.** The build passed and the page drew. A write made in that browser still reached the server. What failed was the bootstrap: the sync pass answered `pending=-1`, the worker asked for the bootstrap again every few seconds, and a fresh browser was never sent a row. Nothing reached the page's console.
- **The gem's tests would say so.** They run on CRuby, where the number is fine.

## What holds now

- The two gigabyte default is `InstantRecord::Files::MAX_SIZE`, in `lib/instant_record/files.rb`, which the browser never compiles. `Configuration#max_file_size` starts as `nil`.
- `test/files_test.rb` reads `configuration.rb` and `syncable.rb` and fails when either multiplies numbers or writes one of ten digits.
- A model's file is compiled too. `sync_file max_size:` there must stay under two gigabytes; a larger limit goes in `config.max_file_size` (the initializer is carved out of the browser's app by `carve.py`). The README says so.

## How to look

A sync pass that fails in a compiled app says why on the app's stderr, which the worker does not print. Run the pass in Node:

```js
import { AppHost } from "./compiled/web/src/app-host.js"
const host = new AppHost(new WebAssembly.Module(readFileSync("compiled/web/dist/app-<hash>.wasm")),
  { exchange: () => ({ status: 200, body: bootstrapJson }) })
host.ensureBooted()
const result = host.sync("http://127.0.0.1:3210/instant_record")
console.log(result.pending, result.exit, result.errors)   // -1, 1, ["RangeError: integer overflow in *"]
```

In a page, `window.__spinel.worker` posts `instant_record.debug` messages: a `sync-pass` entry whose path is `-1 pending`, over and over, is this failure.

## When this applies

Before adding a constant or a default to any file on `vendor_gem.py`'s COPY list, or to a model: a size in bytes, a time in milliseconds since 1970, a count multiplied up. After such a change, open a compiled build in a browser with no database and see that it is sent its rows, not only that it builds.
