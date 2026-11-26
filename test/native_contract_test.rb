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

  test "a prop must be declared, scalar and of the declared type, checked in that order" do
    contract = contract_of(scalar("title"), one("author"), many("lines"), many_scalar("tags"))

    assert_contract_error 'View: undeclared prop "extra"', contract, prop("extra", "nope")
    assert_contract_error "View.author: expected one but emitted scalar prop", contract, prop("author", "nope")
    assert_contract_error "View.lines: expected many but emitted scalar prop", contract, prop("lines")
    assert_contract_error "View.tags: expected many_scalar but emitted scalar prop", contract, prop("tags")
    assert_contract_error 'View.title: expected type "string", got "int"', contract, prop("title", "int")
  end

  test "a nested record must be declared and a one field, and its own fields are checked" do
    contract = contract_of(one("author", scalar("name")), scalar("title"), many("lines"), many_scalar("tags"))

    assert_contract_error 'View: undeclared nested record "extra"', contract, record("extra", prop("bad"))
    assert_contract_error "View.title: expected scalar but emitted nested record", contract, record("title", prop("bad"))
    assert_contract_error "View.lines: expected many but emitted nested record", contract, record("lines")
    assert_contract_error "View.tags: expected many_scalar but emitted nested record", contract, record("tags")
    assert_contract_error 'View.author: undeclared prop "bad"', contract, record("author", prop("bad"))
    assert_contract_error 'View.author: missing required prop "name" (string)', contract, record("author")
  end

  test "a list must be declared and a many field, and each item is checked with its index" do
    contract = contract_of(many("lines", scalar("sku")), many_scalar("tags"), scalar("title"), one("author"))
    line = record("", prop("sku"))

    assert_contract_error 'View: undeclared list prop "extra"', contract, list("extra", prop("bad"))
    assert_contract_error "View.title: expected scalar but emitted list", contract, list("title", prop("bad"))
    assert_contract_error "View.author: expected one but emitted list", contract, list("author")
    assert_contract_error 'View.lines[1]: expected record item, got "prop"', contract, list("lines", line, prop("sku"))
    assert_contract_error 'View.lines[1].sku: expected type "string", got "int"', contract,
      list("lines", line, record("", prop("sku", "int")))
    assert_contract_error 'View.lines[1]: missing required prop "sku" (string)', contract, list("lines", line, record(""))
    assert_contract_error 'View.tags[1]: expected scalar prop item, got "record"', contract, list("tags", prop(""), line)
    assert_contract_error 'View.tags[1]: expected type "string", got "bool"', contract, list("tags", prop(""), prop("", "bool"))
  end

  test "a child of any other kind is an error, at the top and nested" do
    contract = contract_of(one("author"), many("lines"), many_scalar("tags"))

    assert_contract_error 'View: unexpected child node kind "text"', contract, node("text")
    assert_contract_error "View: unexpected child node kind :prop", contract, node(:prop)
    assert_contract_error "View: unexpected child node kind nil", contract, node(nil)
    assert_contract_error 'View.author: unexpected child node kind "swift"', contract, record("author", node("swift"))
    assert_contract_error "View.lines[0]: expected record item, got :record", contract, list("lines", node(:record))
    assert_contract_error "View.tags[0]: expected scalar prop item, got nil", contract, list("tags", node(nil))
    assert_contract_error "View.tags[0]: expected scalar prop item, got :prop", contract, list("tags", node(:prop))
  end

  test "the first missing required field is named with its type or kind, optional ones may be absent" do
    assert_contract_error 'View: missing required prop "count" (int)',
      contract_of(scalar("note", optional: true), scalar("count", type: "int"), one("author"))
    assert_contract_error 'View: missing required prop "author" (one)', contract_of(one("author"))
    assert_contract_error 'View: missing required prop "lines" (many)', contract_of(many("lines"))
    assert_contract_error 'View: missing required prop "tags" (many_scalar)', contract_of(many_scalar("tags"))

    optional = contract_of(scalar("note", optional: true), one("author", scalar("name"), optional: true),
      many("lines", optional: true), many_scalar("tags", optional: true))
    assert_valid optional
    assert_contract_error 'View.author: missing required prop "name" (string)', optional, record("author")
  end

  test "the first wrong child wins over later ones and over missing fields" do
    contract = contract_of(scalar("title"), one("author", scalar("name")), many_scalar("tags"))

    assert_contract_error 'View.title: expected type "string", got "int"', contract, prop("title", "int"), node("text")
    assert_contract_error 'View: unexpected child node kind "text"', contract, node("text"), prop("title", "int")
    assert_contract_error 'View.author: missing required prop "name" (string)', contract, record("author"), prop("extra")
    assert_contract_error 'View.tags[0]: expected type "string", got "int"', contract,
      list("tags", prop("", "int"), node("text")), prop("extra")
  end

  test "node names and types are compared as strings, and missing ones as empty strings" do
    contract = contract_of(scalar("title"), one("author"), many("lines"), many_scalar("tags"))

    assert_valid contract, prop(:title, :string), record(:author), list(:lines), list(:tags, prop(nil, :string))
    assert_contract_error 'View: undeclared prop ""', contract, prop(nil)
    assert_contract_error 'View: undeclared nested record ""', contract, record(nil)
    assert_contract_error 'View: undeclared list prop ""', contract, list(nil)
    assert_contract_error 'View.title: expected type "string", got ""', contract, prop("title", nil)
    assert_contract_error 'View.tags[0]: expected type "string", got ""', contract, list("tags", prop("", nil))
  end

  test "several children may share a name and every one is checked" do
    contract = contract_of(scalar("title"), many_scalar("tags"))

    assert_valid contract, prop("title"), prop("title"), list("tags"), list("tags", prop(""))
    assert_contract_error 'View.title: expected type "string", got "int"', contract,
      prop("title"), list("tags"), prop("title", "int")
  end

  test "of two fields with one name the last is used, and one child satisfies both" do
    contract = contract_of(scalar("title"), scalar("title", type: "int"))

    assert_valid contract, prop("title", "int")
    assert_contract_error 'View.title: expected type "int", got "string"', contract, prop("title")
    assert_contract_error 'View: missing required prop "title" (string)', contract
  end

  test "errors deep in the tree carry the whole path" do
    contract = contract_of(one("page", many("rows", one("cell", many_scalar("tags", type: "int")))))
    tree = ->(*tags) { record("page", list("rows", record("", record("cell", list("tags", *tags))))) }

    assert_valid contract, tree.call(prop("", "int"))
    assert_contract_error 'View.page.rows[0].cell.tags[1]: expected type "int", got "string"', contract,
      tree.call(prop("", "int"), prop(""))
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

  private

  def contract_of(*fields)
    InstantRecord::Native::Contract.new(component: "View", fields: fields)
  end

  def field(name, kind, **options)
    InstantRecord::Native::ContractField.new(name: name, kind: kind, **options)
  end

  def scalar(name, type: "string", **options) = field(name, :scalar, type: type, **options)
  def one(name, *fields, **options) = field(name, :one, fields: fields, **options)
  def many(name, *fields, **options) = field(name, :many, fields: fields, **options)
  def many_scalar(name, type: "string", **options) = field(name, :many_scalar, type: type, **options)

  def node(kind, props = {}, children = [])
    InstantRecord::Native::Node.new(kind).tap do |node|
      node.props.merge!(props)
      node.children.concat(children)
    end
  end

  def prop(name, type = "string") = node("prop", { "name" => name, "type" => type })
  def record(name, *children) = node("record", { "name" => name }, children)
  def list(name, *children) = node("props", { "name" => name }, children)

  def assert_valid(contract, *children)
    assert_nil validation_error(contract, children)
  end

  def assert_contract_error(message, contract, *children)
    error = validation_error(contract, children)
    assert_instance_of InstantRecord::Native::ContractError, error
    assert_equal message, error.message
  end

  def validation_error(contract, children)
    contract.validate!(node("swift", {}, children))
    nil
  rescue InstantRecord::Native::ContractError => error
    error
  end
end
