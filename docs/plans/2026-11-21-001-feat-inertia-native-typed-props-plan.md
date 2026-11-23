---
title: "Elevate InstantRecord::Native::Screen#swift into Inertia Native (Typed Prop Contracts & Prism Codegen)"
type: feat
status: active
date: 2026-11-21
---

# Inertia Native: Typed Prop Contracts & Prism Codegen

## Goal

Elevate `InstantRecord::Native::Screen#swift` into "Inertia Native": a declarative, Spinel-safe typed prop & action contract DSL in Ruby that compiles via a Prism AST codegen step in `NativeBuild` into strongly typed Swift `Codable` structs, `@Observable` state stores, and action enums (plus optional Kotlin data classes + sealed action interfaces), backed by a typed SwiftUI binding layer in `InstantRecordNative` and proven end-to-end on the Inbox demo screens.

## Design Decisions & Constraints

1. **Monomorphic Spinel-safe wire format (zero RBS double-typing regression):**
   - Keep `InstantRecord::Native::Node` strictly monomorphic (`Hash[String, String]` for `link_params`, `args`, `props`, `String` for `kind`, `id`, `text`, `action`).
   - Extend `InstantRecord::Native::Screen` with:
     - `decimal(name, value)` (`type: "float"`)
     - `record(name = "") { ... }` (supports both unnamed array records inside `props` and named nested objects like `record("sender") { ... }`)
     - Scalar list items via `prop("", value)` / `number("", value)` / `flag("", value)` / `decimal("", value)` / `time("", value)` inside `props("tags") { ... }`
     - Nil-safe optional omission in `prop`/`flag`/`number`/`decimal`/`time` (`return nil if value.nil?`) so omitted optional fields decode cleanly as `nil` / `null` without putting `nil` into `Node#text`.
     - `component(name, &block)` as a clean platform-neutral alias for `swift(name, &block)` (emitting `kind: "swift"` for full backward compatibility).
   - Keep `sig/instant_record/native.rbs` strictly aligned and guarded by `NativeBuild.loose_node_fields` and `NativeBuild.certain_type_errors`.

2. **Plain-Ruby declarative contract DSL (`InstantRecord::Native::Contract`):**
   - Declared at the class level on any `InstantRecord::Native::Screen` subclass using `yield` (no `instance_eval`, no `method_missing`, no dynamic `define_method`):
     ```ruby
     contract "ConversationView" do |c|
       c.string :subject
       c.string :participants
       c.bool :archived
       c.many :messages do |m|
         m.string :author
         m.string :address
         m.date :date
         m.string :body
         m.bool :mine
       end
       c.action :archive
       c.action :reply do |a|
         a.value :body, :string
       end
     end
     ```
   - Supported field types: `:string`, `:int`, `:float`, `:bool`, `:date`, `optional: true`, `one :name` (nested struct, optional `as:` / `optional:`), `many :name` (array of nested structs, optional `as:` / `optional:`), `many :name, of: :string|:int|:float|:bool|:date` (array of scalars), and `prop :name, :type` shorthand alias.
   - Supported actions: `c.action :name` with optional block taking `a.arg :name, :type` (or `a.string` / `a.int` / `a.float` / `a.bool` / `a.date`) for action `args`, and `a.value :name, :type` for form `values`.
   - **CRuby runtime validation:** In CRuby (`!InstantRecord.browser?`), `Screen#render` validates any emitted `"swift"` node whose component name matches a declared contract on the screen class, raising `InstantRecord::Native::ContractError` on missing required props, undeclared props, or type mismatches.
   - **Compile-time stripping in `GemVendor`:** `GemVendor#rewrite_scoped_blocks` strips class-level `contract ... do ... end` blocks from staged `app/screens/*.rb` using Prism byte offsets so Roundhouse and Spinel generate zero C code for declarations and never see Symbol/DSL types in screen inference. `lib/instant_record/native/contract.rb` is also written in plain monomorphic Ruby for standalone Spinel compatibility.

3. **Prism AST Codegen inside `NativeBuild`:**
   - `InstantRecord::Compiler::NativeContracts` parses `app/screens/**/*.rb` using Ruby's built-in `Prism` parser, extracts `Contract` IR objects statically without loading Rails, and fails fast with file+line `BuildError` on syntax errors, non-literal contract arguments, unknown types, or duplicate contract/field/action names.
   - `InstantRecord::Compiler::SwiftCodegen` emits deterministic Swift 5.9+/iOS 17+ source (`InstantRecordContracts.swift`):
     - `public struct <Name>Props: NativeProps, Codable, Equatable, Sendable` (with `componentName`, `CodingKeys` for snake_case -> camelCase mapping, nested `Codable` structs, and explicit `public init`)
     - `public enum <Name>Action: NativeAction, Equatable, Sendable` (when actions are declared; otherwise `NativeProps` defaults `Action = NoAction`)
     - `@Observable public final class <Name>State: NativePropsState` with per-property stored fields updated via `apply(_ props:)` only on change, plus `send(_ action:)`
   - `InstantRecord::Compiler::KotlinCodegen` emits deterministic Kotlin source (`InstantRecordContracts.kt`) with `@Serializable data class` (and `@SerialName` for snake_case fields), nested data classes, `companion object { const val COMPONENT_NAME }`, and `sealed interface <Name>Action` (`data object` / `data class`), with `serializable: true|false` option.
   - Wired into `NativeBuild#run`: runs contract extraction before `emit_tree` (fail fast), writes `<build_dir>/generated/InstantRecordContracts.swift` when contracts exist, writes `<build_dir>/generated/InstantRecordContracts.kt` when `kotlin: true` or `kotlin_out:` / `kotlin_package:` is specified, and also exposes `InstantRecord::Compiler.generate_native_contracts(...)` + `rake instant_record:native:contracts` for instant regeneration without a C build.

4. **Typed SwiftUI Binding in `native/ios/InstantRecordNative/`:**
   - New `TypedContracts.swift` defining `NativeAction`, `NoAction`, `NativeProps`, `NativePropsState`, `TypedActions<Action>`, `NativeWire`, `PropsDecodingError`, and `NativeStateHost` (`@State` lifecycle host that keeps `@Observable` state alive across `AppHost` redraws).
   - Extend `Props` in `Screens.swift` with `double(_:)`, `nested(_:)`, `jsonObject()`, and `decode<T: Decodable>(_ type: T.Type) throws -> T` (using `JSONDecoder` with `Moment.date` ISO 8601 fractional-seconds decoding).
   - Extend `Screens` with typed `register(_ propsType:, view:)` and `register(state:, view:)` while keeping untyped `register(_ name:, view:)` 100% backward compatible.
   - Extend `Actions.perform` and `AppHost.perform` to accept explicit `values: [String: String] = [:]` merged over `typed[route]`.

5. **Demo Migration (`Inbox`):**
   - Add typed contracts to `demo/app/screens/thread_screen.rb` (`ConversationView`) and `demo/app/screens/mailbox_screen.rb` (`InboxSummary`).
   - Generate `native/ios/Inbox/Inbox/InstantRecordContracts.swift` and regenerate `Inbox.xcodeproj/project.pbxproj` via `ruby native/ios/Inbox/project.rb`.
   - Migrate `ConversationView.swift` to use `ConversationViewProps` and `TypedActions<ConversationViewAction>` (`.archive`), and `InboxSummary.swift` to use `InboxSummaryProps`.
   - Update `InboxApp.swift` to use typed `views.register(ConversationViewProps.self)` and `views.register(InboxSummaryProps.self)` (leaving `FeedbackForm` untyped to prove coexistence).

## Implementation Units

- **Unit 1: Ruby Contract DSL & Monomorphic `Screen` Enhancements**
  - Create `lib/instant_record/native/contract.rb`
  - Update `lib/instant_record/native.rb`, `lib/instant_record/native/screen.rb`, `sig/instant_record/native.rbs`, `lib/instant_record/compiler/gem_vendor.rb`
- **Unit 2: Prism Extractor, Swift & Kotlin Codegen, and `NativeBuild` Integration**
  - Create `lib/instant_record/compiler/native_contracts.rb`, `lib/instant_record/compiler/swift_codegen.rb`, `lib/instant_record/compiler/kotlin_codegen.rb`
  - Update `lib/instant_record/compiler.rb`, `lib/instant_record/compiler/native_build.rb`, `lib/tasks/instant_record.rake`
- **Unit 3: SwiftUI Typed Binding Layer in `InstantRecordNative`**
  - Create `native/ios/InstantRecordNative/Sources/InstantRecordNative/TypedContracts.swift`
  - Update `Screens.swift`, `AppHost.swift`, `ScreenView.swift`
  - Create `native/ios/InstantRecordNative/Tests/InstantRecordNativeTests/TypedContractsTests.swift`
- **Unit 4: Demo Migration & End-to-End Verification**
  - Update `demo/app/screens/thread_screen.rb`, `demo/app/screens/mailbox_screen.rb`
  - Generate `native/ios/Inbox/Inbox/InstantRecordContracts.swift` and run `ruby native/ios/Inbox/project.rb`
  - Update `ConversationView.swift`, `InboxSummary.swift`, `InboxApp.swift`
  - Add comprehensive Ruby tests (`test/native_contract_test.rb`, `test/native_codegen_test.rb`, updates to `test/native_xcode_project_test.rb`, `test/compiler_test.rb`, `demo/test/screens/*`)

## Verification Plan

1. `bundle exec rake test` (all gem tests including contract validation, Prism extraction, Swift/Kotlin codegen, `NativeBuild` stub pipeline, and Swift compilation check of generated contracts via `swiftc`).
2. `cd demo && bin/rails test` (all demo tests including `ThreadScreenTest`, `MailboxScreenTest`, `NativeDevTest`, `IosGeneratorTest`).
3. `cd native/ios/InstantRecordNative && swift test` (full Swift package test suite including new `TypedContractsTests` covering `Codable` decoding, `@Observable` state updates, typed actions with `args` + `values`, and SwiftUI rendering).
4. Compile check of `native/ios/Inbox/Inbox/InstantRecordContracts.swift`, `ConversationView.swift`, and `InboxSummary.swift` against `InstantRecordNative` module using `swiftc` to verify zero Swift type errors.
5. Merge `origin/main` into `feat/inertia-native-typed-props`, re-run required test suites, merge `--no-ff` into `main`, push `main`, and delete branch per `AGENTS.md`.
