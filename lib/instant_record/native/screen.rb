module InstantRecord
  module Native
    # A screen of a native app, written in Ruby.
    #
    #   class MailboxScreen < InstantRecord::Native::Screen
    #     def body
    #       navigation title: param("inbox").capitalize do
    #         list do
    #           MailEntry.open_messages.each do |entry|
    #             row id: entry.id, link: "thread", with: { "id" => entry.id } do
    #               text entry.author, style: "headline"
    #               text entry.subject, lines: 1
    #               swipe "Archive", action: "archive", with: { "id" => entry.id }, role: "destructive"
    #             end
    #           end
    #         end
    #       end
    #     end
    #
    #     def perform(action, params)
    #       case action
    #       when "archive" then archive(params["id"].to_s)
    #       end
    #     end
    #   end
    #
    # `body` describes the screen with the words iOS draws. The app's renderer
    # turns the description into native views and knows nothing else about the
    # app. A screen is opened with named params, which it reads with `param`.
    # A tap comes back as `perform` with the action the element named and the
    # params it carried (`with:`), together with whatever was typed into the
    # fields beside that element, and the screen is rendered again afterwards. A screen
    # that was just opened over another is told so: `perform("open", {})`.
    #
    # A screen, or one part of it, can instead be a view the app wrote in
    # SwiftUI. `swift` names the view and hands it props, as a Rails action
    # hands a React page its props with `render inertia: "Email/Index",
    # props: { ... }`:
    #
    #   def body
    #     swift "ConversationView" do
    #       prop "subject", message.subject
    #       flag "archived", archived?
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
    # The app registers the view under that name and reads `props["subject"]`,
    # `props.bool("archived")` and `props.list("messages")`. What the view
    # does comes back through `perform`, like any tap. Used inside a list or a
    # stack, `swift` puts one hand-written view among the stock ones, as a
    # partial would.
    #
    # Keep to plain Ruby here: blocks, `yield` and `case`. The phone runs this
    # file through an ahead-of-time compiler with no `method_missing`, no
    # `instance_eval` and no `send` to a computed name.
    class Screen
      attr_reader :params

      def initialize(params = {})
        @params = params
        @open = []
      end

      # A value the screen was opened with, or "" when it was given none.
      def param(name)
        @params[name].to_s
      end

      def body
      end

      def perform(action, params)
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
        node.set("title", title.to_s)
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
        node.text = title.to_s
        inside(node) { yield }
      end

      # One line of a list. `id` is the record it shows, which is how the list
      # keeps its place when it is drawn again. `link` names the screen a tap
      # opens, and `with` is the params that screen is opened with.
      def row(id: "", link: "", with: {})
        node = add("row")
        node.id = id.to_s
        node.set("link", link)
        node.carry(with)
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
      # text. `lines` is the most lines it may take, or 0 for as many as it needs.
      def text(value, style: "", tone: "", lines: 0)
        node = add("text")
        node.text = value.to_s
        node.set("style", style)
        node.set("tone", tone)
        node.set("lines", lines.to_s) if lines > 0
        node
      end

      # A moment, as ISO 8601. The phone writes it out in its own language and
      # time zone. `style` and `tone` are as for text.
      def date(iso8601, style: "", tone: "")
        node = add("date")
        node.text = iso8601.to_s
        node.set("style", style)
        node.set("tone", tone)
        node
      end

      # An icon by what it means: "person", "filter", "archive", "inbox",
      # "unread", "read", "send", "compose". The renderer picks the
      # platform's symbol for it. A name it does not know is used as given.
      def image(name, tone: "")
        node = add("image")
        node.text = name
        node.set("tone", tone)
        node
      end

      # In a toolbar, `position` is "leading" or "trailing". A button given a
      # block is a menu, and the block holds its items.
      def button(label, action: "", with: {}, role: "", image: "", position: "")
        node = add("button")
        act(node, label, action, with, role)
        node.set("image", image)
        node.set("position", position)
        inside(node) { yield } if block_given?
        node
      end

      # One line of a menu. With an `action` it is performed like a button's.
      # With a `link` it opens that screen with `with` in place of the first
      # screen, as choosing another account does. `selected` gives it a tick.
      def item(title, action: "", with: {}, link: "", image: "", role: "", selected: false)
        node = add("item")
        act(node, title, action, with, role)
        node.set("link", link)
        node.set("image", image)
        node.set("selected", "true") if selected
        node
      end

      # A swipe on the row that holds it. `edge` is "trailing" or "leading".
      def swipe(label, action:, with: {}, role: "", edge: "", image: "")
        node = add("swipe")
        act(node, label, action, with, role)
        node.set("edge", edge)
        node.set("image", image)
        node
      end

      # Controls in the navigation bar: buttons, and buttons that open a menu.
      def toolbar
        inside(add("toolbar")) { yield }
      end

      # A bar pinned under the screen, above the keyboard: a reply box.
      def bottom
        inside(add("bottom")) { yield }
      end

      # A box to type in. A button in the same container (the same `bottom`,
      # stack, section or row) sends what the box shows to `perform` under
      # `name`, and the box is emptied afterwards.
      def field(name, placeholder: "", value: "")
        node = add("field")
        node.id = name
        node.text = value.to_s
        node.set("placeholder", placeholder)
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

      # A string for the Swift view, by name.
      def prop(name, value)
        typed("prop", name, value.to_s)
      end

      # True or false for the Swift view, by name.
      def flag(name, on)
        typed("flag", name, on ? "true" : "false")
      end

      # A whole number for the Swift view, by name.
      def number(name, count)
        typed("number", name, count.to_s)
      end

      # A list for the Swift view, by name. The block holds its records.
      def props(name)
        node = add("props")
        node.id = name
        inside(node) { yield }
      end

      # One entry of a list: the block holds its props.
      def record
        inside(add("record")) { yield }
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

      def act(node, label, action, with, role)
        node.text = label.to_s
        node.action = action
        node.carry(with)
        node.set("role", role)
      end

      def typed(kind, name, value)
        node = add(kind)
        node.id = name
        node.text = value
        node
      end
    end
  end
end
