require "test_helper"

class NativeScreenTest < ActiveSupport::TestCase
  Letter = Struct.new(:id, :from, :subject)

  class LettersScreen < InstantRecord::Native::Screen
    LETTERS = [Letter.new("a1", "Rae", "Night shift"), Letter.new("b2", "Sam", "October invoice")]

    def letters = LETTERS.reject { |letter| self.class.archived.include?(letter.id) }

    def self.archived = (@archived ||= [])

    def body
      navigation title: "Letters" do
        list do
          section "Open" do
            letters.each do |letter|
              row id: letter.id, link: "letter", params: { "id" => letter.id } do
                stack "horizontal" do
                  text letter.from, style: "headline", lines: 1
                  spacer
                end
                text letter.subject
                swipe "Archive", action: "archive", args: { "id" => letter.id }, role: "destructive"
              end
            end
          end
        end
      end
    end

    def perform(action, args, values)
      case action
      when "archive" then self.class.archived << args["id"]
      when "rename" then self.class.archived << values["id"]
      end
    end
  end

  class MenuScreen < InstantRecord::Native::Screen
    def body
      navigation title: "Letters" do
        list refreshable: true
        toolbar do
          button "Boxes", image: "person.crop.circle", position: "leading" do
            item "Inbox", link: "menu", params: { "box" => "inbox" }, image: "tray", selected: param("box") == "inbox"
            item "Sent", replace: "menu", params: { "box" => "sent" }, selected: param("box") == "sent"
            item "Empty", action: "empty", args: { "box" => param("box") }, role: "destructive"
          end
          button "New", action: "compose", position: "trailing"
        end
      end
    end
  end

  class SwiftScreen < InstantRecord::Native::Screen
    def body
      swift "LetterView" do
        prop "subject", "Night \"shift\""
        flag "archived", false
        number "unread", 3
        time "sent", "2026-11-19T06:00:00.000000Z"
        props "replies" do
          LettersScreen::LETTERS.each do |letter|
            record do
              prop "from", letter.from
              props("tags") { record { prop "name", letter.id } }
            end
          end
        end
        props("nobody") { }
      end
    end
  end

  class PartialScreen < InstantRecord::Native::Screen
    def body
      list do
        swift("Banner") { prop "count", "2" }
        row(id: "a1") { text "Rae" }
        swift "Footer"
      end
    end
  end

  class BothScreen < InstantRecord::Native::Screen
    def body
      toolbar { button("Boxes") { item "Inbox", link: "menu", replace: "menu" } }
    end
  end

  class ReplyScreen < InstantRecord::Native::Screen
    def body
      bottom do
        field "body", label: "Reply", value: param("draft"), multiline: true
        button "Send", action: "reply"
      end
      more "older:letters", query: "type=Letter&before_id=a1" if param("older") == "yes"
    end
  end

  class EmptyScreen < InstantRecord::Native::Screen
    def body
      list
    end
  end

  class QuotedScreen < InstantRecord::Native::Screen
    def body
      text "She said \"hi\"\n\tthen left \\ café ☕ \u0001"
    end
  end

  setup { LettersScreen.archived.clear }

  test "a screen returns its nodes nested in the order the body wrote them" do
    root = LettersScreen.new.render

    assert_equal "screen", root.kind
    navigation = root.children.first
    assert_equal ["navigation", "Letters"], [navigation.kind, navigation.props["title"]]
    section = navigation.children.first.children.first
    assert_equal ["section", "Open"], [section.kind, section.text]
    assert_equal %w[a1 b2], section.children.map(&:id)
    assert_equal %w[stack text swipe], section.children.first.children.map(&:kind)
  end

  test "a row names its record, the screen it opens and that screen's params" do
    row = rows(LettersScreen.new.render).first

    assert_equal "a1", row.id
    assert_equal ["letter", { "id" => "a1" }], [row.props["link"], row.link_params]
    assert_equal ["", {}], [row.action, row.args]
  end

  test "a swipe carries the action the host sends back" do
    swipe = rows(LettersScreen.new.render).first.children.last

    assert_equal ["Archive", "archive", { "id" => "a1" }, "destructive"], [swipe.text, swipe.action, swipe.args, swipe.props["role"]]
  end

  test "the tree is JSON a host can parse" do
    tree = JSON.parse(LettersScreen.new.json)

    row = tree.dig("children", 0, "children", 0, "children", 0, "children", 0)
    assert_equal "row", row["kind"]
    assert_equal "a1", row["id"]
    assert_equal({ "link" => "letter" }, row["props"])
    assert_equal({ "id" => "a1" }, row["params"])
    assert_equal({}, row["args"])
    assert_equal({ "id" => "a1" }, row["children"].last["args"])
    assert_equal({ "kind" => "text", "id" => "", "text" => "Night shift", "action" => "", "params" => {}, "args" => {}, "props" => {}, "children" => [] }, row["children"][1])
  end

  test "quotes, newlines, control characters and non-ASCII text survive" do
    text = JSON.parse(QuotedScreen.new.json).dig("children", 0, "text")

    assert_equal "She said \"hi\"\n\tthen left \\ café ☕ \u0001", text
  end

  test "a list with nothing in it is still a list" do
    list = EmptyScreen.new.render.children.first

    assert_equal "list", list.kind
    assert_empty list.children
  end

  test "a toolbar button says which side of the bar it sits on" do
    menu, plain = toolbar(MenuScreen.new("box" => "inbox"))

    assert_equal ["leading", "person.crop.circle"], [menu.props["position"], menu.props["image"]]
    assert_equal ["trailing", "compose"], [plain.props["position"], plain.action]
    assert_empty plain.children
  end

  test "a button with a block is a menu of items" do
    inbox, sent, empty = toolbar(MenuScreen.new("box" => "sent")).first.children

    assert_equal %w[item item item], [inbox, sent, empty].map(&:kind)
    assert_equal ["Inbox", "menu", { "box" => "inbox" }, "tray"], [inbox.text, inbox.props["link"], inbox.link_params, inbox.props["image"]]
    assert_equal ["empty", { "box" => "sent" }, "destructive"], [empty.action, empty.args, empty.props["role"]]
    assert_nil empty.props["link"]
  end

  test "only the chosen item is selected" do
    inbox, sent, empty = toolbar(MenuScreen.new("box" => "sent")).first.children

    assert_equal [nil, "true", nil], [inbox, sent, empty].map { |item| item.props["selected"] }
    assert_equal({ "replace" => "menu", "selected" => "true" }, JSON.parse(MenuScreen.new("box" => "sent").json).dig("children", 0, "children", 1, "children", 0, "children", 1, "props"))
  end

  test "a list can ask to be refreshed by a pull, and does not by default" do
    assert_equal "true", MenuScreen.new.render.children.first.children.first.props["refresh"]
    assert_nil EmptyScreen.new.render.children.first.props["refresh"]
  end

  test "a screen can be one Swift view, named, with its props" do
    view = SwiftScreen.new.render.children.sole

    assert_equal ["swift", "LetterView"], [view.kind, view.text]
    assert_equal [%w[prop subject], %w[prop archived], %w[prop unread], %w[prop sent], %w[props replies], %w[props nobody]], view.children.map { |node| [node.kind, node.props["name"]] }
    assert_equal ["Night \"shift\"", "false", "3", "2026-11-19T06:00:00.000000Z"], view.children.first(4).map(&:text)
  end

  test "a prop says what type it is, so the host need not guess" do
    view = SwiftScreen.new.render.children.sole

    assert_equal %w[string bool int date], view.children.first(4).map { |node| node.props["type"] }
    assert_equal "true", flagged(true).text
    assert_empty view.children.first.id
  end

  test "a list of props holds records, and a record can hold a list" do
    replies, nobody = SwiftScreen.new.render.children.sole.children.last(2)

    assert_equal %w[record record], replies.children.map(&:kind)
    assert_equal [%w[from Rae], %w[tags]], replies.children.first.children.map { |node| [node.props["name"], node.text].reject(&:empty?) }
    assert_equal "b2", replies.children.last.children.last.children.sole.children.sole.text
    assert_empty nobody.children
  end

  test "the props reach the host as JSON it can read by name" do
    view = JSON.parse(SwiftScreen.new.json).dig("children", 0)

    assert_equal({ "kind" => "prop", "id" => "", "text" => "Night \"shift\"", "action" => "", "params" => {}, "args" => {}, "props" => { "name" => "subject", "type" => "string" }, "children" => [] }, view["children"].first)
    assert_equal %w[Rae Sam], view["children"][4]["children"].map { |record| record["children"].first["text"] }
  end

  test "a Swift view sits among stock elements, with or without props" do
    banner, row, footer = PartialScreen.new.render.children.sole.children

    assert_equal %w[swift row swift], [banner, row, footer].map(&:kind)
    assert_equal ["Banner", "count", "2"], [banner.text, banner.children.sole.props["name"], banner.children.sole.text]
    assert_equal ["Footer", []], [footer.text, footer.children]
  end

  test "an action changes what the next render shows" do
    LettersScreen.new.perform("archive", { "id" => "a1" }, {})

    assert_equal %w[b2], rows(LettersScreen.new.render).map(&:id)
  end

  test "a stack holds a spacer where room is wanted, and text says how many lines it may take" do
    name, room = rows(LettersScreen.new.render).first.children.first.children

    assert_equal ["text", "1", "spacer"], [name.kind, name.props["lines"], room.kind]
    assert_nil rows(LettersScreen.new.render).first.children[1].props["lines"]
  end

  test "a menu item opens a screen over this one or in place of the first, and may not ask for both" do
    inbox, sent = MenuScreen.new.render.children.first.children.last.children.first.children

    assert_equal ["menu", nil], inbox.props.values_at("link", "replace")
    assert_equal [nil, "menu"], sent.props.values_at("link", "replace")
    error = assert_raises(ArgumentError) { BothScreen.new.render }
    assert_match "link: or replace:", error.message
  end

  test "a bar under the screen holds a field by name and the button that sends it" do
    bar = ReplyScreen.new.render.children.sole
    field, send = bar.children

    assert_equal ["bottom", "field", "button"], [bar.kind, field.kind, send.kind]
    assert_equal({ "name" => "body", "label" => "Reply", "multiline" => "true" }, field.props)
    assert_equal ["", "reply"], [field.text, send.action]
    assert_equal "kept", ReplyScreen.new("draft" => "kept").render.children.sole.children.first.text
  end

  test "a list that goes on at the server says what to ask for and the key the answer is kept under" do
    more = ReplyScreen.new("older" => "yes").render.children.last

    assert_equal ["more", "older:letters", "type=Letter&before_id=a1"], [more.kind, more.id, more.props["query"]]
  end

  test "a form's values reach the action beside its args" do
    LettersScreen.new.perform("rename", {}, { "id" => "b2" })

    assert_equal %w[a1], rows(LettersScreen.new.render).map(&:id)
  end

  test "a param holds whatever characters it was given, and one not given is empty" do
    odd = "a\nb/c \"q\" ☕"
    screen = LettersScreen.new("box" => odd)

    assert_equal [odd, ""], [screen.param("box"), screen.param("missing")]
  end

  test "params and args cross to the host as objects, whatever they hold" do
    odd = "a\nb/c \"q\""
    item = JSON.parse(MenuScreen.new("box" => odd).json).dig("children", 0, "children", 1, "children", 0, "children", 2)

    assert_equal({ "box" => odd }, item["args"])
  end

  test "what a host sends becomes strings by name" do
    strings = InstantRecord::Native::Screen.strings(JSON.parse('{"id":"a1","count":3,"gone":null}'))

    assert_equal({ "id" => "a1", "count" => "3", "gone" => "" }, strings)
    assert_equal({}, InstantRecord::Native::Screen.strings(nil))
    assert_equal({}, InstantRecord::Native::Screen.strings("maya/support"))
  end

  test "an action the screen does not know does nothing" do
    assert_nothing_raised { LettersScreen.new.perform("shred", { "id" => "a1" }, {}) }
    assert_nothing_raised { EmptyScreen.new.perform("archive", { "id" => "a1" }, {}) }
    assert_equal 2, rows(LettersScreen.new.render).size
  end

  test "a screen is found by the name its class gives it" do
    screen = InstantRecord::Native.screen("letters", { "box" => "x" })

    assert_instance_of LettersScreen, screen
    assert_equal "x", screen.param("box")
    assert_raises(ArgumentError) { InstantRecord::Native.screen("nowhere") }
  end

  test "a screen's file names its class, and the class names it back" do
    assert_equal "TwoWordsScreen", InstantRecord::Native.class_name("two_words")
    assert_equal "letters", InstantRecord::Native.screen_name(LettersScreen)
    %w[mailbox two_words inbox2 a1_b].each do |name|
      assert_equal name, InstantRecord::Native.underscore(InstantRecord::Native.class_name(name).delete_suffix("Screen"))
    end
  end

  test "a file name the rule cannot turn back is refused, with the rule" do
    %w[a_1 Two two__words _x 1st two-words].each do |name|
      error = assert_raises(ArgumentError) { InstantRecord::Native.class_name(name) }
      assert_match "<name>_screen.rb", error.message
    end
  end

  test "the client forgets what it held in memory about a database that was closed" do
    client = InstantRecord::Client
    client.note_change("Letter", "a1")
    client.unlisted_changes

    client.forget_database

    assert_empty client.changed_records
    client.note_change("Letter", "b2")
    assert_equal "records_changed\nLetter:b2", client.changes_notice
  ensure
    client.forget_database
  end

  private

  def flagged(value)
    screen = Class.new(InstantRecord::Native::Screen) { define_method(:body) { flag "on", value } }
    screen.new.render.children.sole
  end

  def toolbar(screen)
    screen.render.children.first.children.last.children
  end

  def rows(root)
    root.children.first.children.first.children.first.children
  end
end
