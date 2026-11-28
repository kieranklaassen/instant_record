# Getting started

You need a Mac with Xcode, and a Rails app with InstantRecord.

## With Rails pages

This needs no compiler toolchain.

```sh
bundle add ruby_native
bin/rails generate ruby_native:install
bin/rails generate instant_record:ios Shop --hybrid
```

List at least two tabs in `config/ruby_native.yml`:

```yaml
app:
  name: Shop
tabs:
  - title: Orders
    path: /orders
    icon: shippingbox
  - title: Account
    path: /account
    icon: person
```

Put the tab bar and the gem's stylesheet in your layout:

```erb
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<%= stylesheet_link_tag :ruby_native %>
...
<body>
  <%= native_tabs_tag %>
  <div class="native-inset-top"></div>
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
