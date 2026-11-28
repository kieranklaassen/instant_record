# The device

A capability is something the device does, by name. All three kinds of view call the same ones.

```ruby
# A Ruby screen
button "Buzz", action: "native:haptics.play", args: { "style" => "success" }

def perform(action, args, values)
  case action
  when "native:location.current" then save_place(values["latitude"], values["longitude"])
  end
end
```

```js
// A Rails page
const device = await InstantRecord.call("device.info")
```

```swift
// SwiftUI
try await capabilities.call("haptics.play", ["style": "success"])
```

What came of it reaches `perform` in `values`, or as `values["error"]`. In a page the promise is rejected.

## Standard

These ask for no permission: `app.info`, `device.info`, `network.status`, `haptics.play`, `clipboard.write`, `speech.speak`, `speech.stop`, `audio.play`, `audio.pause`, `audio.resume`, `audio.stop`, `audio.seek`, `audio.status`, and on iOS `battery.status`, `screen.keepAwake`, `app.settings`, `torch.set`. `capabilities.list` names them all.

## By group

These ask the person or hand over what is theirs. An app adds each group it needs:

```swift
let capabilities = Capabilities()
capabilities.allow(.location, .biometrics)
```

| Group | Adds | Info.plist |
|---|---|---|
| `.biometrics` | `biometrics.check` | `NSFaceIDUsageDescription` |
| `.clipboardReading` | `clipboard.read` | |
| `.keychain` | `keychain.set`, `.get`, `.delete` | |
| `.location` | `location.current` | `NSLocationWhenInUseUsageDescription` |
| `.notifications` | `notifications.request`, `.schedule`, `.cancel` (local) | |
| `.recording` | `audio.record`, `audio.finish` | `NSMicrophoneUsageDescription` |

iOS stops an app that asks without its Info.plist line.

## Any other API

```swift
capabilities.add("health.steps") { arguments in
    ["count": try await stepsToday()]
}
```

Arguments and answers are plain values by name. That is the whole bridge: anything Apple offers in Swift is a few lines away.

Nothing else can be called. There is no way to reach a Swift or Objective-C method by its own name, because a page is whatever a server sent. What you `allow` or `add` is open to your server's pages, so leave out what a page should not have.
