# Mixing the three

Every place in an app has an address, and any kind can open any other.

| From | to a Ruby screen | to a SwiftUI view | to a Rails page |
|---|---|---|---|
| a tab | `screen: catalog` | `view: MapView` | `path: /orders` |
| a page's link | a route with `screen:` | a route with `view:` | `<a href="/orders">` |
| a Ruby screen's link | `link: "product"` | `link: "swift:MapView"` | `link: "page:/orders/1"` |
| inside a Ruby screen | its elements | `swift "MapView"` | `web "/orders/1"` |

## Tabs

```yaml
tabs:
  - { title: Orders,  path: /orders,  icon: shippingbox }
  - { title: Catalog, path: /catalog, icon: list.bullet, screen: catalog }
  - { title: Map,     path: /map,     icon: map,         view: MapView }
```

`path` is always needed. An app that does not have the screen or the view loads the page, and so does Ruby Native's own app, which ignores both keys. So you can deploy a new tab before the app that draws it natively is out.

The screen must be the app's first one, the name given to `--screen`. A compiled app opens one database at a time, so one tab is Ruby's.

## Routes

A route turns an ordinary link into a native place:

```yaml
routes:
  - { path: "/products/:id", screen: product }
  - { path: "/places/:id",   view: MapView, sheet: true }
```

`<a href="/products/7">` opens `ProductScreen` with `param("id")` as `"7"`. Words after a colon and the query become params. With `sheet: true` it comes up as a sheet. The first route that matches decides, so name a page that a later route would take:

```yaml
routes:
  - { path: "/products/new", page: true }
  - { path: "/products/:id", screen: product }
```

An app without the place, and a browser, follow the link.

Routes see taps on links, native buttons' `href` and `RubyNative.visit`. They do not see a redirect, a form's answer, or a visit a script makes, so those stay pages. Keep the page working.

A menu item's `replace:` in a screen a page opened swaps that screen. It does not change database, as it does on the first screen.

## Inside a Ruby screen

```ruby
def body
  navigation title: "Product" do
    text product.name, style: "title"     # offline, from SQLite
    web "/products/#{product.id}/reviews" # ships with a deploy
  end
end
```

The page has no bar of its own there. Offline it says it could not be loaded, and the rest of the screen still works.

## Signing in

Pages are signed in with cookies, in the web view. A Ruby screen syncs with its own requests, which carry no such cookie. In an app that mixes them, give the sync a token in `Transport(prepare:)`, or sync only what anyone may see. Signing out of the web does not empty the phone's database.

## The app's file

```swift
let app = AppHost(engine: engine, root: Route("catalog"), views: views, store: store)
app.start()
let host = HybridHost(server: server, app: app, screens: ["catalog", "product"])
// ...
WindowGroup { HybridView(host: host) }
```

Without Ruby screens: `HybridHost(server: server, views: views)`.
