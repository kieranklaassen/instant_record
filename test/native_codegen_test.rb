require "test_helper"
require "instant_record/compiler"
require "open3"
require "tmpdir"

class NativeCodegenTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("..", __dir__)

  SAMPLE_SCREEN = <<~RUBY
    class OrderScreen < InstantRecord::Native::Screen
      contract "OrderCard" do |c|
        c.string :title
        c.int :item_count
        c.float :total_amount
        c.bool :paid
        c.date :placed_at
        c.string :class, optional: true
        c.one :customer do |customer|
          customer.string :display_name
          customer.bool :vip
        end
        c.many :line_items, as: "LineItem" do |item|
          item.string :sku
          item.int :qty
        end
        c.many :tags, of: :string
        c.action :mark_paid
        c.action :refund do |a|
          a.arg :order_id, :string
          a.arg :amount, :float
          a.value :reason, :string, optional: true
        end
      end

      def body; end
    end
  RUBY

  test "Prism extracts typed prop and action contracts statically without evaluating Ruby" do
    contracts = InstantRecord::Compiler::NativeContracts.extract_source(SAMPLE_SCREEN, path: "app/screens/order_screen.rb")
    assert_equal 1, contracts.size

    contract = contracts.first
    assert_equal "OrderCard", contract.component
    assert_equal "OrderScreen", contract.screen
    assert_equal %w[title item_count total_amount paid placed_at class customer line_items tags], contract.fields.map(&:name)
    assert_equal %w[mark_paid refund], contract.actions.map(&:name)

    refund = contract.actions.last
    assert_equal [%w[order_id string arg false], %w[amount float arg false], %w[reason string value true]],
      refund.params.map { |p| [p.name, p.type, p.slot.to_s, p.optional?.to_s] }
  end

  test "Prism extractor rejects syntax errors, dynamic names, unknown types, and duplicate contracts with file and line" do
    err = assert_raises(InstantRecord::Compiler::BuildError) do
      InstantRecord::Compiler::NativeContracts.extract_source("class Bad < Screen\n  contract foo do |c|\n  end\nend\n", path: "app/screens/bad_screen.rb")
    end
    assert_match(%r{app/screens/bad_screen\.rb:2:.*component name must be a string or symbol literal}, err.message)

    err = assert_raises(InstantRecord::Compiler::BuildError) do
      InstantRecord::Compiler::NativeContracts.extract_source("class Bad < Screen\n  contract \"Ok\" do |c|\n    c.prop :x, :bogus\n  end\nend\n", path: "app/screens/bad_screen.rb")
    end
    assert_match(%r{app/screens/bad_screen\.rb:3:.*Unknown contract type}, err.message)

    err = assert_raises(InstantRecord::Compiler::BuildError) do
      InstantRecord::Compiler::NativeContracts.extract_source("class Broken < Screen\n  def (\nend\n", path: "app/screens/broken_screen.rb")
    end
    assert_match(%r{app/screens/broken_screen\.rb:}, err.message)

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a_screen.rb"), "class AScreen < InstantRecord::Native::Screen\n  contract \"Dup\" do |c|\n    c.string :x\n  end\nend\n")
      File.write(File.join(dir, "b_screen.rb"), "class BScreen < InstantRecord::Native::Screen\n  contract \"Dup\" do |c|\n    c.string :y\n  end\nend\n")
      err = assert_raises(InstantRecord::Compiler::BuildError) { InstantRecord::Compiler::NativeContracts.extract_dir(dir) }
      assert_match(/Duplicate native contract "Dup"/, err.message)
    end
  end

  test "SwiftCodegen emits Codable structs, CodingKeys, NativeAction enums, keyword escaping, and @Observable state" do
    contracts = InstantRecord::Compiler::NativeContracts.extract_source(SAMPLE_SCREEN)
    swift = InstantRecord::Compiler::SwiftCodegen.generate(contracts)

    assert_includes swift, "public struct OrderCardProps: NativeProps, Codable, Equatable, Sendable"
    assert_includes swift, "public typealias Action = OrderCardAction"
    assert_includes swift, 'public static let componentName = "OrderCard"'
    assert_includes swift, "public struct Customer: Codable, Equatable, Sendable"
    assert_includes swift, "public struct LineItem: Codable, Equatable, Sendable"
    assert_includes swift, "public let itemCount: Int"
    assert_includes swift, "public let totalAmount: Double"
    assert_includes swift, "public let placedAt: Date"
    assert_includes swift, "public let `class`: String?"
    assert_includes swift, "public let tags: [String]"
    assert_includes swift, 'case itemCount = "item_count"'
    assert_includes swift, "case `class`"
    assert_includes swift, "public enum OrderCardAction: NativeAction, Equatable, Sendable"
    assert_includes swift, "case markPaid"
    assert_includes swift, "case refund(orderId: String, amount: Double, reason: String?)"
    assert_includes swift, 'case .markPaid: "mark_paid"'
    assert_includes swift, 'NativeWire.encode(amount)'
    assert_includes swift, "@Observable\npublic final class OrderCardState: NativePropsState"
    assert_includes swift, "public func apply(_ props: OrderCardProps)"
    assert_includes swift, "public func send(_ action: OrderCardAction)"
  end

  test "KotlinCodegen emits @Serializable data classes, @SerialName annotations, and sealed action interfaces" do
    contracts = InstantRecord::Compiler::NativeContracts.extract_source(SAMPLE_SCREEN)
    kotlin = InstantRecord::Compiler::KotlinCodegen.generate(contracts, package: "com.acme.app")

    assert_includes kotlin, "package com.acme.app"
    assert_includes kotlin, "import kotlinx.serialization.SerialName"
    assert_includes kotlin, "import kotlinx.serialization.Serializable"
    assert_includes kotlin, "data class OrderCardProps("
    assert_includes kotlin, '@SerialName("item_count") val itemCount: Int,'
    assert_includes kotlin, "val `class`: String? = null,"
    assert_includes kotlin, "val lineItems: List<LineItem>,"
    assert_includes kotlin, "val tags: List<String>,"
    assert_includes kotlin, 'const val COMPONENT_NAME: String = "OrderCard"'
    assert_includes kotlin, "sealed interface OrderCardAction"
    assert_includes kotlin, "data object MarkPaid : OrderCardAction"
    assert_includes kotlin, "data class Refund("
    assert_includes kotlin, 'override val actionName: String = "refund"'
    assert_includes kotlin, 'reason?.let { put("reason", it) }'

    plain = InstantRecord::Compiler::KotlinCodegen.generate(contracts, package: "com.acme.app", serializable: false)
    refute_includes plain, "@Serializable"
    refute_includes plain, "@SerialName"
  end

  test "CodegenNaming and SwiftCodegen share inflection, nested naming, and escaping rules" do
    naming = InstantRecord::Compiler::CodegenNaming
    swift = InstantRecord::Compiler::SwiftCodegen
    kotlin = InstantRecord::Compiler::KotlinCodegen

    {
      "categories" => "category",
      "boxes" => "box",
      "dishes" => "dish",
      "matches" => "match",
      "buzzes" => "buzz",
      "glasses" => "glass",
      "people" => "person",
      "children" => "child",
      "items" => "item",
      "data" => "data_item",
      "glass" => "glass_item",
      "a" => "a_item"
    }.each do |plural, singular|
      assert_equal singular, naming.singularize(plural)
      assert_equal singular, swift.singularize(plural)
    end

    assert_equal "itemCount", swift.camel_case("item_count")
    assert_equal "ItemCount", swift.pascal_case("item_count")

    inferred = InstantRecord::Native::ContractField.new(name: "categories", kind: :many, fields: [])
    overridden = InstantRecord::Native::ContractField.new(name: "line_items", kind: :many, type_name: "LineItem", fields: [])
    single = InstantRecord::Native::ContractField.new(name: "billing_address", kind: :one, fields: [])

    assert_equal "Category", swift.nested_type_name(inferred)
    assert_equal "LineItem", swift.nested_type_name(overridden)
    assert_equal "BillingAddress", swift.nested_type_name(single)

    assert_equal '"a\\"b\\n\\r\\t$100"', swift.swift_string("a\"b\n\r\t$100")
    assert_equal '"a\\"b\\n\\r\\t\\$100 \\${name}"', kotlin.kotlin_string("a\"b\n\r\t$100 ${name}")
  end

  test "CodegenNaming.escape_string, SwiftCodegen, and KotlinCodegen escape backslashes, quotes, control chars, and interpolations" do
    naming = InstantRecord::Compiler::CodegenNaming
    swift = InstantRecord::Compiler::SwiftCodegen
    kotlin = InstantRecord::Compiler::KotlinCodegen

    assert_equal 'a\\\\b', naming.escape_string('a\b')
    assert_equal 'a\\\\', naming.escape_string('a\\')
    assert_equal '\\\\(x)', naming.escape_string('\(x)')
    assert_equal 'a\\\\\\"b\\n\\r\\t', naming.escape_string("a\\\"b\n\r\t")
    assert_equal '\\\\n', naming.escape_string('\n')

    assert_equal '"a\\\\b"', swift.swift_string('a\b')
    assert_equal '"a\\\\"', swift.swift_string('a\\')
    assert_equal '"\\\\(x)"', swift.swift_string('\(x)')
    assert_equal '"a\\"b\\n\\r\\t"', swift.swift_string("a\"b\n\r\t")
    assert_equal '"a\\\\\\"b"', swift.swift_string('a\"b')

    assert_equal '"a\\\\b"', kotlin.kotlin_string('a\b')
    assert_equal '"a\\\\"', kotlin.kotlin_string('a\\')
    assert_equal '"\\\\(x)"', kotlin.kotlin_string('\(x)')
    assert_equal '"a\\"b\\n\\r\\t"', kotlin.kotlin_string("a\"b\n\r\t")
    assert_equal '"\\$100 \\${name}"', kotlin.kotlin_string('$100 ${name}')
    assert_equal '"\\\\\\$100 \\\\\\${name}"', kotlin.kotlin_string('\$100 \${name}')
  end

  test "SwiftCodegen handles snapshot collision, keyword state storage, optional action params, and empty contracts" do
    contracts = [
      InstantRecord::Native::Contract.new(
        component: "EdgeView",
        fields: [
          InstantRecord::Native::ContractField.new(name: "snapshot", kind: :scalar, type: "string"),
          InstantRecord::Native::ContractField.new(name: "default", kind: :scalar, type: "int"),
          InstantRecord::Native::ContractField.new(name: "class", kind: :scalar, type: "string", optional: true)
        ],
        actions: [
          InstantRecord::Native::ContractAction.new(
            name: "default",
            params: [
              InstantRecord::Native::ActionParam.new(name: "target_id", type: "string", slot: :arg),
              InstantRecord::Native::ActionParam.new(name: "retry_count", type: "int", slot: :arg, optional: true),
              InstantRecord::Native::ActionParam.new(name: "active", type: "bool", slot: :value)
            ]
          )
        ]
      ),
      InstantRecord::Native::Contract.new(component: "EmptyView", fields: [], actions: [])
    ]

    swift = InstantRecord::Compiler::SwiftCodegen.generate(contracts)

    assert_includes swift, "public private(set) var snapshot: String"
    assert_includes swift, "public private(set) var _snapshot: EdgeViewProps"
    assert_includes swift, "guard self._snapshot != props else { return }"
    assert_includes swift, "self._snapshot = props"

    assert_includes swift, "private var _defaultValue: Int"
    assert_includes swift, "public var `default`: Int { _defaultValue }"
    assert_includes swift, "self._defaultValue = props.`default`"
    assert_includes swift, "if self._defaultValue != props.`default` { self._defaultValue = props.`default` }"
    assert_includes swift, "private var _classValue: String?"
    assert_includes swift, "public var `class`: String? { _classValue }"

    assert_includes swift, "case .`default`(let targetId, let retryCount, _):"
    assert_includes swift, 'out["target_id"] = targetId'
    assert_includes swift, 'if let retryCount { out["retry_count"] = NativeWire.encode(retryCount) }'
    assert_includes swift, 'case .`default`(_, _, let active): return ["active": NativeWire.encode(active)]'

    assert_includes swift, "public struct EmptyViewProps: NativeProps, Codable, Equatable, Sendable {\n    public static let componentName = \"EmptyView\"\n\n    public init() {}\n}"
    refute_includes swift, "EmptyViewAction"
    refute_includes swift, "CodingKeys"
  end

  test "KotlinCodegen handles keyword collisions, SerialName import scoping, empty classes, and action maps" do
    plain_contract = InstantRecord::Native::Contract.new(
      component: "PlainCard",
      fields: [
        InstantRecord::Native::ContractField.new(name: "object", kind: :scalar, type: "string"),
        InstantRecord::Native::ContractField.new(name: "when", kind: :scalar, type: "int", optional: true)
      ],
      actions: [
        InstantRecord::Native::ContractAction.new(
          name: "submit_form",
          params: [
            InstantRecord::Native::ActionParam.new(name: "object", type: "string", slot: :arg),
            InstantRecord::Native::ActionParam.new(name: "count", type: "int", slot: :arg),
            InstantRecord::Native::ActionParam.new(name: "when", type: "bool", slot: :value, optional: true),
            InstantRecord::Native::ActionParam.new(name: "note", type: "string", slot: :value)
          ]
        )
      ]
    )

    plain_kt = InstantRecord::Compiler::KotlinCodegen.generate([plain_contract])
    refute_includes plain_kt, "import kotlinx.serialization.SerialName"
    assert_includes plain_kt, "import kotlinx.serialization.Serializable"
    assert_includes plain_kt, "val `object`: String,"
    assert_includes plain_kt, "val `when`: Int? = null,"
    assert_includes plain_kt, 'override val actionArgs: Map<String, String> = mapOf("object" to `object`, "count" to count.toString())'
    assert_includes plain_kt, '`when`?.let { put("when", it.toString()) }'
    assert_includes plain_kt, 'put("note", note)'

    nested_and_empty = [
      InstantRecord::Native::Contract.new(
        component: "NestedSnake",
        fields: [
          InstantRecord::Native::ContractField.new(
            name: "meta",
            kind: :one,
            fields: [
              InstantRecord::Native::ContractField.new(name: "updated_at", kind: :scalar, type: "date"),
              InstantRecord::Native::ContractField.new(name: "empty", kind: :one, fields: [])
            ]
          )
        ],
        actions: []
      ),
      InstantRecord::Native::Contract.new(component: "EmptyCard", fields: [], actions: [])
    ]

    nested_kt = InstantRecord::Compiler::KotlinCodegen.generate(nested_and_empty)
    assert_includes nested_kt, "import kotlinx.serialization.SerialName"
    assert_includes nested_kt, '@SerialName("updated_at") val updatedAt: String,'
    assert_includes nested_kt, "        @Serializable\n        class Empty\n"
    assert_includes nested_kt, "class EmptyCardProps {\n    companion object {"
    refute_includes nested_kt, "sealed interface EmptyCardAction"
  end

  test "SwiftCodegen and KotlinCodegen produce deterministic byte-for-byte output" do
    contracts = InstantRecord::Compiler::NativeContracts.extract_dir(File.join(GEM_ROOT, "demo/app/screens"))

    swift_first = InstantRecord::Compiler::SwiftCodegen.generate(contracts)
    swift_second = InstantRecord::Compiler::SwiftCodegen.generate(contracts)
    assert_equal swift_first, swift_second

    kotlin_first = InstantRecord::Compiler::KotlinCodegen.generate(contracts)
    kotlin_second = InstantRecord::Compiler::KotlinCodegen.generate(contracts)
    assert_equal kotlin_first, kotlin_second
  end

  test "KotlinCodegen can be required standalone without loading SwiftCodegen" do
    ruby = RbConfig.ruby
    script = <<~RUBY
      contract = InstantRecord::Native::Contract.new(
        component: "StandaloneCard",
        fields: [InstantRecord::Native::ContractField.new(name: "item_count", kind: :scalar, type: "int")]
      )
      kotlin = InstantRecord::Compiler::KotlinCodegen.generate([contract])
      print [defined?(InstantRecord::Compiler::SwiftCodegen).nil?, kotlin.include?("val itemCount: Int")].join(",")
    RUBY
    out, status = Open3.capture2e(
      ruby, "-I#{File.join(GEM_ROOT, 'lib')}",
      "-rinstant_record/native",
      "-rinstant_record/compiler/kotlin_codegen",
      "-e", script
    )
    assert status.success?, "standalone load failed:\n#{out}"
    assert_equal "true,true", out
  end

  test "the demo Inbox app's InstantRecordContracts.swift matches Prism codegen from demo/app/screens" do
    contracts = InstantRecord::Compiler::NativeContracts.extract_dir(File.join(GEM_ROOT, "demo/app/screens"))
    assert_equal %w[ConversationView InboxSummary], contracts.map(&:component)

    expected = InstantRecord::Compiler::SwiftCodegen.generate(contracts)
    committed = File.read(File.join(GEM_ROOT, "native/ios/Inbox/Inbox/InstantRecordContracts.swift"))
    assert_equal expected, committed, "Regenerate native/ios/Inbox/Inbox/InstantRecordContracts.swift from demo/app/screens"
  end

  test "generated Swift contracts compile cleanly against InstantRecordNative when swift is installed" do
    swift_bin = InstantRecord::Compiler::Toolchain.which("swift")
    skip "swift toolchain not installed" unless swift_bin

    package_dir = File.join(GEM_ROOT, "native/ios/InstantRecordNative")
    build_log, status = Open3.capture2e(swift_bin, "build", "--package-path", package_dir)
    assert status.success?, "swift build failed:\n#{build_log}"

    bin_path, status = Open3.capture2(swift_bin, "build", "--package-path", package_dir, "--show-bin-path")
    assert status.success?
    modules_dir = File.join(bin_path.strip, "Modules")
    modules_dir = bin_path.strip unless File.directory?(modules_dir)

    Dir.mktmpdir do |dir|
      sample_swift = File.join(dir, "SampleContracts.swift")
      contracts = InstantRecord::Compiler::NativeContracts.extract_source(SAMPLE_SCREEN)
      File.write(sample_swift, InstantRecord::Compiler::SwiftCodegen.generate(contracts))

      demo_contracts = File.join(GEM_ROOT, "native/ios/Inbox/Inbox/InstantRecordContracts.swift")
      inbox_summary = File.join(GEM_ROOT, "native/ios/Inbox/Inbox/InboxSummary.swift")
      swiftc = InstantRecord::Compiler::Toolchain.which("swiftc")
      out, st = Open3.capture2e(swiftc, "-typecheck", "-I", modules_dir, "-I", bin_path.strip, sample_swift, demo_contracts, inbox_summary)
      assert st.success?, "swiftc -typecheck failed on generated contracts:\n#{out}"
    end
  end
end
