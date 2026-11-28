module InstantRecord
  module Native
    # A screen of a native app, written in Ruby.
    #
    #   class MailboxScreen < InstantRecord::Native::Screen
    #     def body
    #       navigation title: "Support" do
    #         list do
    #           MailEntry.open_messages.each do |entry|
    #             row id: entry.id, link: "thread", params: { "id" => entry.id } do
    #               text entry.author, style: "headline"
    #               text entry.subject, lines: 1
    #               swipe "Archive", action: "archive", args: { "id" => entry.id }, role: "destructive"
    #             end
    #           end
    #         end
    #       end
    #     end
    #
    #     def perform(action, args, values)
    #       case action
    #       when "archive" then archive(args["id"])
    #       end
    #     end
    #   end
    #
    # `body` describes the screen with the words iOS draws. The app's renderer
    # turns the description into native views and knows nothing else about the
    # app. A tap comes back as `perform` with the action and `args` the
    # element named, together with what was typed into the screen's fields
    # (`values`), and the screen is rendered again afterwards. A screen that
    # was just opened over another is told so: `perform("open", {}, {})`.
    #
    # A screen, or one part of it, can instead be a view the app wrote in
    # SwiftUI. `swift` names the view and hands it props, as a Rails action
    # hands a React page its props with `render inertia: "Email/Index",
    # props: { ... }`:
    #
    #   def body
    #     swift "ConversationView" do
    #       prop "subject", message.subject
    #       props "messages" do
    #         replies.each do |reply|
    #           record do
    #             prop "author", reply.author
    #             prop "body", reply.body
    #           end
    #         end
    #       end
    #     end
    #   end
    #
    # The app registers the view under that name and reads `props["subject"]`
    # and `props.list("messages")`. `flag`, `number` and `time` hand it a
    # boolean, a whole number and a moment. What the view does comes back through
    # `perform`, like any tap. Used inside a list or a stack, `swift` puts one
    # hand-written view among the stock ones, as a partial would.
    #
    # Keep to plain Ruby here: blocks, `yield` and `case`. The phone runs this
    # file through an ahead-of-time compiler with no `method_missing`, no
    # `instance_eval` and no `send` to a computed name.
    class Screen
      # `params` are what the screen was opened with, strings by name. Every
      # hash a screen gives to `params:` or `args:` holds strings too: write
      # `entry.id.to_s` for a value that comes from a record, since the
      # phone's compiler types a hash by what it holds and refuses another.
      def initialize(params = Node.strings)
        open_with(params)
        @open = []
      end

      # Keeps the params. A method of its own because the phone's compilers
      # take a type for it from sig/instant_record/native.rbs, which they do
      # not for `initialize`.
      def open_with(params)
        @given = params
      end

      # What a host sent as a JSON object, as strings by name. Anything that
      # is not an object gives an empty hash.
      def self.strings(parsed)
        out = Node.strings
        parsed.each { |name, value| out[name.to_s] = value.to_s } if parsed.is_a?(Hash)
        out
      end

      # One of the params, or "" when the screen was opened without it.
      def param(name)
        @given.fetch(name, "").to_s
      end

      def body
      end

      # A tap. `args` are what the tapped element was given, and `values` are
      # what a form's fields held, both strings by name.
      def perform(action, args, values)
      end

      def render
        root = Node.new("screen")
        @open = [root]
        body
        root
      end

      def json
        render.json
      end

      # A navigation bar with a title over whatever the block holds.
      def navigation(title: "")
        node = add("navigation")
        node.set("title", title)
        inside(node) { yield }
      end

      # `refreshable: true` lets a pull on the list sync and draw it again.
      def list(refreshable: false)
        node = add("list")
        node.set("refresh", "true") if refreshable
        inside(node) { yield } if block_given?
        node
      end

      def section(title = "")
        node = add("section")
        node.text = title
        inside(node) { yield }
      end

      # One line of a list. `id` is the record it shows, which is how the list
      # keeps its place when it is drawn again. `link` names the screen a tap
      # opens over this one ("thread"), or a SwiftUI view ("swift:MapView") or
      # a page Rails serves ("page:/orders/1") in its place, and `params` are handed to that screen, which
      # hears of it as `perform("open", ...)`.
      def row(id: "", link: "", params: Node.strings)
        node = add("row")
        node.id = id
        node.link_params = params
        node.set("link", link)
        inside(node) { yield }
      end

      # Elements side by side ("horizontal") or one under another ("vertical").
      def stack(axis = "vertical")
        node = add("stack")
        node.set("axis", axis)
        inside(node) { yield }
      end

      # Empty room in a stack: what follows it sits at the far edge.
      def spacer
        add("spacer")
      end

      # `style` is one of the system's text styles: "headline", "body",
      # "subheadline", "caption", "title". `tone` is "secondary" for quieter
      # text. `lines` is the most lines it may take, or 0 for as many as it
      # needs.
      def text(value, style: "", tone: "", lines: 0)
        node = add("text")
        node.text = value
        node.set("style", style)
        node.set("tone", tone)
        node.set("lines", lines.to_s) if lines > 0
        node
      end

      # A moment, as ISO 8601. The phone writes it out in its own language and
      # time zone. `style` and `tone` are as for text.
      def date(iso8601, style: "", tone: "")
        node = add("date")
        node.text = iso8601
        node.set("style", style)
        node.set("tone", tone)
        node
      end

      # An icon by what it means: "person", "filter", "archive", "inbox",
      # "unread", "read", "send", "compose". The renderer picks the platform's
      # symbol for it and says its name aloud. A name it does not know is
      # used as the platform's own, such as "envelope.badge".
      def image(name, tone: "")
        node = add("image")
        node.text = name
        node.set("tone", tone)
        node
      end

      # In a toolbar, `position` is "leading" or "trailing". A button given a
      # block is a menu, and the block holds its items.
      def button(label, action: "", args: Node.strings, role: "", image: "", position: "")
        node = add("button")
        act(node, label, action, args, role)
        node.set("image", image)
        node.set("position", position)
        inside(node) { yield } if block_given?
        node
      end

      # One line of a menu. With an `action` it is performed like a button's.
      # With a `link` it opens that screen with `params` over this one, as a
      # row does. With `replace` the screen it names takes the place of the
      # first screen, as choosing another account does. With `sheet` the screen
      # it names comes up over this one and is dismissed, not gone back from.
      # `selected` gives it a tick.
      def item(title, action: "", args: Node.strings, link: "", replace: "", sheet: "", params: Node.strings, image: "", role: "", selected: false)
        places = 0
        places += 1 if link.length > 0
        places += 1 if replace.length > 0
        places += 1 if sheet.length > 0
        raise ArgumentError, "Give a menu item one of link:, replace: or sheet:" if places > 1
        node = add("item")
        act(node, title, action, args, role)
        node.link_params = params
        node.set("link", link)
        node.set("replace", replace)
        node.set("sheet", sheet)
        node.set("image", image)
        node.set("selected", "true") if selected
        node
      end

      # A swipe on the row that holds it. `edge` is "trailing" or "leading".
      def swipe(label, action:, args: Node.strings, role: "", edge: "", image: "")
        node = add("swipe")
        act(node, label, action, args, role)
        node.set("edge", edge)
        node.set("image", image)
        node
      end

      # A view written in SwiftUI (or Compose), by the name the app registered
      # it under. The block hands it typed props.
      def swift(name)
        node = add("swift")
        node.text = name
        inside(node) { yield } if block_given?
        node
      end

      # A page Rails serves, among native elements: the part of a screen that
      # ships with a deploy. Its bar is the screen's. It fills what room is
      # left, so it stands beside a list and not in one. Needs the network, and
      # an app that was given its server (HybridHost, or AppHost's `site`).
      def web(path)
        node = add("web")
        node.text = path
        node
      end

      # Platform-neutral alias for `swift`: hands typed props to a registered
      # native component.
      def component(name)
        node = add("swift")
        node.text = name
        inside(node) { yield } if block_given?
        node
      end

      # A string for the native view, by name: `props["subject"]` in Swift.
      # Passing nil omits the prop (matching an optional field in a contract).
      def prop(name, value)
        return nil if value.nil?
        typed(name, "string", value.to_s)
      end

      # A yes or no for the native view: `props.bool("archived")`.
      def flag(name, value)
        return nil if value.nil?
        typed(name, "bool", value ? "true" : "false")
      end

      # A whole number for the native view: `props.int("unread")`.
      def number(name, value)
        return nil if value.nil?
        typed(name, "int", value.to_s)
      end

      # A floating-point number for the native view: `props.double("score")`.
      def decimal(name, value)
        return nil if value.nil?
        typed(name, "float", value.to_s)
      end

      # A moment for the native view, as ISO 8601: `props.date("sent")`.
      def time(name, iso8601)
        return nil if iso8601.nil?
        typed(name, "date", iso8601.to_s)
      end

      # A list for the native view, by name. The block holds its records or
      # unnamed scalar items (`prop "", value`).
      def props(name)
        node = add("props")
        node.set("name", name)
        inside(node) { yield }
      end

      # One entry of a list (`record { ... }`), or a named nested object
      # (`record("sender") { ... }`): the block holds its props.
      def record(name = "")
        node = add("record")
        node.set("name", name)
        inside(node) { yield }
      end

      # Controls in the navigation bar: buttons, and buttons that open a menu.
      def toolbar
        inside(add("toolbar")) { yield }
      end

      # A bar pinned under the screen, above the keyboard: a reply box.
      def bottom
        inside(add("bottom")) { yield }
      end

      # A box to type in. `label` is what it shows while empty and what it is
      # called aloud. What is typed stays on the phone until the next action
      # from this screen, reaches `perform` in `values` under `name`, and the
      # box is emptied once that action has been performed. A button beside a
      # field cannot be pressed while every field of the screen is blank.
      def field(name, label: "", value: "", multiline: false)
        node = add("field")
        node.text = value
        node.set("name", name)
        node.set("label", label)
        node.set("multiline", "true") if multiline
        node
      end

      # The list goes on at the server. When this comes into view the app
      # asks the sync address for `records?<query>` and hands the answer to
      # the library, which keeps the page and writes down whether more lies
      # below it: `InstantRecord::SyncMetadata.get("history:" + key)` is
      # "more" or "end", and nil before any page. The screen is then drawn
      # again, and leaves this out once the answer is "end".
      def more(key, query:)
        node = add("more")
        node.id = key
        node.set("query", query)
        node
      end

      # -- Controls. Each is kept by `name` and reaches `perform` in `values`,
      # as a field's text does. With an `action` it is performed at once.
      # Amounts are strings, as every value that crosses is: min: "0".

      # A switch. Its value is "true" or "false".
      def toggle(name, label: "", on: false, action: "", args: Node.strings)
        control("toggle", name, label, on ? "true" : "false", action, args)
      end

      # A slider says where the finger left it.
      def slider(name, label: "", value: "", min: "0", max: "1", step: "0.01", action: "", args: Node.strings)
        node = control("slider", name, label, value, action, args)
        bounds(node, min, max, step)
      end

      def stepper(name, label: "", value: "0", min: "0", max: "100", step: "1", action: "", args: Node.strings)
        node = control("stepper", name, label, value, action, args)
        bounds(node, min, max, step)
      end

      # One of several `option`s. `style` is "menu", "segmented" or "inline".
      def picker(name, label: "", value: "", style: "menu", action: "", args: Node.strings)
        node = control("picker", name, label, value, action, args)
        node.set("style", style)
        inside(node) { yield }
      end

      def option(label, value)
        node = add("option")
        node.text = label
        node.set("value", value)
        node
      end

      # A day, and with `time: true` a moment, as ISO 8601.
      def date_picker(name, label: "", value: "", time: false, action: "", args: Node.strings)
        node = control("dates", name, label, value, action, args)
        node.set("time", "true") if time
        node
      end

      # A colour, as "#RRGGBB".
      def color_picker(name, label: "", value: "", action: "", args: Node.strings)
        control("colors", name, label, value, action, args)
      end

      # -- Showing.

      # Without a `value` it turns, for work with no known end.
      def progress(label = "", value: "", total: "1")
        node = add("progress")
        node.text = label
        node.set("value", value)
        node.set("total", total)
        node
      end

      def gauge(label, value:, total: "1")
        node = add("gauge")
        node.text = label
        node.set("value", value)
        node.set("total", total)
        node
      end

      def divider
        add("divider")
      end

      # Words beside an icon.
      def labeled(text, image:)
        node = add("label")
        node.text = text
        node.set("image", image)
        node
      end

      # A picture from the web, or from the app's server by its path. `label`
      # is what it is called aloud.
      def picture(url, label: "", height: "")
        node = add("picture")
        media(node, url, label, height)
      end

      # A button that opens the share sheet.
      def share_link(text, url:)
        node = add("share")
        node.text = text
        node.set("url", url)
        node
      end

      def video(url, height: "")
        node = add("video")
        media(node, url, "", height)
      end

      # A 3D model, a USDZ, that a finger turns.
      def model_3d(url, label: "", height: "")
        node = add("model")
        media(node, url, label, height)
      end

      # `style` is "bar", "line", "area", "point" or "pie". The block holds
      # its points.
      def chart(style: "bar", height: "")
        node = add("chart")
        node.set("style", style)
        node.set("height", height)
        inside(node) { yield }
      end

      def point(label, value, series: "")
        node = add("point")
        node.text = label
        node.set("value", value)
        node.set("series", series)
        node
      end

      # A map of its pins.
      def map_view(height: "")
        node = add("map")
        node.set("height", height)
        inside(node) { yield }
      end

      def pin(label, latitude:, longitude:)
        node = add("pin")
        node.text = label
        node.set("latitude", latitude)
        node.set("longitude", longitude)
        node
      end

      # -- Arranging.

      # Outside a list: what scrolls, "vertical" or "horizontal".
      def scroll(axis = "vertical")
        node = add("scroll")
        node.set("axis", axis)
        inside(node) { yield }
      end

      # As many columns as fit, each at least `width` points.
      def grid(width: "150")
        node = add("grid")
        node.set("width", width)
        inside(node) { yield }
      end

      def disclosure(label)
        node = add("disclosure")
        node.text = label
        inside(node) { yield }
      end

      def card
        inside(add("card")) { yield }
      end

      # One child to a page, swiped between.
      def pages(height: "")
        node = add("pages")
        node.set("height", height)
        inside(node) { yield }
      end

      private

      def control(kind, name, label, value, action, args)
        node = add(kind)
        node.text = label
        node.action = action
        node.args = args
        node.set("name", name)
        node.set("value", value)
        node
      end

      def bounds(node, min, max, step)
        node.set("min", min)
        node.set("max", max)
        node.set("step", step)
        node
      end

      def media(node, url, label, height)
        node.set("url", url)
        node.set("label", label)
        node.set("height", height)
        node
      end

      def add(kind)
        node = Node.new(kind)
        @open.last.children << node
        node
      end

      def inside(node)
        @open << node
        yield
        @open.pop
        node
      end

      def act(node, label, action, args, role)
        node.text = label
        node.action = action
        node.args = args
        node.set("role", role)
      end

      def typed(name, type, value)
        node = add("prop")
        node.set("name", name)
        node.set("type", type)
        node.text = value
        node
      end
    end
  end
end
