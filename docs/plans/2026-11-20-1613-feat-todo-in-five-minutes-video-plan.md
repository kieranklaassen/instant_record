---
title: Todo App In Five Minutes Video - Plan
type: feat
date: 2026-11-20
topic: todo-in-five-minutes-video
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Todo App In Five Minutes Video - Plan

## Goal Capsule

- **Objective:** A Rails developer watches Kieran build a todo app from `rails new` in about five minutes, sees it keep working after he stops the Rails server, and can repeat every step from the README with the same result.
- **Authority:** Kieran's answers of 2026-11-20 in the brainstorm, then this plan, then `AGENTS.md`.
- **Open blockers:** none. What a fresh scaffold breaks in the compiled build is unknown and is found by the rehearsal (R13).

---

## Product Contract

### Summary

A five-minute video in the manner of DHH's 2005 blog demo: Kieran builds a todo app from an empty folder, narrating as he types, and it works as ordinary Rails. Then he adds InstantRecord in a few steps, stops the Rails server on camera, and the app carries on. The gem gets whatever a fresh app needs so those few steps are short and true.

### Problem Frame

InstantRecord's claim is that a Rails developer writes normal Rails and gets offline for free. Every demo in the repo is a finished app inside the gem's own `demo/` folder, so nobody has watched the claim hold from nothing. The 2005 video worked because the viewer saw each line typed and each result appear.

The path a fresh app takes today is not one to film. The install generator copies one toolchain config file. A syncable model needs a string id and two sync columns that a scaffold does not produce. The service worker that lets a page reload with no server lives in the demo app and not in the gem. No plain `rails new` scaffold has been through the compiler.

### Key Decisions

- **The app is a todo list.** (session-settled: user-directed — chosen over a plane journal, which Kieran picked first and then replaced: no reason given.) Governs R2.
- **The offline beat is stopping the Rails server.** (session-settled: user-approved — chosen over turning wifi off: wifi does not cut a connection to localhost, so the demo would prove nothing.) Governs R6.
- **The toolchain is installed beforehand and the compile wait is cut once, with a label.** (session-settled: user-directed — chosen over one take with no cuts and over a free edit: a video soon, with one honest cut.) Governs R3, R4.
- **Sync is shown in a second browser window when the server returns.** (session-settled: user-directed — chosen over wifi alone and over a phone in airplane mode: offline and sync in one beat, nothing to deploy.) Governs R7.
- **The app works as plain Rails before InstantRecord is added.** Offline then arrives as the surprise, the way the original's "whoops" moments did. Governs R5.
- **A todo is checked off with one click from the list.** A todo app that needs an edit page to mark something done reads as broken. Governs R2.

### Requirements

**The video**

- R1. The video runs about five minutes and starts at an empty folder with `rails new`, with Kieran typing and narrating and the browser in view.
- R2. The app is a todo list: add a todo, see the list, check one off from the list with one click, delete one.
- R3. The compiler toolchain is installed before recording, and the video or its description says so.
- R4. The video has exactly one cut, over the compile wait, labeled on screen with the time the compile really took.
- R5. The viewer sees the todo app working against the Rails server before any InstantRecord step is typed.
- R6. Kieran stops the Rails server in the terminal on camera. With it stopped, he adds a todo and checks one off, each shows at once, and both are still there after a reload of the page.
- R7. Kieran starts the server again, and the changes made while it was stopped appear in a second browser window without that window being reloaded.
- R8. The line "and now it also works offline" is said in the video, at the offline beat.

**What a fresh app needs from the gem**

- R9. A fresh `rails new` app with a scaffolded model goes offline-capable through steps that never hand-edit a migration, a toolchain path or JavaScript.
- R10. A scaffolded model becomes syncable without its author writing the key and sync columns by hand.
- R11. The gem's own setup gives a fresh app a page that reloads while the server is stopped (R6), with nothing copied from `demo/`.
- R12. The scaffold's own controller, views and form work in the compiled build for list, create, update, delete and a failed validation.

**Rehearsal and the written path**

- R13. Before recording, the whole path runs on a fresh app on Kieran's Mac from a written script that records each command and how long it took.
- R14. The README's Usage section shows the same steps the video shows, in the same order.
- R15. A shot list gives each beat of the video its on-screen action, its spoken line and its time budget.

### Key Flows

- F1. The video, start to finish
  - **Trigger:** Kieran starts recording at an empty folder.
  - **Steps:** `rails new`. Scaffold the todo. Open it and add a todo (R5). Add InstantRecord and make the model syncable (R9, R10). Compile, with the cut (R4). Open the compiled app. Stop the server, add and check off todos, reload (R6). Start the server, watch the second window (R7).
  - **Outcome:** a todo app that works with no server, built on camera.
  - **Covered by:** R1 to R8.

### Acceptance Examples

- AE1. **Covers R6.** Given the compiled todo app is open and the Rails server has been stopped, when Kieran adds "Buy milk" and reloads the page, then the page loads and "Buy milk" is in the list.
- AE2. **Covers R7.** Given "Buy milk" was added while the server was stopped and a second window is open on the app, when the server starts again, then "Buy milk" appears in the second window with no reload there.
- AE3. **Covers R12.** Given the compiled app with a todo that requires a title, when Kieran submits an empty title, then the scaffold's own error message shows and no todo is added.

### Success Criteria

- Between "the app works as plain Rails" and "the server is stopped", the viewer sees at most five typed commands or edits.
- Every command typed on camera is one Kieran would leave in the README unchanged.
- The rehearsal script runs clean on a fresh app twice in a row before recording.

### Scope Boundaries

- A compile fast enough for a take with no cut is deferred.
- A phone in airplane mode, and anything deployed, is deferred.
- Sign-in and per-user sync stay out of the video.
- Styling beyond what the scaffold produces is out, apart from what the one-click check-off needs.
- Installing the toolchain is not made simpler by this work.
- The existing Todo demo at `/todo` is left as it is.

### Dependencies / Assumptions

- The toolchain is already installed and working on Kieran's Mac.
- A service worker registers on `localhost`, so R6 can be shown without a deployed host.
- Assumed, not verified: a plain scaffold compiles with small fixes. If the rehearsal shows otherwise, R12 is the largest part of the work.

### Outstanding Questions

**Deferred to Planning**

- Which parts of a plain `rails new` scaffold fail in the compiled build, found by running one.
- Which `rails new` flags the video uses, chosen to keep the scaffold inside what the compiler takes.
- Whether the one-click check-off (R2) fits the five steps of the first success criterion or is typed before the InstantRecord steps begin.
- How the compiled app is opened locally after the compile, in one command.

### Sources / Research

- `lib/generators/instant_record/install/install_generator.rb`: the install generator copies the toolchain config and prints next steps, nothing more.
- `demo/app/views/pwa/service-worker.js`: the shell-only service worker a fresh app does not get today.
- `README.md`, Usage: the steps a reader follows now, and the three columns a syncable model needs.
- `compiled/README.md`, Build and serve: what the compile reads from an app and how its output is served.
- `demo/config/routes.rb`: the existing Todo demo at `/todo`, built on `Issue`.
