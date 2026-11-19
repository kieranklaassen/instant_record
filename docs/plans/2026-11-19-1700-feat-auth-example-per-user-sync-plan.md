---
title: Authentication Example With Per-User Sync - Plan
type: feat
date: 2026-11-19
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Authentication Example With Per-User Sync - Plan

## Goal Capsule

- **Objective:** A visitor to the demo can sign in as different people, sign out, see the session the server holds, and watch records they may not see stay out of their browser, so InstantRecord has one clear example of sessions and permissions in a local-first Rails app.
- **Means:** per-identity scoping of the gem's four sync endpoints (KTD1 to KTD5), an identity reset in the client (KTD6), and a new `/auth` demo built on them (KTD7, KTD8).
- **Authority:** Kieran's request of 2026-11-19, then this plan, then `AGENTS.md`.
- **Execution profile:** one branch, merged to `main` with a merge commit per `AGENTS.md`. No pull request.
- **Stop conditions:** the gem's tests or the demo's tests fail on the merged result; a scoped record reaches a client whose identity may not see it in any test; the change breaks the compiled build's carve step.
- **Who finishes:** the implementing agent merges and pushes `main`.

---

## Product Contract

### Summary

The sync endpoints have no authentication today, and every synced model goes to every client. The README names per-user scoping (`syncable_to`) as roadmap. This change builds it, then adds an Auth demo at `/auth` with real Rails sessions, several people with different permissions, and notes that only the right people's browsers ever receive.

### Problem Frame

Anyone evaluating InstantRecord for a real app asks first how sign-in and private data work when the database is in the browser. The honest answer today is that they do not: a synced secret is sent to every visitor, signed in or not, and any client may write any synced record. The Todo demo carries a comment where authentication would go, and nothing shows it working. Without an example that holds, the library reads as a toy for public data.

### Requirements

**Sync scoping in the gem**

- R1. An app can tell the gem who a sync request comes from, using the request (session, cookies, headers). With nothing configured, the gem behaves exactly as it does today.
- R2. A syncable model can declare which of its records a given identity may see, including the signed-out identity. A model with no declaration stays visible to everyone, as today.
- R3. A fresh client's first sync and its history pages contain only records its identity may see.
- R4. The change stream delivers a change to a scoped model only to identities that may see the record now. A record a client holds that its identity may no longer see is removed from that client.
- R5. A model can declare which records an identity may write, separately from which it may see. A client mutation on a scoped model is applied only when the identity may write the record before the write (update, destroy) and after it (create, update). With no write declaration, what an identity may see is what it may write. Otherwise the mutation is rejected and the client rolls back, as with any rejected write. No reply to a mutation reveals whether a hidden record exists or anything it holds.
- R6. When the identity behind a browser changes (sign in, sign out, switch person), the browser drops what it synced and its queued writes on its next sync request, and syncs again as the new identity. From that request on, nothing the old identity held stays readable in the local database. The demo makes that request at once.

**The Auth demo**

- R7. `/auth` lets a visitor sign in as one of several seeded people, switch between them, and sign out. Sign-in sets a real Rails session cookie on the server.
- R8. The page shows the session as the server sees it: who is signed in, their role, and when they signed in. Signed out, it says so.
- R9. The page lists notes with four audiences: everyone, any signed-in person, one person only (the owner), and admins only. Each note shows its audience.
- R10. A visitor sees and holds only the notes their identity may see. Signed out, that is the public notes alone. A person-only note is seen by its owner and nobody else, the admin included.
- R11. A signed-in person can add a note and choose its audience, and can change or delete their own notes. An admin can change or delete any note they can see. Nobody can write a note as someone else, and a signed-out visitor cannot write at all.
- R12. The page proves the boundary: it asks the server's sync endpoint directly, as this browser, and shows how many notes the server holds against how many it sent, and it attempts a write the identity may not make and shows the server's rejection.
- R13. The demo is listed with the other demos on the home page and in the top bar, follows the shared design tokens, and works in both runtimes (Rails-rendered and compiled).

**Documentation**

- R14. The README's auth section describes what now exists: the identity hook, the two model declarations, the four enforcement points, the identity reset, and the limits in Scope Boundaries. The roadmap line about `syncable_to` is removed.

### Scope Boundaries

- No passwords, sign-up, or password reset. People are seeded and chosen from a list, and the page says that a real app puts its own sign-in (Devise, `has_secure_password`) in the same place. The session cookie and everything after it are real.
- No field-level permissions. A record is visible to an identity whole or not at all.
- No cross-origin session sync. Cookie sessions need the sync endpoints and the session door on the page's origin (`config.instant_record.compiled_host`, or a proxy in front of both). The wildcard CORS headers stay as they are and do not allow credentials. A compiled build pointed at a sync server on another origin is always the signed-out identity; the compiled `/auth` page says so when its session request shows it. How the deployed demo is hosted is not recorded in the repo and is a question for Kieran in the report.
- A change stream already open keeps the identity it opened with until its window closes (25 seconds by default); R6 is stated from the next sync request for that reason. A browser that keeps an old stream open on purpose receives, for at most that window, changes its previous identity was allowed a moment before. The demo asks for a fresh sync right after sign-in and sign-out.
- The email demo's own scoped sync endpoints (`Email::SyncController`) are not moved onto the new mechanism.
- No encryption of the local database.

### Assumptions

- Kieran chose on 2026-11-19, on a decision card, to build per-user sync into the gem over keeping secrets as an unsynced, server-rendered model.
- A separate write declaration (`writable_by`) is this plan's choice, made after review showed that "may see" as the only rule lets any reader republish or delete a record.
- "Secret stuff" is modeled as notes with an audience. The four audiences are this plan's choice to show signed-out, signed-in, per-person and per-role permissions in one list.
- The declaration is named `syncable_to`, the name the README's roadmap already uses.
- Three seeded people are enough: one admin and two members.
- An unscoped write queued at the moment of a sign-in is dropped with the rest of the outbox; the narrow window is accepted and named in the README's limits.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Identity comes from one configured block.** `InstantRecord.configure { |c| c.sync_identity = ->(request) { ... } }` returns whatever object the app uses for a person, or nil when signed out. The engine controllers call it once per request. Unset means "no identities", and every scoping branch below is skipped, which is what keeps existing apps and the other demos unchanged (R1). A block over the request, not a `current_user` helper, because the engine controllers are `ActionController::API` and do not share the app's `ApplicationController`.
- **KTD2. Visibility is a relation, declared on the model.** `syncable_to { |identity| where(...) }` is evaluated on the server only and returns the records that identity may see. One relation serves all four endpoints: merged into the bootstrap and history queries, and used as an `exists?` check for stream filtering and mutation authorization. A relation, not a per-record predicate, so bootstrap stays one query per model.
- **KTD3. The stream filters by what is visible now, and sends current state.** The change log is global and holds historical payloads. For a scoped model the stream checks which changed ids are in the identity's relation (one query per model per poll) and sends those with the record's current attributes and version, not the logged payload, so a state from before a record was shared never leaks. Changes to records outside the relation are sent as a destroy with an empty payload: harmless to a client that never held the record, and the revocation R4 asks for to one that did. Destroy events pass through unchanged; they carry an id and nothing else.
- **KTD4. Mutations are authorized inside the write's transaction, against a write relation.** `writable_by { |identity| where(...) }` returns the records an identity may write, and defaults to the `syncable_to` relation. Update looks the record up through the write relation and answers "record not found" when it is absent, the same reply a missing record gets (R5). Destroy of a record outside the write relation answers `applied`, deletes nothing and writes no change-log row, whether the record is hidden or absent, because that is what a destroy of a missing id answers today. Create and update check the write relation again after the save and raise to roll back with a "not permitted" rejection, which is what stops a forged owner or a change of audience the writer may not make. Every `server_attributes` in a result is read through the identity's visible relation, on every rescue path, so a create that reuses a hidden record's id is answered exactly as a not-permitted create, with no attributes. The existing rejection path returns the result and the client rolls back.
- **KTD5. Each identity has an opaque key, and the server names it.** The key is a short digest the gem derives from the identity object (its class and id, or the identity's own `sync_identity_key` when it defines one, for apps where a role change must count as a new identity; a fixed word for nil). Bootstrap returns it only when a `sync_identity` is configured; unset, the body is unchanged. The client stores it beside the cursor and sends it with every events and mutations request. This is how either side notices a change of identity without the browser runtime ever reading a cookie.
- **KTD6. An identity mismatch resets the client.** When the key a client sends differs from the request's current identity, the events endpoint answers with a single reset event and the mutations endpoint rejects the batch. The reset event names the scoped model types, since the browser build cannot know them (`syncable_to` lives in `server_only` and is stripped from it). On reset the client deletes the rows of exactly those types, its outbox, its history marks and its cursor on the pass that receives the event, and bootstraps as the new identity on the next pass (R6). Unscoped models are left alone. Queued writes are dropped, not replayed: they were made as someone else.
- **KTD7. The demo's people are not synced; its notes are.** `AuthUser` is a plain server-side model (name, role). `AuthNote` is syncable with an `audience` and an `owner_id`, and its `syncable_to` and `writable_by` blocks are the whole permission rule, readable in one place. The browser never holds the people table, so the session panel and the person list come from the server.
- **KTD8. One controller serves both runtimes; the session lives in a server-only door.** `Auth::NotesController` renders the list from `AuthNote.all` in the browser (already scoped by sync) and from the same `syncable_to` relation, evaluated for the session's person, on the server, with the `server_only` / `browser_only` split the Todo demo documents. `Auth::SessionsController` (show, create, destroy) runs on the server only; the compiled page reaches it through `InstantRecord.server_url`. After a session change the page asks for a sync so the reset in KTD6 happens at once.

### High-Level Technical Design

```
sign in (POST /auth/session, server) -> session[:auth_user_id]
        |
        v
page asks for a sync
        |
        v
client -> GET /instant_record/events?after=N&identity=<old key>
server: sync_identity.(request) -> new key != old key -> "reset" event
client: wipe scoped models, outbox, cursor
client -> GET /instant_record/bootstrap
server: each model's syncable_to relation for this identity -> records + cursor + identity key
client: local SQLite now holds only this person's notes
```

Directional only. The names of the wire fields are settled during implementation.

### Implementation Constraints

- Every scoping branch is behind "a `sync_identity` is configured and the model declares `syncable_to`". The gem's existing tests pass unchanged.
- `syncable_to`, `writable_by` and `sync_identity` never run in the browser runtime. Models declare the two blocks inside `server_only do ... end`, which `compiled/pipeline/vendor_gem.py` already strips from the browser build (`demo/test/compiled_carve_test.rb` is the pattern for holding that).
- `lib/instant_record/client.rb` compiles through Roundhouse and Spinel. Keep new client code to constructs already used in that file.
- A new synced model is added to `compiled/pipeline/make_wasm_entry.py` (two lists) and `MailShell::MODELS`; new routes are added to `compiled/pipeline/carve.py`; layout and home changes are mirrored in `compiled/pipeline/vendor_gem.py` and `compiled/pipeline/demo/views`.
- The compiled page reaches the server only through marked requests that `compiled/web/src/worker.js` `serverRequest` allows by name, and it forwards no headers. So `Auth::SessionsController` is an `ActionController::API` controller like `Slack::ResetsController`, takes JSON only, has no forgery token, and relies on the session cookie's `SameSite=Lax`. Sign-out is a POST.
- The compiled worker prepares sync requests itself (`sync_plan` in `compiled/pipeline/make_wasm_entry.py`) and `worker.js` refuses a request from Ruby that does not match byte for byte. Any change to what the client sends is made in both places.
- The mutations endpoint is cookie-authenticated once an identity is configured. It must not accept a cross-site form post: require a JSON content type on that path when an identity is configured, and rely on the session cookie's `SameSite=Lax` default.

---

## Implementation Units

### U1. Identity and `syncable_to` in the gem's read paths

**Goal:** R1, R2, R3, R4. **Depends on:** nothing.

- `lib/instant_record/configuration.rb`: `sync_identity`.
- `lib/instant_record.rb`: resolve the identity for a request, derive its key, `visible_scope(model, identity)`.
- `lib/instant_record/syncable.rb`: `syncable_to`, `writable_by` and their readers.
- `app/controllers/instant_record/bootstraps_controller.rb`, `records_controller.rb`: merge the relation; bootstrap returns the identity key.
- `app/controllers/instant_record/events_controller.rb`: filter and rewrite scoped changes per KTD3; reset event on a key mismatch per KTD6.

**Tests:** `test/sync_identity_test.rb` (new), `test/bootstrap_test.rb`, `test/event_stream_test.rb`, `test/fetch_history_test.rb`.

- Nothing configured: bootstrap, records and events answer byte-for-byte as before.
- Bootstrap as nil, as a member and as an admin returns exactly each one's records, and a key that differs between them.
- A history page never contains a record outside the relation.
- The stream sends a visible change with current attributes, sends an invisible create or update as an empty destroy, and passes destroys through.
- A record that leaves the relation produces a destroy for that identity and a normal update for one that still sees it.
- A stale identity key gets one reset event and no changes.

### U2. Mutation authorization

**Goal:** R5. **Depends on:** U1.

- `app/controllers/instant_record/mutations_controller.rb`: resolve the identity, pass it to the applier, reject a batch whose key is stale, require JSON when an identity is configured.
- `app/models/instant_record/mutation_applier.rb`: KTD4.

**Tests:** `test/mutation_authorization_test.rb` (new).

- Create inside the relation applies; create outside it is rejected and no row or change-log entry is left.
- Update of a hidden record answers "record not found". Destroy of a hidden record answers exactly as destroy of a missing id does, leaves the row, and logs no change.
- Update and destroy of a record the identity may see but not write are rejected.
- A create (valid, invalid, and with an unknown column) that reuses a hidden record's id returns no attributes and a reply that does not differ from a not-permitted create.
- A create with another person's owner is rejected.
- An update that would move a record out of the writer's write relation is rejected and rolled back.
- A model with `syncable_to` and no `writable_by` lets an identity write what it sees.
- A signed-out identity cannot write a scoped model.
- A replayed mutation id returns its first result.
- An unscoped model accepts writes from anyone, as before.

### U3. Client identity reset

**Goal:** R6. **Depends on:** U1.

- `lib/instant_record/client.rb`: store the key from bootstrap; include it in the drain payload and the poll URL; handle the reset event in `apply_events` / `consume_stream` as well as `poll_changes`.
- `compiled/pipeline/make_wasm_entry.py`: `sync_plan` builds the identical keyed mutation body, and reports the stored key with the cursor.
- `compiled/web/src/app-host.js`, `compiled/web/src/worker.js`: the worker's `/events` URL carries the key; when a consumed batch leaves the client un-bootstrapped it forgets its cached cursor and starts a sync pass at once, so the next pass bootstraps and never polls from zero.

**Tests:** `test/client_test.rb`, `test/sync_loop_test.rb`.

- Bootstrap stores the key; later requests carry it.
- A reset event deletes the rows of the types it names, the outbox, the history marks and the cursor, leaves other rows, and the next pass bootstraps.
- A reset delivered through `consume_stream` leaves `bootstrapped?` false.
- With no key in the bootstrap body, no key is sent and nothing changes.

### U4. The Auth demo

**Goal:** R7 to R13. **Depends on:** U1, U2, U3.

- `demo/db/migrate/*`: `auth_users`, `auth_notes`. `demo/app/models/auth_user.rb`, `auth_note.rb`. Seeds for three people and a note of each audience.
- `demo/config/initializers/instant_record.rb`: `sync_identity` from `session[:auth_user_id]`.
- `demo/config/routes/auth.rb`, `demo/app/controllers/auth/notes_controller.rb`, `auth/sessions_controller.rb`, `demo/app/views/auth/**`, `demo/app/assets/stylesheets/auth.css`.
- Top bar, home page listing, View source entry, and the compiled mirrors named in Implementation Constraints.
- The proof panel (R12): a small script that fetches the bootstrap as this browser and posts one forbidden mutation, through marked URLs, and a server-only count of all notes for the comparison.
- `compiled/web/src/worker.js`: `serverRequest` allows the session door, the bootstrap and the mutations endpoint, and forwards their bodies. `compiled/pipeline/vendor_gem.py`: the rewrite of each `InstantRecord.server_url(...)` call, as done for `slack_reset_path`.

**Tests:** `demo/test/controllers/auth/notes_controller_test.rb`, `auth/sessions_controller_test.rb`, `demo/test/controllers/instant_record/auth_sync_test.rb`, `demo/test/models/auth_note_test.rb` (all new).

- Sign in sets the session, sign out clears it, switching replaces it; the session panel reflects each.
- `/auth` signed out lists only public notes; as a member, public, member and own notes; as the admin, public, member, admin and own notes, and not another person's person-only note.
- `/instant_record/bootstrap` with each session cookie returns the same sets, and no other demo's records are missing from it.
- A signed-out create, a signed-out update of a public note, a member's write to another member's note, and a member's create with a forged owner are rejected through `/instant_record/mutations`.
- `AuthNote`'s `syncable_to` and `writable_by` for each identity and audience.
- The carve test still passes with the new model and routes.

### U5. Compiled check and docs

**Goal:** R13, R14. **Depends on:** U4.

- `compiled/test/auth.mjs` (new), run with the compiled site and the Rails server on one origin: in the compiled build, sign in as a member, see the member's notes, confirm the local database holds no admin note, sign out, confirm the member's notes are gone from the local database, add a note as one person and confirm the other never receives it.
- `README.md`: rewrite "Server-only controller behavior: auth and scoping" and the roadmap line. `CHANGELOG.md`. `CONCEPTS.md` if it defines sync terms this changes.

---

## Verification Contract

- `bundle exec rake test` in the gem, and `bin/rails test` in `demo/`, on the branch with `origin/main` merged in.
- A browser pass over the Rails-served `/auth`: sign in as each person, sign out, read the proof panel, with screenshots.
- `compiled/test/auth.mjs` against a compiled build. The compiled toolchain lives on Kieran's Mac; if it cannot be reached, the build is made in the cloud. If neither runs, the merge message and the report say the compiled runtime was not exercised.
- A read of the diff for any path that returns a scoped record without passing through the relation.

## Definition of Done

- R1 to R14 hold, each backed by a test or a named check above.
- The other demos behave as before in both runtimes.
- The branch is merged to `main` and pushed, and what did not run is said in the merge message.
