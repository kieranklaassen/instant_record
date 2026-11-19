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
| `keyboard.js`, `focus.js` | `useKeyboardNavigation`: a focused row, a scroll registry, focus that survives a redraw |
| `chord.js`, `shortcuts.js` | `useShortcuts`: one table of bindings (keys, label, group, when it applies) that the key handler, the key list and the key caps on buttons all read |
| `range.js`, `selection.js` | `useSelection`: a set of selected ids with an anchor, a range to any row, select all |
| `held.js`, `undo.js` | `useUndoable`: a write held for five seconds so it can be taken back, sent when the time passes or the page is left |

The second half of that table came with the polish of 2026-11-19 (`docs/plans/2026-11-19-0536-feat-inbox-polish-plan.md`), which also added `write` to `http.js`: a form post that does not visit, so marking twenty rows does not redraw the page twenty times. The files that hold logic and no React (`chord.js`, `range.js`, `held.js`, `focus.js`) are the ones with node tests, since the package has no dependencies of its own to import React from.

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

## Not verified

The compiled toolchain (Spinel, Roundhouse) was not available where this was built, so **nothing here has run in the compiled runtime**. That covers:

- whether Roundhouse compiles the controller's new Ruby (`JSON.generate` of a nested hash, `gsub`, a hash built by assignment);
- `http.js` against the real worker, and so every local read and write, the offline walk (R13), and the Offline switch;
- `compiled/pipeline` now copying `app/assets/builds` and dropping `config/initializers/inertia_rails.rb`;
- the change list on its way through the worker (`compiled/web/src/changes.js`, `app-host.js`, `worker.js`, `main.js`), and whether Spinel compiles the Ruby that writes it. The Ruby is covered by the gem's tests and the parser by a node test;
- `compiled/test/mail-volume.mjs` and `compiled/test/shared-inbox.mjs`, which drive the old markup (`fragment=1`, `.mail-older`) and need rewriting against the new page.

What did run: the Rails suite, the gem suite, the hook's unit tests, and a walk of the Rails-served page in Chromium (keys, 10,000 messages, two personas, a narrow screen). Served by Rails alone there is no local database, so that walk exercises Inertia's stock XHR client and a four-second poll in place of the change signal.

## Left out on purpose

`/` does nothing because the demo has no search. Range selection, bulk actions and undo were left out of the first round and built in the polish that followed. That polish leaves out, on purpose: undo for a sent reply (the write landing at once is what the demo shows), an unarchive on the server (undo holds the write instead, so the mail log stays append-only), and one request for a bulk action (it is one light write per conversation and then one reload).

The polish ran in Chromium against the Rails-served page only: keys, selection, archive and undo, the reply flow, two members, a narrow window and a refused write. As above, none of it has run in the compiled runtime. There `write` goes to `window.fetch`, not through the Inertia client `http.js` hands to the local database, so whether the worker answers it is the first thing to check.
