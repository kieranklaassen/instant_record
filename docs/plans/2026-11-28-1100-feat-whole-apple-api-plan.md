---
title: The Whole Apple API From Ruby - Plan
type: feat
date: 2026-11-28
topic: whole-apple-api
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# The Whole Apple API From Ruby - Plan

A draft to go through with Kieran. Questions marked **Blocking** stop the part they name.

## Goal Capsule

- **Objective:** A Rails developer can use any Apple API an app is allowed, from a Ruby screen, a Rails page or SwiftUI, on iPhone, iPad and Mac, without writing the bridge by hand.
- **Means:** Generate the Ruby methods and the Swift behind them from Apple's own symbol graphs, per framework an app asks for (KTD1).
- **Execution profile:** By phase, each merged by `AGENTS.md`. No pull requests.
- **Stop conditions:** Phase 1's measurement shows too little of the SDK can be generated.

## Product Contract

### Summary

Today there are 23 new Ruby elements and some 20 named capabilities, each written by hand. That is the right shape and the wrong way to reach 314 frameworks. A generator reads what Apple publishes about each framework and writes the typed bridge for the ones an app names.

### Problem Frame

Hand-written bridges cover what their author thought of and go stale each June. Developers then leave Ruby for the one call they need.

### Requirements

- R1. `bin/rails "instant_record:bridge[CoreMotion]"` writes Ruby methods, RBS, JavaScript types and Swift for that framework.
- R2. A generated call has one name in all three kinds of view.
- R3. Objects stay on the Swift side. Ruby and pages hold a handle, and a handle no longer used is let go.
- R4. Streams (location, motion, sound levels) arrive as events that can be stopped.
- R5. SwiftUI views and modifiers become Ruby elements and modifiers.
- R6. What cannot be generated is listed with the reason, never left out in silence.
- R7. A page reaches only what the app allowed, by framework and by call.
- R8. Info.plist lines and entitlements a framework needs are named when it is generated.
- R9. Ruby describes widgets, Live Activities and Siri intents, drawn by generic extensions.
- R10. All of it runs on iPhone and iPad, and on the Mac where the framework exists there.

### Scope Boundaries

- Not planned: private API, and calling a method by a name sent at run time. A page could then call anything, and Apple rejects undeclared use.
- Not planned: Android.

## Planning Contract

### Key Technical Decisions

- KTD1. **Generate at build time from `swift-symbolgraph-extract`.** It was run here: WidgetKit on the iOS 27.2 SDK gives 3,084 symbols with types and availability as JSON. 210 frameworks have Swift modules. 2,797 of those symbols are methods, most of them inherited modifiers, so the first job is to leave out what is not the framework's own.
- KTD2. **Only named frameworks are generated.** All of them would make the app huge and need every privacy text.
- KTD3. **`Capabilities` is the carrier.** Generated code calls `capabilities.add`. Names, allow-lists and the wire stay as built.
- KTD4. **Handles for classes, values for structs and enums.** Closures become events. Generics and opaque types go on R6's list.
- KTD5. **Widgets are drawn from snapshots.** Another process can neither hold the compiled library nor share the open database.

### Phases

| Phase | What | Proves |
|---|---|---|
| 1 | Measure: extract every framework, and count what rules in KTD4 can generate | The stop condition |
| 2 | The generator, with CoreMotion, AVFAudio and EventKit | Values, handles, streams |
| 3 | SwiftUI: views and modifiers as Ruby | R5 |
| 4 | Widgets, Live Activities, intents, with 100 sample widgets in Ruby | R9 |
| 5 | 3D and sound: RealityKit scenes and an audio graph in Ruby | The hard cases |
| 6 | The compiled library for the Mac, and a generated reference | R10 |

## Open Questions

1. **Blocking, all:** Is a generated share enough, say 60% of a framework, with the rest by `capabilities.add`?
2. **Blocking, phase 4:** Which Apple team and App Group sign the widget extension?
3. **Blocking, phase 4:** 100 widgets as ready-made designs, or the tool to make them and a dozen examples?
4. **Phase 2:** May pages call generated frameworks at all, or only Ruby and SwiftUI?
5. What is "a duo"? Read as a possible device, it is none in this Xcode's list. It is not in this plan.

## Verification Contract

- Each generated framework compiles for iOS and macOS and has one test that calls the real API.
- A screen that uses generated methods compiles with Roundhouse and Spinel. This needs the toolchain, which was not on the machine this was drafted on.

## Definition of Done

Set with Kieran, phase by phase.
