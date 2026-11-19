---
title: Native Inbox Hardening - Plan
type: fix
date: 2026-11-19
topic: native-inbox-hardening
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Native Inbox Hardening - Plan

## Goal Capsule

- **Objective:** A person using the Inbox on iPhone can trust it: a tap is never held up by the network, a write made offline goes out without being asked, a failure is visible, and they can reply. A Rails developer can change a screen without a four minute rebuild and can build the phone app for an app other than the demo.
- **Means:** Keep the design (a Ruby screen returns a JSON tree, a fixed SwiftUI renderer draws it, taps return through `perform`) and fix its faults in place, in three groups that each merge to `main` on their own.
- **Product authority:** Kieran said "ok lets fix all these" to the critique in the project thread on 2026-11-19 and invoked lfg. Every design choice below is a bet made for him and is his to change.
- **Execution profile:** Branch-and-merge per `AGENTS.md`, no pull requests. Ruby, C and the Linux library are built and tested in the cloud. Swift, the simulator and UI tests run only on Kieran's Mac.
- **Stop conditions:** Stop a group and report if closing and reopening a database cannot be made safe (U3), or if Spinel compiles neither the planned shape of U1 or U7 nor the fallback named under Risks. Neither invalidates the settled decisions; each narrows one unit.
- **Who finishes:** The agent finishes all three groups. Group C's device build ends at an unsigned build, since signing needs Kieran's Apple account.

---

## Product Contract

### Summary

The native Inbox works in the simulator and has known faults: taps wait behind sync, inputs are packed into strings that can shift, a database is leaked on every inbox switch, errors and pending writes are invisible, nothing can be typed, and only the demo can be built. This plan fixes those and adds the three missing pieces that decide whether this is a framework: forms, live updates, and a mode where Rails serves the screens.

### Problem Frame

The first version proved the idea and nothing more. Someone who archives a message on a train sees it stay archived only if they touch the app again once they have signal. Someone on a slow connection taps a row and waits up to ten seconds, because the tap is queued behind the sync the previous tap started. When Ruby raises, the screen simply does not change. And the app can read mail but not answer it, because no typed text can reach Ruby.

For the developer, a one-line change to a screen costs a full compile, the only app the build knows is the demo, and the Xcode project is a hand-written file nobody should maintain.

### Key Decisions

- **Ruby runs on the phone as a compiled library and a generic renderer draws its screens** (session-settled: user-approved — chosen over translating Ruby to SwiftUI source at build time: a translator leaks wherever Ruby and Swift differ and leaves no Ruby on the phone for models and sync). Governs R1 to R20.
- **A screen may hand props to a hand-written SwiftUI view registered by name** (session-settled: user-directed — chosen over stock elements only: Kieran asked for a Swift escape hatch in the style of `render inertia:`). Governs R4, R13.

### Requirements

**Group A: correctness**

- **R1.** A tap is performed and drawn without waiting for any network call in progress or queued.
- **R2.** Sync passes are coalesced: any number of requests made while one runs cause at most one more.
- **R3.** Input to `render` and `action` is one JSON object. A screen reads named params (`params["inbox"]`), and no value can change the meaning of another whatever characters it holds.
- **R4.** A prop carries a string, a boolean, an integer or a date, and arrives in Swift as that type. A prop's name is its own field, not the node's id.
- **R5.** Switching inbox does not leave the previous database open.
- **R6.** A failed render, a tree that does not decode, a failed sync and a write the server rejected each show the person a message. The app shows when it is offline and how many writes are waiting. A screen with nothing to show says so, and the first launch shows that mail is being fetched.
- **R7.** A write queued offline is sent without a tap: on a timer with backoff while writes are pending, and when the network returns.
- **R8.** The phone's sync requests can carry a credential and a sync scope, supplied by the app, on every request.
- **R9.** The native entry is written from one source shared with the browser entry, not by pattern replacement over the browser's output. The rule that names a screen exists once.

**Group B: the screens**

- **R10.** A screen says whether a link pushes or replaces. Icons are named by meaning, and the renderer maps them to SF Symbols. Spacing and line limits a screen relies on are written in the screen.
- **R11.** A row that leads somewhere is a real navigation link with the system's highlight, and its action still runs. Icons have spoken labels, unread is spoken and not only a dot, a swipe action is also an accessibility action, and the layout holds at the largest text size.
- **R12.** A count on the mailbox is true for the whole inbox once the whole inbox is on the phone, and is marked as a floor ("12+") until then. The list loads further pages as it is scrolled, and says when it is loading, when it has reached the end, and when a page failed. "Mark all read" says how many it will mark.
- **R13.** A screen can hold a form: text fields, a toggle and a submit. Submitting sends the values to `perform`. The conversation has a reply form, and a reply written offline is sent later.
- **R14.** A change made elsewhere appears on the phone without a tap, through the library's `stream` entry, while the app is in the foreground.
- **R15.** `ThreadScreen` shares helpers with `MailboxScreen` through a module, and code that runs on the phone is marked `client_only` (with `browser_only` kept as the same thing).

**Group C: reach**

- **R16.** With a launch argument, the app asks Rails for each screen over HTTP and draws the answer, with no compiled library involved. The same screen classes run under CRuby.
- **R17.** `bin/rails instant_record:native` builds the native library for the app it is run in. `bin/rails generate instant_record:native` writes a starter iPhone app and an example screen.
- **R18.** The library and app build for a device (`iphoneos`), unsigned.
- **R19.** The UI tests pass twice in a row against a server they reset themselves.
- **R20.** The Xcode project for the Inbox is generated by the same generator a new app uses.

### Acceptance Examples

- **AE1.** Covers R1, R2. With the exchange stubbed to take three seconds, five taps on five rows are each drawn within 100 ms, and the engine sees at most two `sync` calls.
- **AE2.** Covers R3. A screen opened with a param whose value is `"a\nb/c"` receives exactly that string.
- **AE3.** Covers R7. Archive with the server stopped, start the server, touch nothing: the server holds the archive within the retry interval.
- **AE4.** Covers R13. Type a reply, submit, and the reply shows in the conversation at once and on the web Inbox after sync.
- **AE5.** Covers R16. Edit a string in `mailbox_screen.rb`, pull to refresh, and the phone shows the new string with no build.

### Success Criteria

- Every acceptance example passes on the Mac in the simulator, and the Ruby and C parts of each pass on Linux.
- `bundle exec rake test`, the Spinel parity test and `cd demo && bin/rails test` with the native host pass on each merge.
- A fresh `rails new` app with one syncable model and the generated screen builds and shows a list in the simulator.

### Scope Boundaries

**In scope:** everything in R1 to R20.

**Deferred for later**

- Renaming `browser_only` across the gem and the compiled pipeline. R15 adds `client_only` as an alias; the rename touches 25 files and the browser build and deserves its own change.
- Rendering only the part of a tree that changed. `AppHost` already publishes a screen only when its tree differs and SwiftUI diffs by id, so the cost today is Ruby time, which U6 reduces. Measure before building anything.
- One database holding several sync addresses. U3 closes and reopens instead, so a write still pending in an inbox the person has left waits until they return to it; the banner says so at the switch.
- Sign-in screens. R8 lets an app supply a credential; where it comes from is the app's.
- Android, a signed device build, push notifications, a tab bar, sheets, alerts and search.

**Outside this product's identity**

- Generating SwiftUI source from Ruby.
- The Rails-served mode as the way to ship an app. It is offered for development and for screens that do not need to work offline; offline is what InstantRecord is for.

### Dependencies / Assumptions

- The cloud container has the toolchain at `/home/claude/tools` and no Swift. The Mac has both, in `~/Downloads/instant-record-native`.
- Roundhouse at b937108ce and Spinel at 7c56323d2 stay pinned.

### Sources / Research

- The critique in the project thread, 2026-11-19, and the code it cites on `main` at `ddd4644`.
- `docs/solutions/2026-11-19-native-ruby-views-what-held.md`, whose Open list names the newline framing, the duplicated name rule and the exchange timeout.
- `compiled/web/src/worker.js:16-50`: in the browser the host, not Ruby, adds the sync scope to every request. The phone follows the same division (KTD5).
- `compiled/pipeline/make_wasm_entry.py:54-74`: `sync_plan` reports pending mutations, `handle_sync` returns `pending=N`, and `handle_stream` consumes an event-stream chunk. The phone has these entries and uses only `sync`.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. One JSON object in, per call.** `render` takes `{"screen","params"}` and `action` takes `{"screen","params","action","args","values"}`. `Screen#initialize(params)` replaces `arg`. A link takes `params:` and an element that names an action takes `args:`, each a hash serialised into the node as a JSON object and sent back unchanged. `perform(action, args, values = {})` receives the action's own arguments; the screen's params stay on the instance. The compiled entry parses with the runtime's `JSON.parse`, which the sync client already uses. The existing `swift` element stays as it is and gains typed props (KTD2). Chosen over length-prefixed fields: the host already builds and reads JSON.
- **KTD2. Typed props by a tag on the node.** A `prop` node gains `name` and a `type` of `string`, `bool`, `int` or `date`, and its value stays text in the JSON. `Props` in Swift decodes by tag (`props.bool("archived")`, `props.int("unread")`). Chosen over JSON-typed values: one `Node` class with string fields is what Spinel compiles today.
- **KTD3. The network never runs on the engine thread.** The library's `sync` is one Ruby call that asks the host for each response from inside the call, and calls may not overlap, so a tap cannot run while an exchange waits. The host therefore follows the browser worker's prepared-reply pattern. On the engine thread it calls `sync_plan` and `cursor` to learn what the pass needs. Off the engine thread `Transport` fetches those: the push (`POST /mutations`), the bootstrap when the plan asks for one, and the catch-up poll (`GET /events?after=<cursor>&window=0`). Back on the engine thread it calls `sync` with an exchange that answers from the fetched replies and never touches the network; a request it has no reply for is answered as offline and the pass ends. A tap's action and draw are queued ahead of the apply step. One pass runs at a time and requests made meanwhile cause one more. Chosen over a second engine thread: the compiled Ruby keeps to the thread it booted on.
- **KTD4. The host owns retry and status.** A timer in `AppHost` asks for a pass while the pending count is above zero (5 s, doubling to 60 s, reset on success) and `NWPathMonitor` asks for one when the path becomes satisfied. `AppHost` publishes `status`: the pending count from the existing `cursor` entry (no new entry), offline when a fetch of the pass returned status 0, an error naming method, path and status for any other non-2xx, and Ruby's message from `ir_error` only when a call raised. One banner sits at the top of the app above the navigation stack, so pushed screens show it. Precedence is error, then offline, then pending. Copy: "Could not sync: <reason>", "Offline. Changes will send when you are back.", "N changes waiting to send". It clears on the next successful pass, an error can be dismissed, and a change is announced to VoiceOver. A write the server rejects is undone locally by the client as today, so an archived row returns and a rejected reply disappears; the banner then says "A change was not accepted and was undone." A failed render or a tree that does not decode keeps the last good tree and shows the error.
- **KTD5. Scope and credential live in the transport.** `Transport` takes a `prepare: (inout URLRequest) -> Void` the app supplies. The Inbox adds the `scope` parameter as the browser does and, with `-token`, an `Authorization` header. The server reads only what `config.scope_from` reads: the default and the demo read the `scope` parameter (the demo also the session) and neither reads a header. An app that sends a token must write a `scope_from` that reads `request.authorization` and returns nil for an unknown token; the README says so and a gem test shows it. Chosen over teaching the compiled client about identity: the browser build made the same choice and `SyncScope` is server only.
- **KTD6. Boot once, then close and open.** The generated `app.h` says `app_boot()` is called once, and today's switch calls it again. The runtime has `Db.close`. Add an `open` entry that closes the current database and opens the one at the path given, running the same table setup the boot runs, and expose it as `ir_open(path)`; `ir_boot` is called once per process. Before leaving an inbox the host runs one pass for it. If writes are still pending after that, the banner says so, and they wait until the person returns to that inbox (see Scope Boundaries).
- **KTD7. One entry template.** Move the body shared by both entries into `compiled/pipeline/entry_template.py`, with the host calls, the streaming flag, the pragmas and where the applied schema version is kept as parameters. `make_wasm_entry.py` and `make_native_entry.py` each fill it. The native entry keeps the applied schema version in `InstantRecord::SyncMetadata` in the database, since it has no host file for it and would otherwise run every migration on each launch. The rule that names a screen stays in Ruby alone: at build time Ruby prints the name-to-class table from `InstantRecord::Native.screens`, and Python pastes it into the entry without deriving anything.
- **KTD8. Forms are values on the action.** `form action: "reply" do field "body", label:, multiline: true; toggle ...; submit "Send" end`. The renderer keeps field state in SwiftUI, keyed by route and action so it survives a redraw, a live arrival, going back and backgrounding, and clears it only when the action has been performed. Submit is disabled while every required field is empty after trimming. A `swift` element may contain a form: the renderer hands the registered view the drawn form as a slot, and `ConversationView` places it in a bottom bar above the keyboard, keeps the keyboard up after send and scrolls to the new reply. Chosen over sending each keystroke to Ruby: a render per keystroke crosses the seam for nothing.
- **KTD9. Live updates by asking again.** The Inbox's events endpoint answers with the catch-up and closes, so there is nothing to hold. A `StreamClient` in the package requests `<endpoint>/events?after=<cursor>` with the cursor the `cursor` entry last reported, feeds the bytes to `stream` on the engine thread, and draws when the notice says records changed. When a response ends cleanly it asks again after one second, as `worker.js` does; an endpoint that does hold the connection simply delivers as bytes arrive. Backoff (KTD4's) applies only to failed requests. It runs while the scene is active. The native entry keeps `streaming = false` so `sync` still pulls.
- **KTD10. Rails-served mode is a second `Engine`, for development.** `InstantRecord::Native::ScreensController` answers `POST <mount>/native/render` and `/native/action` with KTD1's objects, running the screen under CRuby. It inherits from the controller the app names (`config.instant_record.native_screens_parent`, default `"ApplicationController"`), so the app's own `before_action`s apply, requires a JSON content type as `MutationsController#create` does, and is routed only when `config.instant_record.native_screens` is true, which defaults to true in development and false elsewhere. The server's database is not narrowed to one person as the phone's is, so the controller resolves `InstantRecord::SyncScope.identity(request)` and gives it to the screen (`Screen#identity`, nil on the phone), and the README says a served screen must read and write through it. Under CRuby a screen is found by constant from the naming rule and checked to be a `Screen`, so autoloading and reloading work with eager loading off. `HTTPEngine` in the package implements `Engine` over the two routes; `boot`, `sync` and `stream` do nothing, and a server that cannot be reached shows the banner's error with pull to refresh as the retry.
- **KTD11. The generator writes the project with a template, not XcodeGen.** `rails g instant_record:native` copies `lib/generators/instant_record/native/templates/` (an app target of about 40 lines, a bridging header, an `.xcodeproj` with the app's name substituted) and adds a local package reference to the gem's `native/ios/InstantRecordNative`. Chosen over XcodeGen: no tool to install, and the Inbox project becomes the template's first output (R20).
- **KTD12. Counts follow the web Inbox's rule.** No server count row syncs to the phone. The web Inbox counts unread locally and shows it as a floor ("12+") until its history fill has the whole inbox, then bare. The phone does the same: the figure is a floor until the inbox's history mark says the last page is on the phone. Paging uses the `history` entry the library already has. "Mark all read" is labelled "Mark N as read" with the number of loaded unread rows.

### High-Level Technical Design

```
tap ──► AppHost.perform ─┐
                         ├─► engine thread: action → render (publish) ─► ask for sync
timer / path / stream ───┘                                              │
                                             sync lane: one pass at a time, coalesced
                                             status ◄── "changed pending=N cursor=…"
```

Seam after U1 (directional, not a specification):

```
render  in: {"screen":"mailbox","params":{"member":"maya","inbox":"support","filter":"unread"}}
action  in: {"screen":"thread","params":{…},"action":"reply","values":{"body":"On it."}}
```

### Assumptions

- The runtime's `JSON.parse` handles one level of nested object in compiled code, as it does for sync payloads. U1 proves it first.
- `Db.close` followed by opening another file leaves the runtime usable. U3 proves it first.
- The inbox's history mark that the web Inbox reads is reachable from a compiled screen.
- Kieran wants `client_only` as the name. It is an alias and costs nothing to change.

### Sequencing

Group A lands first and alone, since B and C build on its seam. Within A: U1, then U2 to U5 in any order. B: U6, U7, U8. C: U9, U10, U11, U12. Each group ends with the Linux suites here and the Swift suites and simulator on the Mac, then a merge.

### Risks & Dependencies

- **Spinel and nested JSON or a third `perform` argument.** If either fails to compile, U1 falls back to a flat object with dotted keys and U7 to values as a JSON string the screen parses. Proven in the first hour of each unit.
- **The Mac session.** All Swift verification depends on it. If it cannot be reached, a group may merge with its Ruby and C halves verified and its Swift named as unrun in the merge message; the plan is not done until that Swift has run.
- **Main moves.** Three other threads merged to `main` during the last unit. Merge `origin/main` before each group's final run.
- **A held stream on a phone.** It costs battery and is killed in the background; KTD9 bounds it to the active scene.

---

## Implementation Units

### Group A: correctness

### U1. A structured seam, named params and typed props

- **Goal:** R3, R4.
- **Files:** `lib/instant_record/native/screen.rb`, `lib/instant_record/native/node.rb`, `lib/instant_record/native.rb`, `demo/app/screens/mailbox_screen.rb`, `demo/app/screens/thread_screen.rb`, `compiled/pipeline/make_native_entry.py`, `compiled/pipeline/native/instant_record_native.h`, `compiled/pipeline/native/host.c`, `native/ios/InstantRecordNative/Sources/InstantRecordNative/{AppHost,Node,Screens,ScreenView}.swift`, `native/ios/Inbox/Inbox/{InboxApp,ConversationView,InboxSummary}.swift`, tests `test/native_screen_test.rb`, `test/native_spinel_test.rb`, `test/native/sample_screen.rb`, `demo/test/screens/*`, `demo/test/integration/native_inbox_test.rb`, `native/ios/InstantRecordNative/Tests/**`.
- **Approach:** KTD1, KTD2. `Route` in Swift becomes screen plus `[String: String]` params. Start by compiling a one-screen sample that parses a nested object, before touching the demo.
- **Test Scenarios:** A param holding a newline, a slash and a quote arrives unchanged (AE2). A link's params round-trip from Ruby to the host and back into `render`. An unknown screen still raises. A bool, int and date prop each decode to their type in Swift and a missing one to its zero value. The Spinel build prints the same bytes as CRuby for the sample screen. The thread screen opened with a message id of `unread` shows that message.
- **Verification:** gem suite, Spinel parity test, demo native test with the rebuilt host; Swift package tests on the Mac.

### U2. Taps ahead of sync, coalesced sync, retry and status

- **Goal:** R1, R2, R6, R7.
- **Files:** `native/ios/InstantRecordNative/Sources/InstantRecordNative/{AppHost,Engine,Transport,ScreenView}.swift`, new `Status.swift`, new `SyncPass.swift` and the `AppView` banner, tests in the package and `demo/test/integration/native_inbox_test.rb`.
- **Approach:** KTD3, KTD4. Make `settle()` internal and reach it from tests with `@testable import`. A render that fails or does not decode sets `status.error` and leaves the last good tree on screen.
- **Test Scenarios:** AE1 with a stub engine whose exchange sleeps. Ten `sync()` calls during one pass cause one more pass. A failing `render` publishes the error and keeps the old tree. With `pending > 0` and a fake clock, a sync is asked for at 5, 10, 20 seconds and the interval resets after success. A path change to satisfied asks for a sync. The `cursor` entry reports pending=1 after an offline archive and pending=0 after a pass (Linux, against the host). A pass whose replies were fetched beforehand makes no exchange the host cannot answer (Linux: the host given prepared replies, then a `sync` call). A fetch answering 500 sets the error and leaves the outbox as it was. A rejected write is undone and the banner says so. The banner shows error over offline over pending.
- **Verification:** package tests on the Mac; demo native test on Linux.

### U3. Close the database on a switch

- **Goal:** R5.
- **Files:** `compiled/pipeline/native_shim.c`, `compiled/pipeline/native/instant_record_native.h`, `compiled/pipeline/native/host.c`, `compiled/pipeline/make_native_entry.py`, `compiled/pipeline/build_native.py`, `AppHost.swift`, `Engine.swift`, `LibraryEngine.swift`, `demo/test/integration/native_inbox_test.rb`.
- **Approach:** KTD6. Prove close-then-open in the Linux host before changing Swift.
- **Test Scenarios:** Open A, write, open B, write, open A: A holds only its own write and B only its own. After opening B the process holds no open descriptor on A's file (Linux, `/proc/self/fd` from the host). `ir_boot` twice returns an error the second time. A call before any boot returns an error, not a crash. Leaving an inbox with a pending write and the server up sends it before the switch; with the server down the banner names the waiting change.
- **Verification:** demo native test on Linux; package tests on the Mac.

### U4. One entry template and one naming rule

- **Goal:** R9.
- **Files:** new `compiled/pipeline/entry_template.py`, `compiled/pipeline/make_wasm_entry.py`, `compiled/pipeline/make_native_entry.py`, `lib/instant_record/native.rb`, `compiled/pipeline/build_native.py`, `test/native_screen_test.rb`.
- **Approach:** KTD7. The browser entry's output must stay byte-identical; diff it before and after.
- **Test Scenarios:** `main_wasm.rb` is unchanged by the refactor. A screen file named `two_words_screen.rb` is found as `TwoWordsScreen` by both the Ruby registry and the compiled lookup. A file that breaks the rule fails the build with the rule's own message.
- **Verification:** gem suite; a browser compile and `compiled/test/offline-inbox.mjs` on the Mac per `long-runs`.

### U5. A credential and a scope on every request

- **Goal:** R8.
- **Files:** `Transport.swift`, `InboxApp.swift`, `native/ios/README.md`, package tests, `demo/test/integration/native_inbox_test.rb`.
- **Approach:** KTD5. Confirm what the demo's `scope_from` expects after `ddd4644` (`DemoAsker`) and send that.
- **Test Scenarios:** Every request `Transport` makes passes through `prepare`. A request with a scope reaches the server with it on bootstrap, events and mutations. With a `scope_from` that reads `request.authorization`, a known token syncs its rows and an unknown one gets none (gem test). A non-2xx answer surfaces in `status.error` and does not clear the outbox.
- **Verification:** package tests on the Mac; one Linux test driving the host with a scope against the Rails endpoint.

### Group B: the screens

### U6. Screens that say what they mean

- **Goal:** R10, R11, R12, R15.
- **Files:** `lib/instant_record/native/screen.rb`, `lib/instant_record/runtime_scoped.rb`, `compiled/pipeline/vendor_gem.py`, new `demo/app/screens/mail_place.rb` (the shared module), both demo screens, `ScreenView.swift`, new `Icons.swift`, `demo/test/screens/*`, package tests.
- **Approach:** `link:` pushes; `replace:` replaces, and giving both raises. `image` takes a meaning (`"account"`, `"filter"`, `"archive"`, `"unread"`, `"inbox"`), with a raw `symbol:` escape. `spacer` and `lines:` replace the two hidden rules. Rows become `NavigationLink(value:)` with the action sent from the destination's `task`. Query unread ids once per render and pass them down. KTD12 for counts and paging, with a `more` node the renderer turns into `onAppear` on the last row: a footer spinner while loading, nothing at the end, a retry row when the page failed or the phone is offline, and the scroll position kept when rows arrive above. The mailbox draws "No mail", or "You're all caught up" under Unread, when it has no rows, and the renderer shows "Getting your mail" until the first tree or error. Each icon meaning carries a spoken label, a row reads as one element with its unread state and date, and swipes are also accessibility actions.
- **Test Scenarios:** A menu item with `replace:` swaps the root and one with `link:` pushes. An unknown icon name raises under CRuby. A stack without `spacer` no longer pushes its last child. Opening a row marks it read exactly once. With 120 messages seeded, the list shows 50 and reaches 100 after the `more` node appears; the unread figure carries the "+" until the last page is loaded and is bare after. An empty inbox and an empty Unread view each show their sentence. An icon node carries its spoken label. A render makes one unread query (counted through `ActiveSupport::Notifications`). `ThreadScreen` no longer answers `unread_only?`.
- **Verification:** gem and demo suites; simulator on the Mac.

### U7. Forms, and a reply

- **Goal:** R13.
- **Files:** `screen.rb`, `node.rb`, `thread_screen.rb`, `ScreenView.swift`, new `FormView.swift`, `ConversationView.swift` (takes the Ruby-drawn form as a slot and places it in a bottom bar), `Screens.swift`, tests in all three places, `InboxUITests`.
- **Approach:** KTD8. A reply is a `MailEntry` of kind `reply`, written as the web Inbox writes it.
- **Test Scenarios:** A form node lists its fields in order with labels and kinds. `perform("reply", params, {"body" => "On it."})` creates one reply by the member. An empty body creates none. Values with quotes and newlines arrive unchanged through the compiled host. After submit the field is empty and the reply is in the tree. A redraw caused by a live arrival while text is typed leaves the text and focus as they were. Send is disabled while the body is blank. A field's `label:` is its accessibility label. AE4 in the simulator, including with the server stopped.
- **Verification:** all suites; simulator on the Mac.

### U8. Live updates

- **Goal:** R14.
- **Files:** new `StreamClient.swift`, `AppHost.swift`, `Transport.swift`, package tests, `demo/test/integration/native_inbox_test.rb`.
- **Approach:** KTD9.
- **Test Scenarios:** A chunk fed to `stream` with one new message makes the next render include it (Linux, exists in part today). Chunks split mid-event are applied once whole. An endpoint that closes after the catch-up is asked again one second later, not in a tight loop and not after a backoff. It stops when the scene goes inactive and resumes on return. A failed request backs off and a `sync` in between still pulls. A server `reset` event leads to a fresh bootstrap.
- **Verification:** package tests with a stub byte stream; simulator on the Mac with a message sent from the web Inbox.

### Group C: reach

### U9. Screens served by Rails

- **Goal:** R16.
- **Files:** new `app/controllers/instant_record/native/screens_controller.rb`, `config/routes.rb` of the engine, `lib/instant_record/configuration.rb`, new `HTTPEngine.swift`, `InboxApp.swift` (`-served` launch argument), `test/native_screens_controller_test.rb`, `demo/test/integration/native_screens_test.rb`, package tests, README.
- **Approach:** KTD10.
- **Test Scenarios:** `render` returns the same bytes as `Screen#json` for the same params. `action` performs and returns 204. With `native_screens` false both routes 404, and it is false outside development unless set. An unknown screen is 404 with the message. A parent controller whose `before_action` rejects the request stops both routes. A request that is not JSON is 415. The screen receives the request's identity, and the demo's screens read through it. In development with eager loading off, the first render of a screen succeeds and an edited screen file is served after a reload. AE5 in the simulator.
- **Verification:** gem and demo suites; simulator on the Mac.

### U10. A rake task and a generator

- **Goal:** R17, R20.
- **Files:** `lib/tasks/instant_record.rake`, `lib/instant_record/compiler.rb`, `compiled/pipeline/build_native.py`, new `lib/generators/instant_record/native/**`, `native/ios/Inbox/**` regenerated, `test/generators/native_generator_test.rb`, README.
- **Approach:** KTD11. The task follows `instant_record:compile`'s arguments and the browser build's path for another app (`INSTANT_RECORD_APP`, `prepare_app.py`).
- **Test Scenarios:** The generator writes the app target, the bridging header, the project and an example screen, and is idempotent. The generated project names the app and the package path correctly. The task run in the demo produces the same library as `build_native.py`. A fresh Rails app with one model builds its library (Linux) and shows a list (Mac). That library boots twice on the same database without running a migration a second time, and a build with one more migration runs only that one.
- **Verification:** gem suite; a scratch app on Linux and on the Mac.

### U11. A device build

- **Goal:** R18.
- **Files:** `compiled/pipeline/build_native.py`, the project template, `native/ios/README.md`.
- **Approach:** Add `iphoneos` beside `iphonesimulator`, and package both as an XCFramework so the project links one thing.
- **Test Scenarios:** `build_native.py iphoneos` produces arm64 device archives. `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO build` succeeds.
- **Verification:** on the Mac only.

### U12. UI tests that repeat

- **Goal:** R19.
- **Files:** `native/ios/Inbox/InboxUITests/**`, new `demo/script/seed_native_inbox.rb`, `native/ios/README.md`.
- **Approach:** Each test launches with a fresh database path and a member and inbox seeded for it, finds rows by accessibility identifier (the row's id) and never by position. The seed script resets those inboxes and runs as a step before `xcodebuild test`, named in the README and in the scheme's test pre-action.
- **Test Scenarios:** The whole suite passes twice in a row. Pull to refresh, a rejected write and a live arrival each have a test.
- **Verification:** on the Mac only.

### U13. Documentation

- **Goal:** The READMEs, `CHANGELOG.md` and `docs/solutions` say what is true after each group.
- **Files:** `compiled/README.md`, `native/ios/README.md`, `README.md`, `CHANGELOG.md`, `docs/solutions/2026-11-19-native-ruby-views-what-held.md`.
- **Approach:** With each group, not at the end. Say what has not run wherever it is described.
- **Test Scenarios:** Test expectation: none -- documentation.
- **Verification:** read against the code.

---

## Verification Contract

- **Linux, every group:** `bundle exec rake test`; `INSTANT_RECORD_TOOLCHAIN=… bundle exec rake test TEST=test/native_spinel_test.rb`; rebuild with `compiled/pipeline/build_native.py`; `cd demo && INSTANT_RECORD_NATIVE_HOST=../compiled/.build-native/host bin/rails test`.
- **Mac, every group:** `swift test` in `native/ios/InstantRecordNative`; `build_native.py iphonesimulator`; `xcodebuild test` for the Inbox on the iPhone 17 simulator.
- **Mac, group A only:** a browser compile and `compiled/test/offline-inbox.mjs`, since U4 touches the browser entry.
- **Acceptance examples:** AE1 and AE2 in package tests; AE3, AE4 and AE5 in the simulator, with a screenshot each.

## Definition of Done

- R1 to R20 hold and each acceptance example has passed where the contract says.
- Each group is merged to `main` with a message that says what ran and what did not.
- The deferred list above is in `native/ios/README.md` so the next reader finds it.

## Deferred / Open Questions

- Is the Rails-served mode development-only, or something Kieran wants to ship for apps Spinel cannot compile (Cora)? The plan builds it on in development only, behind the app's own controller, and a served screen must scope its reads by identity either way.
- `client_only` as the name for code that runs on a device.
- A write still pending in an inbox the person has left waits until they return. The alternative is the deferred single database for several addresses.
