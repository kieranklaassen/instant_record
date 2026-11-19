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
              row id: letter.id, link: "letter", arg: letter.id do
                text letter.from, style: "headline"
                text letter.subject
                swipe "Archive", action: "archive", arg: letter.id, role: "destructive"
              end
            end
          end
        end
      end
    end

    def perform(action, arg)
      case action
      when "archive" then self.class.archived << arg
      end
    end
  end

  class MenuScreen < InstantRecord::Native::Screen
    def body
      navigation title: "Letters" do
        list refreshable: true
        toolbar do
          button "Boxes", image: "person.crop.circle", position: "leading" do
            item "Inbox", link: "menu", arg: "inbox", image: "tray", selected: arg == "inbox"
            item "Sent", link: "menu", arg: "sent", selected: arg == "sent"
            item "Empty", action: "empty", arg: arg, role: "destructive"
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
    assert_equal ["letter", "a1"], [row.props["link"], row.arg]
  end

  test "a swipe carries the action the host sends back" do
    swipe = rows(LettersScreen.new.render).first.children.last

    assert_equal ["Archive", "archive", "a1", "destructive"], [swipe.text, swipe.action, swipe.arg, swipe.props["role"]]
  end

  test "the tree is JSON a host can parse" do
    tree = JSON.parse(LettersScreen.new.json)

    row = tree.dig("children", 0, "children", 0, "children", 0, "children", 0)
    assert_equal "row", row["kind"]
    assert_equal "a1", row["id"]
    assert_equal({ "link" => "letter" }, row["props"])
    assert_equal "a1", row["arg"]
    assert_equal({ "kind" => "text", "id" => "", "text" => "Rae", "action" => "", "arg" => "", "props" => { "style" => "headline" }, "children" => [] }, row["children"].first)
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
    menu, plain = toolbar(MenuScreen.new("inbox"))

    assert_equal ["leading", "person.crop.circle"], [menu.props["position"], menu.props["image"]]
    assert_equal ["trailing", "compose"], [plain.props["position"], plain.action]
    assert_empty plain.children
  end

  test "a button with a block is a menu of items" do
    inbox, sent, empty = toolbar(MenuScreen.new("sent")).first.children

    assert_equal %w[item item item], [inbox, sent, empty].map(&:kind)
    assert_equal ["Inbox", "menu", "inbox", "tray"], [inbox.text, inbox.props["link"], inbox.arg, inbox.props["image"]]
    assert_equal ["empty", "sent", "destructive"], [empty.action, empty.arg, empty.props["role"]]
    assert_nil empty.props["link"]
  end

  test "only the chosen item is selected" do
    inbox, sent, empty = toolbar(MenuScreen.new("sent")).first.children

    assert_equal [nil, "true", nil], [inbox, sent, empty].map { |item| item.props["selected"] }
    assert_equal({ "link" => "menu", "selected" => "true" }, JSON.parse(MenuScreen.new("sent").json).dig("children", 0, "children", 1, "children", 0, "children", 1, "props"))
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

    assert_equal({ "kind" => "prop", "id" => "subject", "text" => "Night \"shift\"", "action" => "", "arg" => "", "props" => {}, "children" => [] }, view["children"].first)
    assert_equal %w[Rae Sam], view["children"][2]["children"].map { |record| record["children"].first["text"] }
  end

  test "a Swift view sits among stock elements, with or without props" do
    banner, row, footer = PartialScreen.new.render.children.sole.children

    assert_equal %w[swift row swift], [banner, row, footer].map(&:kind)
    assert_equal ["Banner", "count", "2"], [banner.text, banner.children.sole.id, banner.children.sole.text]
    assert_equal ["Footer", []], [footer.text, footer.children]
  end

  test "an action changes what the next render shows" do
    LettersScreen.new.perform("archive", "a1")

    assert_equal %w[b2], rows(LettersScreen.new.render).map(&:id)
  end

  test "an action the screen does not know does nothing" do
    assert_nothing_raised { LettersScreen.new.perform("shred", "a1") }
    assert_nothing_raised { EmptyScreen.new.perform("archive", "a1") }
    assert_equal 2, rows(LettersScreen.new.render).size
  end

  test "a screen is found by the name its class gives it" do
    screen = InstantRecord::Native.screen("letters", "x")

    assert_instance_of LettersScreen, screen
    assert_equal "x", screen.arg
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
