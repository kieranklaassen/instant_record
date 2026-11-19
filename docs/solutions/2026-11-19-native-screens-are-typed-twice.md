# Ruby screens for the phone are typed by two compilers

Date: 2026-11-19. From the hardening of the native Inbox (`docs/plans/2026-11-19-0940-fix-native-inbox-hardening-plan.md`). Follows `2026-11-19-native-ruby-views-what-held.md`. Seen on Linux x86_64 and in the iOS simulator on arm64.

## What was believed and was wrong

- **One compiler types a screen.** Two do. Roundhouse infers types from the whole app's call sites and writes them as `.rbs` beside each file it emits. Spinel takes those as seeds for the C it writes. Where the two disagreed about a hash, nothing failed at build time: the library crashed on its first render, on the phone. It took nine native builds to find that out through tests.
- **A module is a safe way for two screens to share code.** A module included into `MailboxScreen` and `ThreadScreen` made Roundhouse type `item`'s `params:` as `Hash[String, untyped]` in the subclasses, and Spinel refused the build: "a parameter default given a Hash, which no conversion keeps in its sp_StrPolyHash * slot". The shared code is now a plain object each screen constructs (`demo/app/screens/mail_access.rb`, `MailAccess.new(member, inbox)`).

## What holds now

- The DSL's types are written by hand in `sig/instant_record/native.rbs`, which `vendor_gem.py` copies into the staged app. Roundhouse reads an app's `sig/**/*.rbs` and does not override a signature it finds there.
- It takes no signature for `initialize` or for an instance variable. That is why a screen's params pass through `Screen#open_with`, a method that can be given one.
- Inline RBS comments do not survive Roundhouse.
- An empty `{}` has no type. `InstantRecord::Native::Node.strings` returns an empty hash the compilers know to be a hash of strings; use it for a default.
- One hash of another kind handed to `params:` or `args:` anywhere in an app loosens the node's field for every screen. `build_native.py` reads the generated C and stops the build when that happened (`loose_node_fields`) or when the C holds a certain `TypeError` at a screen's line (`certain_type_errors`). `test/native_build_guards_test.rb` covers both with canned C.

## How to look, without a build

Run only the emit (`build.emit_tree`, about two seconds) and read `compiled/.build-native/wasm-tree/app/models/**/*.rbs`: they show what Roundhouse decided each method takes and returns. A full native build is about six minutes. To trace a compiled call that raises, run `compiled/.build-native/host` under gdb with a breakpoint at `sp_raise_cls`.

## When this applies

Before changing `lib/instant_record/native/*.rb`, `sig/instant_record/native.rbs` or an app's `app/screens`: a change that reads as a style cleanup in Ruby (a mixin, a `{}` default, an instance variable set in `initialize`) can change what both compilers infer. Check the emitted `.rbs` first, then build.
