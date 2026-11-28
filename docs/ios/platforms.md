# iPhone, iPad and Mac

A generated app runs on iPhone and iPad. One with no compiled Ruby runs on the Mac too, from the same project:

```sh
xcodebuild -project Shop.xcodeproj -scheme Shop -destination 'platform=macOS' build
```

| | iPhone | iPad | Mac |
|---|---|---|---|
| Rails pages | yes | yes | yes |
| SwiftUI views | yes | yes | yes |
| Ruby screens, compiled | yes | yes | not yet: the libraries are built for iOS |
| Tabs | a bar | a bar that becomes a sidebar (iOS 18) | a sidebar (macOS 15) |
| Turning | upright | any way up | |
| Pull to refresh, haptics | yes | pull to refresh | no |

On the Mac a page's `prompt` answers nothing, and tabs show whether or not the page asks for them.
