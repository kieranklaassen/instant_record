# iOS guides

There are three ways to put a Rails app on an iPhone with InstantRecord. They mix freely in one app.

| | Ruby screens | SwiftUI views | Rails pages |
|---|---|---|---|
| You write | Ruby in `app/screens` | SwiftUI, fed typed props from Ruby | HTML, with Ruby Native's helpers |
| Drawn by | stock iOS controls | your view | a web view under native tabs and bars |
| Data | the phone's own SQLite | the phone's own SQLite, through Ruby | your server |
| Works offline | yes | yes | no |
| A change ships with | an App Store build | an App Store build | a deploy |
| Needs the compiled library | yes | for props from Ruby, yes | no |
| Guide | [Ruby screens](ruby-screens.md) | [SwiftUI views](swiftui-views.md) | [Rails pages](rails-pages.md) |

Start with Rails pages when you want to ship often. Write a Ruby screen where a list must open at once and work offline. Write SwiftUI where a view needs gestures, animation or a device feature. [Mixing the three](mixing.md) explains how each opens the others.

1. [Getting started](getting-started.md): from a Rails app to a running simulator
2. [Ruby screens](ruby-screens.md): the Ruby DSL
3. [SwiftUI views](swiftui-views.md): props and actions, typed
4. [Rails pages](rails-pages.md): native tabs, bars, buttons and menus from HTML
5. [Mixing the three](mixing.md): tabs, links and embedding
6. [Ruby Native compatibility](ruby-native.md): what is supported, and what is not

[native/ios/README.md](../../native/ios/README.md) is the reference for the renderer, themes, sync and the Inbox demo.
