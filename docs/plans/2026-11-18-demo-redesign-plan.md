---
title: Demo redesign - Plan
type: feat
date: 2026-11-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Demo redesign - Plan

## Goal Capsule

- Objective: Anyone opening the InstantRecord demo site sees one polished, consistent product. Warm paper, clear type, a shared top bar. They can still do everything each demo did before: create and sync records, go offline, read the source, and run migrations and console queries.
- Means: restyle the existing ERB views and plain CSS against the approved Claude Design canvas (https://claude.ai/artifact/9RQZHmNY4i35tZ4fTF2xhd), keeping markup hooks intact (KTD1, KTD2).
- Authority: Kieran's decisions in the project thread (settled decisions below), then this plan, then the canvas artboards as visual reference.
- Execution profile: one branch (`claude/project-thread-13tvtm`), one draft PR, units landed in order U1 → U9.
- Stop conditions: a change would require removing a Stimulus target, data attribute, route or accessible name an existing test drives and the test cannot be updated honestly. Or the demo cannot be booted or tested at all in this environment (report, don't guess).
- Finisher: the implementing agent ships the draft PR. Kieran reviews and merges.

---

## Product Contract

### Summary

Replace the Swiss grid style (Helvetica, black rules, one red) across every demo with the approved warm-paper design inspired by Cora's design system. Add a shared top bar with demo tabs and an Online/Offline switch, rename three demos, and rewrite the home page around "What if your Rails app were instant?".

### Problem Frame

The demos are the gem's public face. The Swiss poster style reads as a prototype and each demo carries its own chrome. Kieran approved a redesign on the canvas on 2026-11-18 and asked to implement it.

### Requirements

- R1. Shared visual language on every demo page. Paper page `#FBF8F2`, white content cards, beige hairlines `#E2D9CC`, ring-halo depth (no heavy shadows), Figtree for UI, Newsreader for headings and reading text, JetBrains Mono for code. Session-settled, user-approved. Rejected: the Swiss grid/Helvetica/red. Reason: Kieran asked for professional and polished, Cora-inspired.
- R2. No strong gradient band, grain texture or postmark. At most a faint top wash. Session-settled, user-directed. Rejected: the stronger band. Reason: "the bg is too much".
- R3. One shared top bar on every page: InstantRecord mark, demo tabs (Home, Todo, Chat, Inbox, Assistant, Ship v2, Console) with the current one highlighted, an Online/Offline switch on the right, and View source. It replaces the current `site-nav`. Session-settled, user-approved. Rejected: per-demo chrome.
- R4. The Online/Offline switch drives the same offline simulation as the sync inspector's Offline checkbox, and the two stay in step. Session-settled, user-directed. Rejected: inspector-only.
- R5. Inbox (email) demo: no visible "Load older conversations" button. Older pages load by infinite scroll. Session-settled, user-directed.
- R6. Renames in visible copy: "Postroom" → "Inbox", "Swiss Slack" → "Chat", "Relay" → "Assistant". Session-settled (Inbox user-directed; Chat and Assistant user-approved).
- R7. Home page order: an "experiment" note, the headline "What if your Rails app were instant?", a short pitch, a "How it works" section (a model snippet and four steps: write locally, queue durably, sync in the background, stream everyone else), then the demo cards and the receipts link. Session-settled, user-directed.
- R8. Chat is Slack-like but more playful: a warm-dark sidebar, a tangerine accent `#E8794A`, rounded avatar tiles, a header with the channel name, and the existing thread panel. Session-settled, user-approved ("love it").
- R9. Todo, Assistant, Console, Receipts and Ship v2 follow their artboards: Todo in green, Assistant in clay, Console as a dark terminal card, Receipts as a printed receipt, and Ship v2 in purple. Every existing control and figure stays.
- R10. All existing behavior stays as it is: sync, outbox, morphing, infinite scroll, threads, the source drawer, the inspector log, migrations, console eval, measurements, and the reset form.

### Scope Boundaries

- In scope: views, CSS, the layout, small JS text changes, and test updates for renamed copy.
- Out of scope (deferred, recorded for the PR body): Inbox "Needs reply/Waiting" grouping, category badges, typing presence, chat emoji reactions, and new bot personas (Otto Sync and friends). None of these has model support today, so faking them would be dishonest in a demo about real data. The seed copy in `Slack::Seeds` stays as it is.
- Out of scope: gem code under `lib/` and `app/` at the repo root.

### Success Criteria

- Every demo page renders with the new look and the shared top bar on the server runtime.
- The demo's Rails test suite passes, with only copy assertions updated where R6 renamed text.
- Browser-test selectors in `compiled/test/*.mjs` still match the markup (checked by grep when the compiled runtime can't run here).

---

## Planning Contract

### Key Technical Decisions

- KTD1. Restyle, don't restructure. Keep every class, id, `data-*` attribute, Stimulus target and accessible name that a controller or test uses (`.mail-row`, `.mail-older`, `ol.messages`, `.thread-panel`, `ul.issues li`, `form.todo-form`, `#pending-count`, `ul.columns li`, `table.notes td.num`, `.relay-answer`, `.relay-response`, `#inspector`, `[data-inspector-target=offline]`, `#source-drawer`). Add wrapper elements and new classes where the design needs them. This keeps `compiled/test/*.mjs` and the controller tests valid without running the wasm toolchain.
- KTD2. Replace `swiss.css` with a token foundation, `base.css`. It holds custom properties (paper, ink, hairline, muted, the per-demo accent `--accent`), font stacks, buttons, cards, chips, the top bar and the restyled inspector and source drawer. Each demo stylesheet then uses only those tokens. The `stylesheet_link_tag :app` already includes every file, so removing `swiss.css` needs no layout change beyond class names.
- KTD3. The header switch is a second checkbox that calls a new `inspector#toggleOffline` action. That action sets `offlineTarget.checked` and runs the existing `simulate()`. `simulate()` and `connect()` mirror the state back to the header switch through a new optional `headerOffline` target. The inspector's own checkbox keeps its target name, so tests using `[data-inspector-target=offline]` still work.
- KTD4. Inbox infinite scroll already works through an `IntersectionObserver` on the `.mail-older` sentinel (`mailbox_controller.js`). Keep the element and its target, and make it a visually quiet sentinel: no label, no button styling, an accessible name kept for assistive tech. The JS that recreates it stops setting its visible text.
- KTD5. Fonts come from Google Fonts with full system fallbacks. Offline or blocked loads fall back cleanly, which suits a local-first demo. There is no CSP to update.
- KTD6. The sync inspector stays, restyled to match. It's the demo's teaching tool and tests depend on it. Resolves the open area on keeping the inspector.

### Sequencing

U1 (foundation + top bar) first, because every other unit depends on its tokens. Then U2–U8 in any order. U9 (tests and verification) last.

### Assumptions

- The Ruby in this container (3.3.6) differs from the demo's `.ruby-version`/Gemfile (3.3.3). The executor resolves that at run time, for example with a local `RUBY_VERSION` override that isn't committed. If Postgres can't be brought up, they report which tests could not run.

---

## Implementation Units

### U1. Foundation tokens, shared top bar, inspector and drawer restyle

- Goal: R1, R2, R3, R4, KTD2, KTD3, KTD5, KTD6.
- Files: `demo/app/assets/stylesheets/base.css` (new), `demo/app/assets/stylesheets/swiss.css` (deleted), `demo/app/views/layouts/application.html.erb`, `demo/app/javascript/controllers/inspector_controller.js`, `demo/app/assets/images/icon.svg` (only if the mark needs it).
- Approach: tokens on `:root`, Google Fonts `<link>` in the layout head, and a new `<header class="site-bar">` with mark, tabs (`link_to` each demo root path, current one by `controller_path`), the switch and View source (`#source-drawer`). Restyle `#inspector` and `#source-drawer` with the tokens. The body class `demo-<name>` sets `--accent`.
- Test scenarios: the home controller test still finds "InstantRecord" and both demo paths. The header switch flips the inspector checkbox and the reverse (manual or browser check).
- Verification: boot the server, then open `/` and one demo.

### U2. Inbox (email)

- Goal: R1, R5, R6, KTD4. Follows `Main.dc.html`/`Compose.dc.html`/`Mobile.dc.html`.
- Files: `demo/app/assets/stylesheets/mail.css`, `demo/app/views/email/mailboxes/index.html.erb`, `demo/app/views/email/mailboxes/_mail.html.erb`, `demo/app/javascript/controllers/mailbox_controller.js`.
- Approach: rename the brand to Inbox, put "View as" avatars and the sync status in the bar, serif subject and title, white reader card, pill buttons, rounded selected row. Mail is a full-height app, so the page's own layout stays below the shared bar.
- Test scenarios: `demo/test/controllers/email/*` keep passing (`.mail-thread h2`, `.mail-thread p`, `.mail-list a`). The sentinel is still present when more pages exist.

### U3. Chat

- Goal: R1, R6, R8. Follows `Chat.dc.html`.
- Files: `demo/app/assets/stylesheets/slack.css`, `demo/app/views/slack/channels/_sidebar.html.erb`, `_pane.html.erb`, `_messages.html.erb`, `_thread_panel.html.erb`.
- Approach: rename the brand to Chat. Dark warm sidebar with channel tiles and unread badges, the content as a rounded paper panel, avatar tiles, a tangerine send button. Keep the `<span class="name">` markup and the `"1 reply ⟶"` thread-link copy, or update the test to match new copy.
- Test scenarios: `demo/test/controllers/slack/*` pass, and the channel-navigation and full-demo browser selectors still match.

### U4. Home

- Goal: R6, R7. Follows `Home.dc.html`.
- Files: `demo/app/views/home/index.html.erb`, `demo/app/assets/stylesheets/home.css`.
- Approach: the experiment pill, the H1 and pitch, a How it works section with a `Issue` model snippet and four steps, the demo cards (Inbox and Assistant cards get the new names), the receipts band, and the open-source footer. Keep the preview images.
- Test scenarios: the home controller test passes.

### U5. Todo

- Goal: R9. Follows `Todo.dc.html`.
- Files: `demo/app/views/todo/issues/index.html.erb`, `_list.html.erb`, `demo/app/assets/stylesheets/todo.css`.
- Approach: a title and lede, an add-issue card containing `form.todo-form` and `ul.issues`, round check boxes, done rows struck through, and stat cards (Open/Done/Runtime/Store/Pending with `#pending-count`).
- Test scenarios: `demo/test/controllers/todo/*` pass, and the selectors in `full-demo.mjs`/`overlapping-writes.mjs` still match.

### U6. Assistant

- Goal: R6, R9. Follows `Assistant.dc.html`.
- Files: `demo/app/views/assistant/chats/*.erb`, `demo/app/assets/stylesheets/assistant.css`.
- Approach: rename "Relay" in visible copy only. Keep the `relay-*` classes, which the controllers and browser tests rely on. Clay accent, user bubbles, serif replies, a dark code block, a rounded composer.
- Test scenarios: `demo/test/controllers/assistant/*` pass, and the `.relay-answer`/`.relay-response` selectors stay.

### U7. Console and Receipts

- Goal: R9. Follows `Console.dc.html`, `Receipts.dc.html`.
- Files: `demo/app/views/console/sessions/*.erb`, `demo/app/assets/stylesheets/console.css`, `demo/app/views/receipts/index.html.erb`, `demo/app/assets/stylesheets/receipts.css`.
- Approach: Console gets adapter chips, an amber warning callout (copy kept, including "Do not ship an eval endpoint" and `browser_only`), a dark terminal card for snippets, transcript and form. Receipts get a serif heading and lede, and the ledger tables in a receipt-paper card. Every `data-figure` cell is kept.
- Test scenarios: the console and receipts controller tests pass.

### U8. Ship v2 (migrate)

- Goal: R9. Follows `Migrate.dc.html`.
- Files: `demo/app/views/migrate/notes/*.erb`, `demo/app/assets/stylesheets/migrate.css`.
- Approach: a schema pill, the steps as numbered markers, the facts in a stat card, column chips (`ul.columns li`, with the added column highlighted), a purple Ship v2 button, and the notes table kept as `table.notes`.
- Test scenarios: `demo/test/controllers/migrate/*` pass.

### U9. Tests and copy assertions

- Goal: R10.
- Files: any `demo/test/**` assertion on renamed copy. Grep `compiled/test/*.mjs` against the new markup.
- Test scenarios: the full demo Rails suite passes.

---

## Verification Contract

- `cd demo && bin/rails test` (Postgres required), the whole demo suite.
- Gem suite unaffected: `bundle exec rake test` at the repo root, only if gem files change (they shouldn't).
- Visual check: boot `bin/rails server` and screenshot `/`, `/todo`, `/slack`, `/email`, `/assistant`, `/migrate`, `/console`, `/receipts` with Playwright at desktop and phone widths.
- The compiled browser suite (`compiled/test/*.mjs`) needs the Spinel toolchain. Run it if that's available, otherwise grep its selectors against the changed views and say it didn't run.

## Definition of Done

- U1–U9 are done, and no `swiss.css` rules or Swiss copy ("Demo 0x", "Swiss Slack", "Postroom", visible "Relay") remain.
- The demo suite passes, and screenshots show the new design on every page at desktop and phone width.
- No dead CSS from abandoned attempts is left in the diff.
- The PR body lists the deferred design elements from Scope Boundaries.
