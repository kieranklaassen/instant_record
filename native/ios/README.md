# Ruby screens on iPhone

A Rails app's screens, written in Ruby, drawn with stock iOS controls. The
app's models, its sync client and its screens are compiled to a C library
that runs inside the app. `InstantRecordNative` is a Swift package with no
dependencies: it runs that library, decodes each screen's JSON and draws it.
`Inbox` is the demo's app.

## Your own app

In a Rails app that uses InstantRecord, with screens in `app/screens` and the
toolchain file `compiled/README.md` describes:

```sh
bin/rails generate instant_record:ios Shop --screen catalog
bin/rails "instant_record:native[iphonesimulator]"
xcodebuild -project native/ios/Shop/Shop.xcodeproj -scheme Shop -destination 'platform=iOS Simulator,name=iPhone 17' build
```

The generator writes a thin app in `native/ios/Shop`: the first screen's
name, the server's address, and the Xcode project. The project file is
generated from the Swift files in the folder. After adding one, run the
generator again with `--force`.

## The Inbox demo

```sh
python3 compiled/pipeline/build_native.py iphonesimulator
cd demo && bin/rails db:prepare && bundle exec falcon serve --bind http://localhost:3000
cd native/ios/Inbox
xcodebuild -project Inbox.xcodeproj -scheme Inbox -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build build
xcrun simctl boot "iPhone 17"
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Inbox.app
xcrun simctl launch booted dev.instantrecord.Inbox -server http://localhost:3000
```

`InboxApp.swift` lists the launch arguments: the member and inbox, a token,
the dev mode, the sync timer and a reset. `ruby native/ios/Inbox/project.rb`
writes `Inbox.xcodeproj` again.

## A screen

A screen is one Ruby class in `app/screens`. `mailbox_screen.rb` is the
screen named `mailbox`. It is opened with named params, draws itself in
`body`, and answers taps in `perform`.

```ruby
class MailboxScreen < InstantRecord::Native::Screen
  def body
    navigation title: param("inbox").capitalize do
      list refreshable: true do
        messages.each do |entry|
          row id: entry.id, link: "thread", with: { "inbox" => param("inbox"), "id" => entry.id.to_s } do
            stack "horizontal" do
              text entry.author, style: "headline", lines: 1
              spacer
              date entry.created_at.utc.iso8601(6), style: "caption", tone: "secondary"
            end
            text entry.subject, lines: 1
            swipe "Archive", action: "archive", with: { "id" => entry.id.to_s }, role: "destructive", image: "archive"
          end
        end
      end
      toolbar do
        button "View", image: "filter", position: "trailing" do
          item "Unread", link: "mailbox", with: { "inbox" => param("inbox"), "show" => "unread" }
          item "Mark read", action: "read_all"
        end
      end
    end
  end

  def perform(action, params)
    case action
    when "archive" then archive(params["id"].to_s)
    when "read_all" then read_all
    end
  end
end
```

- **Values travel by name.** `with:` is what a row hands the screen it opens,
  or what a button hands `perform`. Names and values are strings, so write
  `entry.id.to_s`. Nothing is packed into one string and split again.
- **A pushed screen is told it opened**: `perform("open", {})`. The
  conversation marks its message read there.
- **A menu item with `link:`** puts that screen in the first screen's place,
  as choosing another account does.
- **Layout is in the Ruby.** `spacer` pushes what follows to the far edge,
  and `lines:` caps a text. The renderer adds no rules of its own.
- **Icons are named by meaning** (`archive`, `filter`, `person`, `inbox`,
  `unread`, `read`, `send`, `compose`), and `Icons.swift` picks the SF
  Symbol. A name it does not know is used as an SF Symbol name.
- **What two screens share goes in a module** in `app/screens`
  (`demo/app/screens/mail_access.rb`).

### Forms

```ruby
bottom do
  field "body", placeholder: "Reply"
  button "Send", action: "reply", image: "send"
end
```

A button sends what was typed into the fields beside it, under their names,
with its action (`params["body"]`), then empties them. `bottom` pins its
contents under the screen, above the keyboard.

### A view written in SwiftUI

A screen can hand its data to a view the app wrote by hand, the way a Rails
action hands a React page its props with `render inertia:`.

```ruby
swift "ConversationView" do
  prop "subject", entry.subject
  flag "archived", archived?(entry)
  number "replies", replies.size
  props "messages" do
    replies.each do |reply|
      record do
        prop "author", reply.author
        prop "body", reply.body
      end
    end
  end
end
```

```swift
// Once at launch, handed to the AppHost
var views = Screens()
views.register("ConversationView") { props, actions in
    ConversationView(props: props, actions: actions)
}

// In the view
props["subject"]                 // String
props.bool("archived")           // Bool
props.int("replies")             // Int
props.list("messages")           // [Props]
actions.perform("archive")       // reaches the screen's perform, like any tap
```

Used inside a list, `swift` puts one hand-written view among stock ones, as a
partial would. A name nobody registered shows a warning in its place.

## What the renderer draws

| Element | Drawn as |
|---|---|
| `navigation title:` | the bar's title: large on the first screen, inline on pushed ones |
| `list`, `section` | `List`, `Section`; `refreshable: true` adds pull to refresh |
| `row` | a list row kept by its `id`; with `link:` a `NavigationLink` |
| `stack`, `spacer` | `VStack` or `HStack`, `Spacer` |
| `text`, `date`, `image` | `Text` in a system style, a date in the phone's language, an icon |
| `button`, `swipe` | `Button`, a swipe action; a destructive swipe is tinted red |
| `toolbar` | bar buttons on the side `position:` names; a button with `item`s is a `Menu` |
| `field`, `bottom` | `TextField`, a bar pinned under the screen |
| `swift` | the registered SwiftUI view |

## Sync, and what the app tells you

The app decides when to sync (`SyncSchedule.swift`). A tap asks for a sync,
and taps close together share one. A sync that could not reach the server,
or left writes waiting, is tried again after 2 seconds, then 4, up to a
minute. The network coming back runs one at once. While the app is in
front it syncs every 5 seconds, which is how a change made elsewhere
arrives. It does not hold a stream open.

A line under the screen says "Offline" and how many changes are waiting. A
banner over it shows what last went wrong until it is dismissed.

Each account has its own SQLite file, because one file syncs with one
address. The app says which (`AppHost.Store`), and the host closes one and
opens the other when the first screen changes.

## Developing: no rebuild after an edit

```sh
xcrun simctl launch booted dev.instantrecord.Inbox -server http://localhost:3000 -dev YES
```

In this mode the phone asks Rails for each screen and sends it each tap, so
an edit to a screen's Ruby shows after a pull. The same screen classes run
on the server. There is no database on the phone and nothing works offline.

Turn it on in the app's development environment:

```ruby
config.instant_record.native_dev = true
```

The endpoints run a screen's actions as whoever the params name. They answer
404 unless that setting is on, the environment is local, and the request
comes from this machine with a JSON content type, and they send no CORS
headers, so a web page open in the developer's browser cannot reach them.

## The token

The app sends `Authorization: Bearer <token>` with every sync request when
it is launched with `-token`. `bin/rails 'inbox:token[maya]'` prints one.

In the demo this is not what keeps mail private. Its members are public
personas, and a request with no token is served, so that the browser demo
works as before. Started with `INBOX_REQUIRE_TOKEN=1` the demo refuses a
request without a valid token. The gem's own sync endpoints do not check
it. An app with private data must require the token and take the member
from it, not from the address. There is no sign-in screen yet.

## Tests

- `swift test` in `InstantRecordNative` runs the package's tests on the Mac.
- `native/ios/ui-test.sh` runs the Inbox's flows in the simulator. It
  recreates a database of its own (`postgres:///instant_record_native_ui`),
  seeds a fixed inbox, starts the demo with a token required, and stops it
  afterwards, so it can be run again and again. It covers open and read,
  reply, archive, switching inbox, unread only, older mail, a message
  arriving with no touch, pull to refresh, an archive the server refuses,
  an archive made offline that goes out when the server returns, and the
  main controls in dark mode at the largest text size.

## What has run, and what has not

On macOS arm64 with Xcode 27.2, in the iPhone 17 simulator on iOS 26.5:
everything above, and a fresh `rails new` app with one synced model and one
screen, generated, built and launched twice.

Not built for a device, signed, or run on a phone. No Android renderer, no
tab bar, no sign-in screen. The sync is a poll, not a held stream.
