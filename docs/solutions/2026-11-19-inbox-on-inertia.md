# The Inbox on Inertia and React: what held

Date: 2026-11-19. Answers `docs/brainstorms/2026-11-19-inbox-inertia-react-requirements.md`.

## The answer

InstantRecord works under Inertia, and the page stays an ordinary Inertia page. Its state is its props and its address. Reading is a partial reload, writing is a form post, and nothing holds a second copy of the data.

Inertia 3 already has the two seams this needed, and the demo fills each with one small file:

- **Live props.** A page object names, under `liveProps`, the events each prop listens for, and Inertia reloads a prop when its event arrives: throttled, paused in a hidden tab, repeated on reconnect. `app/frontend/instant_record/live.js` is a transport with one event, the gem's `instant-record:records-changed`.
- **A pluggable HTTP client.** In the compiled runtime `app/frontend/instant_record/http.js` sends Inertia's requests to the app's own controller in the worker, so a partial reload is answered by the local database and no request reaches Rails.

`createInertiaApp({ ...instantRecord(), resolve, setup })` wires both.

## How a change reaches the screen

1. Sync or a local write touches the local database and the gem fires its event.
2. Inertia marks `mail` and `thread` dirty and reloads them, once per burst.
3. The controller answers from the local database. Inertia merges the props and re-renders.
4. Rows are memoized on their own data, so a change to one conversation redraws one row. The list is virtual, so only the rows on screen exist.

A write is `router.post` or `useForm`, with Inertia's `optimistic` option for archive and read. Rails redirects back and the answer carries fresh props.

## What it cost

About 370 lines in `demo/app/frontend/instant_record/`, none of which knows about mail:

| File | Job |
| --- | --- |
| `live.js` | The live transport |
| `http.js` | The HTTP client for the compiled runtime |
| `window.js` | `useLiveWindow` (a list prop that widens with the scroll), `useLiveParam` (a query parameter and the props that depend on it), `useStableRows` |
| `LiveList.jsx` | A react-virtuoso list that holds the reader's place while rows arrive above |
| `keyboard.js` | `useKeyboardNavigation`: a focused row, a key map, a scroll registry, focus that survives a redraw |

## What the gem would need to offer it properly

1. **Changed ids in the signal.** The event says something changed, not what. So each change reloads the whole list prop. Inertia's live envelope can carry props by value, which would skip the reload: that needs the gem to say which records changed.
2. **`liveProps` from Ruby.** inertia_rails 3.23 has no word for live props, so `config/initializers/inertia_rails.rb` prepends eight lines to its renderer. A `live:` option on `render inertia:` belongs upstream or in this gem.
3. **Headers through the worker.** The worker's requests carry no headers, which is why `http.js` says `_inertia=1` and `_only=` in the address and the controller has a `browser_only` half that writes the page object by hand. With headers, the compiled controller could be the same code as the server's.
4. **The files themselves.** `instant_record/` is written to move into the gem as an npm package.

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
- `compiled/test/mail-volume.mjs` and `compiled/test/shared-inbox.mjs`, which drive the old markup (`fragment=1`, `.mail-older`) and need rewriting against the new page.

What did run: the Rails suite, the gem suite, the hook's unit tests, and a walk of the Rails-served page in Chromium (keys, 10,000 messages, two personas, a narrow screen). Served by Rails alone there is no local database, so that walk exercises Inertia's stock XHR client and a four-second poll in place of the change signal.

## Left out on purpose

Shift+J / Shift+K range selection and bulk actions, as the requirements say. `/` does nothing because the demo has no search.
