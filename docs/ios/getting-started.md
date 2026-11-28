# Getting started

You need a Mac with Xcode, and a Rails app with InstantRecord.

## With Rails pages

This needs no compiler toolchain.

```sh
bin/rails generate instant_record:ios Shop --hybrid
```

It writes `config/native.yml`. List at least two tabs there, then put the bar in your layout:

```erb
<head><%= native_head %></head>
<body><%= native_tabs %><div class="native-top"></div>
```

Start Rails, then build and open the app:

```sh
bin/rails server
cd native/ios/Shop
xcodebuild -project Shop.xcodeproj -scheme Shop -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build build
xcrun simctl boot "iPhone 17"
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Shop.app
xcrun simctl launch booted com.example.Shop
```

Launch with `-server https://shop.example.com` to use another server.

## With Ruby screens

This needs the toolchain in [compiled/README.md](../../compiled/README.md).

```sh
bin/rails generate instant_record:ios Shop --screen catalog
bin/rails "instant_record:native[iphonesimulator]"
```

## With both

```sh
bin/rails generate instant_record:ios Shop --hybrid --screen catalog
bin/rails "instant_record:native[iphonesimulator]"
```

`--screen` names the first Ruby screen. The generated app lists every screen in `app/screens` at that moment as one a route may open, in `RubyScreens.swift`.

## After adding a file

Run the generator again with the same options and `--force` after adding a Ruby screen or a Swift file. It writes the Xcode project and `RubyScreens.swift` again. It never writes over `ShopApp.swift`, which is yours.

## While developing

A page shows its edit after a pull. Ruby screens do too with `-dev YES`, which asks Rails for each screen. Set `config.instant_record.native_dev = true` in development for that.
