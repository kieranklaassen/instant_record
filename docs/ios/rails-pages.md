# Rails pages

Rails serves HTML. Hidden elements in it say what should be native, and the app draws that. Nothing about a page is in the app's binary, so a deploy changes it.

The helpers are those of the [ruby_native](https://github.com/Ruby-Native/gem) gem, which is MIT licensed. The app that reads them is InstantRecord's own.

## Tabs

```yaml
# config/ruby_native.yml
appearance:
  tint_color: "#AA3366"
tabs:
  - { title: Orders, path: /orders, icon: shippingbox, badge: true }
  - { title: Account, path: /account, icon: person }
```

The bar shows on pages with `<%= native_tabs_tag %>`. Leave it out of a sign-in page. `<%= native_badge_tag 3 %>` puts a count on the tab with `badge: true`.

The app reads the config at launch and each time it comes to the front. A copy is kept for when the server cannot be reached. A broken config never replaces a good one.

## The navigation bar

```erb
<%= native_navbar_tag "Orders" do |navbar| %>
  <% navbar.button "New", icon: "plus", href: new_order_path %>
  <% navbar.button "More", icon: "ellipsis.circle" do |menu| %>
    <% menu.item "Archive", click: "#archive" %>
    <% menu.item "Delete", click: "#delete", destructive: true %>
  <% end %>
  <% navbar.segment "Open", href: orders_path, selected: true %>
  <% navbar.segment "Done", href: done_orders_path %>
<% end %>
```

`href` goes to a page. `click` clicks the element the selector finds, also one hidden with `class="native-hidden"`.

## Forms

```erb
<%= native_form_tag %>
<%= native_navbar_tag "New order" do |navbar| %>
  <% navbar.submit_button title: "Place", click: "#place" %>
<% end %>
```

Back passes over a page marked as a form.

## Native or web?

```erb
<% unless native_app? %><nav>...</nav><% end %>
```

## Turbo and Inertia

Both work, and need nothing. The app follows the page as it changes, with or without a full load. For Inertia, the gem's `@ruby-native/react` and `@ruby-native/vue` packages are described as rendering the same elements. This shell has been run with Turbo, not with those packages.

## Safety

- Only the main frame of your own server can speak to the app. An iframe and another origin cannot.
- A link to another origin opens outside the app. Other schemes are refused, apart from mail, phone, message and FaceTime links.
- Pages share one cookie store across tabs. A Ruby screen's sync does not use it. See [Mixing the three](mixing.md#signing-in).
