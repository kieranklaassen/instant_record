# Ruby Native compatibility

InstantRecord's shell reads the public contract of the [ruby_native](https://github.com/Ruby-Native/gem) gem, version 0.21.1: its config, its helpers' markup, its user agent and `window.RubyNative`. It is a separate program. It has none of Ruby Native's app code, is not affiliated with Ruby Native, and does not include its build and deploy service.

## Supported

| Part | Notes |
|---|---|
| `/native/config.json` | `app.entry_path`, `appearance.tint_color`, and a tab's `title`, `titles`, `path`, `icon`, `icons.ios`, `key`, `badge`, `eager` |
| `native_tabs_tag` | two tabs or more |
| `native_navbar_tag` | title, `pull_to_refresh:` |
| `navbar.button`, `menu.item` | icon, `href`, `click`, position (also `:title`), `selected`, `destructive`, `action: :replace` |
| `navbar.segment`, `submit_button`, `share_button`, `share_item` | a segment replaces when it has an `href` |
| `native_form_tag` | Back passes over it |
| `native_badge_tag` | `tab:` and `tabs:`, not `home:` |
| `native_fab_tag` | icon, title, color, `href`, `click` |
| `native_toast_tag` | message and icon |
| `native_haptic_data` | on a tap |
| `native_back_button_tag` | |
| `native_app?`, `native_platform`, `native_version` | from the user agent |
| `window.RubyNative` | `visit`, `share`, `postMessage({action: "back"})`. Other methods do nothing |

InstantRecord adds `screen:` and `view:` to a tab, and a list of `routes:`. Ruby Native's app ignores unknown keys. Its `ruby_native` MCP server's config check may warn about them.

## Not supported

- Advanced Mode: pushed pages, modals, `native_presentation_tag`
- push, in-app purchase, barcode scanning, OAuth and secure sessions
- `native_menu_tag`, `native_locale_tag`, `native_keyboard_tag`, `native_overscroll_tag`, `native_review_tag`, `native_identity_tag`
- the navbar logo, splash and error screen settings, `auto_route`, `search` tabs, a toast's duration and appearance
- Android

A signal that is not supported does nothing. The user agent says `RubyNative/0.21.1`, so a page that tests `native_version` may use one. It also says `InstantRecord/1`, which tells the two apart.
