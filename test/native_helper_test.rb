require "test_helper"
require "action_view"
require "instant_record/native_config"
require_relative "../app/helpers/instant_record/native_helper"

class NativeHelperTest < ActiveSupport::TestCase
  FIXTURE = File.expand_path("../native/ios/InstantRecordNative/Tests/InstantRecordNativeTests/Fixtures/native_page.html", __dir__)
  PAGE = <<~ERB
    <!doctype html><html><head><title>Orders page</title><%= native_head %></head><body>
    <%= native_tabs %><%= native_form %><%= native_badge true, tab: :inbox %><%= native_badge "new", tab: :cart %><%= native_toast "Saved" %>
    <%= native_floating_button icon: "plus", href: "/x" %>
    <%= native_bar "Orders", refresh: false,
          leading: [native_button("Close", icon: "xmark", href: "/close")],
          buttons: [native_button("More", icon: "ellipsis.circle", menu: [
            native_button("Edit", href: "/edit", selected: true, replace: true),
            native_button("Delete", click: "#delete", destructive: true),
            native_button("Share", share: "/orders/1")
          ]), native_button("Share", icon: "square.and.arrow.up", share: "/orders")],
          segments: [native_button("Open", href: "/open", selected: true), native_button("Done", href: "/done")],
          submit: native_button("Save", click: "#save") %>
    <button id="delete" class="web-only" onclick="document.body.dataset.deleted = '1'">Delete</button>
    </body></html>
  ERB

  def view = ActionView::Base.with_empty_template_cache.empty.extend(InstantRecord::NativeHelper)

  test "the app's fixture is what the helpers render (UPDATE_FIXTURES=1 writes it)" do
    html = view.render(inline: PAGE)
    File.write(FIXTURE, html) if ENV["UPDATE_FIXTURES"]
    assert_equal File.read(FIXTURE), html
  end

  test "what a page is given cannot leave its element" do
    html = view.native_toast(%("><script>alert(1)</script>))
    assert_no_match(/<script/, html)
    assert_equal %("><script>alert(1)</script>), JSON.parse(CGI.unescapeHTML(html[/data-native="([^"]*)"/, 1])).dig("toast", "message")
    assert_equal "", view.native_toast(nil)
  end

  test "a config with a mistake is refused" do
    assert_nil InstantRecord::NativeConfig.check("tabs" => [{ "title" => "A", "path" => "/a" }]).then { nil }
    [nil, {}, { "tabs" => [] }, { "tabs" => [{ "title" => "A", "path" => "//evil" }] }, { "tabs" => [{ "path" => "/" }] },
      { "tabs" => [{ "title" => "A", "path" => "/" }], "routes" => [{ "path" => "/x", "view" => "V", "screen" => "s" }] }].each do |bad|
      assert_raises(InstantRecord::NativeConfig::Invalid, bad.inspect) { InstantRecord::NativeConfig.check(bad) }
    end
  end
end
