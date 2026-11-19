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
generator again with `--force`. `XcodeProject.new(packages: { "Feedback" =>
"../../feedback" })` links another Swift package by its path from the app's
folder.

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
          row id: entry.id, link: "thread", params: { "inbox" => param("inbox"), "thread" => entry.id.to_s } do
            stack "horizontal" do
              text entry.author, style: "headline", lines: 1
              spacer
              date entry.created_at.utc.iso8601(6), style: "caption", tone: "secondary"
            end
            text entry.subject.to_s, lines: 1
            swipe "Archive", action: "archive", args: { "id" => entry.id.to_s }, role: "destructive", image: "archive"
          end
        end
        more "older:#{param("inbox")}", query: below(messages.last) if older?
      end
      toolbar do
        button "View", image: "filter", position: "trailing" do
          item "Unread", replace: "mailbox", params: { "inbox" => param("inbox"), "filter" => "unread" }
          item "Mark as read", action: "read_all"
        end
      end
    end
  end

  def perform(action, args, values)
    case action
    when "archive" then archive(args.fetch("id", ""))
    when "read_all" then read_all
    end
  end
end
```

- **Values travel by name.** `params:` is what a row or item opens another
  screen with, and `args:` is what a button or swipe hands `perform`. Names
  and values are strings, so write `entry.id.to_s`. Nothing is packed into
  one string and split again.
- **A pushed screen is told it opened**: `perform("open", {}, {})`. The
  conversation marks its message read there.
- **A menu item with `replace:`** puts that screen in the first screen's
  place, as choosing another account does. With `link:` it opens the screen
  over this one, as a row does.
- **Layout is in the Ruby.** `spacer` pushes what follows to the far edge,
  and `lines:` caps a text. The renderer adds no rules of its own.
- **Icons are named by meaning** (`archive`, `filter`, `person`, `inbox`,
  `unread`, `read`, `send`, `compose`), and `Icons.swift` picks the SF
  Symbol and what it is called aloud. A name it does not know is used as an
  SF Symbol name.
- **`more`** stands for the rest of a list that is still on the server. When
  it scrolls into view the app fetches `records?<query>` from the sync
  address and hands the page to the library, and the screen leaves it out
  once nothing more is there.

### Forms

```ruby
bottom do
  field "body", label: "Reply", multiline: true
  button "Send", action: "reply", image: "send"
end
```

What is typed stays on the phone, by screen, through redraws and a trip back
and forth. It reaches `perform` as `values["body"]` with the next action from
that screen and is forgotten once that action has been performed. A button
beside fields cannot be pressed while they are all blank. `bottom` pins its
contents under the screen, above the keyboard.

### A view written in SwiftUI

A screen can hand its data to a view the app wrote by hand, the way a Rails
action hands a React page its props with `render inertia:`.

```ruby
swift "ConversationView" do
  prop "subject", entry.subject.to_s
  flag "archived", archived?(entry)
  number "replies", replies.size
  time "sent", entry.created_at.utc.iso8601(6)
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
props.date("sent")               // Date?
props.list("messages")           // [Props]
actions.perform("archive")       // reaches the screen's perform, like any tap
```

A prop that was not sent, or is read as another kind than it was sent as,
reads as empty, false, zero or nil. `actions.perform` can carry arguments:
`actions.perform("archive", ["id": id])`.

Used inside a list, `swift` puts one hand-written view among stock ones, as a
partial would. A name nobody registered shows a warning in its place.

### A view from a library: the feedback form

The Inbox's View menu ends with "Send feedback". The screen behind it is
four lines of Ruby (`demo/app/screens/feedback_screen.rb`) that name a Swift
view, `FeedbackForm`, and hand it the member and the inbox. The view is not
this repo's: it is the form of the `Feedback` package in
[EveryInc/swift-libraries](https://github.com/EveryInc/swift-libraries), which
files a note as a GitHub issue through a relay.

- **The package is taken by path** from a checkout beside this repo:
  `../swift-libraries` next to `instant_record`. `project.rb` names it
  (`packages: { "Feedback" => "../../../../swift-libraries/feedback" }`), so
  the project holds no path of anyone's machine. Without that checkout the
  Inbox does not build: `git clone https://github.com/EveryInc/swift-libraries`
  beside this repo first.
- **`InboxApp.swift`** calls `Feedback.setUp(product: "instant-record-inbox",
  relay:)` once and registers the form as `FeedbackForm`. The form holds a
  navigation stack of its own, which SwiftUI refuses inside a pushed screen
  (it stops the app), so the screen opens it as a sheet, the way the library
  means it to be used, and goes back when the sheet closes. The member and
  inbox are listed under the note as "From" and "Inbox" with the rest of what
  is sent.
- **Nothing is filed yet.** The relay files only for the products in its own
  list, and `instant-record-inbox` is not in it. Send is answered with "This
  form is not set up to send feedback yet.", shown in red under the form, and
  the note stays where it was. Adding the product is a line in the relay's
  `PRODUCTS` and a deploy, which is the relay owner's to do. With no
  connection the form says "That couldn’t be sent. Check your connection and
  try again."
- `-relay http://localhost:8787` sends to another relay: `node relay/demo.js`
  in the library's `feedback` folder runs one on this Mac that sends nothing
  anywhere.

## What the renderer draws

| Element | Drawn as |
|---|---|
| `navigation title:` | the bar's title: large on the first screen, inline on pushed ones |
| `list`, `section` | `List`, `Section`; `refreshable: true` adds pull to refresh |
| `row` | a list row kept by its `id` and read aloud as one thing; with `link:` a `NavigationLink` |
| `stack`, `spacer` | `VStack` or `HStack`, `Spacer` |
| `text`, `date`, `image` | `Text` in a system style, a date in the phone's language, an icon |
| `button`, `swipe` | `Button`, a swipe action; a destructive swipe is tinted red |
| `toolbar` | bar buttons on the side `position:` names; a button with `item`s is a `Menu` |
| `field`, `bottom` | `TextField` (one that grows with `multiline:`), a bar pinned under the screen |
| `more` | a spinner at the foot of the list while the next page loads, or a line to tap when it could not |
| `swift` | the registered SwiftUI view |

## How it looks

`AppView(host: host, theme: .cora)` gives the app a look. A `Theme`
(`Theme.swift`) is a few colours and two faces: the page, a row's surface, a
quiet fill, a hairline, ink, muted ink, the tint of links and buttons, an
accent fill with the ink that goes on it, the face of labels and controls,
and the face of what is read. The stock elements use it: a list's ground,
rows and separators, `tone: "secondary"` and `tone: "accent"`, the status
line, the reply box and its bar, the foot of a list, and the bar's titles.
A `text` with no `style:` is running text and is set in the reading face.
A hand-written view reads the same value with `@Environment(\.theme)`.

With no theme the app is iOS as it comes (`Theme.system`), which is what a
generated app starts with.

The Inbox uses `Theme.cora`: warm paper (#FBF8F2), white rows, stone ink
(#302B26), one blue (#2F6CA3 for links, #86B2D9 as a fill under dark text),
flat, with hairlines. In the dark it is the same ramp from the other end:
a stone-950 page, stone-900 rows, stone-100 ink and the lighter blue.
Cora's own typefaces are licensed and are not in this repo. The system's
rounded face stands in for headlines and controls and its serif for a
message's subject and body. Sizes are system text styles, so Dynamic Type
works as before, and a test holds every text and ground pair to AA contrast
in both appearances.

The feedback form is drawn by its library. The theme reaches the sheet
around it (the paper, the blue of Cancel and Send, the face), not the
form's own fields.

## Sync, and what the app tells you

Every call into the library runs on one thread, and none of them waits for
the network. A sync pass asks the library what it will want (`sync_plan`,
`cursor`), fetches that on another queue, and then lets the library sync
against those answers alone. A tap made meanwhile is performed and drawn
first, and what it wrote goes out with a pass of its own.

The app decides when to sync (`SyncSchedule.swift`). A tap asks for a pass,
and taps close together share one. A pass that could not reach the server,
was refused, or left writes waiting is tried again after 5 seconds, then 10,
up to a minute. The network coming back runs one at once. While the app is
in front it follows the server's events (`StreamClient.swift`): it asks
`events?after=<cursor>`, hands what arrives to the library, and asks again a
second after a clean end, so a change made elsewhere shows without a touch.

One line over the screen says, in this order: what went wrong ("Could not
sync: POST /mutations answered 401", or what Ruby raised), that the app is
offline, or how many changes are waiting to send. An error stays until it is
dismissed or a pass succeeds. A screen that cannot be drawn keeps the last
one that could.

Each account has its own SQLite file, because one file syncs with one
address. The app says which (`AppHost.Store`). The files are kept: nothing
deletes one but a launch with `-reset YES`.

Switching account does not wait for the network. The host closes the
database being left, opens the other (`ir_open`) and draws it from what is
on the phone, and only then syncs it. "Getting your mail" shows only for a
file that has never synced. Writes still waiting in the database being left
get one pass first, for at most a second (`leaveWithin`). What did not go
out by then waits in that file until it is opened again.

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

`Transport` takes a `prepare` closure that sees every request before it
goes. The Inbox uses it to send `Authorization: Bearer <token>` when it is
launched with `-token`. `bin/rails 'inbox:token[maya]'` prints one.

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
  reply, archive, switching inbox, unread only, the feedback form, older mail, a message
  arriving with no touch, pull to refresh, an archive the server refuses,
  an archive made offline that goes out when the server returns, and the
  main controls in dark mode at the largest text size. The script refuses
  to start when something already answers on its port.

## What has run, and what has not

On macOS arm64 with Xcode 27.2, in the iPhone 17 simulator on iOS 26.5:
everything above, and a fresh `rails new` app with one synced model and one
screen, generated, built and launched twice.

Not signed or run on a phone. No Android renderer, no tab bar, no sign-in
screen. In the development mode there is no paging and no event stream.
