module InstantRecord
  # What a page asks the native app to draw around it. Each helper writes one
  # hidden element that holds JSON, which the app reads (HybridBridge). In a
  # browser they show nothing.
  #
  # Plain Ruby, like a screen's: a page that runs on the phone has this file
  # compiled into it.
  module NativeHelper
    # The app's tab bar shows on this page.
    def native_tabs
      native_element("tabs" => true)
    end

    # The page is a form, which Back passes over.
    def native_form
      native_element("form" => true)
    end

    # A navigation bar.
    #
    #   <%= native_bar "Orders",
    #         buttons: [native_button("New", icon: "plus", href: new_order_path)],
    #         segments: [native_button("Open", href: orders_path, selected: true)] %>
    #
    # `leading` stand on the near side, `title_menu` hangs from the title, and
    # `submit` is the form's own button. `refresh: false` turns off the pull.
    def native_bar(title = "", buttons: [], leading: [], segments: [], title_menu: [], submit: nil, refresh: true)
      bar = {
        "title" => title.to_s, "pullToRefresh" => refresh,
        "buttons" => leading.map { |button| button.merge("leading" => true) } + buttons, "segments" => segments
      }
      bar["buttons"] = bar["buttons"] + [{ "title" => "", "inTitle" => true, "items" => title_menu }] unless title_menu.empty?
      bar["submit"] = submit if submit
      native_element("navbar" => bar)
    end

    # A button, a segment, or a menu's line. It goes to `href` or clicks the
    # element `click` selects. `menu` makes it a menu of others. `share` opens
    # the share sheet for an address.
    def native_button(title, icon: "", href: nil, click: nil, menu: [], selected: false, destructive: false, replace: false, share: nil)
      button = { "title" => title.to_s, "icon" => icon.to_s }
      button["href"] = href.to_s if href
      button["click"] = click.to_s if click
      button["items"] = menu unless menu.empty?
      button["selected"] = true if selected
      button["destructive"] = true if destructive
      button["replace"] = true if replace
      button["share"] = true if share
      button["shareURL"] = share.to_s if share
      button
    end

    # A button that floats over the page. `color` is "#rrggbb".
    def native_floating_button(icon:, title: "", href: nil, click: nil, color: nil)
      button = native_button(title, icon: icon, href: href, click: click)
      button["color"] = color.to_s if color
      native_element("fab" => button)
    end

    # A count, a short word, or `true` for a dot, on the tab with that `key`.
    def native_badge(value, tab:)
      native_element("badges" => { tab.to_s => value.to_s })
    end

    # A word over the page, shown once. Nothing for a blank one, so it takes a
    # flash as it is.
    def native_toast(message, icon: "checkmark.circle.fill")
      return "".html_safe if message.to_s.empty?
      native_element("toast" => { "message" => message.to_s, "icon" => icon.to_s })
    end

    # Put on a link or a button: `data: native_haptic(:success)`.
    def native_haptic(style = :success)
      { "native-haptic" => style.to_s }
    end

    # Whether the page is shown in the app: the app says so when it asks.
    def native_app?
      request.user_agent.to_s.include?("InstantRecordNative/")
    end

    # For the layout's head: the app's safe area, and what only a browser shows.
    def native_head
      ('<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">' \
        "<style>[data-native-app] .web-only{display:none!important}" \
        "html:not([data-native-app]) .native-only{display:none!important}" \
        ".native-top{height:env(safe-area-inset-top)}.native-bottom{height:env(safe-area-inset-bottom)}" \
        ".native-back{display:none}body.can-go-back .native-back{display:inline}</style>").html_safe
    end

    private

    # JSON in an attribute and not in a script, which a content security
    # policy may refuse. ERB's escaping is the attribute's.
    def native_element(parts)
      "<div hidden data-native=\"#{ERB::Util.html_escape(JSON.generate(parts))}\"></div>".html_safe
    end
  end
end
