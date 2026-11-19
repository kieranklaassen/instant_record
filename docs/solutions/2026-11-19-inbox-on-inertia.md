# The Inbox on Inertia and React: what held

Date: 2026-11-19. Answers `docs/brainstorms/2026-11-19-inbox-inertia-react-requirements.md`.

## The answer

InstantRecord works under Inertia, and the page stays an ordinary Inertia page. Its state is its props and its address. Reading is a partial reload, writing is a form post, and nothing holds a second copy of the data.

Inertia 3 already has the two seams this needed, and the gem's `frontend/` package fills each with one small file:

- **Live props.** A page object names, under `liveProps`, the events each prop listens for, and Inertia reloads a prop when its event arrives: throttled, paused in a hidden tab, repeated on reconnect. `frontend/live.js` is a transport over the gem's `instant-record:records-changed`, with one event per synced model.
- **A pluggable HTTP client.** In the compiled runtime `frontend/http.js` sends Inertia's requests to the app's own controller in the worker, so a partial reload is answered by the local database and no request reaches Rails.

`createInertiaApp({ ...instantRecord(), resolve, setup })` wires both.

## How a change reaches the screen

1. Sync or a local write touches the local database and the gem fires its event.
2. Inertia marks the props made of the changed models dirty and reloads them, once per burst.
3. The controller answers from the local database. Inertia merges the props and re-renders.
4. Rows are memoized on their own data, so a change to one conversation redraws one row. The list is virtual, so only the rows on screen exist.

A write is `router.post` or `useForm`, with Inertia's `optimistic` option for archive and read. Rails redirects back and the answer carries fresh props.

## What it cost

About 400 lines, none of which knows about mail. They ship in the gem, in `frontend/`, as a package an app installs with `npm install "$(bundle show instant_record)/frontend"`:

| File | Job |
| --- | --- |
| `live.js` | The live transport |
| `http.js` | The HTTP client for the compiled runtime |
| `window.js` | `useLiveWindow` (a list prop that widens with the scroll), `useLiveParam` (a query parameter and the props that depend on it), `useStableRows` |
| `LiveList.js` | A react-virtuoso list that holds the reader's place while rows arrive above |
| `keyboard.js`, `focus.js` | `useKeyboardNavigation`: a focused row, a key map, a scroll registry, focus that survives a redraw |

In Ruby, `lib/instant_record/inertia.rb` adds `live:` to `render inertia:`. It names the synced models each prop is made from, and the page object carries `liveProps` with one event per model.

## What the change signal says

`instant-record:records-changed` carries `detail.changes`, a list of `{ type, id }`, when the sync pass can list what it changed (a stream batch or a poll, up to 200 records). The transport reloads a prop only when a record of one of its models is in the list. A bootstrap, an eviction, an acknowledged write and another tab's write are not listed: `changes` is `null` and every live prop reloads.

The ids reach a page as the payload of Inertia's `live` event. Nothing patches a row by value yet: a row here is what the controller makes of several records (its unread mark is a query), so an id alone does not say what the row became.

## What is still missing

1. **Rows by value.** Inertia's live envelope can carry a prop's new value and skip the reload. That needs a way to ask the controller for the rows of given ids, and a list prop keyed by id to merge them into.
2. **Headers through the worker.** The worker's requests carry no headers, which is why `http.js` says `_inertia=1` and `_only=` in the address and the controller has a `browser_only` half that writes the page object and `liveProps` by hand. With headers, and inertia_rails compiled in, the two halves could be one.
3. **`live:` upstream.** The gem prepends to inertia_rails's renderer, which is private to it. A test in the demo fails if an upgrade moves it.

## The open questions, answered

1. **The compiled build.** It serves the same React bundle. The in-browser controller writes the Inertia page object itself (`index.html.erb` for a first load, JSON for a visit).
2. **Where the read runs.** In the worker's SQLite, through the app's controller. There is no SQL from JavaScript, and none was needed.
3. **Build tooling.** Vite writes one file, `app/assets/builds/inbox.js`, and Propshaft serves it. `bin/rails test` and `assets:precompile` build it first. No other demo has a build step.
4. **Older mail.** One data path. The address carries `limit`; scrolling widens the local window (`instant_record.fetch_history`), then the limit. A reload returns to the same depth.

## Verified in the compiled runtime

Later the same day the toolchain was built in a cloud thread (Roundhouse `b937108ce`, Spinel `7c56323d2`, WASI SDK 34, SQLite 3.54.1 built to an amalgamation from its GitHub source) and the demo was compiled and run in Chromium beside a local Rails sync server. What ran there:

- a walk of the Inbox in the real worker: j/k, Enter, reply, archive, older mail fetched from the sync server, compose, reload, with no page error;
- two workers in separate profiles: a message sent in one reached the other in under a second, as a change event carrying `{ type: "MailEntry", id }`, in the same document;
- `compiled/test/shared-inbox.mjs` (offline reply, reload, inbox switch, teammate delivery, a kept draft) and `compiled/test/mail-volume.mjs --incoming` (10,000 messages), both brought up to the new page. `mail-volume.mjs` also passes against the Rails-served page.

What that run found and fixed:

- the layout asked for `controller_path`, which a Roundhouse layout does not have: the bundle's script tag moved into the two roots;
- the first page sat in a `raw` script element behind a `gsub`: it now sits in an escaped `data-page` attribute that `instantRecord()` hands to Inertia;
- the compiled build of `main` did not build at all: the shell snapshot's `MailShell` and `Email::ShellBuildJob` name the server's `Mailbox`, and are now carved out of the browser's copy;
- the source drawer still listed the removed Stimulus controller;
- a link to a conversation deep in the list opened the newest one in a browser that had not scrolled that far, in both runtimes: the list now widens to hold the conversation the address names, and a row's link carries its depth.

## Not verified

- `compiled/test/mail-volume.mjs` with `--all` (the whole inbox) and `--mobile`, and the other compiled tests (`full-demo`, `sync-inspector`, `release-upgrade` and the rest), none of which this change touches;
- a compiled build served by its deploy (nginx, the service worker's cache): `/assets/inbox.js` has no digest in its name there, so a cache that keeps it must be told when it changes;
- any browser but Chromium.

## Left out on purpose

Shift+J / Shift+K range selection and bulk actions, as the requirements say. Search came after this was written: `/` focuses it, and `compiled/test/offline-inbox.mjs` runs it, the background fill and the shell snapshot (`?shell=1`) with this page in a compiled build.
