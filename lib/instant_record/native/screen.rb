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
    #               text entry.subject
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
    # element named, and the screen is rendered again afterwards.
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
      # opens and `params` are handed to that screen. A row with an `action`
      # has it performed with `args` before the screen opens.
      def row(id: "", link: "", params: Node.strings, action: "", args: Node.strings)
        node = add("row")
        node.id = id
        node.action = action
        node.args = args
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

      # `style` is one of the system's text styles: "headline", "body",
      # "subheadline", "caption", "title". `tone` is "secondary" for quieter text.
      def text(value, style: "", tone: "")
        node = add("text")
        node.text = value
        node.set("style", style)
        node.set("tone", tone)
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

      # A system symbol by name, such as "envelope.badge".
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
      # With a `link` it opens that screen with `params` in place of the first
      # screen, as choosing another account does. `selected` gives it a tick.
      def item(title, action: "", args: Node.strings, link: "", params: Node.strings, image: "", role: "", selected: false)
        node = add("item")
        act(node, title, action, args, role)
        node.link_params = params
        node.set("link", link)
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

      # A view written in SwiftUI, by the name the app registered it under.
      # The block hands it props.
      def swift(name)
        node = add("swift")
        node.text = name
        inside(node) { yield } if block_given?
        node
      end

      # A string for the Swift view, by name: `props["subject"]` in Swift.
      def prop(name, value)
        typed(name, "string", value)
      end

      # A yes or no for the Swift view: `props.bool("archived")`.
      def flag(name, value)
        typed(name, "bool", value ? "true" : "false")
      end

      # A whole number for the Swift view: `props.int("unread")`.
      def number(name, value)
        typed(name, "int", value.to_s)
      end

      # A moment for the Swift view, as ISO 8601: `props.date("sent")`.
      def time(name, iso8601)
        typed(name, "date", iso8601)
      end

      # A list for the Swift view, by name. The block holds its records.
      def props(name)
        node = add("props")
        node.set("name", name)
        inside(node) { yield }
      end

      # One entry of a list: the block holds its props.
      def record
        inside(add("record")) { yield }
      end

      # Controls in the navigation bar: buttons, and buttons that open a menu.
      def toolbar
        inside(add("toolbar")) { yield }
      end

      private

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
