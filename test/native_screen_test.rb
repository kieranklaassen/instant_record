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
              row id: letter.id, link: "letter", with: { "id" => letter.id } do
                text letter.from, style: "headline"
                text letter.subject, lines: 2
                swipe "Archive", action: "archive", with: { "id" => letter.id }, role: "destructive"
              end
            end
          end
        end
      end
    end

    def perform(action, params)
      case action
      when "archive" then self.class.archived << params["id"]
      end
    end
  end

  class MenuScreen < InstantRecord::Native::Screen
    def body
      navigation title: "Letters" do
        list refreshable: true
        toolbar do
          button "Boxes", image: "person.crop.circle", position: "leading" do
            item "Inbox", link: "menu", with: { "box" => "inbox" }, image: "inbox", selected: param("box") == "inbox"
            item "Sent", link: "menu", with: { "box" => "sent" }, selected: param("box") == "sent"
            item "Empty", action: "empty", with: { "box" => param("box") }, role: "destructive"
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
        prop "archived", ""
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
    assert_equal %w[text text swipe], section.children.first.children.map(&:kind)
  end

  test "a row names its record, the screen it opens and that screen's argument" do
    row = rows(LettersScreen.new.render).first

    assert_equal "a1", row.id
    assert_equal ["letter", { "id" => "a1" }], [row.props["link"], row.params]
  end

  test "a swipe carries the action the host sends back" do
    swipe = rows(LettersScreen.new.render).first.children.last

    assert_equal ["Archive", "archive", { "id" => "a1" }, "destructive"], [swipe.text, swipe.action, swipe.params, swipe.props["role"]]
  end

  test "the tree is JSON a host can parse" do
    tree = JSON.parse(LettersScreen.new.json)

    row = tree.dig("children", 0, "children", 0, "children", 0, "children", 0)
    assert_equal "row", row["kind"]
    assert_equal "a1", row["id"]
    assert_equal({ "link" => "letter" }, row["props"])
    assert_equal({ "id" => "a1" }, row["params"])
    assert_equal({ "kind" => "text", "id" => "", "text" => "Rae", "action" => "", "params" => {}, "props" => { "style" => "headline" }, "children" => [] }, row["children"].first)
    assert_equal({ "lines" => "2" }, row["children"][1]["props"])
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
    menu, plain = toolbar(MenuScreen.new({ "box" => "inbox" }))

    assert_equal ["leading", "person.crop.circle"], [menu.props["position"], menu.props["image"]]
    assert_equal ["trailing", "compose"], [plain.props["position"], plain.action]
    assert_empty plain.children
  end

  test "a button with a block is a menu of items" do
    inbox, sent, empty = toolbar(MenuScreen.new({ "box" => "sent" })).first.children

    assert_equal %w[item item item], [inbox, sent, empty].map(&:kind)
    assert_equal ["Inbox", "menu", { "box" => "inbox" }, "inbox"], [inbox.text, inbox.props["link"], inbox.params, inbox.props["image"]]
    assert_equal ["empty", { "box" => "sent" }, "destructive"], [empty.action, empty.params, empty.props["role"]]
    assert_nil empty.props["link"]
  end

  test "only the chosen item is selected" do
    inbox, sent, empty = toolbar(MenuScreen.new({ "box" => "sent" })).first.children

    assert_equal [nil, "true", nil], [inbox, sent, empty].map { |item| item.props["selected"] }
    assert_equal({ "link" => "menu", "selected" => "true" }, JSON.parse(MenuScreen.new({ "box" => "sent" }).json).dig("children", 0, "children", 1, "children", 0, "children", 1, "props"))
  end

  test "a list can ask to be refreshed by a pull, and does not by default" do
    assert_equal "true", MenuScreen.new.render.children.first.children.first.props["refresh"]
    assert_nil EmptyScreen.new.render.children.first.props["refresh"]
  end

  test "a screen can be one Swift view, named, with its props" do
    view = SwiftScreen.new.render.children.sole

    assert_equal ["swift", "LetterView"], [view.kind, view.text]
    assert_equal [%w[prop subject], %w[prop archived], %w[props replies], %w[props nobody]], view.children.map { |node| [node.kind, node.id] }
    assert_equal ["Night \"shift\"", ""], view.children.first(2).map(&:text)
  end

  test "a list of props holds records, and a record can hold a list" do
    replies, nobody = SwiftScreen.new.render.children.sole.children.last(2)

    assert_equal %w[record record], replies.children.map(&:kind)
    assert_equal [%w[from Rae], %w[tags]], replies.children.first.children.map { |node| [node.id, node.text].reject(&:empty?) }
    assert_equal "b2", replies.children.last.children.last.children.sole.children.sole.text
    assert_empty nobody.children
  end

  test "the props reach the host as JSON it can read by name" do
    view = JSON.parse(SwiftScreen.new.json).dig("children", 0)

    assert_equal({ "kind" => "prop", "id" => "subject", "text" => "Night \"shift\"", "action" => "", "params" => {}, "props" => {}, "children" => [] }, view["children"].first)
    assert_equal %w[Rae Sam], view["children"][2]["children"].map { |record| record["children"].first["text"] }
  end

  test "a Swift view sits among stock elements, with or without props" do
    banner, row, footer = PartialScreen.new.render.children.sole.children

    assert_equal %w[swift row swift], [banner, row, footer].map(&:kind)
    assert_equal ["Banner", "count", "2"], [banner.text, banner.children.sole.id, banner.children.sole.text]
    assert_equal ["Footer", []], [footer.text, footer.children]
  end

  class FormScreen < InstantRecord::Native::Screen
    def body
      navigation title: nil do
        stack "horizontal" do
          text nil
          spacer
          text 7, lines: 1
        end
        swift "Card" do
          prop "nothing", nil
          flag "archived", param("archived") == "yes"
          flag "empty", false
          number "unread", 3
        end
        bottom do
          field "body", placeholder: "Reply", value: param("draft")
          button "Send", action: "reply", with: { "id" => "a/1\nb" }
        end
      end
    end
  end

  test "a value with a slash, a newline or a quote is carried as it is" do
    send = FormScreen.new.render.children.sole.children.last.children.last

    assert_equal({ "id" => "a/1\nb" }, send.params)
    assert_equal({ "id" => "a/1\nb" }, JSON.parse(FormScreen.new.json).dig("children", 0, "children", 2, "children", 1, "params"))
  end

  test "nothing, or a number, given as text is written as text" do
    blank, spacer, seven = FormScreen.new.render.children.sole.children.first.children

    assert_equal ["", "spacer", "7", "1"], [blank.text, spacer.kind, seven.text, seven.props["lines"]]
    assert_nil FormScreen.new.render.children.sole.props["title"]
    assert_nothing_raised { JSON.parse(FormScreen.new.json) }
  end

  test "a Swift view is handed flags and numbers as well as strings" do
    nothing, archived, empty, unread = FormScreen.new({ "archived" => "yes" }).render.children.sole.children[1].children

    assert_equal [["prop", "nothing", ""], ["flag", "archived", "true"], ["flag", "empty", "false"], ["number", "unread", "3"]],
      [nothing, archived, empty, unread].map { |node| [node.kind, node.id, node.text] }
    assert_equal "false", FormScreen.new.render.children.sole.children[1].children[1].text
  end

  test "a field has a name, a placeholder and what it starts with, in a bar under the screen" do
    bar = FormScreen.new({ "draft" => "Hello" }).render.children.sole.children.last
    field = bar.children.first

    assert_equal "bottom", bar.kind
    assert_equal ["field", "body", "Hello", "Reply"], [field.kind, field.id, field.text, field.props["placeholder"]]
    assert_equal "", FormScreen.new.render.children.sole.children.last.children.first.text
  end

  test "a param the screen was not opened with reads as empty" do
    assert_equal ["x", ""], [FormScreen.new({ "draft" => "x" }).param("draft"), FormScreen.new.param("draft")]
  end

  test "an action changes what the next render shows" do
    LettersScreen.new.perform("archive", { "id" => "a1" })

    assert_equal %w[b2], rows(LettersScreen.new.render).map(&:id)
  end

  test "an action the screen does not know does nothing" do
    assert_nothing_raised { LettersScreen.new.perform("shred", { "id" => "a1" }) }
    assert_nothing_raised { EmptyScreen.new.perform("archive", { "id" => "a1" }) }
    assert_equal 2, rows(LettersScreen.new.render).size
  end

  test "a screen is found by the name its class gives it" do
    screen = InstantRecord::Native.screen("letters", { "box" => "x" })

    assert_instance_of LettersScreen, screen
    assert_equal ["x", ""], [screen.param("box"), screen.param("missing")]
    assert_raises(ArgumentError) { InstantRecord::Native.screen("nowhere") }
  end

  private

  def toolbar(screen)
    screen.render.children.first.children.last.children
  end

  def rows(root)
    root.children.first.children.first.children.first.children
  end
end
