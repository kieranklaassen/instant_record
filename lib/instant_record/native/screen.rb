module InstantRecord
  module Native
    # A screen of a native app, written in Ruby.
    #
    #   class MailboxScreen < InstantRecord::Native::Screen
    #     def body
    #       navigation title: "Support" do
    #         list do
    #           MailEntry.open_messages.each do |entry|
    #             row id: entry.id, link: "thread", arg: entry.id do
    #               text entry.author, style: "headline"
    #               text entry.subject
    #               swipe "Archive", action: "archive", arg: entry.id, role: "destructive"
    #             end
    #           end
    #         end
    #       end
    #     end
    #
    #     def perform(action, arg)
    #       case action
    #       when "archive" then archive(arg)
    #       end
    #     end
    #   end
    #
    # `body` describes the screen with the words iOS draws. The app's renderer
    # turns the description into native views and knows nothing else about the
    # app. A tap comes back as `perform` with the action and argument the
    # element named, and the screen is rendered again afterwards.
    #
    # Keep to plain Ruby here: blocks, `yield` and `case`. The phone runs this
    # file through an ahead-of-time compiler with no `method_missing`, no
    # `instance_eval` and no `send` to a computed name.
    class Screen
      attr_reader :arg

      # `arg` is what the element that opened this screen passed along, most
      # often a record's id.
      def initialize(arg = "")
        @arg = arg
        @open = []
      end

      def body
      end

      def perform(action, arg)
      end

      def render
        root = Node.new("screen")
        @open = [root]
        body
        root
      end

      def to_json
        render.to_json
      end

      # A navigation bar with a title over whatever the block holds.
      def navigation(title: "")
        node = add("navigation")
        node.set("title", title)
        inside(node) { yield }
      end

      def list
        node = add("list")
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
      # opens and `arg` is handed to that screen. A row with an `action` has it
      # performed with the same `arg` before the screen opens.
      def row(id: "", link: "", arg: "", action: "")
        node = add("row")
        node.id = id
        node.action = action
        node.arg = arg
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

      def button(label, action:, arg: "", role: "", image: "")
        node = add("button")
        act(node, label, action, arg, role)
        node.set("image", image)
        node
      end

      # A swipe on the row that holds it. `edge` is "trailing" or "leading".
      def swipe(label, action:, arg: "", role: "", edge: "", image: "")
        node = add("swipe")
        act(node, label, action, arg, role)
        node.set("edge", edge)
        node.set("image", image)
        node
      end

      # Controls in the navigation bar.
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

      def act(node, label, action, arg, role)
        node.text = label
        node.action = action
        node.arg = arg
        node.set("role", role)
      end
    end
  end
end
