require "test_helper"
require "instant_record/compiler"
require "tmpdir"

class NativeContractTest < ActiveSupport::TestCase
  class TypedCardScreen < InstantRecord::Native::Screen
    contract "OrderCard" do |c|
      c.string :title
      c.int :item_count
      c.float :total
      c.bool :paid
      c.date :placed_at
      c.string :note, optional: true
      c.one :customer do |customer|
        customer.string :name
        customer.bool :vip
      end
      c.many :lines do |line|
        line.string :sku
        line.int :qty
      end
      c.many :tags, of: :string
      c.action :refund do |a|
        a.arg :order_id, :string
        a.value :reason, :string, optional: true
      end
    end

    def body
      component "OrderCard" do
        prop "title", "Order #42"
        number "item_count", 2
        decimal "total", 19.5
        flag "paid", true
        time "placed_at", "2026-11-21T10:00:00.000000Z"
        prop "note", param("note").empty? ? nil : param("note")
        record "customer" do
          prop "name", "Rae"
          flag "vip", true
        end
        props "lines" do
          record do
            prop "sku", "A1"
            number "qty", 2
          end
        end
        props "tags" do
          prop "", "priority"
          prop "", "express"
        end
      end
    end
  end

  class MissingPropScreen < InstantRecord::Native::Screen
    contract "Summary" do |c|
      c.string :title
      c.int :count
    end

    def body
      swift "Summary" do
        prop "title", "Hello"
      end
    end
  end

  class WrongTypeScreen < InstantRecord::Native::Screen
    contract "Summary" do |c|
      c.int :count
    end

    def body
      swift "Summary" do
        prop "count", "3"
      end
    end
  end

  class UndeclaredPropScreen < InstantRecord::Native::Screen
    contract "Summary" do |c|
      c.string :title
    end

    def body
      swift "Summary" do
        prop "title", "Hi"
        prop "extra", "oops"
      end
    end
  end

  class NestedMismatchScreen < InstantRecord::Native::Screen
    contract "Thread" do |c|
      c.many :messages do |m|
        m.string :author
        m.bool :mine
      end
    end

    def body
      swift "Thread" do
        props "messages" do
          record do
            prop "author", "Rae"
            prop "mine", "true"
          end
        end
      end
    end
  end

  class FallbackScreen < InstantRecord::Native::Screen
    contract "Detail" do |c|
      c.string :title
    end

    def body
      if param("missing") == "1"
        text "Not found"
      else
        swift("Detail") { prop "title", "Found" }
      end
    end
  end

  test "a screen with a full typed contract renders monomorphic nodes and passes validation" do
    root = TypedCardScreen.new.render
    card = root.children.sole

    assert_equal ["swift", "OrderCard"], [card.kind, card.text]
    props_by_name = card.children.select { |n| n.kind == "prop" }.to_h { |n| [n.props["name"], [n.props["type"], n.text]] }
    assert_equal({
      "title" => ["string", "Order #42"],
      "item_count" => ["int", "2"],
      "total" => ["float", "19.5"],
      "paid" => ["bool", "true"],
      "placed_at" => ["date", "2026-11-21T10:00:00.000000Z"]
    }, props_by_name)

    customer = card.children.find { |n| n.kind == "record" }
    assert_equal "customer", customer.props["name"]
    assert_equal %w[name vip], customer.children.map { |n| n.props["name"] }

    tags = card.children.find { |n| n.kind == "props" && n.props["name"] == "tags" }
    assert_equal %w[priority express], tags.children.map(&:text)
    assert_equal %w[string string], tags.children.map { |n| n.props["type"] }

    with_note = TypedCardScreen.new("note" => "Leave at door").render.children.sole
    assert_equal "Leave at door", with_note.children.find { |n| n.props["name"] == "note" }.text
  end

  test "nil values on prop helpers omit the node rather than emitting nil text" do
    screen = Class.new(InstantRecord::Native::Screen) do
      def body
        swift "Nullables" do
          prop "a", nil
          flag "b", nil
          number "c", nil
          decimal "d", nil
          time "e", nil
          prop "kept", ""
          flag "off", false
        end
      end
    end

    view = screen.new.render.children.sole
    assert_equal [%w[kept], %w[off]], view.children.map { |n| [n.props["name"]] }
    assert_equal ["", "false"], view.children.map(&:text)
  end

  test "contract validation catches missing props, wrong types, undeclared props, and nested errors" do
    err = assert_raises(InstantRecord::Native::ContractError) { MissingPropScreen.new.render }
    assert_match(/Summary.*missing required prop "count"/, err.message)

    err = assert_raises(InstantRecord::Native::ContractError) { WrongTypeScreen.new.render }
    assert_match(/Summary\.count.*expected type "int", got "string"/, err.message)

    err = assert_raises(InstantRecord::Native::ContractError) { UndeclaredPropScreen.new.render }
    assert_match(/Summary.*undeclared prop "extra"/, err.message)

    err = assert_raises(InstantRecord::Native::ContractError) { NestedMismatchScreen.new.render }
    assert_match(/Thread\.messages\[0\]\.mine.*expected type "bool", got "string"/, err.message)
  end

  test "a screen that renders a fallback instead of its declared component passes validation" do
    assert_equal "text", FallbackScreen.new("missing" => "1").render.children.sole.kind
    assert_equal "swift", FallbackScreen.new.render.children.sole.kind
  end

  test "GemVendor strips contract blocks from staged app/screens while preserving line numbers" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app, "app/screens"))
      source = <<~RUBY
        class DemoScreen < InstantRecord::Native::Screen
          contract "DemoView" do |c|
            c.string :title
            c.action :tap do |a|
              a.arg :id, :string
            end
          end

          def body
            swift("DemoView") { prop "title", "Hi" }
          end
        end
      RUBY
      File.write(File.join(app, "app/screens/demo_screen.rb"), source)

      InstantRecord::Compiler::GemVendor.vendor(gem_src: File.expand_path("..", __dir__), app_dir: app, demo: false)

      staged = File.read(File.join(app, "app/screens/demo_screen.rb"))
      refute_includes staged, "contract"
      assert_equal source.lines.count, staged.lines.count, "line numbers must stay aligned for Spinel #line diagnostics"
      assert_equal source.lines.index("  def body\n"), staged.lines.index("  def body\n")
    end
  end
end
