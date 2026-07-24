---
title: Prefer Stimulus for InstantRecord demo JavaScript
date: 2026-07-22
category: conventions
module: demo
problem_type: convention
component: frontend_stimulus
severity: medium
applies_when:
  - "adding or changing JavaScript in the InstantRecord Slack demo"
  - "choosing between vanilla JS modules and Stimulus for demo UI behavior"
  - "wiring Turbo navigation lifecycle to client-side conversation UI"
tags:
  - stimulus
  - hotwire
  - turbo
  - rails-javascript
  - demo
  - slack
  - convention
related_components:
  - hotwire_turbo
  - rails_view
---

# Prefer Stimulus for InstantRecord demo JavaScript

## Context

InstantRecord's Swiss Slack demo needed scrollback, live morphing, and composer behavior that felt like Rails, not a hand-rolled SPA. The first cut lived in `demo/app/javascript/slack_conversation.js` (removed by this conversion): a vanilla ES module with module-level state, `turbo:load` initialization, document-level submit delegation, and an `IntersectionObserver` wired outside any framework lifecycle. That worked, but it fought Turbo Drive (the conversation root used a `data-turbo="false"` escape hatch so navigations stayed full loads) and forced manual "am I ready?" bookkeeping whenever the page was restored or morphed.

An earlier plan for the Slack demo had settled on HTML+Rails only and explicitly rejected Stimulus controllers ([docs/plans/2026-07-22-001-feat-slack-demo-multi-app-plan.md](../../plans/2026-07-22-001-feat-slack-demo-multi-app-plan.md)). After shipping windowed infinite scroll (PR #6, still on the vanilla module), the more Rails-like choice won: Stimulus for page behavior. The durable convention (as of this conversion): **use Stimulus for most demo JavaScript**.

## Guidance

Prefer Stimulus controllers for Swiss Slack (and similar demo) UI behavior—scrolling, morph refresh, composer send, sidebar reset—rather than standalone modules that listen for `turbo:load` and manage global ready flags.

Keep InstantRecord gem / service-worker bridge helpers as plain JavaScript when they are infrastructure rather than presentation glue. Controllers may call those helpers; they should not become a second ad-hoc app shell.

Expose tunables as Stimulus values in the view (for example `data-conversation-prefetch-margin-value` with `static values = { prefetchMargin: … }` in the controller), not as buried module constants. Operators can change knobs without opening the controller.

Wire the page with Hotwire idioms:

- `data-controller` on the conversation root
- Targets for the scroller and message list
- Window and form actions for sync, rearm, and send
- A sibling `reset` controller on the sidebar form so morph-replaced sidebars reconnect automatically

Let Turbo Drive navigate between channels. On each visit, Stimulus `connect` mounts lifecycle (history sentinel, scroll-to-bottom); `disconnect` tears down observers and removes ephemeral nodes so Turbo's snapshot cache does not duplicate them on restore. Drop `data-turbo="false"` escapes once controllers reconnect cleanly.

Remove the importmap pin for a one-off module once behavior lives under `demo/app/javascript/controllers/`; `pin_all_from "app/javascript/controllers"` is enough ([demo/config/importmap.rb](../../../demo/config/importmap.rb)).

## Why This Matters

Rails-like front ends stay declarative at the HTML boundary. When scroll and sync logic lives in Stimulus, Turbo Drive can own navigation again, morph updates reconnect controllers for free, and there is no parallel init path (`turbo:load` + manual flags) that drifts out of sync with the DOM. Tunables on the element keep demo UX adjustable without forking JS. The split—Stimulus for page behavior, plain JS for worker/gem bridges—keeps Hotwire conventions without forcing every InstantRecord transport helper into a controller.

## When to Apply

- Adding or changing JavaScript in the InstantRecord Slack demo
- Choosing between a vanilla JS module and Stimulus for demo UI behavior
- Wiring Turbo navigation lifecycle to client-side conversation UI
- Attaching observers or fetch lifecycle that must clean up on leave
- Exposing UX knobs that belong next to the markup

Do not force Stimulus onto low-level InstantRecord service-worker messaging or gem client code that has no natural controller element. This learning is grounded in the Swiss Slack demo as of 2026-07-22.

## Examples

**Before — vanilla module.** The historical (pre-conversion) file `demo/app/javascript/slack_conversation.js` held page size and state at module scope, initialized on `turbo:load`, delegated form submits from `document`, and owned an `IntersectionObserver` without Stimulus connect/disconnect. Importmap pinned the file explicitly. The conversation root used `data-turbo="false"` so channel navigation forced a full page load and re-ran that init path.

**After — Stimulus controllers.** Conversation behavior lives in [`demo/app/javascript/controllers/conversation_controller.js`](../../../demo/app/javascript/controllers/conversation_controller.js) with targets `scroller` and `list`, value `prefetchMargin`, and actions for sync, rearm, and send. On connect it mounts the sentinel then scrolls to bottom; on disconnect it disconnects the observer and removes the sentinel. The show view wires it like this:

```erb
<div class="slack"
     data-instant-refresh
     data-controller="conversation"
     data-conversation-prefetch-margin-value="800"
     data-action="instant-record:records-changed@window->conversation#sync online@window->conversation#rearm">
  …
  <div class="message-scroll" data-conversation-target="scroller">
    <%= render "messages" %>
  </div>
  <%= form_with … data: { action: "conversation#send" } do |f| %>
```

The messages partial exposes `data-conversation-target="list"`. Sidebar reset uses `data-controller="reset"` and `data-action="reset#submit"` so a live morph that replaces `.sidebar` gets a fresh controller instance. Importmap drops the `slack_conversation` pin. Turbo Drive navigates channels; Stimulus reconnects. README (updated alongside this conversion) points at the conversation controller as the infinite-scroll reference wiring.

## Related

- [README.md](../../../README.md) — names `conversation_controller.js` as the Slack infinite-scroll Stimulus reference
- [docs/plans/2026-07-22-001-feat-slack-demo-multi-app-plan.md](../../plans/2026-07-22-001-feat-slack-demo-multi-app-plan.md) — earlier plan rejected Stimulus; this convention supersedes that stance for demo UI JS
- Hotwire Stimulus: controllers, targets, values, actions, and connect/disconnect across Turbo visits
- Fragment contract in `demo/app/views/slack/channels/_messages.html.erb` (list dataset cursors / `has-more`) consumed by the conversation controller
- Service-worker history fetch helpers used by the controller remain plain functions; presentation lifecycle stays in Stimulus
