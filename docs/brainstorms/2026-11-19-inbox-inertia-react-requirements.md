# Inbox on Inertia + React: requirements

Date: 2026-11-19. Status: requirements, ready for `ce-plan`. Scope chosen by Kieran: rebuild the Inbox demo on Inertia + React.

## Problem

The Inbox demo reads as a static page. It has anchored infinite scroll over a 150-row window and no keyboard at all, so it does not feel like a mail client. Separately, InstantRecord has never run under Inertia. The README and the spike plan describe an Inertia-compatible layer (props as the first-paint seed, a JS read surface over PGlite live queries) and defer it. Nobody knows yet whether that shape holds.

## Goal

One demo answers both. Rebuild Inbox as an Inertia page in React, with the keyboard and scroll feel of Cora, reading its mail from the local database. If it works, InstantRecord has a proven path into an Inertia Rails app. If it does not, we learn where it breaks.

## Scope

In: the Inbox demo (`demo/app/controllers/email`, its views, `mailbox_controller.js`, `mail.css`), the build tooling it needs, and the smallest read layer that lets React see local data.

Out: the other demos, which stay on Hotwire. The sync protocol. The mail model.

## Requirements

### Experience

- R1. **j / k** move a focus ring down and up the message list. The focused row always scrolls into view, including rows the list has not rendered yet.
- R2. **Enter** or **o** opens the focused message. **Esc** or **u** returns to the list with focus on the row that was open.
- R3. **e** archives and **r** opens reply, on the focused row in the list and on the open message. After an archive, focus moves to the next row, never to the top.
- R4. **c** opens compose, **/** focuses search if the demo has one, **?** shows the key list. Keys do nothing while a text field has focus.
- R5. Focus survives everything that redraws the list: a message arriving over sync, an archive by the other member, going offline and back, a reload.
- R6. The list is virtualized. The whole mailbox scrolls as one list with no "Load older" control and no visible window edge. Older mail is fetched as the reader nears it, and the scroll position does not jump when rows are added above or below.
- R7. Mouse and keyboard agree. Hovering does not steal the focus ring, and clicking a row moves it there.
- R8. The approved design stays: paper page, sky accent, Figtree and Newsreader, the Online/Offline switch in the header, the sync inspector on the left, the live dock. This is a rebuild of behaviour, not a redesign.

### InstantRecord under Inertia

- R9. The controller renders with `render inertia:` and passes the first screen of mail as props. The page paints from those props with no wait on the local database.
- R10. After first paint the list reads from the local database through live queries, and a change that arrives over sync appears without a request or a reload.
- R11. Ruby keeps writes and sync. Compose, reply and archive go through the existing InstantRecord mutation path and outbox, so a write made offline queues and sends on reconnect as it does today.
- R12. No change to the HTTP + SSE wire format, the bootstrap, or the scoping by persona and inbox.
- R13. Offline works as it does now: reload offline, read mail, queue a write, reconnect, and the other member receives it.
- R14. Props and the local database never disagree on screen. When both hold a row, the local one wins once it is loaded.
- R15. The read layer is small and has one job: hand a React component a live result for a query. It is written so it could move into the gem, but it ships in the demo first.

### From Cora

- R16. Take the patterns, not the file. Cora's `useKeyboardNavigation` is about 1,850 lines for a product with many surfaces. Inbox needs a hook a tenth that size: a focus index, a key map, a registry that asks the virtual list to scroll a row into view, and focus restore.
- R17. Use the same stack Cora runs: Inertia 3, React 19, react-virtuoso.

## Not in this round

- Shift+J / Shift+K range selection, bulk actions and undo. They are the next step once single-row focus is solid.
- Needs reply / Waiting sections and category badges. The mail model has nothing to group by.
- Server-side rendering.
- Moving any other demo to Inertia.
- Publishing the read layer as part of the gem's public API.

## Open questions for planning

1. **The compiled build.** The demo also ships as a compiled app that runs Ruby in the browser and renders ERB there, and its pipeline mirrors layouts and views by hand. An Inertia page has no ERB to render. Either Inbox drops out of the compiled build, or the compiled build serves the same React bundle with props produced by the in-browser Ruby. This is the largest unknown and decides how much of R13 is new work.
2. **Where the live query runs.** The demo's browser store is described two ways in the docs (PGlite in the README, a SQLite outbox in the shared inbox plan). Planning has to confirm what the Inbox reads from today and what a live query over it costs.
3. **Build tooling.** The demo has no Vite and no React today. Adding them for one demo is acceptable, but the other demos must keep working with no build step of their own.
4. **Who owns older mail.** R6 needs older rows on demand. Either the existing windowed sync widens its window as the reader scrolls, or Inertia's merge props page them in. The first keeps one data path, which fits R10.

## Done when

- A person can read, archive, reply and compose in Inbox without touching the mouse.
- Scrolling a long mailbox is smooth and never shows a loading control.
- Two personas in two windows see each other's mail arrive live, with focus held.
- The offline walk in R13 passes.
- The write-up says plainly whether InstantRecord works under Inertia, what the read layer cost, and what the gem would need to offer it properly.
