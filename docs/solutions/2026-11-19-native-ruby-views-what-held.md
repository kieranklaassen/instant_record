# Ruby screens compiled to a native library: what held

Date: 2026-11-19. Answers `docs/plans/2026-11-19-0630-feat-native-ruby-views-plan.md`, units U1 to U4. Ran on Linux x86_64 only. Nothing here has been linked for iOS.

## The answer

The demo, with screens written in Ruby (`InstantRecord::Native::Screen`), goes through Roundhouse and Spinel and comes out as a C library that renders the Inbox as JSON, takes taps, and syncs with the Rails endpoint. A screen compiled with Spinel prints the same bytes as under CRuby (`test/native_spinel_test.rb`), and eight tests drive the built library against the sync endpoint (`demo/test/integration/native_inbox_test.rb`).

## What was believed and was wrong

- **A class may define `to_json`.** The compiled runtime gives every object a `to_json` of its own and that one won, so a screen printed the runtime's generic JSON. A node now writes itself with `json`. Under Spinel, pick a name the runtime does not own.
- **The browser's SQLite settings carry over.** `PRAGMA locking_mode = EXCLUSIVE` and `journal_mode = MEMORY` suit one in-memory connection in a worker. Against a file on disk the app's second connection failed with "database is locked". The native entry drops both.
- **The browser's entry is the native entry with the host swapped.** It also sets `InstantRecord::Client.streaming = true`, because in the browser the page holds the event stream and the worker never polls. Left in, a native `sync` pushed and bootstrapped but never pulled again. A review found it, since the first tests fed every remote change through `stream`. The native entry turns streaming off, and one test now syncs twice with a server write between.
- **The demo still compiled on `main`.** It did not: `MailShell` and `Email::ShellBuildJob` name `Mailbox`, which the carve removes, and Roundhouse stopped at emit. Server-only code that names a carved class has to be carved with it.
- **A lookup's fallback can be a harmless default.** The generated `case` that finds a screen by name returned an empty screen for a name nobody wrote, where CRuby raised. It raises now, and the host reports the message through `ir_error`.

## Smaller facts

- Roundhouse rejects a nested `def` inside `server_only` or `browser_only`. `vendor_gem.py` unwraps them, now for `app/screens` too.
- The runtime writes `storage/secret_key_base` under the working directory when `SECRET_KEY_BASE` is unset. The shim sets a fresh one at boot, since a phone app cannot write beside its binary.
- Spinel's FFI copies a string result, so the shim may free a slot after handing it over.
- A node's fields are strings. A `nil` or an integer given to `text` or `id:` builds a tree and fails in `json`.

## Open

- Render and action inputs are newline-separated fields. An argument holding a newline shifts them. Escape or length-prefix before a renderer exists.
- The screen-name rule is written twice: `InstantRecord::Native.screen_name` in Ruby, and `camelize` in `make_native_entry.py`. Nothing checks that they agree.
- The header asks the host for one serial queue and does not say the host must time its network exchange out.
- `libspinel_rt.a` is linked beside `libinstant_record_app.a`, not inside it.

## Later the same day: what the phone taught

Answers `docs/plans/2026-11-19-0929-fix-native-ios-hardening-plan.md`. Ran on macOS arm64 and in the iPhone 17 simulator.

- **Spinel compiles for iOS.** Its generated C and its runtime built for the simulator with one change, `arc4random_buf` in place of `getentropy`.
- **A hash of strings is the way to pass values.** `row ..., with: { "id" => entry.id.to_s }` and `JSON.parse` of nested objects compile. A value in `with:` that is not a string (`entry.id` straight from a model) compiles and then fails at run time with "wrong argument type Hash (expected Hash)". Write `to_s`.
- **A module included in two screens goes through Roundhouse**, with `server_only` and `browser_only` halves in it.
- **`fetch_history` is not how a screen pages.** It needs a sync window the model does not declare, keeps its marks in memory, and does not exist on the server's model. The mailbox asks the records address through the client's transport and keeps the page's receipt in `SyncMetadata`.
- **A destructive swipe and an asynchronous answer collide.** With the destructive role the list removes the row itself at once, and the app's own update arrives a moment later from another thread. The two could meet in one batch update and crash. The swipe is tinted red instead.
- **Run the largest text size.** The hand-written summary card squeezed its words into one narrow column there. Nothing else would have shown it.
- **The Open items above are closed**: inputs are JSON, the screen-name rule is one Ruby method the build calls, and the header says the exchange needs a timeout.
- **Another app did not build until three things in this repository were fixed**: screens were not staged, the schema version was asked of a host slot that does not exist, and the gem did not ship the Swift package.
