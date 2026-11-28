# What iOS offers, and how you reach it

An audit of the iOS 27.2 SDK (314 framework entries) and of common iOS design patterns, against this package.

- **Built in**: use it from Ruby or a page now.
- **Add**: a few lines with `capabilities.add`. It answers with values.
- **View**: a SwiftUI view you register. It draws.
- **Target**: needs an extension target of its own. The generator writes none yet.
- **Entitlement**: as Add or View, and Apple must grant it.

## Design patterns

| Pattern | How |
|---|---|
| Tabs, sidebar on iPad | Built in |
| Navigation stack, sheets | Built in |
| Lists, sections, swipe actions, pull to refresh | Built in |
| Menus, toolbars, title menu, floating button, toast | Built in |
| Toggle, slider, stepper, picker, date, colour | Built in |
| Grid, cards, paged views, horizontal scroll, disclosure | Built in |
| Progress, gauge, badge | Built in |
| Charts: bar, line, area, point, pie | Built in |
| Maps with pins | Built in |
| Picture, video, share sheet | Built in |
| Alerts and confirmations | Built in, from a page's `confirm` |
| Offline, errors, retry, conflicts | Built in |
| Dark mode, Dynamic Type, VoiceOver labels | Built in |
| Search field, context menu, drag and drop, full-screen cover, popover, detents | View |
| Split view, inspector, multiple windows | View |
| Hero and zoom transitions, custom animation | View |
| Onboarding tips | View (TipKit) |

## Frameworks

| Area | Framework | How |
|---|---|---|
| Sound | AVFoundation playing, speaking, recording | Built in |
| | MusicKit, MediaPlayer, ShazamKit, CoreMIDI, AudioUnit, PHASE | Add |
| | Speech recognition, SoundAnalysis | Add |
| Sight | Video | Built in |
| | Camera, PhotosUI, VisionKit, PDFKit, QuickLook, PencilKit, PaperKit | View |
| | Vision, CoreImage, ImageIO | Add |
| 3D | USDZ models (SceneKit) | Built in |
| | RealityKit, ARKit, RoomPlan, SpriteKit, MetalKit | View |
| Place | Location, once | Built in |
| | Following location, geofences, CoreMotion, NearbyInteraction | Add |
| | WeatherKit | Entitlement |
| People | Face ID, keychain | Built in |
| | Contacts, EventKit, MessageUI | Add or View |
| | Sign in with Apple, passkeys (AuthenticationServices) | Entitlement |
| | HealthKit, HomeKit, FamilyControls, FinanceKit | Entitlement |
| Notice | Local notifications | Built in |
| | Push | Entitlement |
| | AlarmKit | Add |
| Money | StoreKit | Add or View |
| | PassKit | Entitlement |
| Thinking | FoundationModels, CoreML, NaturalLanguage, Translation | Add |
| Nearby | CoreBluetooth, MultipeerConnectivity, Network | Add |
| | CoreNFC, CarPlay, NetworkExtension | Entitlement |
| Games | GameController, GameKit | Add |
| System | Haptics, clipboard, battery, torch, network | Built in |
| | CoreSpotlight, BackgroundTasks | Add, with setup at launch |
| | AppIntents (Siri, Shortcuts) | Swift in the app, read at build time |
| Outside the app | WidgetKit, ActivityKit | Target |
| | Share, keyboard, Safari, notification and file extensions, App Clips, watch | Target |

Others in the SDK follow the same rule: what answers is Add, what draws is View, what runs outside the app is Target. Underscored entries are overlays of two frameworks and have no use alone.

## Widgets

None yet. A widget is another process. It cannot load the compiled Ruby library in the memory iOS gives it, and it cannot share the app's SQLite file safely while the app writes to it. So it must be drawn from a snapshot: Ruby describes it with the elements above, the app writes the JSON to a shared App Group, and one generic extension draws it. With that, a hundred widgets are a hundred short Ruby files. It needs an App Group, a second target in the generated project, and a signing team.

## Why not every API by name

Objective-C methods could be called by name at run time. It was considered and not built. Newer frameworks are Swift only and cannot be reached that way, a server's page would be able to call anything, and Apple reviews for code that reaches undeclared APIs.
