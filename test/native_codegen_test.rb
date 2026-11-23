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
