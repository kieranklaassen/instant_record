# Compiling InstantRecord apps

`bin/rails instant_record:compile` builds a static browser site from a Rails app.
Roundhouse translates the Rails source, Spinel compiles it to WebAssembly, and a
dedicated worker serves local requests from a persistent SQLite connection. The
worker saves database snapshots in IndexedDB and sends pending mutations to the
Rails sync endpoint. This backend uses an experimental compiler toolchain.

## Install the toolchain

Use Python 3, Node and npm, a C toolchain, and the following build inputs:

- [Spinel](https://github.com/matz/spinel) at `7c56323d2`, including its WASI runtime and bundled packages. Build it with `make` and `make wasm-rt`.
- [Roundhouse](https://github.com/rubys/roundhouse) at `b937108ce`. Build the release binary with `cargo build --release`.
- [WASI SDK](https://github.com/WebAssembly/wasi-sdk) 34 and the SQLite 3.54.1 [amalgamation](https://www.sqlite.org/download.html).
- The npm dependencies pinned in the gem’s `compiled/web/package-lock.json`. Binaryen’s `wasm-opt` is optional.

Copy the example configuration and install the JavaScript dependencies in your app:

```sh
gem_dir="$(bundle show instant_record)"
mkdir -p tmp/instant_record/js config
cp "$gem_dir"/compiled/web/package*.json tmp/instant_record/js/
npm ci --prefix tmp/instant_record/js
cp "$gem_dir"/compiled/toolchain.env.example config/instant_record_toolchain.env
```

Fill in absolute paths in the config. Set `WEB_NODE_MODULES` to the directory created by
npm, `RAILS_GEMS` to the directory containing the installed Hotwire gem assets, and
`CACHE` to a writable build cache. The benchmark’s Playwright setting is optional
for application builds. Point `INSTANT_RECORD_TOOLCHAIN` at another config if desired.

## Build and serve

The gem includes SQLite and Prism for compiling migrations on the build machine.
The Rails sync server keeps its existing database.

```sh
bin/rails db:migrate
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
steps before rendering. The database and migration version commit in one
IndexedDB transaction. A failed upgrade keeps the previous database and outbox.
An older release cannot open a newer saved schema. Fix a bad published migration
with a new, higher-numbered migration and roll forward.

If an earlier compiled app already stored **unversioned** SQLite snapshots,
set `config.instant_record.compiled_migration_baseline` to the numeric Rails
schema version that bundle actually shipped. Publish a versioned baseline
release before changing the schema. Existing profiles with differing unrecorded
schemas require an app-specific migration strategy. A fresh app needs no baseline.

## Demo and compatibility

From this repository, copy the config to `compiled/toolchain.env` and run:

```sh
python3 compiled/pipeline/build.py
node compiled/bench/serve.mjs
```

Open the catalog at `/` or `/home`. Todo and Chat use local writes and background
sync. Ship v2 alters the live SQLite schema and backfills notes. Console offers
compiled ActiveRecord queries. Receipts measures this browser’s boot, module size
and local/server round trips. The source drawer loads the source for the selected
page on demand. The Sync inspector shows local and network traffic and simulates
Offline and Slow connections.

Spinel compiles code ahead of time. Arbitrary Ruby evaluation, file uploads,
encrypted attributes, and server-only Rails subsystems are outside this browser
backend. Tabs on the same origin and browser profile share
one durable SQLite snapshot. Each write picks up the latest revision and saves
the changed records and outbox together before the browser confirms the write.
Pending changes survive closing every tab and sync when the app reopens online.
The demo's Ship v2 page runs its teaching migration on demand. Consumer apps
apply their release migrations at boot. The sync server remains authoritative across clients.

## Deploying it

`deploy/` serves the built folder as a static site: nginx in a container, deployed with Kamal.

    SYNC_ENDPOINT=https://your-rails-app.example/instant_record python3 pipeline/build.py
    cp -R web/dist deploy/site
    python3 deploy/scrub_path.py deploy/site/app-*.wasm "$PWD/.build/wasm-tree"
    cd deploy
    cp deploy.env.example .kamal/deploy.env    # fill in, then:
    source .kamal/deploy.env
    kamal deploy --version <a tag for this build>

- The sync server must allow cross-origin requests from the site; the gem's endpoints do.
- Give it its own hostname, or replace the ruby.wasm build on its host (below). It cannot live
  under a path next to that build: that build's service worker takes over every request on its
  origin.
- The module contains the absolute path of the folder it was built in; `scrub_path.py` replaces
  it with a neutral one of the same length.
- Every path that is not a file serves the shell page, so deep links and reloads work.

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
