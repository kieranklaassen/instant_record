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

  def rows(root)
    root.children.first.children.first.children.first.children
  end
end
