---
title: Native iPhone Hardening - Plan
type: fix
date: 2026-11-19
topic: native-ios-hardening
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
origin: docs/plans/2026-11-19-0630-feat-native-ruby-views-plan.md
---

# Native iPhone Hardening - Plan

## Goal Capsule

- **Objective:** A developer can build a second screen set on the native runtime without tripping over the Inbox demo's shortcuts: taps and screens carry named values, the app keeps itself in sync and says when it is not, and a form sends typed text to Ruby.
- **Means:** Fix the twenty items in the author's critique of `feat/native-ios` (head `9ffac1b`), on branch `feat/native-ios-hardening`.
- **Product authority:** Kieran asked for all of them ("ok lets fix all these"). The shapes chosen for auth, the dev mode and icon names are bets made for him and are his to change.
- **Execution profile:** One branch, units in the order below, each leaving the gem, demo and Swift suites green. Shipping follows `AGENTS.md`: no pull request.
- **Stop conditions:** Stop if Spinel cannot compile a hash of named params on a node or a screen, or parse an action input with its two nested maps (KTD1), since every later unit builds on it.

---

## Product Contract

### Problem Frame

The Inbox runs in the iPhone simulator with Ruby screens, but it was built to prove one demo. Values cross between Swift and Ruby as loosely packed strings, so a newline or a slash in the wrong place changes their meaning. The app syncs only when touched, hides its errors, and shows counts that describe one page as if it were the inbox. Nothing typed on the phone can reach Ruby. A developer starting a second app would inherit all of that.

### Requirements

**Values between Swift and Ruby**

- R1. A render or an action reaches Ruby as one JSON object, and a screen reads named params. No value's meaning depends on a newline or a slash.
- R9. A Swift view reads flags and numbers as such, and a `nil` given to a text element draws nothing instead of failing.
- R14. The rule that names a screen from its class is written once.

**Data and sync**

- R2. Choosing another inbox closes the open database and opens the other. It does not boot the app a second time.
- R3. A write made offline reaches the server without the user touching the app.
- R6. Sync requests made close together run as one pass.
- R15. A change made elsewhere appears on the phone while the app is in front, without a tap or a pull.
- R5. The mailbox says how much mail is on the phone and whether the server has more, loads older mail on request, and "mark read" names how many it marks.
- R17. The phone's sync requests carry a token. The demo server checks it when one is sent, and can be started so that it requires one.

**What the user sees**

- R4. The app shows when it is offline, how many changes are waiting, and what went wrong.
- R7. A row that opens a screen is a system navigation link.
- R8. Layout rules are in the Ruby: a `spacer` element and a line limit on text. The renderer adds none of its own.
- R11. Screens name icons by meaning, and the renderer maps them to the platform's symbols.
- R16. A screen can hold a text field, and the conversation has a reply form that sends what was typed.

**Structure and tooling**

- R10. `ThreadScreen` does not inherit from `MailboxScreen`.
- R12. The Swift-view registry and the C engine wrapper hold no global state, and the test helper is not public API.
- R13. The Xcode project is written by a generator.
- R18. In a dev mode the phone asks Rails for each screen, so editing a screen needs no rebuild.
- R19. A rake task builds the native libraries for a Rails app and a generator writes its iPhone app.
- R20. The simulator tests seed their own server, find rows by identity and can be run twice. They cover pull to refresh, a rejected write, live arrival, dark mode and large text.

### Scope Boundaries

**Deferred for later**

- A real device, signing and TestFlight.
- Android, and a tab bar.
- A sign-in screen. The token arrives as a launch argument.
- Holding the gem's event stream open. The Inbox demo's sync endpoint answers polls only.
- One database that syncs several addresses.

**Outside this change**

- The browser build and the React demo. Both stay as they are.

### Success Criteria

- The gem suite, the demo suite, `swift test` and the simulator tests pass on the branch, and the simulator tests pass a second time without reseeding by hand.
- With the server stopped, an archive leaves the list and the app shows it is offline with one change waiting. After the server returns, the change reaches it with no touch.
- Typing a reply and sending it shows the reply in the conversation and on the server.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Calls carry JSON and screens take named params.** `ir_call("render")` and `("action")` receive one JSON object: screen, params, and for an action its name and params. A node gains a `params` map of strings and loses `arg`. A screen reads `param("inbox")`. A row or item that leads somewhere carries the target's params. Governs R1.
- KTD2. **Ruby DSL and SwiftUI stay plain, with no third-party dependency.** (session-settled: user-directed — chosen over adopting the ruby_native gem: Kieran's words were "do similar here but with plain swift/ruby".) Governs R11, R13, R16.
- KTD3. **Ruby stays compiled on the phone and nothing is translated to Swift.** (session-settled: user-approved — chosen over translating Ruby to SwiftUI source: a translator leaks and leaves no Ruby on the phone for models and sync.) The dev mode in KTD11 adds a second engine and replaces nothing. Governs R18.
- KTD4. **A Ruby screen can hand props to a registered SwiftUI view.** (session-settled: user-directed — chosen over Ruby-drawn screens only: Kieran asked for Swift as a second option, similar to Inertia.) Typed props extend it: `flag` and `number` beside `prop`. Governs R9.
- KTD5. **A new `open` entry closes the database and opens another.** The runtime already has `Db.close` and `SqliteAdapter.configure`. `ir_boot` runs once for the process. Chosen over one database with several sync scopes, which would change the gem's cursor and outbox for every client. Governs R2.
- KTD6. **The host owns when to sync.** Requests coalesce behind a short delay. A failed pass or a non-zero pending count schedules a retry with backoff. A network-path change to reachable triggers a pass, and so does a foreground timer. Each pass publishes online or offline and the pending count. Governs R3, R4, R6, R15.
- KTD7. **Live means polling while in front.** `Email::SyncController#events` returns what exists and closes, so there is no stream to hold. The library's `stream` entry stays for an app whose server offers one. Governs R15.
- KTD8. **A pushed screen is told it opened.** The host performs `open` on a screen when it is pushed, and `ThreadScreen` marks the message read there. Rows lose their `action`, which is what lets them be `NavigationLink`s. Governs R7.
- KTD9. **Fields live in the screen that drew them.** A `field` node has a name. The renderer keeps what is typed per screen and sends it as params with the next action from that screen, then clears the fields that action named. Governs R16.
- KTD10. **Auth is a bearer token the server checks when present.** The app sends `Authorization: Bearer` on every exchange. `Email::SyncController` verifies a signed, member-scoped token and refuses a mismatch. A request with no token behaves as today, so the browser demo is unchanged, unless the demo is started with `INBOX_REQUIRE_TOKEN` set: then a request with no valid token is refused. The README says plainly that without that setting the token is not access control, that the gem's own sync endpoints do not check it, and that an app with private data must require the token and take the member from it, not from the address. Governs R17.
- KTD11. **Dev mode is a second `Engine` that calls Rails.** The gem draws the render and action routes only when `config.instant_record.native_dev` is on and `Rails.env.local?` holds. The controller answers 404 to a request that is not `request.local?`, sends no CORS headers and answers no preflight, so a web page cannot drive it. The same screen classes run under CRuby and write through their `server_only` branch. Governs R18.
- KTD12. **One generator writes every Xcode project.** A Ruby class in the gem writes `project.pbxproj` from the app's name, bundle id and Swift files. The Inbox project is its output, and a test fails when the committed file differs. The Rails generator calls the same class. Governs R13, R19.
- KTD13. **No pull request.** (session-settled: user-directed — chosen over opening a PR: `AGENTS.md` records Kieran's word of 2026-11-18.)

### Assumptions

- Spinel compiles a `Hash` of `String` to `String` passed as a keyword argument and stored on a node, and `JSON.parse` of an object whose values are strings or string-to-string objects, two of them in an action's input (`params` and `with`). The `history` entry already parses a flat object this way.
- A module of instance methods included in two screen classes goes through Roundhouse's screen overlay. If it does not, a shared base class that is not itself a screen replaces it.
- `InstantRecord::Client.transport` reaches the server from a screen's action through the existing exchange callback. `fetch_history` is not used: `MailEntry` declares no sync window, and the compiled browser pages through the `history` entry instead.
- A fresh Rails app with one model may not go through Roundhouse. U11 attempts it and reports the result; it does not gate the branch.

### Sequencing

U1 first, since it changes every call. U2 and U3 then touch the same Ruby and Swift files and go in that order. U4 through U9 each add one behaviour and need U1. U10 and U11 are tooling. U12 tests the result. U13 writes it up.

### Risks

- U1 rewrites the demo's screens, both test suites and the renderer in one step. The host test compares the phone's JSON with CRuby's, which catches a mismatch.
- Timers and network-path events make sync tests flaky. The scheduler takes its clock and its path monitor as inputs so tests drive them.
- Auth is a risk surface. KTD10 keeps the no-token path byte-identical and tests the refusals.

---

## Implementation Units

### U1. Named params and JSON across the seam

- **Goal:** Render and action inputs are JSON, and screens, nodes and routes carry named params.
- **Requirements:** R1.
- **Dependencies:** none.
- **Files:** `lib/instant_record/native/node.rb`, `lib/instant_record/native/screen.rb`, `lib/instant_record/native.rb`, `compiled/pipeline/make_native_entry.py`, `compiled/pipeline/native/instant_record_native.h`, `demo/app/screens/mailbox_screen.rb`, `demo/app/screens/thread_screen.rb`, `test/native_screen_test.rb`, `test/native/sample_screen.rb`, `demo/test/screens/mailbox_screen_test.rb`, `demo/test/screens/thread_screen_test.rb`, `demo/test/integration/native_inbox_test.rb`, `native/ios/InstantRecordNative/Sources/InstantRecordNative/Node.swift`, `AppHost.swift`, `ScreenView.swift`, `Screens.swift`, `native/ios/InstantRecordNative/Tests/InstantRecordNativeTests/`, `native/ios/Inbox/Inbox/InboxApp.swift`, `ConversationView.swift`.
- **Approach:** Per KTD1.
  1. `Screen.new(params)` takes a hash. `param(name)` returns a string, empty when absent.
  2. `row`, `item`, `button` and `swipe` take `with:` for the params they carry. `arg:` goes.
  3. The bridge parses `{"screen","params","action","with"}` and calls `perform(action, params)`.
  4. `Route` in Swift is a screen name and a sorted params map. `Actions.perform` takes a dictionary.
  5. The mailbox's filter becomes the param `show`, and a thread's message the param `id`.
- **Test scenarios:**
  - A param value holding a newline, a slash and a quote reaches `perform` unchanged, under CRuby and compiled.
  - A message whose id is `unread` opens as a thread and does not filter the mailbox.
  - A missing param reads as an empty string.
  - An action input that is not JSON is an error the host can read, and the next call works.
  - The phone's mailbox JSON equals the server's for the same params.
  - Two routes with the same params in a different order are equal.
- **Verification:** The gem, demo and Swift suites pass with no `split("/")` left in a screen and no newline-joined input in the Swift package.

### U2. Explicit layout, neutral icons, typed props, navigation links

- **Goal:** The Ruby says what the renderer used to assume, and linking rows are system links.
- **Requirements:** R7, R8, R9, R11.
- **Dependencies:** U1.
- **Files:** `lib/instant_record/native/screen.rb`, `demo/app/screens/`, `test/native_screen_test.rb`, `test/native/sample_screen.rb`, `demo/test/screens/`, `native/ios/InstantRecordNative/Sources/InstantRecordNative/ScreenView.swift`, `Screens.swift`, `Icons.swift` (new), `AppHost.swift`, tests beside them, `native/ios/Inbox/Inbox/`.
- **Approach:**
  1. Add `spacer` and `text ..., lines:`. Remove the far-edge rule and the two-line cap from the renderer, and use both in the mailbox.
  2. Text, prop and field values pass through `to_s` in the DSL.
  3. Add `flag(name, bool)` and `number(name, int)`. `Props` gains `bool` and `int`.
  4. `Icons.swift` maps a short list of meanings (`person`, `filter`, `archive`, `inbox`, `unread`, `read`, `send`, `compose`) to SF Symbols. A name it does not know is used as given.
  5. Per KTD8: rows become `NavigationLink(value:)`, the host performs `open` on a pushed route, and `ThreadScreen#perform("open")` marks read.
- **Test scenarios:**
  - `text nil` and `prop "x", nil` build and serialise, compiled and under CRuby.
  - A flag reads `true` and `false` in Swift, and a number reads as an `Int`.
  - A horizontal stack with no spacer keeps its children together.
  - Pushing a route performs `open` on it once, before its first render.
  - Opening an unread message marks it read, once, and reopening adds nothing.
  - An icon meaning maps to its symbol and an unknown name passes through.
- **Verification:** Suites pass, and the mailbox screenshot matches the earlier layout.

### U3. Screens share a module, and one name rule

- **Goal:** `ThreadScreen` stands beside `MailboxScreen`, and the build takes screen names from Ruby.
- **Requirements:** R10, R14.
- **Dependencies:** U1.
- **Files:** `demo/app/screens/mail_access.rb` (new), `demo/app/screens/mailbox_screen.rb`, `demo/app/screens/thread_screen.rb`, `compiled/pipeline/make_native_entry.py`, `compiled/pipeline/vendor_gem.py`, `lib/instant_record/native.rb`, `test/native_screen_test.rb`.
- **Approach:** `MailAccess` holds member, inbox, `allowed?` and `append`. The build script reads each file's class name and asks `InstantRecord::Native.screen_name` for its name, in one `ruby` call.
- **Test scenarios:**
  - A file in `app/screens` that is not a `*_screen.rb` is carried into the build and is not a screen.
  - `ThreadScreen.superclass` is the gem's `Screen`.
  - A class named `OrderLinesScreen` builds as `order_lines`, from the Ruby rule.
- **Verification:** Both native targets build and `native_inbox_test` passes.

### U4. Open another database without booting again

- **Goal:** Switching inbox closes one SQLite file and opens the other.
- **Requirements:** R2.
- **Dependencies:** U1.
- **Files:** `compiled/pipeline/make_native_entry.py`, `compiled/pipeline/native_shim.c`, `compiled/pipeline/native/instant_record_native.h`, `compiled/pipeline/native/host.c`, `demo/test/integration/native_inbox_test.rb`, `native/ios/InstantRecordNative/Sources/InstantRecordNative/Engine.swift`, `AppHost.swift`, `native/ios/Inbox/Inbox/LibraryEngine.swift`.
- **Approach:** Per KTD5. `ir_call("open", path)` closes, configures and prepares the schema. `ir_boot` refuses a second call. `Engine` gains `open(database:)`.
- **Test scenarios:**
  - After `open` on a second file, a render shows that file's rows and a sync uses its own cursor.
  - Opening the first file again shows its rows and its queued write.
  - A second `ir_boot` returns an error and leaves the app usable.
  - `open` on a path that cannot be created is an error and the earlier database stays open.
- **Verification:** The host test switches six times and the first database's file has no open handle left behind that blocks deleting it.

### U5. The host decides when to sync, and says how it went

- **Goal:** Sync is coalesced, retried, triggered by reachability and by a foreground timer, and its state is on screen.
- **Requirements:** R3, R4, R6, R15.
- **Dependencies:** U1.
- **Files:** `native/ios/InstantRecordNative/Sources/InstantRecordNative/SyncSchedule.swift` (new), `AppHost.swift`, `Transport.swift`, `ScreenView.swift`, `native/ios/InstantRecordNative/Tests/InstantRecordNativeTests/SyncScheduleTests.swift` (new), `AppHostTests.swift`.
- **Approach:** Per KTD6 and KTD7. The schedule takes a clock and a reachability source so tests drive both. The host reads `pending=` from the sync result and whether the transport answered offline. The app view shows a bottom bar when offline or when changes wait, and an error banner that can be dismissed.
- **Test scenarios:**
  - Three sync requests inside the delay run one pass.
  - A pass that fails offline schedules a retry, and the delays grow to a ceiling.
  - Reachability returning runs a pass at once and resets the delay.
  - With zero pending and a successful pass, only the foreground timer remains.
  - Going to the background stops the timer.
  - Offline with one queued write publishes offline and pending 1. After a good pass both clear.
  - A render that raises publishes the error, and a later good render leaves it until dismissed.
- **Verification:** In the simulator, an archive made with the server stopped reaches it after the server returns, with no touch.

### U6. Honest counts and older mail

- **Goal:** The mailbox says what is on the phone, loads older mail, and marks a named number read.
- **Requirements:** R5.
- **Dependencies:** U1, U2.
- **Files:** `demo/app/screens/mailbox_screen.rb`, `demo/app/models/mail_entry.rb` if a scope is shared, `compiled/pipeline/make_native_entry.py` if the receipt code is shared with the `history` entry, `demo/test/screens/mailbox_screen_test.rb`, `demo/test/integration/native_inbox_test.rb`, `native/ios/Inbox/Inbox/InboxSummary.swift`.
- **Approach:** The screen lists every open message on the phone. A last row "Load older mail" performs `older`. The menu item reads "Mark N read".
  1. `older` has two halves, like `append`. On the phone it asks the server's `records` address for the page below the oldest local row through the client's transport, then applies the records and stores the page's has-more receipt in `InstantRecord::SyncMetadata` in one transaction, as the `history` entry does. On the server it does nothing, since the server holds every row.
  2. A transport failure changes nothing and reports offline.
  3. The summary's more-on-server flag and the load row read that receipt: absent or "more" means more, "end" means none. It lives in the database, so it survives a redraw and a switch of inbox.
- **Test scenarios:**
  - With more mail on the server than the first page, the summary flags more and the load row is present.
  - `older` adds the next page below the last row and keeps the rows above.
  - At the beginning of the inbox the load row is gone and the flag is off.
  - `older` offline changes nothing and reports offline.
  - "Mark N read" marks exactly the unread mail on the phone.
- **Verification:** The host test pages a 120-message inbox to its beginning.

### U7. Text fields and the reply form

- **Goal:** A screen holds a text field and the conversation sends a reply.
- **Requirements:** R16.
- **Dependencies:** U1, U2.
- **Files:** `lib/instant_record/native/screen.rb`, `demo/app/screens/thread_screen.rb`, `demo/app/screens/mail_access.rb`, `test/native_screen_test.rb`, `test/native/sample_screen.rb`, `demo/test/screens/thread_screen_test.rb`, `demo/test/integration/native_inbox_test.rb`, `native/ios/InstantRecordNative/Sources/InstantRecordNative/ScreenView.swift`, tests beside it.
- **Approach:** Per KTD9. Add `field(name, placeholder:, value:)` and `bottom`, a bar pinned under the screen. `ThreadScreen` keeps its Swift view and adds a `bottom` with the field and a Send button. `perform("reply")` appends a reply through `MailAccess`.
- **Test scenarios:**
  - An action from a screen with a field carries the typed text under the field's name.
  - A reply holding quotes, a newline and non-ASCII text is stored as typed.
  - An empty or blank reply writes nothing.
  - After a reply the field is empty and the conversation shows the reply.
  - A reply made offline shows at once and reaches the server on the next pass.
  - A reply to a conversation in another inbox writes nothing.
- **Verification:** In the simulator, a typed reply appears as a bubble and exists on the server.

### U8. A token on sync requests

- **Goal:** The phone identifies itself and the demo server checks it.
- **Requirements:** R17.
- **Dependencies:** U1.
- **Files:** `demo/app/models/mail_directory.rb`, `demo/app/controllers/email/sync_controller.rb`, `demo/lib/tasks/inbox.rake` (new), `demo/test/controllers/email/sync_token_test.rb` (new), `native/ios/InstantRecordNative/Sources/InstantRecordNative/Transport.swift`, `native/ios/Inbox/Inbox/InboxApp.swift`, `native/ios/InstantRecordNative/Tests/InstantRecordNativeTests/TransportTests.swift` (new).
- **Approach:** Per KTD10. `MailDirectory.token(member)` signs with the app's message verifier, and a rake task prints one. The controller refuses a present token that is invalid or names another member, and with `INBOX_REQUIRE_TOKEN` set refuses a missing one. The app reads `-token`. The README note is the one KTD10 words.
- **Test scenarios:**
  - A request with no `Authorization` header behaves as before.
  - A valid token for the member in the address is accepted.
  - A valid token for another member, a tampered token and a malformed header are each refused with 401.
  - With `INBOX_REQUIRE_TOKEN` set, a request with no header is refused with 401 and one with a valid token is served.
  - The transport sends the header on GET and POST when it has a token and none when it has not.
  - A 401 reaches Ruby as a failed exchange and the write stays queued.
- **Verification:** The demo suite passes, including every existing sync test untouched.

### U9. Dev mode: the phone asks Rails for its screens

- **Goal:** A screen edit shows on the phone after a pull, with no rebuild.
- **Requirements:** R18.
- **Dependencies:** U1.
- **Files:** `app/controllers/instant_record/native_screens_controller.rb` (new), `config/routes.rb`, `lib/instant_record/engine.rb`, `lib/instant_record/configuration.rb`, `test/native_screens_controller_test.rb` (new), `native/ios/InstantRecordNative/Sources/InstantRecordNative/HTTPEngine.swift` (new), tests beside it, `native/ios/Inbox/Inbox/InboxApp.swift`.
- **Approach:** Per KTD11. The endpoints take the same JSON as the C calls. `HTTPEngine` implements `Engine`: `boot` and `sync` succeed without work. The app uses it when launched with `-dev <address>`.
- **Test scenarios:**
  - With the flag off, both endpoints answer 404.
  - With the flag on in the production environment, both endpoints answer 404.
  - A request from an address that is not loopback answers 404.
  - A response carries no `Access-Control-Allow-Origin` header, and an OPTIONS request is not answered.
  - Render returns the screen's JSON, and an unknown screen answers 404 with the message.
  - An action runs `perform` and the next render shows its effect.
  - `HTTPEngine` returns nil and an error text when the server is down.
- **Verification:** With the app in dev mode, changing a string in `mailbox_screen.rb` and pulling shows the new string.

### U10. No global state in the Swift package

- **Goal:** The registry belongs to the host and the engine wrapper to its instance.
- **Requirements:** R12.
- **Dependencies:** U1.
- **Files:** `native/ios/InstantRecordNative/Sources/InstantRecordNative/Screens.swift`, `AppHost.swift`, `ScreenView.swift`, `native/ios/Inbox/Inbox/LibraryEngine.swift`, `InboxApp.swift`, tests beside them.
- **Approach:** `Screens` becomes a value the app fills and hands to `AppHost`. `LibraryEngine` passes itself as the exchange context. `settle` becomes internal.
- **Test scenarios:**
  - Two hosts with different registries each draw their own view for the same name.
  - A name missing from a host's registry draws the warning.
- **Verification:** No `static var` remains in the package or the app, and `swift test` passes.

### U11. A generator for the Xcode project, and a rake task for the build

- **Goal:** The Inbox project is generated, and another Rails app gets the same two commands.
- **Requirements:** R13, R19.
- **Dependencies:** U10.
- **Files:** `lib/instant_record/native/xcode_project.rb` (new), `lib/generators/instant_record/ios/ios_generator.rb` (new) and its templates, `lib/tasks/instant_record.rake`, `lib/instant_record/compiler.rb`, `compiled/pipeline/build_native.py`, `compiled/pipeline/prepare_app.py`, `compiled/pipeline/make_native_entry.py`, `compiled/pipeline/native_shim.c`, `test/native_xcode_project_test.rb` (new), `test/generators/ios_generator_test.rb` (new), `native/ios/Inbox/Inbox.xcodeproj/project.pbxproj`.
- **Approach:** Per KTD12.
  1. The rake task `instant_record:native` stages the pipeline and its environment as `InstantRecord::Compiler.build` does for the browser, then runs `build_native.py` with the target as its argument.
  2. `prepare_app.py` copies `app/screens` when the native build asks for it. Today it leaves them out, so another app would build with no screens.
  3. The native entry keeps the schema version a database was last migrated to in that database, and reads it in place of the host's `schema_version` slot, which the shim does not have. Without this every migration would run again on the second launch.
- **Execution note:** After the generator test passes, try both commands on a fresh `rails new` app with one synced model and record what happens. A failure inside Roundhouse or Spinel is reported, not fixed here. A failure in this repository's own pipeline is fixed.
- **Test scenarios:**
  - Generating for the Inbox's name, bundle id and files produces the committed `project.pbxproj` byte for byte.
  - Adding a Swift file to the app folder adds it to the project's sources.
  - The generator writes an app file naming the first screen and sync address it was given, and refuses to overwrite an existing folder without `--force`.
  - The rake task fails with a clear message when no toolchain file is configured.
  - A consumer app's screen appears in the built entry's lookup.
  - Booting twice on the same database file with one migration in the plan succeeds.
- **Verification:** `xcodebuild build` succeeds on the regenerated Inbox project.

### U12. Simulator tests that can run twice

- **Goal:** One command seeds a server, runs every flow and leaves nothing behind.
- **Requirements:** R20.
- **Dependencies:** U2, U5, U6, U7.
- **Files:** `native/ios/Inbox/InboxUITests/InboxUITests.swift`, `native/ios/ui-test.sh` (new), `demo/db/seeds/native_ui.rb` (new), `native/ios/InstantRecordNative/Sources/InstantRecordNative/ScreenView.swift` for accessibility identifiers, `native/ios/Inbox/Inbox/InboxApp.swift`.
- **Approach:** The script recreates a database of its own, seeds a small fixed inbox, starts the server on a free port with `INBOX_REQUIRE_TOKEN` set and hands the app a token, runs `xcodebuild test`, and stops the server. The app takes `-reset` to start from an empty local database. Rows carry their node id as accessibility identifier. The tests reach the server themselves for an incoming message. The script changes the simulator's appearance and text size for the last two tests and restores them.
- **Test scenarios:**
  - Open, archive, switch inbox, unread only and reply, each finding rows by id.
  - Pull to refresh shows a message that arrived with the timer off.
  - A message that arrives with the timer on appears without a touch.
  - An archive of a message the server has since lost returns to the list.
  - Offline archive, then the server returns, and the bar clears.
  - In dark mode and at the largest text size, the mailbox's first row, both bar buttons and the reply field exist and can be tapped.
- **Verification:** The script passes twice in a row.

### U13. Documentation

- **Goal:** The docs describe the seam, the DSL and the commands as they now are.
- **Requirements:** R1 through R20.
- **Dependencies:** all.
- **Files:** `native/ios/README.md`, `compiled/README.md`, `CHANGELOG.md`, `docs/solutions/2026-11-19-native-ruby-views-what-held.md`.
- **Approach:** Say what ran and on what, and what did not.
- **Test expectation:** none -- prose.
- **Verification:** Every command in the READMEs was run as written.

---

## Verification Contract

| Check | Command | Applies to |
|---|---|---|
| Gem tests, Spinel parity included | `INSTANT_RECORD_TOOLCHAIN=<env> bundle exec rake test` | U1 to U3, U7, U9, U11 |
| Native build, both targets | `python3 compiled/pipeline/build_native.py` and the same with `iphonesimulator` | U1 to U4, U6, U7 |
| Demo tests with the host | `cd demo && INSTANT_RECORD_NATIVE_HOST=../compiled/.build-native/host bin/rails test` with the model keys unset | U1 to U4, U6 to U8 |
| Swift package | `swift test` in `native/ios/InstantRecordNative` | U1, U2, U5, U7 to U10 |
| App build | `xcodebuild build` for the iPhone 17 simulator | U1, U2, U10, U11 |
| Simulator flows | `native/ios/ui-test.sh`, twice | U12 |

Demo commands run with `DATABASE_URL` set to this checkout's own databases.

## Definition of Done

- Every unit's verification holds and its commit says what ran.
- The browser build is unchanged: `compiled/pipeline/build.py` is untouched apart from what U3 shares, and the existing suites pass.
- A requirement that could not be met is named in `CHANGELOG.md` and the final report with the reason, not left silent.
- No dead experiment or unused helper remains in the diff.

## Deferred / Open Questions

- Whether a fresh Rails app compiles end to end is unknown until U11 tries it.
- A sign-in flow and token storage in the Keychain.
- Holding a real event stream for apps whose server has one.
