require "test_helper"

class RuntimeScopedTest < Minitest::Test
  def with_browser(value, &block)
    InstantRecord.singleton_class.class_eval do
      alias_method :original_browser?, :browser?
      define_method(:browser?) { value }
    end
    block.call
  ensure
    InstantRecord.singleton_class.class_eval do
      remove_method :browser?
      alias_method :browser?, :original_browser?
      remove_method :original_browser?
    end
  end

  def build_class
    Class.new do
      extend InstantRecord::RuntimeScoped

      server_only do
        def self.server_rule = "server"
      end

      browser_only do
        def self.browser_rule = "browser"
      end
    end
  end

  def test_server_runtime_gets_only_server_blocks
    klass = with_browser(false) { build_class }

    assert_equal "server", klass.server_rule
    refute_respond_to klass, :browser_rule
  end

  def test_browser_runtime_gets_only_browser_blocks
    klass = with_browser(true) { build_class }

    assert_equal "browser", klass.browser_rule
    refute_respond_to klass, :server_rule
  end

  def test_syncable_models_get_the_dsl_automatically
    with_browser(false) do
      model = Class.new(ActiveRecord::Base) do
        self.table_name = "widgets"
        def self.name = "Widget"
        include InstantRecord::Syncable
      end

      assert_respond_to model, :server_only
      assert_respond_to model, :browser_only
    end
  end
end
