# The Inbox on iPhone

The demo's Inbox as an iPhone app whose screens are Ruby. `InstantRecordNative`
is a Swift package with no dependencies: it runs the compiled app
(`compiled/pipeline/build_native.py`), decodes each screen's JSON and draws it
with stock SwiftUI controls. `Inbox` is the app: it names the first screen,
says where a mailbox keeps its data, and holds two views written by hand.

## Build and run

On a Mac with Xcode, and the toolchain `compiled/README.md` describes:

```sh
python3 compiled/pipeline/build_native.py iphonesimulator
cd demo && bin/rails db:prepare && bundle exec falcon serve --bind http://localhost:3000
cd native/ios/Inbox
xcodebuild -project Inbox.xcodeproj -scheme Inbox -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build build
xcrun simctl boot "iPhone 17"
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Inbox.app
xcrun simctl launch booted dev.instantrecord.Inbox -server http://localhost:3000 -mailbox maya/support
```

`swift test` in `InstantRecordNative` runs the package's tests on the Mac
with no simulator. `xcodebuild test` with the same project and scheme taps
through the app's flows in the simulator against the running server
(`Inbox/InboxUITests`).

## Two ways to draw a screen

### Ruby draws it

A screen describes itself with the words iOS draws, and the renderer turns
each into the stock control. No Swift is written for it.

```ruby
class MailboxScreen < InstantRecord::Native::Screen
  def body
    navigation title: inbox.capitalize do
      list refreshable: true do
        messages.each do |entry|
          row id: entry.id, link: "thread", params: place.merge("thread" => entry.id), action: "read", args: { "id" => entry.id } do
            text entry.author, style: "headline"
            text entry.subject.to_s
            swipe "Archive", action: "archive", args: { "id" => entry.id }, role: "destructive"
          end
        end
      end
      toolbar do
        button "Inboxes", image: "person.crop.circle", position: "leading" do
          item "Support", link: "mailbox", params: { "member" => member, "inbox" => "support" }, selected: true
          item "Billing", link: "mailbox", params: { "member" => member, "inbox" => "billing" }
        end
        button "View", image: "slider.horizontal.3", position: "trailing" do
          item "Mark all read", action: "read_all"
        end
      end
    end
  end

  def perform(action, args, values)
    archive(args["id"]) if action == "archive"
  end

  def member = param("member")
  def inbox = param("inbox")
  def place = { "member" => member, "inbox" => inbox }
end
```

A screen is opened with `params`, strings by name, and reads one with
`param("inbox")`. A link names the next screen's params. An element that
names an `action` carries `args`, and a tap brings both back to `perform`
with what a form's fields held (`values`). Params and args cross to the phone
and back as JSON objects, so a value may hold any character.

A toolbar button with a block is a menu. An item with an `action` is
performed by the screen. An item with a `link` puts that screen in the first
screen's place, as choosing another account does. The app says which
database and sync address that screen uses (`AppHost.Store` in
`InboxApp.swift`), because one database syncs with one address.

### Swift draws it, Ruby hands it props

A screen can hand its data to a view written in SwiftUI, by name, the way a
Rails action hands a React page its props with `render inertia:`.

```ruby
class ThreadScreen < MailboxScreen
  def body
    swift "ConversationView" do
      prop "thread", param("thread")
      prop "subject", message.subject.to_s
      flag "archived", archived?
      props "messages" do
        replies.each do |reply|
          record do
            prop "author", reply.author
            prop "body", reply.body.to_s
          end
        end
      end
    end
  end
end
```

```swift
// InboxApp.swift, once at launch
Screens.register("ConversationView") { props, actions in
    ConversationView(props: props, actions: actions)
}

struct ConversationView: View {
    let props: Props
    let actions: Actions

    var body: some View {
        VStack {
            Text(props["subject"])
            ForEach(Array(props.list("messages").enumerated()), id: \.offset) { Text($0.element["body"]) }
            if !props.bool("archived") {
                Button("Archive") { actions.perform("archive", ["id": props["thread"]]) }
            }
        }
    }
}
```

A prop says what it is: `prop` hands over a string, `flag` a boolean,
`number` a whole number and `time` a moment (ISO 8601). Swift reads them as
`props["subject"]`, `props.bool("archived")`, `props.int("unread")` and
`props.date("sent")`, and a prop that was not sent reads as empty, false, zero
or nil. `props.list("messages")` is a list of records. `actions.perform`
reaches the screen's `perform(action, args, values)` by the same road as a tap
on a Ruby-drawn button: the write is local, the screens are drawn again, and
it syncs.

The same element puts one Swift view among stock ones, as a partial would:

```ruby
list do
  swift "InboxSummary" do
    prop "inbox", inbox.capitalize
    number "unread", unread.size
  end
  messages.each { |entry| row(id: entry.id) { text entry.subject.to_s } }
end
```

```swift
Screens.register("InboxSummary") { props, _ in InboxSummary(props: props) }
```

A name nobody registered shows a warning on screen in its place.

## What the renderer does with each element

| Element | Drawn as |
|---|---|
| `navigation title:` | the navigation bar's title: large on the first screen, inline on pushed ones |
| `list`, `section` | `List`, `Section`; `refreshable: true` adds pull to refresh, which syncs |
| `row` | a list row, kept by its `id`; with `link:` a tap performs its `action` and pushes that screen |
| `stack` | `VStack`, or `HStack` with the last element at the far edge |
| `text`, `date`, `image` | `Text` in a system text style, a date in the phone's language, an SF Symbol |
| `button`, `swipe` | `Button`, a swipe action; `role: "destructive"` is honoured |
| `toolbar` | bar buttons, on the side `position:` names; a button holding `item`s is a `Menu` |
| `swift` | the registered SwiftUI view |

The app syncs on launch, when it comes to the front, after each tap and on a
pull. There is no tab bar yet, and a change made elsewhere arrives on the
next of those syncs: the app does not hold the event stream open.

## What has run

On macOS arm64 with Xcode 27.2, in the iPhone 17 simulator on iOS 26.5. It
has not been built for a device, signed, or run on a phone.
