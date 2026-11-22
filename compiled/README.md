# Compiling InstantRecord apps

`bin/rails instant_record:compile` builds a static browser site from a Rails app.
Roundhouse translates the Rails source, Spinel compiles it to WebAssembly, and a
dedicated worker serves local requests from a persistent SQLite connection. The
worker saves database snapshots in IndexedDB and sends pending mutations to the
Rails sync endpoint. This backend uses an experimental compiler toolchain.

## Install the toolchain

Use Ruby 3.3+, Node and npm, a C toolchain, and the following build inputs:

- [Spinel](https://github.com/matz/spinel) at `7c56323d2`, including its WASI runtime and bundled packages. Build it with `make` and `make wasm-rt`.
- [Roundhouse](https://github.com/rubys/roundhouse) at `b937108ce`. Build the release binary with `cargo build --release`.
- [WASI SDK](https://github.com/WebAssembly/wasi-sdk) 34 and the SQLite 3.54.1 [amalgamation](https://www.sqlite.org/download.html).
- The npm dependencies pinned in the gem’s `compiled/web/package-lock.json`. Binaryen’s `wasm-opt` is optional.

Copy the example configuration (or run `bin/rails generate instant_record:install`) and install the JavaScript dependencies in your app:

```sh
gem_dir="$(bundle show instant_record)"
mkdir -p tmp/instant_record/js config
cp "$gem_dir"/compiled/web/package*.json tmp/instant_record/js/
npm ci --prefix tmp/instant_record/js
bin/rails generate instant_record:install
```

Fill in absolute paths in `config/instant_record_toolchain.env`. Set `WEB_NODE_MODULES` to the directory created by `npm ci` (`tmp/instant_record/js/node_modules`) and `CACHE` to a writable build cache. `RAILS_GEMS` is optional in consumer apps using Bundler — `turbo-rails` and `stimulus-rails` assets are resolved from `Gem.loaded_specs` automatically. `PLAYWRIGHT_NODE_MODULES` is only needed for this repository's benchmarks. Point `INSTANT_RECORD_TOOLCHAIN` at another config if desired.

## Build and serve

The gem includes SQLite and Prism for compiling migrations on the build machine.
The Rails sync server keeps its existing database.

```sh
bin/rails db:migrate
bin/rails instant_record:doctor
bin/rails instant_record:compile
```

The task discovers named models using `InstantRecord.syncable_models`. It reads
your routes, ERB views, models, controllers, helpers, assets and `db/schema.rb`,
then stages the browser build under `tmp/instant_record/compiled`. Run it again
after changing the app. Keep server secrets and server-only logic out of code
shipped to the browser.

Serve `tmp/instant_record/compiled/web/dist` from the root of a static origin.
Return its `index.html` for page routes and serve Wasm with the
`application/wasm` content type. Route `/instant_record` to your Rails server
or build with `SYNC_ENDPOINT=https://your-rails.example/instant_record`.
The standalone compile task stages sources outside the gem.

### Ship on a Rails deploy

```ruby
# config/application.rb
config.instant_record.build_on_precompile = :compiled
config.instant_record.compiled_host = "browser.example.com"
```

Point that hostname at Rails and allow it in your Rails host configuration.
Run `bin/rails assets:precompile` with the compiler toolchain available. Include
`public/instant_record_compiled` from the build in the deployed Rails image.
The hook publishes an immutable release directory and atomically switches the
`current` symlink after a successful build. The gem serves browser navigation and
compiled assets on the configured hostname. Sync requests continue through Rails.
Keep the previous release directory in the image or shared asset store during a
rollout so a tab that just received the old HTML can still fetch its worker and Wasm.
`build_on_precompile = true` also selects the compiled build.

Open compiled tabs check the release manifest on focus, on reconnect, and once
a minute while visible. An idle tab reloads. After input, the tab offers a
reload button so the reader can finish editing. Applications with custom draft
state can cancel the `instant-record:before-update` window event. When adopting
this mechanism from an older bundle, reload those tabs once.

### Migrate an existing browser database

Commit the Rails migration and its updated `db/schema.rb` together. The
compiler reads the configured Rails migration paths. Literal `create_table`,
`add_column`, `add_index`, and `execute` operations in `change` or `up` are
compiled to SQLite SQL. For example, a release can add a column and backfill
it with a SQL UPDATE that runs against each browser's existing rows.

For a Ruby backfill, adapter-specific SQL, or another unsupported operation,
provide `db/browser_migrate/<same migration filename>.sql`. This file contains
the SQLite equivalent for the whole migration. For renames and deletions,
handle any queued mutations that refer to the old fields and keep the sync
server compatible with older clients. An unsupported declaration without a
companion file fails the build before publication.

New profiles start at the dumped schema. Returning profiles run only pending
steps before rendering, with each compiled migration version wrapped in an
atomic SQLite transaction (`BEGIN IMMEDIATE` / `COMMIT` / `ROLLBACK`). The
database and migration version commit together in one IndexedDB transaction. If
a browser encounters schema drift, a release rollback, or a failed migration,
the worker automatically extracts pending `instant_record_outbox` rows, rebuilds
a clean database at the target schema, re-inserts the preserved outbox rows,
and drains + re-bootstraps against the server.

Check in `db/instant_record_lock.json` (generated by `bin/rails instant_record:schema:lock`
or on first compile) and run `bin/rails instant_record:schema:verify` (or
`bin/rails instant_record:doctor`) in CI. Verification asserts that published
migrations have not been mutated and replays every historical schema version
populated with sample rows and pending `OutboxMutation` rows up to `HEAD`.

For column renames, drops, or rolling-deploy schema skew (N-1 or N+1 clients),
declare `upcast_outbox` on your syncable model (or globally via
`InstantRecord.upcast_outbox`) so queued mutations transform cleanly on the
server before `MutationApplier` writes them.

If an earlier compiled app already stored **unversioned** SQLite snapshots,
set `config.instant_record.compiled_migration_baseline` to the numeric Rails
schema version that bundle actually shipped. Publish a versioned baseline
release before changing the schema. Existing profiles with differing unrecorded
schemas require an app-specific migration strategy. A fresh app needs no baseline.

## Demo and compatibility

From this repository, copy the config to `compiled/toolchain.env` and run:

```sh
bundle exec rake compile   # or: ruby compiled/pipeline/build.rb
node compiled/bench/serve.mjs
```

Open the catalog at `/` or `/home`. Todo and Chat use local writes and background
sync. Ship v2 alters the live SQLite schema and backfills notes. Console offers
compiled ActiveRecord queries. Receipts measures this browser’s boot, module size
and local/server round trips. The source drawer loads the source for the selected
page on demand. The Sync inspector shows local and network traffic and simulates
Offline and Slow connections.

Spinel compiles code ahead of time. Arbitrary Ruby evaluation, multipart form file uploads (use `sync_file` with `frontend/files.js` instead),
encrypted attributes, and server-only Rails subsystems are outside this browser
backend. Tabs on the same origin and browser profile share
one durable SQLite snapshot. Each write picks up the latest revision and saves
the changed records and outbox together before the browser confirms the write.
Pending changes survive closing every tab and sync when the app reopens online.
The demo's Ship v2 page runs its teaching migration on demand. Consumer apps
apply their release migrations at boot. The sync server remains authoritative across clients.

## A native library (experimental)

The same models can run outside a browser. `build_native.rb` (or `bundle exec rake compile:native`) compiles the demo,
with the screens in `demo/app/screens`, to a C library and a small host program:

```sh
bundle exec rake compile:native   # or: ruby compiled/pipeline/build_native.rb
cd demo && INSTANT_RECORD_NATIVE_HOST=../compiled/.build-native/host bin/rails test test/integration/native_inbox_test.rb
```

A screen is a Ruby class (`InstantRecord::Native::Screen`) whose `body` describes
what to draw and whose `perform` answers a tap. The library has six functions,
declared in `pipeline/native/instant_record_native.h`: `ir_boot` starts the
app on a SQLite file, once in a process, `ir_open` closes that file and opens
another, and `ir_call` runs `render`, `action`, `sync`, `stream` and the rest
the header lists, each taking and returning a string. `render` and `action`
take one JSON object (the screen's name and its params, and for an action its
name, args and a form's values) and a render returns the screen as JSON. The
library never opens a connection: when it needs the server it calls the host
back with one request and the host answers. A host that must not wait on the
network inside a call asks `sync_plan` and `cursor` what a pass will request,
fetches those itself, and answers the pass from what it fetched.

Both builds end with the same entry, built in Ruby by
`InstantRecord::Compiler::EntryBuilder`. The class a screen's file holds is
decided in Ruby alone (`InstantRecord::Native.class_name`).

`pipeline/native/host.c` is that host with no screen, driven over standard
input. The test starts it, answers its requests from the Rails app, and checks
that the mailbox renders the same bytes as under CRuby, that an archive made
with no connection waits in the outbox and reaches the server later, that the
database survives a restart, that a rejected write is undone, that a pass
answered from replies fetched beforehand asks for nothing else, that a typed
reply keeps every character, that a page of older mail handed to the
`history` entry lengthens the list, and that opening another inbox's file
closes the first.

A list that goes on at the server ends in a `more` element, which names what
to ask the sync address's records door for. The host fetches that page and
hands it to `history`; the screen reads back whether more is left. Code that
runs only in the compiled app is marked `client_only` (the same thing as
`browser_only`, by the name that fits a phone).

Another Rails app builds its own library with `bin/rails instant_record:native`
(add `[iphonesimulator]` or `[iphoneos]` for iOS), which stages the app with
its `app/screens` as `instant_record:compile` stages it for the browser.
`bin/rails generate instant_record:ios Name --screen first` writes a thin
Xcode project that links the result. While developing, the phone can ask Rails
for its screens and skip the build: with `config.instant_record.native_dev`
on, in a local environment, `POST <mount>/native/render` and `/native/action`
take what the library takes and answer from the same screen classes under
CRuby. They answer only requests from the same machine, since a screen's
action writes as whoever its params name.

A screen can also hand props to a view written in SwiftUI (`swift "Name" do
prop ... end`), as a Rails action hands a React page its props.

### On iPhone

```sh
bundle exec rake "compile:native[iphonesimulator]"   # or: ruby compiled/pipeline/build_native.rb iphonesimulator
```

builds the same library for the iOS simulator, with Spinel's runtime and the
packages the app uses compiled from Spinel's sources beside it
(`.build-native/iphonesimulator/libinstant_record_app.a` and
`libspinel_rt.a`). `native/ios` holds a SwiftUI renderer and the Inbox as an
app that links them. [native/ios/README.md](../native/ios/README.md) has the
build steps and the two ways to draw a screen.

What ran, on macOS arm64 with Xcode 27.2 and the iPhone 17 simulator on iOS
26.5:

- The library and host build on macOS with no change, and the test above
  passes there (9 runs).
- Spinel's generated C, its runtime and SQLite compile and link for the
  simulator with one change: the iOS SDK has no `<sys/random.h>`, so the shim
  uses `arc4random_buf` on Apple platforms.
- In the simulator the Inbox lists mail from its local database, opens a
  conversation and marks it read, archives with a swipe, switches inbox and
  filter from its bar menus, and archives with the server stopped. The
  archive reached the server on the next launch after it came back.

`build_native.rb iphoneos` builds the same two libraries for a device, and the
Inbox builds against them unsigned. What did not run: nothing was signed or
installed on a phone.

## Deploying it

`deploy/` serves the built folder as a static site: nginx in a container, deployed with Kamal.

    SYNC_ENDPOINT=https://your-rails-app.example/instant_record ruby pipeline/build.rb
    cp -R web/dist deploy/site
    ruby deploy/scrub_path.rb deploy/site/app-*.wasm "$PWD/.build/wasm-tree"
    cd deploy
    cp deploy.env.example .kamal/deploy.env    # fill in, then:
    source .kamal/deploy.env
    kamal deploy --version <a tag for this build>

- The sync server must allow cross-origin requests from the site; the gem's endpoints do.
- Give it its own hostname, or replace the ruby.wasm build on its host (below). It cannot live
  under a path next to that build: that build's service worker takes over every request on its
  origin.
- The module contains the absolute path of the folder it was built in; `scrub_path.rb` replaces
  it with a neutral one of the same length.
- Every path that is not a file serves the shell page, so deep links and reloads work.
- The build copies the app's `app/views/pwa/service-worker.js` to `/service-worker.js`, and the
  demo's `application.js` registers it. It caches the shell (the page, `/harness`, `/assets`, the
  module, the fonts), so a reopened app starts with no connection; it leaves every sync request
  and the change stream alone. It keeps the two newest modules. Pending changes are still sent
  only while the app is open: a service worker cannot drain the outbox, which lives in the
  app's database. When hosting through Rails (`config.instant_record.compiled_host`), `InstantRecord::CompiledSite` serves `/service-worker.js` with `cache-control: no-cache` whenever the compiled build includes one.

### Replacing the ruby.wasm build on its host

A browser that visited the ruby.wasm build still has its service worker. Three things make the
switch clean for it:

- Keep `/instant_record` on that host going to the Rails app and send everything else here.
  With kamal-proxy that is the Rails service deployed with `--path-prefix /instant_record
  --strip-path-prefix=false` and no TLS options; the service on the root path carries TLS for
  the host.
- Copy `deploy/rails.sw.js` into `deploy/site/` before building the image. The old worker's
  browser asks for that path on its next visit; this file takes the old worker's place, removes
  itself, reloads the tab and leaves the old local database intact.
- `nginx.conf` answers `/app.wasm` with 404. That stops the old worker from starting its app,
  and from opening its change stream, on that one last visit.

Measured in Chrome: a returning browser shows the old worker's error text for about three
seconds, reloads by itself, and is on this build after about four. A first visit is not affected.
