# Rails pages

HTML, from your controllers and views, under native tabs and bars.

## Where they are drawn

In an app with compiled Rails, **on the device**: your router, controllers and ERB run on the phone, over the same SQLite file as its Ruby screens. A page opens with no network. A form's write is queued and synced. A change that arrives redraws a page that uses Turbo.

What the compiled app has no route for comes from your server. So does every page of an app with no compiled Rails.

| | Drawn on the device | Drawn by the server |
|---|---|---|
| Offline | yes | no |
| A change ships with | an App Store build | a deploy |
| Which | the compiled routes (`local_first`) | all others |

The two do not mix for one address: a page in the compiled app is the compiled one until the next build. Keep what you want to change by deploy out of `local_first`.

Stylesheets and scripts come from a `Pages` folder in the app, if it has one. Others are fetched once and kept, so add the folder for a first launch with no network: the generator does not yet.

## Native parts

```erb
<%# the layout %>
<head><%= native_head %></head>
<body><%= native_tabs %><div class="native-top"></div> ...
```

```erb
<%= native_bar "Orders",
      buttons: [
        native_button("New", icon: "plus", href: new_order_path),
        native_button("More", icon: "ellipsis.circle", menu: [
          native_button("Archive", click: "#archive"),
          native_button("Delete", click: "#delete", destructive: true)
        ])
      ],
      segments: [
        native_button("Open", href: orders_path, selected: true),
        native_button("Done", href: done_orders_path)
      ] %>
```

| Helper | Draws |
|---|---|
| `native_tabs` | the tab bar, on this page |
| `native_bar` | the bar: `buttons:`, `leading:`, `segments:`, `title_menu:`, `submit:`, `refresh:` |
| `native_button` | a button, segment or menu line: `href:`, `click:`, `menu:`, `share:`, `selected:`, `destructive:`, `replace:` |
| `native_form` | Back passes over the page |
| `native_badge 3, tab: :inbox` | a count on the tab with that `key` |
| `native_toast notice` | a word, once |
| `native_floating_button` | a button over the page |
| `data: native_haptic(:success)` | a tap you feel |
| `native_app?` | whether the app is asking |

`class="web-only"` hides in the app, and `class="native-only"` in a browser. Icons are SF Symbol names. In a page's JavaScript: `InstantRecord.visit`, `.share`, `.back` and [`.call`](capabilities.md).

Each helper writes one hidden element with JSON. A part the app does not know is ignored, so a newer page works in an older app.

## Tabs

```yaml
# config/native.yml
tint: "#AA3366"
tabs:
  - { title: Orders,  path: /orders,  icon: shippingbox, key: orders }
  - { title: Account, path: /account, icon: person }
```

Also `start:` (the first address), `titles:` by language and `eager:`. The app reads it at launch and when it comes to the front. A broken file never replaces a good one.

## Turbo and Inertia

The app follows a page as it changes, with or without a full load. It was run with Turbo.

## Safety

- Only the main frame of your server, or of the app itself, can speak to the app.
- A link to another origin opens outside. Other schemes are refused, apart from mail, phone, message and FaceTime.
